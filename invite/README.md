# homelab-invite

Singleton backend for the invite mechanism: token issuance, per-sender
quota/dedup enforcement, and the public one-time-use page an invitee
actually clicks into. The only process in this fleet holding a live
credential to the `invite` Postgres schema — the companion package
[homelab-roundcube-invite](../roundcube-invite/README.md) holds none at
all, calling this service through homelab-api's gateway with the
logged-in user's own JWT instead.

This service **never writes to `api.users`**. Creating the actual
login-capable account is homelab-api's own job — an extended
`POST /api/v1/auth/register` (see `api/lib/Homelab/API/App.pm`'s
`_register`/`_consume_invite`), gated behind config `auth.require_invite`
and reusing its already-proven Argon2id hashing. This service's role
stops at "was this token real, unused, and not expired" and "atomically
mark it consumed" — deliberately, to avoid duplicating security-critical
identity code in a second, public-facing codebase.

## Deployment

Fronted two different ways from one process, both real proxy hops
(`MOJO_REVERSE_PROXY=1` in the systemd unit, same as homelab-domain-admin):

- `/internal/v1/invites/*` — reached via homelab-api's own
  `/api/v1/invites/*` gateway route (strip `/api/v1`, reprepend
  `/internal/v1`, same transform as `/api/v1/domains`). JWT-authenticated,
  same `introspect()` mechanism as every other gateway-fronted service.
- `/invite/*` — the public acceptance page, fronted by its own dedicated
  webproxy vhost (`invite.<domain>`, matching the pattern every other
  public-facing service uses, e.g. SSO's `login.<domain>`). Add to
  `homelab-webproxy`'s `sites.yml`:
  ```yaml
  - domain: invite.test.mailmasker.org
    upstream: 127.0.0.1:2514
  ```
  No new nftables rule needed — port 80/443 are already open fleet-wide;
  only the loopback upstream port is new, and that's never internet-facing.

Install order: `homelab-api` (needs the extended `_register` + gateway
route) → `homelab-invite` → (optionally) `homelab-roundcube-invite` on
each roundcube host → the webproxy `sites.yml` entry above.

`config auth.require_invite` on homelab-api defaults to `false` —
installing this package doesn't change anything until an operator
explicitly flips that flag (after confirming `homelab-cli admin fleet
status` shows `invite` registered and healthy).

## Acceptance flow: the invitee chooses a username (2026-09-27 redesign)

Accepting an invite is NOT "set a password for the recipient_email
address." The invitee **chooses a username**, and their account login
becomes `<username>@<account_domain>` — the fleet's own mail domain
(`invite.account_domain` config, or, blank, derived from the mailer
identity's domain). `recipient_email` (where the invite was emailed)
becomes purely a contact address and the default **recovery email**.

Why: an invite goes to someone's real external address, but they need a
fleet identity, not an account named after their gmail. The old flow
hard-wired the login to `recipient_email`, which stopped making sense the
moment invites to fleet-managed recipients were (correctly) rejected —
see below.

Public endpoints the acceptance page's own JS drives:
- `GET /invite/:token` — renders the form (username + password ×2 +
  recovery email, pre-filled with `recipient_email`). Rejects up front,
  with a clear page, an invite whose recipient is on a fleet-managed
  domain.
- `POST /invite/:token/username {username}` — live availability check.
  Proxies homelab-api's system_agent-gated `/auth/username-availability`
  (this service holds the credential, the browser never does). Returns
  `{available:true}`, or `{available:false, suggestions:[…]}` for a taken
  name (deliberately never says "taken" — no account-existence oracle),
  or `{available:false, invalid:true, error}` for a malformed name.
- `POST /invite/:token/accept {username, password, password_confirm,
  recovery_email?}` — validates, then calls homelab-api's
  `/auth/register` with the chosen `<username>@<account_domain>` login +
  `recovery_email`. A taken username (409 from register) comes back as
  fresh `suggestions`, and the token is NOT burned (register's
  existing-email check runs before consume). `consume` no longer requires
  the registered email to equal `recipient_email` (they diverge by
  design now).

**Recipient-domain restriction lives here now**, not in homelab-api's
`_register`. `_recipient_domain_error` (Controller::Invites) checks the
invite's `recipient_email` against homelab-domain-admin's mail-managed
lookup, first thing in `accept()`/`show()`. It moved out of `_register`
because the account being registered is now a *deliberately*
fleet-domain login — checking that would reject every legitimate
acceptance; the address that must not be fleet-managed is the invite's
contact address, which only this service knows.

## Data model

One `invite` schema, three tables (see `migrations/001-invites.sql`):

- `invites` — token (64 hex chars, 32 bytes of `/dev/urandom`),
  sender_email/recipient_email/accepted_user_email/revoked_by_email as
  bare TEXT (no cross-schema FK into `api.users` — this schema's role has
  no grant there, same convention as `domainadmin.recipient_access.
  user_email`), status (pending/accepted/revoked/expired), expires_at. A
  partial unique index on `(sender_email, recipient_email) WHERE
  status='pending'` is the real, race-safe dedup enforcement — the
  application-level pre-check in `Controller::Invites::create` is just a
  fast path that avoids hitting it in the common case.
- `invite_quotas` — per-sender override (max_pending, max_per_day); an
  absent row means the config-file defaults apply.
- `verification_attempts` — every lookup against `/invite/:token`,
  successful or not, same shape/spirit as `api.login_attempts`. Feeds the
  public page's own rate limiting.

## API

`/internal/v1/invites` (gateway-fronted, `authenticated_email_any` unless
noted):
- `POST` `{recipient_email, message?, channel?}` — `channel` is `'cli'`
  (default; this service sends the invite email itself) or
  `'roundcube_plugin'` (the caller sends it, e.g. via Roundcube's own
  `deliver_message()` — this service only mints the token).
- `GET [?all=true]` — `?all=true` requires `site_admin`.
- `DELETE /:id[?user=EMAIL]` — revoke; `?user=` is `site_admin`-only.
- `GET /quota` — the caller's own effective quota (override or default).
- `GET|PUT /quota/:sender_email` — `site_admin`-only.
- `POST /consume {token, email}` — **not** end-user-authenticated; requires
  the `system_agent` role (checked via `introspect()`, same mechanism
  homelab-api's own `_require_system_agent` uses internally — this
  service doesn't hold the JWT signing secret, so it can't verify locally
  the way homelab-api itself does). The only caller is homelab-api's own
  `_register`, presenting its own host's homelab-agent credential
  (`Homelab::Common::Registry::system_agent_token`). Atomically flips
  `pending → accepted` in one `UPDATE ... WHERE status='pending' AND
  expires_at > NOW()`, closing the double-accept race — two concurrent
  calls on the same token: exactly one succeeds, confirmed in `t/basic.t`.

`/invite` (public, no auth, fronted by the `invite.<domain>` vhost):
- `GET /:token` — renders the acceptance page (inline HTML, no
  `templates/` directory — this is the only page any homelab-* backend
  has ever needed to render, and a templating layer for one page is more
  machinery than the task warrants). Every dynamic value is
  `Mojo::Util::xml_escape`'d before interpolation.
- `POST /:token/accept {password}` — never accepts an email field; the
  account created is always the invite's own `recipient_email`, resolved
  server-side, never client-suppliable. Calls homelab-api's own
  `/api/v1/auth/register` (which internally calls this service's own
  `/consume`), then sends the "your account is ready" welcome email.

## Consume endpoint trust model

`/internal/v1/invites/consume` is technically reachable through the
SAME public `invite.<domain>` vhost as the unauthenticated `/invite/*`
pages (the vhost proxies the whole app, not just `/invite/*`). This is
fine: every `/internal/v1/*` route enforces its own auth independently of
which port/vhost it was reached through — nothing in this service relies
on network topology or path-hiding as a security boundary.

## Anti-abuse

Right-sized to the actual threat model, not a copy of the old (pre-
migration) production system's 5-layer defense (honeypot, time-delay
token, JS-required token, focus-order check, exponential backoff) — that
design defends an *open, tokenless* signup page. This one is gated by an
unguessable, single-use, short-TTL, rate-limited token from the start, so
an attacker without a valid token has almost nothing to gain from
scripting the accept form.

What's actually in place: 32-byte urandom hex tokens, one-time-use via
atomic UPDATE, a 14-day default expiry (debconf-configurable), and IP
rate limiting via `verification_attempts` (20 non-success lookups/hour —
looser than `api.login_attempts`' 10/15min, deliberately: the real
defense here is token entropy, not the rate limit, which only needs to
blunt automated scanning noise).

Honeypot / minimum-time-before-submit are explicitly deferred, not
forgotten — revisit only if real bot traffic against `/invite/:token`
ever actually shows up.

## Email sending

The one genuinely new mail-sending pattern in this codebase: every other
send (homelab-mailbridge, Roundcube's own native `deliver_message()`) is
a real logged-in human's OAuth-authenticated session. Both the invite
email (`channel='cli'` only) and the "your account is ready" welcome
email have no human behind them.

Rejected: an unauthenticated local relay straight to Postfix.
`homelab-postfix`'s own `mynetworks` is `127.0.0.0/8` only, and its own
e2e tests confirm unauthenticated relay to an EXTERNAL recipient is
correctly rejected (`554 5.7.1 Access denied`) — invite recipients are
external by definition, so this would only work by accident (e.g.
co-locating with postfix and hoping) and break the moment it didn't.

Instead: a real, dedicated `api.users` mailbox identity (`config.yml`'s
`mailer.email`, e.g. `invites@<domain>`), created once via
`homelab-cli admin users create-service-account --email invites@<domain>`
(prints the generated password once, same one-time-reveal choreography as
homelab-sso's own OAuth client secrets), authenticating over real SMTP
submission (587, STARTTLS, `Net::SMTP`'s built-in `->auth`) exactly like
any human or plugin send already does — applying this fleet's own "one
shared identity authenticates everything" model to a system-owned mailbox
rather than inventing a second, parallel send mechanism. See
`lib/Homelab/Invite/Mailer.pm`.

## CLI

```
homelab-cli invite send --to EMAIL [--message TEXT]
homelab-cli invite list [--all]                    # --all: site_admin
homelab-cli invite revoke ID [--user EMAIL]         # --user: site_admin
homelab-cli invite quota show [--user EMAIL]        # site_admin
homelab-cli invite quota set --user EMAIL --max-pending N --max-per-day N
```

CLI-initiated invites always use `channel='cli'` (this service sends the
email); the Roundcube plugin always uses `channel='roundcube_plugin'`.

## Gotchas

- **Ordering in homelab-api's `_register`**: the "email already
  registered" check MUST run before the invite is consumed, not after —
  otherwise a registration that fails on that check would have already
  permanently burned the one-time token for nothing. Fixed in review
  before this ever shipped, but worth stating explicitly since it's easy
  to get backwards when adding a precondition to an existing flow.
- **`consume`'s email check** is a defense-in-depth sanity check, not the
  primary security boundary — the actual guarantee that an invitee can
  only ever register the address they were invited to comes from
  `/invite/:token/accept` never accepting an email field from the browser
  at all, always resolving it server-side from the invite row itself.
- **`Digest::SHA`'s `sha1_sum` is not exported by that module** — the
  message-ID generator actually needs `Mojo::Util::sha1_sum` (same import
  homelab-mailbridge's own `send_message` uses). Caught by `perl -c`
  during development, not left as a runtime surprise.

## Testing

`t/basic.t` needs `HOMELAB_INVITE_CONFIG` pointing at a real,
already-deployed `config.yml` with a reachable `homelab-api` (same "no
mocks, real integration" convention as every other homelab-* service's
own test suite) and passwordless `sudo -u postgres psql` for granting
`site_admin`/`system_agent` to throwaway test accounts (no self-service
"become an admin" API exists by design).
