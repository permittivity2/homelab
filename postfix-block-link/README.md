# homelab-postfix-block-link

The milter half of the click-to-block-link mechanism. Installs onto an
already-running [homelab-postfix](../postfix/README.md) host and injects a
unique management link into inbound mail, so a recipient using a regular
mail client (not just Roundcube) can block the address(es) a message was
sent to. See [homelab-block-link](../block-link/README.md) for the
settings backend + public page this milter talks to.

**Not a new blocking mechanism** — this package only decides *whether* to
inject a link and mints the token; the actual block happens later, when
someone visits the link, via `homelab-block-link`'s own call into
`domainadmin.recipient_access` (the same table `recipient_blocking`/
`homelab-cli mail block` already write to).

## Install order

Requires, already installed and migrated, on the DB host this package
bootstraps against:
1. `homelab-api` (`api.users`)
2. `homelab-domain-admin` (`domainadmin.domains`, `domainadmin.mail_aliases`)
3. `homelab-block-link` (`block_link.domain_settings`,
   `block_link.account_settings`, `block_link.pending_links`)

The bootstrap script (`homelab-postfix-block-link-bootstrap-role`) checks
all four required tables exist and fails loudly, before minting anything,
if they don't — same `check_*_exists` discipline
`homelab-postfix-bootstrap-role` already uses for
`domainadmin.domains`/`mail_aliases`.

## How it decides whether to inject a link

Per `RCPT TO`, in the `envrcpt` callback:
1. Resolve the envelope address to a destination account, replicating
   Postfix's own exact-then-catch-all `domainadmin.mail_aliases` lookup
   (`Homelab::PostfixBlockLink::Milter::resolve_recipient` — the *same*
   query `postfix/config/pgsql-virtual-alias-maps.cf.template` uses, not
   reinvented; this milter is a separate program and gets none of
   Postfix's own map-lookup fallback behavior for free).
2. Look up that account's effective setting: its own
   `block_link.account_settings.enabled` override if set, else its *home*
   domain's `block_link.domain_settings` default (`effective_setting`).

If any resolved recipient on the transaction is enabled, `eom` mints one
32-byte-random-hex token, `INSERT`s one `block_link.pending_links` row
(JSONB array of every enabled candidate), and injects:
- **Always**: a `List-Unsubscribe: <https://blockemail.<domain>/l/<token>>`
  header — a brand-new header, not a rewrite of an existing one, so DKIM
  signing that happens later in the milter chain sees a normal added
  header, not a mutated one.
- **If the domain's mode includes `body`**, and the message is top-level
  `text/plain` (including messages with *no* `Content-Type` header at
  all — RFC 2045 defaults that case to `text/plain`), and it isn't
  PGP/S-MIME signed: a short plain-text footer with the same link,
  appended via `$ctx->replacebody`.

**Mixed-mode transactions**: if a message has multiple enabled
recipients across domains with different modes, the body gets included if
*any* of them wants it — a milter operates on one shared body per
transaction, not one per recipient, so it can't structurally split by
recipient. Documented, not silently inconsistent.

## Why PGP/S-MIME-signed mail always falls back to header-only

Appending plaintext to a cryptographically signed body either breaks the
signature or ends up outside the signed part depending on the client —
either way, untrustworthy. Detected via `Content-Type`:
`multipart/signed`, `application/(x-)?pkcs7-mime`,
`application/pkcs7-signature`. The header is unaffected by the body
signature and is still injected.

## Why this milter must run *after* OpenDKIM

Postfix's `smtpd_milters`/`non_smtpd_milters` execute in list order, each
milter seeing the previous one's changes. `postinst` appends this
milter's `inet:HOST:PORT` entry to whatever's already configured — the
*same* idempotent read-current-then-append `postconf -e` pattern
`homelab-postfix`'s own postinst already uses to wire in OpenDKIM (see
that package's postinst, "DKIM" section). Appending (never overwriting)
means this milter naturally lands after OpenDKIM if OpenDKIM is enabled
on the host, which is the order that matters: OpenDKIM's own inbound
`Authentication-Results` verification should reflect the *untouched*
original message, not one this milter has already added a header/footer
to.

## Fail open, always

Every DB-touching operation (`envrcpt`, `eom`) is wrapped in `eval {}`. On
any error — DB unreachable, query failure, anything — it logs to stderr
(journald, via systemd) and returns `SMFIS_CONTINUE` with the message
unmodified. This milter sits on the hot SMTP delivery path for every host
it's installed on; it must never become a new way to reject, defer, or
delay real mail.

## Why no per-connection DB handle is created at file scope

`prefork_dispatcher` forks worker processes *after* this script's
top-level code runs. A Postgres/DBI connection opened before that fork
would be silently shared (and corrupted) across children. The `_pg()`
helper lazily creates the connection on first use in a given process and
transparently reconnects if `$$` (the pid) ever changes from when it was
created — covers prefork's own up-front fork and any other dispatcher
style that forks later.

## Config

`/etc/homelab/postfix-block-link/config.yml`, written once by `postinst`
from `config/postfix-block-link.example.yml` — see that file for the full
annotated shape. Three things worth knowing:

- `database.*` points at pgbouncer (this milter never talks straight to
  Postgres at runtime — only its own one-time bootstrap script does).
- `milter.listen` uses `Sendmail::PMilter`'s own `setconn()` syntax,
  `inet:PORT@HOST` — the *reverse* of Postfix's own `smtpd_milters`
  connect syntax, `inet:HOST:PORT`. `postinst` converts between the two
  when wiring the milter chain; only `milter.listen` is the source of
  truth.
- `block_link.public_base_url` / `block_link.link_ttl_days` **must match
  `homelab-block-link`'s own identically-named settings on whatever host
  runs it** — not auto-synced, same deliberate "two related settings,
  kept in sync by hand" pattern already used for Roundcube's
  `session_lifetime` vs. `homelab-sso`'s JWT lifetime elsewhere in this
  project. If `homelab-block-link`'s `public_base_url` changes, update
  this too (`dpkg-reconfigure homelab-postfix-block-link`) or generated
  links point at the wrong place.

Settings themselves (`enabled`/`mode`) are read live, per-transaction,
straight from Postgres — never cached in this config, so a settings
change made through `homelab-block-link`/`homelab-cli` takes effect on
the very next message with no milter reload needed.

## Multiple postfix hosts (HA)

Each instance needs its own Postgres role — a shared role means the last
install's password rotation silently invalidates every other
already-running instance's in-memory connection (found and fixed for
`homelab-postfix`/`homelab-dovecot`/`homelab-roundcube`'s own runtime
roles earlier in this project's history). Set
`homelab-postfix-block-link/instance_id` (e.g. `ct05`) via debconf/
`dpkg-reconfigure` on every host but the first.

## Testing

```
prove -I lib t/basic.t
```

Pure-function tests (`is_signed_mime`, `generate_token`,
`build_header_value`) run everywhere, no setup needed. The DB-backed
tests (`resolve_recipient`, `effective_setting`, `insert_pending_link`)
are skipped unless `HOMELAB_POSTFIX_BLOCK_LINK_CONFIG` points at a real,
already-deployed `config.yml` on a host where `homelab-api`/
`homelab-domain-admin`/`homelab-block-link` are all migrated — same "no
mocks" convention as every other `homelab-*` test suite in this project.

For real end-to-end verification (actual header/footer appearing in a
delivered message, actual click-to-block, actual fail-open behavior), see
`homelab-block-link/README.md` and this project's own verification
checklist — there is no substitute for sending a real message through a
real Postfix and fetching it back over real IMAP.
