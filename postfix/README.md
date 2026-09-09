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
- **Inbound reachability from the real internet is partially, not
  fully, confirmed.** `test-static-internet-ip`'s own `nft` firewall
  originally dropped all inbound traffic except DNS/DHCP/NTP/SSH — with
  the user's explicit approval (2026-09-09, this host is genuinely
  public-facing), narrow allow rules for 25/80/443/587/993/143 were
  added to `/etc/nftables.conf` and verified live (the new rules show up
  in `nft list ruleset`, and the host's own SSH access survived the
  reload). What ISN'T independently confirmed: whether traffic on these
  new ports actually reaches the host from genuine external clients —
  ad hoc connectivity tests from the admin workstation itself gave
  inconsistent results (DNS reachable, SSH not, on the same public IP,
  from the same vantage point), suggesting that workstation isn't a
  reliable "real internet" test point either way, and don't rule out a
  separate upstream layer (`pve2` host-level or the `pfsense02` VM,
  both outside this project's 4-host authorization) still filtering
  something the same way it was already documented to for 80/443
  specifically. Confirming true external reachability needs a test from
  a genuinely independent vantage point — the user's own connection, or
  a third-party "is my port open" service.
