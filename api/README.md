# homelab-api

Identity/auth/RBAC and the service registry for the `homelab-*`
ecosystem — and, deliberately, a **public-facing API product**, not
just an internal implementation detail other features happen to share.

## Two different clients, two different trust models

- **Browser apps** (`homelab-drive`, `homelab-roundcube`) never expose
  this API directly to a browser — they proxy login server-side and
  hold the resulting token in their own HttpOnly session cookie (the
  BFF pattern). That's about *where a bearer token lives*: a browser
  page running arbitrary/third-party JS is a bad place for one (XSS),
  so it never gets one at all.
- **Everything else** — `homelab-cli`, or anyone's own scripts calling
  this API directly — has a completely different trust model. A token
  sitting in a local CLI config file (`~/.config/homelab-cli/
  session.yml`, mode 0600) is the normal, standard pattern (the same
  thing `gh`, `aws`, `kubectl` all do). This is *why* the API is public:
  a CLI running on someone's own laptop needs a real network endpoint to
  call, not just a loopback address only reachable from this host.
  `homelab-cli login <email>` already stores the token exactly this way.

Both are correct simultaneously — one isn't a workaround for the other.

## Hardening for being public

- **Instant session revocation** (`migrations/005-sessions.sql`): every
  JWT carries a `jti` tied to a row in `api.sessions`; `/auth/introspect`
  checks it on every call. Without this, a JWT stayed valid on pure
  signature+expiry grounds for up to its own `expiry_seconds` (~30min)
  regardless of `/auth/logout` — now logout is immediate, which is also
  the actual foundation real SSO logout depends on (see `../sso/README.md`
  once that exists).
- **Per-IP rate limiting** (`migrations/006-login-attempts.sql`): 10
  failed attempts / 15 minutes on `/auth/login` and `/auth/register`,
  429 beyond that. Backed by a real table, not app log lines, so a
  future abuse-detection tool can run a normal SQL query
  (`SELECT ip, count(*) FROM api.login_attempts WHERE success = false
  AND attempted_at > now() - interval '1 hour' GROUP BY ip HAVING
  count(*) > 20`) instead of scraping journald. This project's own
  eventual "bad-ips"-style integration is out of scope here — this table
  is just the data it would need.
- **Requires `MOJO_REVERSE_PROXY=1`** (set in `systemd/
  homelab-api.service`) once `homelab-webproxy` fronts this service —
  homelab-api only ever listens on `127.0.0.1`, so the only thing that
  can reach it directly is the reverse proxy on the same host; without
  this env var every request looks like it came from `127.0.0.1` and
  the rate limiter throttles the whole service as a single client
  instead of per attacker.

## Exposing it

Add an entry to `homelab-webproxy`'s `sites.yml` (see
`webproxy/config/sites.example.yml`) pointing `api.<domain>` at
`127.0.0.1:3000`, same as any other upstream — homelab-webproxy doesn't
need to know or care that this one issues credentials instead of
serving a webmail UI.

## `/api/v1/auth/introspect` carries the caller's roles

`_introspect` returns `{email, exp, roles}` — `roles` is a plain array
of role names (e.g. `["user"]` or `["user", "site_admin"]`), joined
straight from `api.user_roles`/`api.roles` by email at introspect time,
not baked into the JWT itself (so a role grant/revoke takes effect on
the caller's very next request, no re-login needed — same "verify at
every hop, live" property the rest of this app already has). Added so
that a downstream backend behind the gateway (`homelab-domain-admin`
being the first consumer — see `../domain-admin/README.md`) can enforce
its own role gate after `introspect()` without needing a second,
separate lookup of its own; every backend forwards the caller's
`Authorization` header unchanged and calls `introspect()` itself, so
this field is available anywhere in the ecosystem the same way `email`
and `exp` already were.

## Admin endpoints (site_admin role required)

`GET /api/v1/admin/users` (list every user with their granted role
names), `POST /api/v1/admin/users/:id/roles` (`{role: "..."}`, granting
an unknown role name 400s rather than silently no-op'ing), `DELETE
/api/v1/admin/users/:id/roles/:role` — gated by a hardcoded `site_admin`
role check (`_require_site_admin`), not a separate permissions table
(see `migrations/003-rbac.sql`'s own comment on why: a bad row edit in a
permissions table could lock every admin out at once). There's no
self-service "become the first admin" endpoint by design — the first
`site_admin` grant is always a direct SQL insert into `api.user_roles`,
same as `test-admin@test.mailmasker.org` was granted. This is what
`homelab-cli admin` talks to.

## Client-facing gateway (`/api/v1/drive/*`, `/api/v1/mail/*`, `/api/v1/domains/*`)

**This app is the only address a client (`homelab-cli`, or any
third-party script) ever needs** — like Shopify's API or GitHub's SSH
interface, not a "know every feature's own address" design. Added
2026-09-09 after exactly that complaint: the CLI briefly needed 6
separate addresses (one per feature) before this existed.

`/api/v1/drive/*`, `/api/v1/mail/*`, and `/api/v1/domains/*` forward the
request (method, path, query, `Authorization` header, body — including
real multipart file uploads) to `homelab-drive`, `homelab-mailbridge`,
and `homelab-domain-admin` respectively, resolving each one's
*internal* address via the service registry server-side
(`$self->registry->lookup(...)` — direct in-process DB access, not an
HTTP round trip to itself) and relaying the response straight back.
The shared forwarding logic is `Homelab::Common::Proxy::forward()` (see
`../common/README.md`) — auth is **not** re-checked at this layer; the
`Authorization` header passes through unchanged and each backend
independently re-verifies it via its own `introspect()` call, same
"verify at every hop" convention used everywhere else in this codebase.

This is deliberately *not* a "proxy every backend's raw protocol"
design: mail specifically is IMAP/SMTP, not HTTP, so there's no
tunneling involved — `homelab-mailbridge` is a real Mojolicious service
with its own JSON API that happens to be implemented using IMAP/SMTP
calls internally (see `../mailbridge/README.md`). And it's not a
"route every internal call through here either" design — features that
talk to each other directly (or to Postgres directly on a hot path)
keep doing that; this gateway is specifically about what an *external*
client needs.

`homelab-drive`'s real paths have no `/drive/` prefix of their own
(`/api/v1/files`, not `/api/v1/drive/files`) — that prefix only exists
in this gateway's client-facing namespace, sitting where `/api/v1`
already was on drive's side. So its route strips `/api/v1/drive` *and*
re-prepends `/api/v1` (`Homelab::Common::Proxy::forward`'s
`backend_prefix` option) — a plain prefix strip alone lands on `/files`,
which 404s. `homelab-mailbridge`'s own routes are deliberately already
`/api/v1/mail/...` themselves (it exists only to back this gateway), so
nothing needs rewriting for that one. `homelab-domain-admin`'s own
routes are `/internal/v1/domains/...` (a namespace deliberately
distinct from this gateway's `/api/v1/domains/...`, since that
service's API might reasonably be called by something other than this
gateway later — see `../domain-admin/README.md`) — note they *keep*
the `domains` segment, unlike drive. So its route strips only
`/api/v1` (not `/api/v1/domains`, which would drop `domains` entirely
and land on the wrong backend path — a real bug caught by an actual
`homelab-cli dns domains list` call) and re-prepends `/internal/v1`.
Also unlike drive/mail, it needs *two* route registrations, not one: a
`*capture` wildcard placeholder requires at least one captured
character after its own leading `/`, so it never matches the bare
`/api/v1/domains` (list/create) — only `/api/v1/domains/<something>`.
Drive/mail never hit this because they have no bare top-level resource
with nothing after the prefix.

## Testing

`t/auth.t` (unit, no DB), `t/basic.t` (real Postgres, real HTTP — set
`HOMELAB_API_CONFIG`), `t/admin.t` (same, covering the admin
endpoints specifically: 401 with no token, 403 with a valid token but no
site_admin role, unknown-role/nonexistent-user rejection, and that both
granting and revoking are idempotent rather than erroring on a repeat
call), and `t/gateway.t` (same, real `homelab-drive`/`homelab-mailbridge`
must actually be running and registered — a real file upload through
the gateway, not just JSON GETs, and confirming a missing
`Authorization` header 401s through the gateway same as any other
route) cover registration, login/introspect/refresh/logout, the session-
revocation property specifically (a JWT rejected immediately after
logout despite being nowhere near its own expiry), rate limiting (loops
until a real 429 shows up, then cleans up its own rows so repeated test
runs don't self-interfere via the shared per-IP counter), and the
service registry. `Homelab::Common::Proxy::forward()`'s own forwarding
logic (path rewriting, multipart body passthrough, the 502/504 error
cases) is unit-tested in isolation with fakes in
`../common/t/proxy.t` — `t/gateway.t` proves the real wiring on top of
that, not the forwarding mechanism itself again. Live coverage of the
public HTTPS path is `tests/e2e/test_api_public.py`; live coverage of
the whole CLI-only-needs-`--api-base` story is
`tests/e2e/test_cli_features.py`.
