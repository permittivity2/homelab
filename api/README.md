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

## Testing

`t/auth.t` (unit, no DB) and `t/basic.t` (real Postgres, real HTTP —
set `HOMELAB_API_CONFIG`) cover registration, login/introspect/refresh/
logout, the session-revocation property specifically (a JWT rejected
immediately after logout despite being nowhere near its own expiry),
rate limiting (loops until a real 429 shows up, then cleans up its own
rows so repeated test runs don't self-interfere via the shared per-IP
counter), and the service registry. Live coverage of the public HTTPS
path is `tests/e2e/test_api_public.py`.
