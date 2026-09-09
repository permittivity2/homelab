# homelab-dovecot

IMAP/LMTP mail delivery, wired to the same shared identity every other
`homelab-*` feature uses. Dovecot's SQL passdb queries `homelab-api`'s
own `api.users` table directly — via a narrow, column-scoped cross-schema
grant (`email`, `password_hash`, `active` only; see
`script/homelab-dovecot-bootstrap-role`) — so the same Argon2id password
authenticates both HTTP login (`homelab-drive`) and IMAP/SMTP login. No
separate mail-specific password store.

Storage is static: a shared `vmail` system uid/gid and a Maildir++ tree
under `/var/mail/vhosts/<domain>/<user>/`, resolved via userdb `static`
(no SQL userdb — home/uid/gid are the same formula for every user, so
there's nothing a per-user database lookup would add). This means the
package owns **no schema/tables of its own**, and therefore has **no
migrate role** — unlike the standard split runtime/migrate Postgres role
pattern most other `homelab-*` features use (see the root `CLAUDE.md`).
That's intentional: there's no DDL for a migrate role to ever run. Only
`homelab_dovecot_runtime` exists, minted by
`script/homelab-dovecot-bootstrap-role` (a bespoke, one-off script — see
its own header comment for why this wasn't folded into the generic
`homelab-bootstrap-app-role`).

## Gotchas: Dovecot 2.4's incompatible config-language rewrite

Debian's own `dovecot-core` package says it plainly (`NEWS.Debian`):

> Dovecot 2.4 is a major upgrade from the previous 2.3 branch and
> introduces an incompatible configuration language... The default
> configuration shipped by Debian has been updated for compatibility
> with the new configuration, but any locally maintained configuration
> will need to be updated.

Same category of breaking change as PowerDNS 5.x's master/slave →
primary/secondary rename (see `homelab-dns`'s README) — except more
pervasive, since it touches nearly every setting name. Everything in
`conf.d/91-homelab-dovecot.conf.template` was verified empirically
against a live 2.4.2 instance (`doveconf -n`, `doveadm auth test`, and a
real IMAPS login/select/append/search round-trip) — most of the
pre-2.4-era documentation and examples still floating around (including,
at least as fetched 2026-09-09, some of Dovecot's own current docs
pages) describe syntax this version no longer accepts, or omit settings
that turn out to matter in practice. Specific traps hit along the way:

- **`mail_location = maildir:/path` is gone.** Split into two
  independent settings: `mail_driver = maildir` and `mail_path = /path`.
- **The SQL driver connection block's syntax is genuinely different**
  from the classic `passdb { driver = sql; args = /etc/dovecot/
  dovecot-sql.conf.ext }` + separate `dovecot-sql.conf.ext` file. In
  2.4, the connection is its own named block —
  `pgsql <host> { parameters { port = ...; dbname = ...; user = ...;
  password = ... } }` — and the block's positional name **is** the
  host; there's no separate `host = ` field. Passing the whole libpq
  conninfo string as the positional name (`pgsql "host=... port=..." {
  }`) is accepted by `doveconf -n` as syntactically valid but does
  **not** work — it gets treated as a literal (bogus) hostname, and the
  auth process hangs for 60s per connection attempt ("no free
  connections") rather than failing fast. `default_password_scheme` (not
  `default_pass_scheme`, the 2.3 name) lives inside `passdb sql { }`.
- **`mail_inbox_path` is a real, separate setting from `mail_path`.**
  Left unset, it defaults to the legacy shared-spool convention
  (`/var/mail/<user>`, owned `root:mail`, not writable by `vmail`) —
  breaking **only** INBOX (every other mailbox uses `mail_path` and
  works fine) with `Failed to autocreate mailbox: Permission denied`.
  `doveconf -n` reports the config as fully valid either way; this is
  only caught by a real IMAP `SELECT INBOX`. Setting it to empty
  (`mail_inbox_path =`) does *not* fall back to `mail_path` either — it
  resolves INBOX to a `.INBOX` Maildir++ subfolder instead of the
  per-user maildir root, a different (valid, but different) on-disk
  layout than the rest of this ecosystem assumes. The fix that actually
  produces one shared maildir root for INBOX and every other folder is
  setting `mail_inbox_path` to the **exact same value** as `mail_path`.
- **A malformed/half-resolved `pgsql { }` block can crash the auth
  worker outright** (signal 11, not a clean error) rather than fail
  gracefully — seen once during iteration, before landing on the
  correct syntax above. `doveconf -n` passing is necessary but not
  sufficient evidence a config is safe to load; a real `doveadm auth
  test` (or better, a real IMAP login) is what actually proves it.

None of this is discoverable from `doveconf -n` alone — every one of
these was only caught by actually running a real login against a real
account. See `tests/e2e/test_dovecot_login.py`.

## Testing

Package-local: none beyond `t/dovecot-bootstrap-role.t` (needs a real
local Postgres with `homelab-api` already migrated — see its own header;
gated behind `HOMELAB_DOVECOT_TEST_LIVE_BOOTSTRAP=1`). There isn't much
else here to unit test — this package is almost entirely debconf +
`sed` + a vendor daemon, the same shape as `homelab-dns`, which relies on
its own `tests/e2e/` test for the same reason.

Real, live coverage is `tests/e2e/test_dovecot_login.py`: registers a
throwaway account via `homelab-api`, confirms IMAP login fails with a
wrong password and succeeds with the right one, then confirms a real
`APPEND`/`SELECT`/`SEARCH` round-trip against `INBOX` — this is what
actually exercises the `mail_inbox_path` gotcha above; a login-only test
would have passed even with the broken config, since `LOGIN` succeeded
long before `SELECT INBOX` was fixed.
