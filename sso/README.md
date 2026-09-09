# homelab-sso

An OIDC-style single sign-on provider for the homelab-* ecosystem: one
login, shared browser-wide across every relying party (`homelab-drive`,
`homelab-roundcube`, and anything else registered as an OAuth client
here) -- "login once, login everywhere" -- and one logout that kills the
session everywhere too, without a shared cross-app cookie or a webhook
fan-out.

## How "everywhere" actually works

There's no cross-app cookie and no back-channel logout webhook. Instead:

- Every relying party already calls homelab-api's
  `/api/v1/auth/introspect` on (essentially) every request it serves
  (Drive on every request; Roundcube via its native OAuth
  refresh/keep-alive hooks) -- that's just how a bearer token gets
  verified in the first place.
- `/oauth/authorize` here checks for a live *IdP session* (this app's
  own `homelab-sso` cookie, independent of any relying party's own
  session) via that same `introspect()` call. If it's live, the login
  form is skipped and a fresh authorization code is issued immediately
  -- that's "login once, login everywhere."
- `/logout` here calls homelab-api's `/api/v1/auth/logout`, which flips
  `revoked = true` on the underlying session row (`api.sessions`, see
  `../api/README.md`). Every relying party's next `introspect()` call --
  which was already going to happen regardless -- now fails, for free.
  That's "logout once, logout everywhere."

This was a deliberate simplification versus an earlier, since-retired
design that used a shared "session epoch" cookie set across every app's
domain to force cross-app logout: it worked, but broke silently under
Brave's cookie-shielding (and any other browser privacy feature that
treats a first-party-but-cross-subdomain cookie with suspicion).
Centralized revocation checked through a call every relying party
already makes has no equivalent failure mode, and needed no new
cross-app mechanism at all -- just a `jti` column and one indexed
lookup on the homelab-api side.

Also deliberately NOT implemented: `id_token` / JWKS / OIDC discovery.
There's no RS256 signing key to generate, rotate, or publish, because
identity is fetched directly via `GET /oauth/userinfo` (a thin Bearer-
passthrough to homelab-api's `introspect()`), which is exactly what
Roundcube's native OAuth plugin already falls back to when a client has
no `oauth_id_token_uri`/JWKS configured (`oauth_identity_uri`). This is
an authorization-code flow with a userinfo endpoint, not full OIDC --
that's enough for every relying party this ecosystem actually has.

## Authorization codes are one-time and live in Postgres

`sso.oauth_codes` (own schema, split runtime/migrate roles per
`CLAUDE.md`), not held in-process -- hypnotoad runs multiple workers,
and an in-process code store would make a code minted by one worker
unusable if the token exchange landed on another. Codes are single-use
(`_take_code` is an atomic `DELETE ... RETURNING`) and expire quickly;
`_purge_expired` sweeps stale rows.

## Wiring in a relying party

Add an entry under `clients:` in `config.yml` (see
`config/sso.example.yml`) with a `client_id`, `client_secret`, and
`redirect_uri`. The packaged install prompts for `homelab-drive`'s and
`homelab-roundcube`'s redirect URIs and client secrets via debconf
(`dpkg-reconfigure homelab-sso` to redo); leaving a secret blank
auto-generates one and prints it at the end of the install for you to
copy into that relying party's own config -- there's no automated
secret-handoff between packages yet, so this coordination is
deliberately manual and explicit rather than silently generating
mismatched secrets on both sides.

## Testing

```bash
HOMELAB_SSO_CONFIG=/path/to/config.yml \
HOMELAB_SSO_TEST_CLIENT_SECRET=... \
  prove -I lib t/
```

Needs a real config (real runtime DB credentials, migrations already
applied), a real reachable `homelab-api` (`homelab_api.base_url` in
that config), and a `clients` entry named `test-client` with a known
secret/`redirect_uri` (`http://127.0.0.1:9999/oauth/callback` --
`t/basic.t`'s header documents the exact expected values).
`t/basic.t` proves the full flow for real, including the two properties
that matter most: a second `/oauth/authorize` call in the same browser
session skips the login form and gets a genuinely new code
(login-once), and after `/logout`, the next `/oauth/authorize` call
shows the login form again (logout-once) -- see the comments in that
file for why the test ordering matters (the `refresh_token` grant test
rotates the same underlying token the IdP session cookie holds, so it
has to run after the session-persistence check, not before it).
