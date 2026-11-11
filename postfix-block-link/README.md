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
- **If the domain's mode includes `body`** and the message isn't
  PGP/S-MIME signed: a short footer with the same link is appended via
  `$ctx->replacebody`.
  - `text/plain` (including messages with *no* `Content-Type` header at
    all — RFC 2045 defaults that case to `text/plain`): a plain-text
    footer is appended directly to the body.
  - `multipart/*` and `text/html` (i.e. essentially all real-world mail —
    Gmail/Outlook/etc. send `multipart/alternative`): the footer is
    injected into every `text/plain` and `text/html` **leaf part** via
    `Email::MIME`, which decode/re-encodes each part's own
    `Content-Transfer-Encoding` (quoted-printable/base64/7bit) and
    preserves the message's existing MIME boundary. The HTML footer is
    inserted just before `</body>` when present, else appended.
    (Earlier versions only handled top-level `text/plain`, so a
    multipart message got the header but no footer — the common case,
    now fixed.)

Since 0.2.2 the same footer can also carry the "Reply from the alias"
line (see that section below) — above the block link, or on its own when
the message gets no block link.

**Mixed-mode transactions**: if a message has multiple enabled
recipients across domains with different modes, the body gets included if
*any* of them wants it — a milter operates on one shared body per
transaction, not one per recipient, so it can't structurally split by
recipient. Documented, not silently inconsistent.

**One link per message, even across accounts**: for the same reason, a
message that reaches several mailmasker accounts in one transaction (To,
Cc or Bcc) gets ONE `pending_links` row listing every enabled recipient,
and the same link lands in every copy. The link page is what keeps the
accounts apart: since homelab-block-link 0.1.4 it shows and blocks only
the signed-in account's addresses on such a link, and nothing at all
when nobody is signed in. See
[block-link's README](../block-link/README.md), "Who sees which
addresses, and signing in".

## Why PGP/S-MIME-signed mail always falls back to header-only

Appending plaintext to a cryptographically signed body either breaks the
signature or ends up outside the signed part depending on the client —
either way, untrustworthy. Detected via `Content-Type`:
`multipart/signed`, `application/(x-)?pkcs7-mime`,
`application/pkcs7-signature`. The header is unaffected by the body
signature and is still injected.

## Where this milter sits relative to OpenDKIM (per listener)

Postfix's milter lists execute in order, each milter seeing the previous
one's changes. Until 0.2.0 the postinst appended this milter's entry
"if missing", which left the order to whichever postinst ran last —
prod ended up with this milter *before* OpenDKIM on 25, so OpenDKIM
verified inbound mail that already carried our header/footer. Since
0.2.0 both postinsts (this one and `homelab-postfix`'s DKIM block) apply
the same fixed rules, so they converge whatever the run order:

| list | order | why |
|---|---|---|
| `smtpd_milters` (25) | OpenDKIM first, this milter **last** | inbound `Authentication-Results` verification must see the untouched original |
| `non_smtpd_milters` (pickup/sendmail) | this milter **first**, OpenDKIM last | sign local mail after everything else is done with it |
| `submission/inet` (587, a `postconf -P` per-service override) | this milter **first**, OpenDKIM last | the reply rewrite below changes `From:`; the signature must cover that From and use that domain's key |

The 587 override also sets `milter_default_action=tempfail` (see "Fail
open — with one deliberate exception"). Check with `postconf -h
smtpd_milters`, `postconf -h non_smtpd_milters` and `postconf -Ph
submission/inet/smtpd_milters`.

## Reply from the alias a message was sent to (post-cutover #67)

Phone mail apps always send a reply *From* the account's primary address,
and catch-all aliases are invented on the spot, so no client can be told
about them in advance. Since 0.2.0 this milter makes the alias behave as
the sending identity anyway, with nothing to configure per alias:

1. **Inbound, every message, every account** (fails open): for each
   destination account on the transaction, `choose_reply_address`
   (`Milter.pm`) picks which of the account's own addresses the message
   was addressed to — the first of them on the **To** line, else the first
   on **Cc**, else the first envelope recipient (Bcc, mailing lists). To/Cc
   addresses are resolved through the same `resolve_recipient` lookup, not
   just matched against this transaction's envelope, so a message split
   over several deliveries reaches the same answer. If the winner is an
   alias, one row `(account, Message-ID) → chosen` goes into
   `domainadmin.mail_received_via` (`ON CONFLICT DO NOTHING`; owned and
   pruned by homelab-domain-admin, migration 009). The real address
   winning records nothing. Recorded regardless of the user's setting, so
   switching it on later works for mail already received.
2. **Submission (587, `{daemon_name}` = `ORIGINATING`), authenticated
   user, switch on** (`domainadmin.mail_reply_identity`, set in myaccount):
   if the message is a reply (`In-Reply-To`, else the last `References`
   id), its `From:` is exactly the login address, and a row exists for
   `(login, parent id)`, then the `From:` (and a `Reply-To:`/`Sender:` that
   also names the login) is rewritten to the recorded alias — keeping the
   display name, dropping it if it *contains* the real address — and the
   envelope sender is replaced (`chgfrom`), so `Return-Path` and bounces
   follow the alias too. Mail already From an alias (Roundcube identity,
   `homelab-cli mail send --from`) has `From ≠ login` and is never touched.

**The authorization boundary moved here on purpose.** Postfix's
`reject_authenticated_sender_login_mismatch` on 587 checks the client's
MAIL FROM *before* this milter runs and never re-checks after `chgfrom`.
So `allowed_to_send_as` re-applies the same rule as
`pgsql-sender-login-maps.cf` for the authenticated login (its own
address; an `active AND send_enabled` `mail_aliases` row, exact or
`@domain`, whose destination is the login) at reply time — a revoked or
suspended alias is never used even if it was recorded earlier. The
recorded address itself came from somebody else's To/Cc header, so it
must also pass `is_safe_address` (plain atext@dns-name, no quotes,
brackets, spaces or control characters) before it is written anywhere.
The lookup is keyed by the authenticated account, so a forged
`In-Reply-To` naming another account's message finds nothing.

3. **The footer line (0.2.2).** When the message came to an alias of the
   **one** account it is for and that account's switch is on, the body gets
   one line, right above the block link (or alone when the message gets no
   block link):

       Reply from the alias: a reply to this message goes out from shop01@forge.name.

   It starts with the setting's own name so a reader knows where to look,
   and names only the alias — never the real address, the thing the
   feature hides, and footers get forwarded. It is written only when the
   row from step 1 exists, so it never promises a rewrite step 2 cannot
   find. Not written: when the message went to the real address (nothing
   changes for it), when the switch is off, when the message is PGP/S-MIME
   signed, and when the transaction has **more than one destination
   account** — a milter edits one body shared by every recipient, and one
   person's alias is nobody else's business. The line reflects the switch
   at the time the message arrived: switching off later leaves older
   messages carrying it. Decided at `eoh` (`single_account`, one
   `mail_reply_identity` lookup) so the body callback knows to buffer;
   written by the same code path as the block-link footer
   (`footer_text_lines`/`footer_html` in `Milter.pm`), text and html leaf
   parts alike. Log line: `footer: reply line for <account> names <alias>`.

Log lines (journald, `homelab-postfix-block-link`): `reply-identity:
recorded …`, `reply-identity: rewrote …`, `reply-identity: … left alone
(<reason>)`, `footer: reply line …`, and the tempfail cases below.

## Fail open — with one deliberate exception

Every inbound operation (`envrcpt`, block-link injection, recording the
alias) is wrapped in `eval {}`. On any error — DB unreachable, query
failure, anything — it logs to stderr (journald, via systemd) and
returns `SMFIS_CONTINUE` with the message unmodified. This milter sits
on the hot SMTP delivery path for every host it's installed on; it must
never become a new way to reject, defer, or delay real inbound mail.

The exception is the #67 reply rewrite on 587: when an authenticated
reply from the login address *could* be owed a rewrite and the database
cannot be consulted (or the rewrite fails midway), the milter answers
`451 4.7.1` and Postfix defers the message — the phone keeps it in its
outbox and retries. Letting it through would mean silently sending from
the real address, the very thing the user switched the feature on to
prevent. Gardner's decision (2026-11-10); `reply_identity.on_db_error:
accept` in `config.yml` is the operator's escape hatch. For the same
reason the postinst sets `milter_default_action=tempfail` on the 587
service only (25 keeps `accept`): if this milter is unreachable,
submissions wait until it is back (`Restart=on-failure`, seconds), rather
than leak. Postfix's own sender-login lookup on 587 is a pgsql map, so a
database outage already deferred submissions before this change.

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
