# homelab-domain-admin

DNS + mail-domain administration for the `homelab-*` ecosystem — "what
domains are we authoritative for, and what is their DKIM/mail-routing
state" as one cohesive concern, fronted by `homelab-api`'s
`/api/v1/domains/*` gateway route the same way `homelab-mailbridge`
backs `/api/v1/mail/*`. See the repo root `CLAUDE.md` and the approved
plan this package implements for the full design discussion (single
consolidated package vs. extending `dns`/`postfix` in place, and why).

This release covers domain metadata + DNS zone/record CRUD, per-recipient
mail allow/block, and the full DKIM key rotation lifecycle (this last
piece, Phase 5 of the original design, is documented in its own section
below). All three share the same `site_admin`-gated auth model.

## Deployment topology

**Must be installed on the same host as `homelab-postfix`/OpenDKIM.**
DKIM private key material is read from local disk only and must never
cross a network — this service cannot run remotely from the OpenDKIM
install it manages. It reaches
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
- `domainadmin.dkim_selectors` — DKIM rotation state machine (see the
  dedicated section below). **No private key column, deliberately**: a
  DKIM private key must exist on the OpenDKIM host's disk regardless of
  anything else (that's how OpenDKIM reads it), so a second copy in
  this shared, `pg_dump`-backed database would only add a single
  high-value target without removing that requirement. Only the public
  key, selector, state, and timestamps are ever stored here.
- `domainadmin.recipient_access` — per-recipient mail allow/block.
  `user_email` (nullable) distinguishes admin-created/global rows
  (`NULL`, the only kind before this column existed) from self-service
  rows a user created for one of their own addresses via `POST
  .../recipient-access/mine` — see "Self-service address blocking"
  below.
- `domainadmin.pending_restart` — the debounce table described above.

## DKIM key rotation

Selectors are **date + incrementing-letter** (`20260910a`, then
`20260910b` if a second rotation happens the same day), not a single
fixed selector reused forever — a fixed selector can never rotate
safely, since the moment a new key is published under the old name,
every in-flight message signed with the old key stops verifying. Each
selector moves through a state machine, one row per selector per domain
in `domainadmin.dkim_selectors`:

```
pending  --activate-->  active  --(auto, after overlap)-->  retired
   |                        |
   `--cancel (delete)       `--activate of a NEW selector--> retiring --(overlap elapses)--> retired
                                                                 |
                                                                 `--retire (break-glass)--> retired
```

- **`rotate`** generates a brand-new 2048-bit key (`opendkim-genkey`),
  publishes its public half as a DNS TXT record, and stores the row as
  `pending`. Nothing signs with it yet — a pending key existing in DNS
  before it's ever used to sign is exactly what lets a verifier resolve
  it the instant `activate` flips a live sender over, with no
  publish-then-wait race.
- **`activate`** starts signing outbound mail with this selector and,
  in the same DB transaction, demotes whichever selector was previously
  `active` (if any) to `retiring`, setting `retire_after = NOW() +
  retirement_days` (config `dkim.retirement_days`, **default 7 days**).
  During this overlap window the old selector's TXT record and key file
  both stay fully published and valid, so mail already in flight (or
  sitting in a slow queue) signed with the old key still verifies —
  this overlap is a hard requirement of the design, not a nicety: two
  selectors are simultaneously live in DNS by design during a rotation.
- A plain `Mojo::IOLoop->recurring` timer in `App.pm` (not Minion —
  this project's standing choice for lightweight periodic work, see the
  root `CLAUDE.md`) checks every 60 seconds for any `retiring` row past
  its `retire_after`, claims it with `SELECT ... FOR UPDATE OF s SKIP
  LOCKED LIMIT 1` (safe under a multi-worker hypnotoad the same way the
  PowerDNS restart debounce already is), and retires it automatically —
  removing the DNS TXT record, deleting the on-disk key files, and
  marking the row `retired`. No human action needed for the normal case.
- **`retire`** is the break-glass path: retires a selector (`active` or
  `retiring`) immediately, skipping the rest of the overlap window, for
  a suspected-compromised key. Shares its actual retirement logic
  (`_do_retire`) with the automatic timer above rather than
  duplicating it.
- **`cancel`** (DELETE) removes an in-progress, never-activated
  (`pending`) rotation outright — deletes the DNS TXT record, the key
  files, and the row itself (unlike `retire`, which keeps a historical
  `retired` row for audit purposes).

KeyTable/SigningTable (`/etc/opendkim/KeyTable`, `/etc/opendkim/
SigningTable`) are **fully rebuilt from scratch** from every
currently-`active` selector across every domain on every
activate/retire, then OpenDKIM is sent a reload (SIGHUP), not a
restart. This only matters for *signing* — verification of an inbound
signature is a pure DNS TXT lookup by the remote server, so a
`pending`/`retiring` selector correctly needs no KeyTable/SigningTable
entry at all even though its key file and TXT record both still exist;
a full rebuild is simpler and safer than incrementally patching two
flat files, and means a partially-failed previous write can never leave
a stale entry behind.

The public key is extracted straight from the private key file via
`openssl rsa -in <priv> -pubout -outform DER | openssl base64 -A`
rather than parsing `opendkim-genkey`'s own human-oriented, BIND-zone-
quoted `.txt` output — fewer moving parts, and it's the same well-known
technique used to hand-build a DKIM TXT record from any RSA key.

This depends on `homelab-postfix`'s opt-in OpenDKIM wiring (see its
own README) already being enabled on this host — DKIM rotation calls
will fail with a clear `opendkim-genkey failed` error if
`opendkim-tools` isn't installed or `/etc/opendkim/keys` isn't writable
by the `homelab` user, rather than a confusing lower-level error.

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

GET    /internal/v1/domains/:domain/dkim/selectors
POST   /internal/v1/domains/:domain/dkim/rotate
POST   /internal/v1/domains/:domain/dkim/:selector/activate
POST   /internal/v1/domains/:domain/dkim/:selector/retire
DELETE /internal/v1/domains/:domain/dkim/:selector      (cancel a still-'pending' rotation)

GET    /internal/v1/domains/recipient-access[?user=<email>]      (site_admin)
POST   /internal/v1/domains/recipient-access                     {recipient, action, reason?}  (upsert, site_admin)
DELETE /internal/v1/domains/recipient-access/:recipient          (site_admin)

GET    /internal/v1/domains/recipient-access/mine[?q=<substring>]  (self-service -- any authenticated user)
POST   /internal/v1/domains/recipient-access/mine                {recipient, action, reason?}  (upsert, self-service)
DELETE /internal/v1/domains/recipient-access/mine/:recipient     (self-service -- own rows only)
```

The `recipient-access` routes are registered *before* the `/:domain`
routes above, on purpose — an unqualified `:domain` placeholder would
otherwise greedily match the literal path segment `recipient-access`
too (Mojolicious tries routes in registration order), routing to
`domains#show` with `domain=recipient-access` instead of
`recipient_access#list`. `:recipient` needs the same dot-truncation
placeholder fix as `:domain` (a real address always has one).

Auth: every route requires a valid bearer token, verified via
`Homelab::Common::AuthClient::introspect()`, AND the `site_admin` role
specifically — both enforced in one place, the `authenticated_email`
helper in `App.pm` (403 with a clear "site_admin role required" message
if the token is valid but lacks the role). Because every route already
calls `$c->authenticated_email or return;` as its first line, this one
change gates the entire package at once — DKIM key rotation and DNS
zone edits are exactly the kind of action that shouldn't be available
to a plain authenticated user. This relies on `homelab-api`'s
`/api/v1/auth/introspect` response carrying a `roles` array (added
alongside this), so "verify at every hop" now includes "and check the
role at every hop," not just token validity.

Gateway route added to `homelab-api` (`api/lib/Homelab/API/App.pm`):
`/api/v1/domains/*` → this service, `strip_prefix => '/api/v1/domains'`,
`backend_prefix => '/internal/v1'`.

## Self-service address blocking

`/mine` (JWT-only, no `site_admin` requirement — `authenticated_email_
any` in `App.pm`, the same self-service tier `mail-aliases/mine`
already established) lets any user block/unblock/list *their own*
entries in the exact same `domainadmin.recipient_access` table/
`check_recipient_access` enforcement the admin-only routes above
already use — no new subsystem, just an ownership layer on top of
something already shipped.

**This is address blocking, not sender blocking.** `recipient_access`
was investigated as a candidate to model production Roundcube's
`recipient_blocking` plugin on — despite that plugin's name, it turned
out to reject ALL mail to one specific address a user owns, regardless
of who sends it (useful for burning a single-use masked address, e.g.
`namecheap20240520@forge.name`, once it starts getting spammed) — not
a per-sender block. `check_recipient_access` already matches this
exactly: it's keyed purely on the real SMTP `RCPT TO` Postfix received
(never a parsed `To:`/`Cc:` header, which is attacker-controlled,
unverified text), evaluated once per `RCPT TO`, so a multi-recipient
message is judged correctly per-recipient with no extra design needed.

Two guards run in `RecipientAccess::create_mine` before every upsert,
both hard rejections (400/403), not warnings:

- **Ownership** (`_owns_recipient`) — `recipient` must be the caller's
  own login address, or covered by a `domainadmin.mail_aliases` grant
  where `destination` is the caller (exact-address grant, or the
  recipient's domain matches a catch-all `@domain` grant of theirs) —
  same resolution `MailAliases::mine` already computes for listing,
  reused here as a boolean check. Anything else is a 403.
- **Self-block** (`_is_own_exact_address`) — rejects (400) blocking the
  caller's own login address, or an *exact* (non-catch-all) mail_alias
  address that routes to them. `recipient_access` is blanket — it
  rejects mail from every sender — so blocking your own address would
  permanently cut off ALL mail there, including anything account/
  security-related, not just spam. A catch-all *domain* grant they own
  is never rejected by this guard: there's no single address at risk
  in `@forge.name` itself, only in a specific address under it, which
  the guard independently catches the moment THAT address is the one
  being blocked.

Production's own equivalent plugin (`recipient_blocking.php`) opens a
*second*, separate raw DB connection straight from Roundcube's
web-facing PHP, using the same shared `dovecot_user` credential
Postfix/Dovecot's own services use — no API layer, no scoped role, no
audit boundary beyond whatever that PHP code happens to check. This
design deliberately does not repeat that: every self-service block
goes through this service's existing narrow Postgres role and JWT
auth, the same as every other write in this codebase.

`pgsql-recipient-access.cf.template` (in `../postfix/config/`) also
now appends `reason` to `action` in its query response (`REJECT no
longer accepting mail here` instead of a bare `REJECT`), so a rejected
sender actually sees why — the column was always stored but never
reached Postfix before this.

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

homelab-cli dns dkim list example.org
homelab-cli dns dkim rotate example.org
homelab-cli dns dkim activate example.org 20260910a
homelab-cli dns dkim retire example.org 20260910a

homelab-cli dns recipient-access list
homelab-cli dns recipient-access block bad@example.org --reason spam
homelab-cli dns recipient-access allow vip@example.org
homelab-cli dns recipient-access remove bad@example.org

homelab-cli mail block someone@your-domain.org --reason "no longer active"
homelab-cli mail unblock someone@your-domain.org
homelab-cli mail blocked [--search someone]
```

`mail block`/`unblock`/`blocked` are the self-service counterpart to
`dns recipient-access` above — same table, same enforcement, scoped to
the caller's own addresses only (see "Self-service address blocking").

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
- **A literal route segment can lose to an earlier catch-all
  placeholder.** `/internal/v1/domains/recipient-access` needed its
  routes registered *before* `/internal/v1/domains/:domain` — Mojolicious
  matches routes in registration order, so the placeholder would
  otherwise have matched the literal segment first. Worth remembering
  for any future route added under `/domains/`.
- **`subprocess.run(["ssh", host, "cmd", "arg with spaces"])` doesn't
  survive the trip.** OpenSSH joins every trailing argv element with a
  plain space and hands the whole thing to the remote shell as one
  string to re-tokenize — a space inside one Python-side argument
  silently becomes two words on the far side. Caught by
  `tests/e2e/test_postfix_mail.py`'s own new recipient-access test
  (a `--reason "e2e test"` argument), not by inspection — same root
  cause already documented in `postfix/script/homelab-postfix-bootstrap-role`'s
  comments, now bitten a second time in test code instead of shipped
  code. `shlex.quote()` each piece, or join into one pre-quoted command
  string, when a remote CLI argument might contain whitespace.
- **OpenDKIM's `RequireSafeKeys` check rejects every signing attempt
  under this design, unconditionally, not as an edge case.** OpenDKIM
  refuses to sign with a key if it considers the key file's group
  membership insecure — and the `opendkim` daemon account's own primary
  group already *is* `opendkim`, with `homelab` (this package's service
  account, needing write access to generate/rotate keys) added as a
  second, deliberate member of that same group. Two members is already
  "multiple users" to this check, so it fires on every single signing
  attempt, not just some hypothetical loosely-shared directory. Caught
  by a real `homelab-cli dns dkim rotate` → real send, which came back
  "key data is not secure: root is in group ... which has multiple
  users". Fixed with `RequireSafeKeys no` in
  `postfix/config/opendkim.conf.template` — see that file's own comment
  and `postfix/README.md` for why this is the correct call here, not an
  unconsidered weakening.
- **A new debian/rules template needs its own explicit `install -D`
  line, or postinst fails at runtime, not at build time.** Adding
  `opendkim.conf.template` to `postfix/config/` without also adding the
  matching `install -D` line in `postfix/debian/rules` built a `.deb`
  that looked fine but failed with `install: No such file or directory`
  the moment postinst tried to install it on a real host with DKIM
  enabled — the build itself never checks that every file under
  `config/` has a matching install line. Worth double-checking this
  file whenever a new config template is added to any package in this
  repo, not just this one.
- **`Mail::DKIM::Verifier->load($fh)` silently returned `Result: none`
  on a real Maildir-stored message** during manual signature
  verification — no error, just a useless result, despite the message
  genuinely being signed. The fix was reading the message line-by-line
  and normalizing each line to CRLF (`$line =~ s/\r?\n$/\r\n/`) before
  feeding it through the `PRINT`/`CLOSE` streaming interface instead —
  DKIM canonicalization is CRLF-based per RFC 6376, and a Maildir's
  bare-LF line endings apparently defeat the simpler `load()` interface
  silently rather than erroring. Not this package's code (this was
  ad hoc verification tooling used to confirm the real rotate/activate
  cycle actually produces valid signatures), but worth keeping in mind
  for any future DKIM-verification tooling in this repo.

## Testing

`t/basic.t` (Test::Mojo, real Postgres + a real reachable PowerDNS API —
set `HOMELAB_DOMAIN_ADMIN_CONFIG`) covers auth-required-on-every-route,
`site_admin`-required-on-every-route (a plain authenticated token gets
403), domain metadata CRUD (including the `dns_managed=false` mail-only
path, which makes zero PowerDNS calls), a real DNS zone/record CRUD
round trip against a throwaway zone name that can never collide with a
real domain, and a full DKIM lifecycle round trip against a throwaway
`.invalid` zone (rotate twice, activate the first then the second —
confirming the first is correctly demoted to `retiring` with a real
`retire_after` timestamp — force-retire, then confirm both a 409 on
retiring an already-retired selector and a 404 on a nonexistent one).

Beyond the automated suite, the full DKIM lifecycle was also manually
verified end-to-end against the real `test.forge.name` domain with
actual cryptographic signature checking (`Mail::DKIM::Verifier`, not
just HTTP status codes): rotate → activate → send a real email → verify
`Result: pass`; rotate a second selector → activate it (demoting the
first to `retiring` with `retire_after` seven days out) → confirm the
*first* email, sent before the rotation, still verifies `pass` during
the overlap window → confirm a *new* email is signed with the new
selector → force-retire the old selector via the CLI → confirm via an
external `dig` that its TXT record is gone and via the on-disk key
directory that only the new selector's key files remain. Live
end-to-end coverage against the real `test.forge.name` domain is in
`../tests/e2e/`.
