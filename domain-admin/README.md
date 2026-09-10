# homelab-domain-admin

DNS + mail-domain administration for the `homelab-*` ecosystem — "what
domains are we authoritative for, and what is their DKIM/mail-routing
state" as one cohesive concern, fronted by `homelab-api`'s
`/api/v1/domains/*` gateway route the same way `homelab-mailbridge`
backs `/api/v1/mail/*`. See the repo root `CLAUDE.md` and the approved
plan this package implements for the full design discussion (single
consolidated package vs. extending `dns`/`postfix` in place, and why).

This first release covers domain metadata + DNS zone/record CRUD. DKIM
key generation/rotation and per-recipient mail allow/block land in
later releases — their schema already exists (see Data model below) so
the install-ordering story for `homelab-postfix` doesn't shift under it
later.

## Deployment topology

**Must be installed on the same host as `homelab-postfix`/OpenDKIM.**
DKIM private key material (generated in a later release) is read from
local disk only and must never cross a network — this service cannot
run remotely from the OpenDKIM install it will manage. It reaches
PowerDNS over the network via PowerDNS's own HTTP API (public zone data
only) and `homelab-api` for auth (bearer tokens only) — both fine to
call remotely. On `test-static-internet-ip` (currently single-host)
this is automatic.

## Talking to PowerDNS

Via PowerDNS's own built-in HTTP API (`webserver`/`api` settings), not a
direct grant on the separate `powerdns` database and not `pdnsutil`:
the vendor's own purpose-built automation interface, correct SOA-serial
and NOTIFY handling for free, and it avoids a second ad-hoc exception to
this project's "one shared `homelab` DB" convention (`homelab-dns`
already establishes the first one — PowerDNS keeping its own separate
database — deliberately; this package doesn't need a second).

This package's own postinst enables that API via an additive drop-in
into the *same* `/etc/powerdns/pdns.d/` directory `homelab-dns` already
owns (`95-homelab-domain-admin-api.conf`, bound to `127.0.0.1` only,
with a random API key) — the same class of cross-package-but-same-
directory write `homelab-postfix` already does into Dovecot's
`conf.d/`. Skipped gracefully if PowerDNS isn't installed yet
(`Recommends: homelab-dns`, not `Depends:` — a domain can have
`dns_managed=false`, and this package can be installed before
`homelab-dns` is).

### PowerDNS restart debounce

PowerDNS caches its zone list at process **start**. Creating a
brand-new zone, or a brand-new record *name* within an already-served
zone, does not become servable until `systemctl restart pdns` — there
is no reload path for this daemon at all (confirmed empirically,
documented in `../dns/README.md`). Existing names' record *values*
update live through the gpgsql backend, no restart needed.

Every write that can introduce a new zone or new name marks
`domainadmin.pending_restart` (a single-row upsert); a recurring timer
in `Homelab::DomainAdmin::App` restarts `pdns` ~10 seconds after the
last such write settles, so one composite "add domain + zone + record"
operation collapses into a single restart rather than several. Claimed
via `SELECT ... FOR UPDATE SKIP LOCKED`, so a multi-worker hypnotoad
process never races two workers into restarting `pdns` at once. Record/
zone *deletion* is treated the same as an add (restarts too) — the
documented gotcha only confirms the add case, so this stays conservative
until proven otherwise. Every write response includes
`restart_pending: true/false` so a caller knows whether the change is
resolvable yet.

This requires a narrow, explicit `sudoers.d/homelab-domain-admin` grant
(`homelab ALL=(root) NOPASSWD: /usr/bin/systemctl restart pdns,
/usr/bin/systemctl reload opendkim, /usr/bin/systemctl restart
opendkim` — the `opendkim` commands are unused until DKIM lands but
granted now since it's one static file), `visudo -c` validated by
postinst before being installed. New privilege surface, worth a
dedicated look next time `/security-review` runs against this repo.

## Data model

New schema `domainadmin` in the shared `homelab` database (own
`_runtime`/`_migrate` role pair via `homelab-bootstrap-app-role`, same
split-role pattern as every other feature — see `../CLAUDE.md`):

- `domainadmin.domains` — the anchor table. `dns_managed` records
  whether *this ecosystem* is responsible for the zone existing; it
  never duplicates zone content (PowerDNS's own `domains`/`records`,
  in its own separate database, stay the single source of truth for
  that). `mail_enabled` is what `homelab-postfix`'s live domain lookup
  will query once it's wired up.
- `domainadmin.dkim_selectors` — DKIM rotation state machine, unused
  until a later release. **No private key column, deliberately**: a
  DKIM private key must exist on the OpenDKIM host's disk regardless of
  anything else (that's how OpenDKIM reads it), so a second copy in
  this shared, `pg_dump`-backed database would only add a single
  high-value target without removing that requirement. Only the public
  key, selector, state, and timestamps are ever stored here.
- `domainadmin.recipient_access` — per-recipient mail allow/block,
  unused until a later release.
- `domainadmin.pending_restart` — the debounce table described above.

## API

Internal routes are `/internal/v1/...` — deliberately a *different*
namespace than the gateway's client-facing `/api/v1/domains/...` (the
same distinction `strip_prefix`/`backend_prefix` exists to manage
elsewhere), since this service's own API might reasonably be called by
something other than the gateway later.

```
GET    /internal/v1/domains
POST   /internal/v1/domains                          {domain_name, mail_enabled?, dns_managed?, nameservers?}
GET    /internal/v1/domains/:domain
PATCH  /internal/v1/domains/:domain                   {mail_enabled?, dns_managed?, active?}
DELETE /internal/v1/domains/:domain                   (soft: active=false, never deletes the zone)

GET    /internal/v1/domains/:domain/dns/records
POST   /internal/v1/domains/:domain/dns/records        {name, type, content, ttl?}
DELETE /internal/v1/domains/:domain/dns/records        {name, type}
```

Auth: every route requires a valid bearer token, verified via
`Homelab::Common::AuthClient::introspect()` (the `authenticated_email`
helper). Role-gating to `site_admin` specifically is a later release —
it needs `homelab-api`'s own `/api/v1/auth/introspect` response
extended with a `roles` field, which is a separate, small,
`homelab-api`-side change tracked apart from this package. Until then,
this is the same bar every other backend applies before its own
additional checks — not a gap, "verify at every hop" like everywhere
else in this ecosystem.

Gateway route added to `homelab-api` (`api/lib/Homelab/API/App.pm`):
`/api/v1/domains/*` → this service, `strip_prefix => '/api/v1/domains'`,
`backend_prefix => '/internal/v1'`.

## CLI

```bash
homelab-cli dns domains list
homelab-cli dns domains add example.org
homelab-cli dns domains add mail-only.example.org --no-dns
homelab-cli dns domains show example.org
homelab-cli dns domains enable example.org
homelab-cli dns domains disable example.org

homelab-cli dns records list example.org
homelab-cli dns records add example.org --name example.org --type A --value 203.0.113.10
homelab-cli dns records delete example.org --name example.org --type A
```

## Gotchas (real bugs found building this)

- **`:domain` route placeholders silently truncated dotted domains.**
  Mojolicious's default `:name` placeholder pattern excludes `.`
  (reserved for `:id.format`-style extension detection, e.g. a route
  ending in `:id` matching `5.json` as `id=5 format=json`) — so an
  unqualified `:domain` matched `test.forge.name` as just `test`. Every
  route embedding `:domain` in `App.pm` now has an explicit
  `[domain => qr/[^\/]+/]` override. Caught by a real `homelab-cli dns
  domains show test.forge.name` 404ing, not by inspection.
- **`dns records list` could hang indefinitely.** `Homelab::DomainAdmin::PowerDNS`'s
  `Mojo::UserAgent` now sets explicit `connect_timeout`/`request_timeout`
  values — without them, a slow or unresponsive PowerDNS API call had no
  bound at all. If this regresses, `dns records list` is the fastest way
  to notice: it should return in well under a second against a healthy
  local PowerDNS instance.
- **TXT record content needs DNS master-file quoting, not a bare
  string.** PowerDNS's API 422s an unquoted TXT value ("Data field in
  DNS should start with quote"). `PowerDNS.pm`'s `_format_record_content`
  wraps TXT/SPF content in double quotes (escaping any literal `\`/`"`
  already present) before sending it; every other record type passes
  through unchanged. Caught by a real `homelab-cli dns records add
  ... --type TXT` call — directly relevant to this package's future
  SPF/DKIM work, since both are TXT records.

## Testing

`t/basic.t` (Test::Mojo, real Postgres + a real reachable PowerDNS API —
set `HOMELAB_DOMAIN_ADMIN_CONFIG`) covers auth-required-on-every-route,
domain metadata CRUD (including the `dns_managed=false` mail-only path,
which makes zero PowerDNS calls), and a real DNS zone/record CRUD round
trip against a throwaway zone name that can never collide with a real
domain. Live end-to-end coverage against the real `test.forge.name`
domain is in `../tests/e2e/`.
