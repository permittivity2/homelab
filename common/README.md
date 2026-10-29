# homelab-common

Shared foundation library for every `homelab-*` feature package. See the
repo root `README.md` and `CLAUDE.md` (local, unpublished) for the full
architecture this implements.

## Modules

- **`Homelab::Common::Config`** — `load_config($env_var, $default_path)`.
  The one config-loading pattern every package used to hand-roll
  separately.
- **`Homelab::Common::DB`** — `pg_url(%opts)` builds a
  `postgresql://` URL (percent-encoding user/password correctly);
  `runtime_pg(%opts)` returns a `Mojo::Pg` handle for the day-to-day,
  DDL-less `<feature>_runtime` role (through pgbouncer); `migrate_dbh(%opts)`
  returns a plain `DBI` handle for the `<feature>_migrate` role (direct
  to Postgres, bypassing pgbouncer — see `CLAUDE.md`'s split-role
  design).
- **`Homelab::Common::AuthClient`** — `introspect($jwt, api_base => ...)`
  verifies a bearer token against `homelab-api`'s
  `/api/v1/auth/introspect`, returning `{email, exp}` or `undef` (never
  dies, including on a transport failure — an unreachable `homelab-api`
  must not crash the caller). Every feature that needs "who is this
  request from" calls this rather than verifying JWTs itself.
- **`Homelab::Common::Registry`** — `register(%opts)` /
  `lookup($feature, %opts)`. The service registry itself lives inside
  `homelab-api`'s own schema; every other feature reaches it over HTTP
  (these two calls), never via a direct cross-schema DB grant.
  `homelab-api`'s own address is never looked up this way — every
  feature gets it from its own local bootstrap config, same as DB
  credentials.
- **`Homelab::Common::Queue`** — `new_minion(%opts)` returns a
  Postgres-backed `Minion` instance for async/fan-out work. Namespace
  task names by owning feature (`drive.thumbnail`, `backup.reconcile`).
- **`Homelab::Common::Migrate`** — `run_migrations(%opts)` applies a
  feature's `migrations/NNN-description.sql` files, each in its own
  transaction, tracked in a per-schema `schema_migrations` table. Must
  be called with a `migrate_dbh`, never a `runtime_pg` connection.
- **`Homelab::Common::Health`** — `mount_health_route($app, %opts)`
  mounts a standard `GET /health` on a Mojolicious app, with an
  optional deeper `check` coderef.
- **`Homelab::Common::Proxy`** — `forward($c, feature_name => ...,
  api_base => ...|host => ..., port => ..., strip_prefix => '',
  backend_prefix => '')`. What makes `homelab-api` usable as the single
  client-facing gateway (see `../api/README.md`): resolves
  `feature_name`'s address via `Registry::lookup` (or skips straight to
  a given `host`/`port`, for a caller like `homelab-api` itself that
  already has direct DB access to the registry and would otherwise be
  round-tripping over HTTP to itself), forwards the request
  (method/path/query/`Authorization`/body — a real multipart upload
  included, via `$c->req->content`, not a re-derived body string) to
  it, and relays the response back. Renders a clean 502/504 itself on a
  registry miss or unreachable backend, never a raw exception page.

### Device setup

Four small modules that together answer "how do I get this mailbox onto
my phone?". They live here because **two** services answer it at two
different moments — `homelab-invite` seconds after an account is created,
`homelab-accountmanage` months later for the next device — and an answer
that differed between them would create a second mail account on the
phone rather than updating the first.

- **`Homelab::Common::MailSetup`** — `mail_settings`, `manual_setup_rows`.
  The single source of IMAP/SMTP client settings. Defaults derive
  `mail.<domain>`/`smtp.<domain>` from the mailbox address, which is what
  the edge certificate actually carries as SANs. Blank config keys mean
  *derive* (YAML renders an empty key as `''`, not undef).
- **`Homelab::Common::AppleProfile`** — `build_mail_profile`,
  `profile_filename`. Emits an iOS/macOS `.mobileconfig`. Two properties
  are load-bearing: identifiers and UUIDs are a pure function of the
  address (a random UUID per request would give a user who taps "Add to
  iPhone" twice *two* copies of the same mailbox), and **no password is
  ever written into the file** — mail passwords are Argon2id hashes so
  there is no plaintext to write, and a URL-fetchable file holding a
  working credential would be an account-takeover primitive.
- **`Homelab::Common::SetupToken`** — `issue_setup_token`,
  `verify_setup_token`. HMAC-SHA256, expiring, purpose-scoped, stateless.
  What lets a QR code carry its own authority to a phone that has never
  signed in. Each issuer uses its own secret, so there is no fleet-wide
  setup secret to distribute. Signature is checked *before* expiry, the
  compare is constant-time, and fields are length-prefixed before signing
  (the subject is an attacker-chosen email address, so a plain delimiter
  would let a field boundary be shifted).
- **`Homelab::Common::QRCode`** — `qr_svg`, `qr_available`. Renders a QR
  code as compact SVG. `Text::QRCode` is loaded **lazily** and its absence
  returns undef rather than dying: this package is installed on every host
  in the fleet and only two of them render codes, so the dependency is
  declared by those two packages, not here.

`Homelab::Common::Mailer`'s `send_mail` also gained an optional `html`
argument, making the message `multipart/alternative` with `body` as the
text part. Both parts are base64 (SMTP caps a line at 998 octets and HTML
routinely exceeds it). The plain-text-only path is byte-identical to what
it emitted before.

## Bootstrap scripts

Two standalone CLI tools ship here too (not in `homelab-database`/
`homelab-pgbouncer`) — every feature needs the *client* tool, but
shouldn't need an entire local Postgres/pgbouncer server install just
to get it:

- **`homelab-bootstrap-app-role`** — creates a split pair of Postgres
  roles (`<feature>_runtime`: CRUD only; `<feature>_migrate`: CRUD+DDL,
  same schema only) + the schema itself, for one feature:
  ```bash
  homelab-bootstrap-app-role --feature homelab_drive --schema drive --db-host database01
  ```
  Prints `RUNTIME_ROLE=`/`RUNTIME_PASSWORD=`/`RUNTIME_SCRAM_SECRET=` and
  `MIGRATE_ROLE=`/`MIGRATE_PASSWORD=`/`MIGRATE_SCRAM_SECRET=` on
  success. Never a stored/network admin credential — OS-level peer auth
  only (`sudo -u postgres`), local first, then SSH if trust already
  works, then a printed-SQL manual fallback. **Critical detail verified
  by `t/bootstrap-role.t`**: the runtime role's default-privileges
  grant must say `ALTER DEFAULT PRIVILEGES FOR ROLE "<migrate_role>"
  ...` — omitting `FOR ROLE` silently scopes it to whatever role ran
  the bootstrap script itself (`postgres`), and the runtime role would
  never get access to anything the migrate role creates afterward. This
  was caught by testing against a real Postgres, not by inspection.
- **`homelab-bootstrap-pgbouncer-entry`** — registers a feature's
  `_runtime` role's SCRAM secret into pgbouncer's `userlist.txt`
  (idempotent — rotation replaces in place). **Never register the
  `_migrate` role** — it connects directly to Postgres, bypassing
  pgbouncer on purpose. Same fallback tiering as above.

## Testing

```bash
prove -I lib t/
```

`t/db.t` and `t/migrate.t` skip their live-connection tests unless
`HOMELAB_COMMON_TEST_DB_HOST` (+ `_NAME`/`_USER`/`_PASSWORD`, and
optionally `_PORT`) are set, pointed at a scratch Postgres database —
`migrate.t` creates and drops its own throwaway schema, safe to run
against a real instance. `t/bootstrap-role.t` needs
`HOMELAB_COMMON_TEST_DB_HOST` (+ `_NAME`/`_USER`/`_PASSWORD`) as well
as `HOMELAB_COMMON_TEST_LIVE_BOOTSTRAP=1` and passwordless `sudo` to
the `postgres` user. `t/registry.t`, `t/bootstrap-entry.t`, and
`t/health.t` need no live infrastructure at all.
