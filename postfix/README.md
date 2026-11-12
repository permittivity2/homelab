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
- **SASL authentication is delegated entirely to Dovecot, over plain
  TCP.** Postfix itself never queries Postgres for credentials —
  `smtpd_sasl_type = dovecot` + `smtpd_sasl_path =
  inet:<dovecot_host>:12345` hands the whole PLAIN/LOGIN exchange to
  Dovecot's own passdb over the network, the exact same passdb every
  IMAP login already uses. One Argon2id password in `api.users` backs
  both paths, but each service holds its own narrowly-scoped
  credential — Postfix's own Postgres role can't even read
  `password_hash`, so a compromise of the SMTP submission path doesn't
  expose password hashes the way a shared "the MTA can also do full
  auth lookups" design would.
- **Delivery is LMTP to `homelab-dovecot`**, not Postfix's own local/
  virtual delivery agent: `virtual_transport = lmtp:inet:<dovecot_host>:24`,
  pointing at the TCP LMTP listener `homelab-dovecot` exposes
  specifically for this (see its own README's Gotchas section for why
  that listener binds all interfaces rather than just loopback).
  `<dovecot_host>` is `homelab-postfix/dovecot_host` (debconf, default
  `localhost`) — Postfix and Dovecot are independently placeable, not
  required to be on the same host. Confirmed against this project's own
  production mail stack, which really does run them on separate hosts
  talking over exactly these same two ports (`lmtp:inet:dovecot01:24`,
  `smtpd_sasl_path = inet:dovecot01:12345`).

## No cross-package config writes

Earlier versions of this package wrote a SASL-socket drop-in directly
into Dovecot's own `conf.d/` (`smtpd_sasl_path = private/auth`, a unix
socket only reachable when co-located) and required Postfix to start
first so the socket directory existed before Dovecot could bind into
it. Both the drop-in and the install-order dependency are gone now that
SASL goes over the network instead: `homelab-dovecot` exposes its auth
listener unconditionally on its own (`conf.d/91-homelab-dovecot.conf.template`'s
`service auth { inet_listener auth { port = 12345 } }`, right next to
its existing LMTP listener), and this package's `postinst` never
touches Dovecot's files at all, co-located or not.

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

## DKIM signing (OpenDKIM, opt-in)

`homelab-postfix/enable_dkim` (debconf boolean, **default false**) wires
DKIM signing into Postfix via OpenDKIM as a milter — deliberately
opt-in rather than forced onto every install: an already-configured,
already-working host answering "false" (the default, and what a routine
`apt upgrade` sees) gets zero milter-config change at all. Turn it on
explicitly with `dpkg-reconfigure homelab-postfix` when ready; key
generation/rotation itself is a completely separate concern handled by
`homelab-domain-admin` (`homelab-cli dns dkim rotate/activate/retire`,
see `../domain-admin/README.md`'s "DKIM key rotation" section for the
full state-machine design) — this package only wires the milter and
prepares the filesystem, it never generates or touches key material
itself.

When enabled, `postinst`:
- Creates `/etc/opendkim/keys` owned `opendkim:opendkim`, mode `0700`,
  and makes every key already there `opendkim:opendkim` 0600 (since
  0.1.29, post-cutover #68). `homelab-domain-admin` >= 0.1.45 does not
  write here: it writes its own staging tree under
  `/var/lib/homelab/opendkim` and hands it to root
  (`sudo homelab-opendkim-install`, its own sudoers rule), which mirrors
  it in. If an OLDER `homelab-domain-admin` is still installed the
  postinst keeps the legacy layout instead (`homelab` in group
  `opendkim`, dir `2770`, keys 0640, `RequireSafeKeys no`) and says so;
  upgrade it, then `dpkg-reconfigure homelab-postfix`.
- Creates empty `KeyTable`/`SigningTable` (0640; `homelab-domain-admin`
  rebuilds their real content on every rotate/activate/retire — this
  package only creates them so OpenDKIM has something to point at from
  first boot) and an empty `TrustedHosts`.
- Installs `config/opendkim.conf.template` wholesale as
  `/etc/opendkim.conf` (OpenDKIM has no drop-in include directory the
  way Postfix/PowerDNS do, so this replaces the vendor default
  entirely rather than patching it).
- Wires `smtpd_milters`/`non_smtpd_milters` to `inet:localhost:8891`
  via the same read-modify-append idiom used elsewhere in this package
  (never clobbers a hand-added milter already present), plus
  `milter_default_action = accept` and `milter_protocol = 6`.
- Enables and (re)starts the `opendkim` service.

**OpenDMARC is deliberately NOT wired here.** An earlier version of
this package's milter config also pointed at `inet:localhost:8893`
(OpenDMARC's default port) — but OpenDMARC was never actually installed
or configured by this package, so every message hit a real, live
"Connection refused" from Postfix trying to reach a milter that
genuinely doesn't exist on this host. Removed from both the postinst
wiring logic and the debconf template's own description text; DMARC
policy enforcement is explicitly out of scope for this package for now,
not an oversight.

### Safe keys: the hand-off through root (`RequireSafeKeys yes` since 0.1.29)

OpenDKIM's "safe keys" check wants a private key readable by its owner
only. Until 0.1.28 that could never pass here: `homelab-domain-admin`
(running as `homelab`) wrote the keys straight into `/etc/opendkim/keys`
and the daemon read them through group `opendkim`, with `homelab` a
second member of that group — "multiple users" to the check. So the
template set `RequireSafeKeys no`; signing worked, and OpenDKIM logged
"key data is not secure: root is in group ... which has multiple users"
on **every** signature (post-cutover #68 counted 13–24 lines a day per
node). Since 0.1.29 (with `homelab-domain-admin` >= 0.1.45) the keys
are written by root from the service's staging tree as
`opendkim:opendkim` 0600, `homelab` is out of the group, and the check
is on. The one remaining knob is the postinst's legacy fallback for a
host whose `homelab-domain-admin` is still older — see above.

Two lines belong together here: `RequireSafeKeys yes` **and** `UserID
opendkim`. The check compares the key directory's owner with the
*executing* uid, and this template never set `UserID`, so OpenDKIM had
been running as root (the Debian unit sets no `User=`); 0.1.29 turned the
check on without it and the first signer refused every key and tempfailed
submissions until 0.1.30 added the line (2026-11-11). Running the filter
as `opendkim` is also simply the right privilege, and what Debian's own
default config does.

## What port 25 does not offer (0.1.31, post-cutover #65)

The public MX answers only what an MX needs. Three `postconf` settings in
`postinst`, re-applied on every configure:

- `smtpd_sasl_auth_enable = no` (main.cf) — **no AUTH on 25**: not
  advertised, `AUTH …` → `503`. The submission (587) and smtps (465)
  stanzas set `-o smtpd_sasl_auth_enable=yes -o smtpd_tls_auth_only=yes`
  for themselves, so authenticated sending is unchanged and TLS-only.
  Fourteen days of logs on all three signers showed zero AUTH attempts on
  25 (successful or failed) before the change; `smtpd_tls_auth_only =
  yes` is also the global default now, for any future listener.
- `disable_vrfy_command = yes` — EHLO stops advertising VRFY on every
  listener and `VRFY x` → `502 5.5.1 VRFY command is disabled`. Scanners
  flag it; no MTA or client uses it. EXPN was never implemented (`500`).
- `smtpd_helo_required = yes` — `MAIL FROM` before HELO/EHLO → `503
  5.5.1 Error: send HELO/EHLO first`. Every real MTA and mail app sends
  EHLO; this turns away the laziest bots.

Not changed, by design: `RCPT TO` on 25 still rejects unknown mailboxes
(an MX must; accepting everything and bouncing later causes backscatter).
Checks: `tests/e2e/test_postfix_mail.py` and
`install-orchestrators/mail-hardening-orchestrate.sh --verify`.

## `master.cf`'s submission (587) and smtps (465) services

Postfix ships `master.cf` with the submission (587) and submissions
(465) services present but fully commented out, each with a slightly
different set of example `-o` overrides in the comments. Rather than try
to uncomment-and-edit those in place (fragile, and the overrides this
deployment actually needs differ from the vendor's commented example),
`postinst` appends two fresh, fully-specified, clearly marked blocks
once, idempotently, and leaves the vendor's commented examples untouched:

- `config/master.cf.submission-stanza` (`# BEGIN/END homelab-postfix
  managed`): port 587, STARTTLS required (`smtpd_tls_security_level=encrypt`).
- `config/master.cf.smtps-stanza` (`# BEGIN/END homelab-postfix managed
  smtps`, since 0.1.28 / post-cutover #70): port 465, implicit TLS
  (`smtpd_tls_wrappermode=yes`), the "SSL/TLS" choice in every mail app.
  Same SASL, relay, recipient and sender-login rules, same `ORIGINATING`
  macro; `syslog_name=postfix/smtps` (bad-ips' Postfix rules match
  `postfix/smtps/smtpd` already). Behind homelab-haproxy the PROXY
  protocol header is read before the TLS handshake, as on Dovecot's 993.

Both services' `smtpd_milters` (OpenDKIM last) and `milter_default_action`
(tempfail, set by homelab-postfix-block-link) are per-service `postconf
-P` overrides re-applied on every configure, never lines in the stanza
files. Offering both ports removes a whole class of client misconfiguration:
"SSL/TLS" on 587 and "STARTTLS" on 465 both fail with unhelpful errors.

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

- **Outbound port 25 to the real internet must be opened by hand on
  every Postfix host's own nftables config -- nothing in this package,
  or anywhere else in this repo, provisions it.** Found live, 2026-09-26:
  a real invite email (Roundcube's own `deliver_message()`, not this
  package's own submission path -- but the outbound relay hop is the
  same either way) sat deferred for nearly an hour
  (`status=deferred (connect to ...:25: Connection timed out)`) before
  someone noticed. `/etc/nftables.conf`'s own `chain output` on every
  Postfix host (ct05/ct06/ct07 as of this writing) had narrow, explicit
  allow rules for this host's OWN internal needs only -- LMTP delivery
  to Dovecot, the OpenDKIM milter socket, Postgres/PgBouncer, port
  80/443 -- and simply never had a rule for plain outbound SMTP at all.
  Inbound port 25 (accepting mail FROM the internet) and internal LMTP
  delivery (to fleet-managed domains) both worked fine without it,
  which is exactly why this went unnoticed until the first real
  external-domain send: nothing about local delivery or receiving mail
  ever exercises Postfix's own OUTBOUND relay path. Confirmed NOT a
  pfsense/production-firewall issue -- port 443 to the same external IP
  worked fine from these same hosts, and port 25 to that same IP worked
  fine from a genuinely different network, isolating the block to each
  Postfix host's own local egress rule. Fix: add a bare
  `tcp dport 25 accept` to `chain output` in `/etc/nftables.conf`
  (deliberately unrestricted by destination -- Postfix's whole job here
  is relaying to arbitrary external mail servers) and
  `systemctl reload nftables` (a full flush+reapply per the file's own
  `flush ruleset` line -- see the badips incident writeup elsewhere in
  this project for why an incremental live `nft add rule` isn't the
  right way to apply a change like this). NOT needed on ct00: it never
  originates outbound SMTP itself, only relays already-open connections
  to the internal Postfix pool via HAProxy, so its own narrower
  `ip daddr 10.50.0.0/22`-scoped rule is correct as-is and was
  deliberately left untouched.

- **A new config template needs its own explicit `install -D` line in
  `debian/rules`, or the package builds fine and fails at postinst
  time instead.** Adding `config/opendkim.conf.template` without also
  adding its matching `install -D` line in `debian/rules` produced a
  `.deb` that built and installed the control scripts without error,
  then failed with `install: No such file or directory` the moment
  `postinst` actually tried to install that template on a host with
  DKIM enabled — nothing at build time checks that every file under
  `config/` has a matching install line. Worth double-checking `rules`
  whenever a new template is added here.
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
