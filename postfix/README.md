# homelab-postfix

SMTP submission and mail relay, wired to the same shared identity every
other `homelab-*` feature uses — but split more finely than
`homelab-dovecot`'s single grant:

- **Recipient validation only** goes through Postgres: a narrow,
  column-scoped cross-schema grant on `api.users` (`email`, `active` —
  no `password_hash` at all; see
  `script/homelab-postfix-bootstrap-role`) backs a `virtual_mailbox_maps`
  pgsql lookup (`config/pgsql-virtual-mailbox.cf.template`) that decides
  accept/reject at `RCPT TO` time, before any message body is accepted
  (avoiding backscatter to forged senders for addresses we can't
  deliver). The value returned is never a delivery path — actual
  delivery goes over LMTP (see below) — so the query only needs to prove
  existence: `SELECT 1 FROM api.users WHERE email='%s' AND active =
  true`.
- **SASL authentication is delegated entirely to Dovecot.** Postfix
  itself never queries Postgres for credentials — `smtpd_sasl_type =
  dovecot` + `smtpd_sasl_path = private/auth` hands the whole
  PLAIN/LOGIN exchange to Dovecot's own passdb over a unix socket at
  `/var/spool/postfix/private/auth`, the exact same passdb every IMAP
  login already uses. One Argon2id password in `api.users` backs both
  paths, but each service holds its own narrowly-scoped credential —
  Postfix's own Postgres role can't even read `password_hash`, so a
  compromise of the SMTP submission path doesn't expose password hashes
  the way a shared "the MTA can also do full auth lookups" design would.
- **Delivery is LMTP to `homelab-dovecot`**, not Postfix's own local/
  virtual delivery agent: `virtual_transport = lmtp:127.0.0.1:24`,
  pointing at the TCP LMTP listener homelab-dovecot 0.1.2+ exposes
  specifically for this (see its own README's Gotchas section for why
  that listener binds all interfaces rather than just loopback).

## Two config touches live in Dovecot's conf.d, split by ownership

Neither Postfix's `main.cf` (a single flat file) nor `master.cf` (fixed
columnar format) has anything like Dovecot's `conf.d/` include
mechanism, so cross-package coordination here works differently in each
direction:

- The **LMTP listener** is `homelab-dovecot`'s own concern (it already
  `Depends:` on `dovecot-lmtpd`) and lives in *its* template
  (`dovecot/conf.d/91-homelab-dovecot.conf.template`).
- The **SASL socket** (`config/92-homelab-postfix-sasl.conf.template`)
  is fundamentally a Postfix feature that happens to delegate to
  Dovecot, so *this* package's `postinst` writes it directly into
  `/etc/dovecot/conf.d/92-homelab-postfix-sasl.conf` and reloads
  Dovecot — a real, intentional cross-package file write, not an
  oversight.

This creates a real install-order dependency within a single `postinst`
run: Postfix must be started *first* (which creates
`/var/spool/postfix/private/`) before the Dovecot SASL drop-in can be
written and Dovecot reloaded — Dovecot can't create a unix socket inside
a directory that doesn't exist yet. `debian/postinst` does exactly this
sequence (start Postfix → write the Dovecot drop-in → reload Dovecot →
add the submission service → reload Postfix again).

## Multi-domain support

`virtual_mailbox_domains` is no longer a single hardcoded debconf
value — it's a live `pgsql:` lookup (`config/pgsql-virtual-domains.cf.template`)
against `homelab-domain-admin`'s own `domainadmin.domains` table
(`SELECT 1 FROM domainadmin.domains WHERE domain_name='%s' AND
mail_enabled = true AND active = true`), the same "live map, not a
static value" shape `virtual_mailbox_maps` already used. `homelab-cli
dns domains add/enable/disable` takes effect on this host without ever
touching Postfix config directly.

`script/homelab-postfix-bootstrap-role`'s single `homelab_postfix_runtime`
role now carries a second, equally narrow, column-scoped cross-schema
grant (`domain_name`, `mail_enabled`, `active` only) reaching into
`homelab-domain-admin`'s schema instead of `homelab-api`'s — same
credential, same password, one more read-only grant, added the same way
the original `api.users` grant was. `domainadmin.recipient_access` is
also granted here, backing the recipient allow/block feature below.

**Rollout safety, for a host with mail already flowing for its
originally-configured domain**: `postinst` never flips
`virtual_mailbox_domains` over blindly.
1. It seeds that domain into `domainadmin.domains` first (idempotent
   `INSERT ... ON CONFLICT DO NOTHING`) — never baked into a migration
   file, which would wrongly hardcode one installation's domain into
   every future install of `homelab-domain-admin`.
2. It then probes the live map with `postmap -q` for that exact domain
   (reusing the same probe idiom already used for the stale-pgbouncer
   check above) and only flips `virtual_mailbox_domains` over if the
   probe actually returns `1`. If it doesn't — `homelab-domain-admin`
   not installed yet, not migrated, or the new grants haven't been
   applied — it warns and leaves the static value in place. Mail flow
   is never interrupted by this upgrade path; a failed probe just means
   the multi-domain feature isn't active yet until re-run via
   `dpkg-reconfigure homelab-postfix`.

**Real bug hit standing this up**: on a host where
`homelab_postfix_runtime` was already bootstrapped by an earlier
package version (the common case — `postinst`'s bootstrap block is
gated on the map file not existing, so it never re-runs on an upgrade),
the two new grants above are never actually applied to the
already-existing role — only a genuinely fresh bootstrap picks up the
updated `build_sql()`. The probe step exists precisely to catch this
class of problem (it failed with `permission denied for schema
domainadmin` until the grants were applied by hand once, matching
exactly what the updated script now generates) rather than silently
leaving `virtual_mailbox_domains` on a lookup that would 500 every
`RCPT TO`.

## Recipient allow/block

A live `pgsql:` lookup (`config/pgsql-recipient-access.cf.template`)
against `homelab-domain-admin`'s `domainadmin.recipient_access` table
backs Postfix's own `check_recipient_access` restriction — `SELECT
action FROM domainadmin.recipient_access WHERE recipient='%s'`, where
`action` is whatever Postfix verb was stored (`OK`, `REJECT`,
`DISCARD`, `DEFER`, or a literal `"550 5.7.1 ..."` response — this
package never duplicates Postfix's own vocabulary). `homelab-cli dns
recipient-access block/allow/remove` takes effect immediately, no
Postfix reload needed (same live-lookup shape as the domains table
above).

Wired into `smtpd_recipient_restrictions` via read-modify-append
(`postinst` never clobbers a hand-added rule already there) — same
provisioning-then-probe-then-flip file layout as the domains feature,
reusing the same `homelab_postfix_runtime` credential. Positioned
**first**, before `permit_mynetworks`/`permit_sasl_authenticated`, not
merely before `reject_unauth_destination`: those two permit rules
return an immediate, terminal `OK` for matching connections, which
would otherwise let a mynetworks or SASL-authenticated sender skip
`check_recipient_access` entirely — exactly the senders most likely to
be trusted enough to reach a blocked recipient in the first place. An
explicit `allow` entry is equally terminal in the other direction: it
returns `OK` immediately, ahead of every other restriction, the same
way an explicit allowlist is supposed to behave.

Real, end-to-end tested (`tests/e2e/test_postfix_mail.py::test_recipient_access_block_then_allow`):
block a real recipient, confirm RCPT TO is rejected (550/554); remove
the block, confirm the same recipient is accepted again (250) — with
zero code path specific to the recipient tested.

## `master.cf`'s submission service

Postfix ships `master.cf` with the submission (587) and submissions
(465) services present but fully commented out, each with a slightly
different set of example `-o` overrides in the comments. Rather than try
to uncomment-and-edit those in place (fragile, and the overrides this
deployment actually needs differ from the vendor's commented example),
`postinst` appends a fresh, fully-specified, clearly marked block
(`config/master.cf.submission-stanza`, delimited by `# BEGIN/END
homelab-postfix managed`) once, idempotently. The vendor's own commented
example is left untouched.

## Testing

Package-local: none — like `homelab-dns` and `homelab-dovecot`, this
package is almost entirely `postconf -e` calls, a Postgres map file, and
a couple of drop-ins; there isn't meaningful logic to unit test outside
`script/homelab-postfix-bootstrap-role`. Real, live coverage is
`tests/e2e/test_postfix_mail.py`.

During development, the full path was verified manually against real
infrastructure, not just the local test host:

- Real SMTP submission (587) with SASL PLAIN authenticated via Dovecot's
  passdb.
- Real recipient validation: a nonexistent local address is rejected at
  `RCPT TO` with `550 5.1.1 User unknown in virtual mailbox table`
  *before* the LMTP handoff is ever attempted.
- Real LMTP handoff to `homelab-dovecot`, landing in the recipient's
  actual Maildir.
- Real anti-relay enforcement: an unauthenticated submission-port
  connection attempting to relay to an external address is rejected
  with `554 5.7.1 Access denied`.
- **Real outbound internet delivery**: an authenticated relay attempt to
  a (deliberately nonexistent) `@gmail.com` address was accepted,
  queued, and Postfix genuinely connected to
  `gmail-smtp-in.l.google.com` on port 25 and got back a real `550-5.2.1
  The email account that you tried to reach is inactive` from Google's
  own mail servers — conclusive proof that **outbound** port 25 is *not*
  blocked by this host's firewall. This is a separate finding from
  **inbound** reachability, governed by different firewall rules — see
  the Gotchas section below for the current state of that.

## Gotchas

- **PgBouncer can serve a stale pooled backend connection for a role
  that was dropped and recreated** (not merely password-rotated via
  `ALTER ROLE`), predating its current grants — `permission denied for
  schema api` from the pgsql map, even though a direct `psql` check at
  that same moment confirms the grant is correct. Root-caused
  2026-09-09 alongside the identical symptom in `homelab-dovecot` (see
  its README for the full investigation): a `postmap -q` invocation
  opens a brand-new connection every single time, yet still hit the
  stale error — ruling out client-side connection pooling in either
  Postfix or Dovecot as the cause. `systemctl restart pgbouncer` is the
  confirmed fix; restarting Postfix (or Dovecot) alone is not reliably
  sufficient. Precisely pinned down by a two-cycle test: one pgbouncer
  restart followed by a fresh install of both packages had zero
  occurrences; immediately repeating the fresh-install cycle with the
  SAME role names (no intervening pgbouncer restart) reproduced it
  again. Since `script/homelab-postfix-bootstrap-role` only ever does
  `CREATE ROLE ... ELSE ALTER ROLE ...` — never `DROP ROLE` — a real
  admin re-running `dpkg-reconfigure` to rotate credentials will never
  trigger this. It only showed up here because this project's own test
  cleanup between install cycles used `DROP ROLE` to simulate a virgin
  host; **anyone continuing to test this way should
  `systemctl restart pgbouncer` right after any manual `DROP ROLE`
  cleanup**, or expect it to resurface — a testing-methodology
  consequence, not a package bug. `debian/postinst` still probes for it
  (via `postmap -q`) and restarts Postfix itself once as cheap, harmless
  defense in depth for the rare case of a genuinely hand-dropped role —
  but doesn't restart the shared PgBouncer service on every other
  feature's behalf.
- **Inbound reachability, port 25 specifically: not yet independently
  confirmed** (unlike 80, see below). `test-static-internet-ip`'s own
  `nft` firewall originally dropped all inbound traffic except DNS/
  DHCP/NTP/SSH — with the user's explicit approval (2026-09-09, this
  host is genuinely public-facing), narrow allow rules for
  25/80/443/587/993/143 were added to `/etc/nftables.conf` and applied
  live. Minutes later, `homelab-webproxy-apply-sites` obtained real
  Let's Encrypt certificates via the real HTTP-01 challenge for both
  `drive.test.mailmasker.org` and `mail.test.mailmasker.org` — Let's
  Encrypt's own servers are an authoritative independent external
  verifier, so **port 80 reachability is now definitively confirmed**
  (see `webproxy/README.md`), which also resolves the earlier
  "separate upstream `pve2`/`pfsense02` layer" concern — evidently there
  wasn't one, at least not for port 80. Port 25 has no equivalent
  built-in independent verifier the way 80 does via Let's Encrypt, so it
  remains unconfirmed from real external mail servers, though the same
  fix that resolved 80 makes it likely 25 is fine too. Confirming it for
  real needs either a genuine external mail server actually attempting
  delivery, or a third-party "is my port open" check.
