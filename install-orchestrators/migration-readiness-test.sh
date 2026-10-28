#!/bin/bash
# ============================================================================
# migration-readiness-test.sh -- cumulative health + readiness harness for the
# greenfield prod-homelab* fleet. RUN ON THE DESKTOP (passwordless ssh+sudo to
# the fleet). Grows one section per tier as the install proceeds.
#
# Two phases:
#   INSTALL-READINESS (always run): every installed tier is healthy + wired.
#   MIGRATION-TIME (--cutover): the end-to-end public tests we run AT cutover,
#     once edge/haproxy/public-DNS are live -- public vhosts, per-domain mail
#     delivery, gmail<->domain round-trips (mutt/swaks), DKIM verification.
#
# Usage: migration-readiness-test.sh [--cutover]
# ============================================================================
set -uo pipefail

CUTOVER=0; [ "${1:-}" = "--cutover" ] && CUTOVER=1
BASELINE=0; [ "${1:-}" = "--baseline" ] && BASELINE=1   # test LIVE old-prod TODAY (reference)
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP+1)); }
sec()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
h()    { printf 'prod-homelab%s' "$1"; }
vm()   { printf 'prod-homelabvm%s' "$1"; }
SSHO="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
S(){ ssh $SSHO "$@"; }                  # ssh to a fleet node (name)
IP(){ ssh $SSHO "gardner@10.20.2.$((144 + 10#$1))" "${@:2}"; }   # edge nodes 00-05 by mgmt IP

# ---------------------------------------------------------------- PRE-MIGRATION BASELINE
# How LIVE production works TODAY -- the reference the new fleet must reproduce at --cutover.
# Run NOW, while old-prod is live and public DNS still points at it. Proves the test logic
# on a known-good system, and captures the DNS/mail contract to match after cutover.
if [ "$BASELINE" = "1" ]; then
  sec "PRE-MIGRATION BASELINE -- LIVE production, today"
  # authoritative production mail domains (try old-prod PowerDNS; fall back to a stub list)
  DOMAINS="$(psql powerdns -tAc 'SELECT name FROM domains ORDER BY name' 2>/dev/null | tr '\n' ' ')"
  [ -z "$DOMAINS" ] && DOMAINS="$(ssh $SSHO database 'psql powerdns -tAc "SELECT name FROM domains ORDER BY name"' 2>/dev/null | tr '\n' ' ')"
  if [ -n "$DOMAINS" ]; then ok "enumerated $(echo $DOMAINS | wc -w) production domains from old-prod PowerDNS"
  else skip "could not read old-prod PowerDNS -- edit DOMAINS= in this script by hand"; DOMAINS="mailmasker.org forge.name"; fi
  printf '  domains: %s\n' "$DOMAINS"

  sec "BASELINE: public web vhosts answer today (served by old-prod)"
  for pub in mail.mailmasker.org drive.mailmasker.org login.mailmasker.org; do
    c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$pub/" 2>/dev/null)
    # any HTTP response = the public edge + vhost are live (SSO vhosts 404 at / by design);
    # only a connection failure (000/empty) is a real baseline failure.
    case "$c" in 000|"") bad "https://$pub unreachable (no HTTP response)";; *) ok "https://$pub answers ($c)";; esac
  done

  sec "BASELINE: per-domain DNS contract (MX / SPF / DMARC) to reproduce after cutover"
  for d in $DOMAINS; do
    mx="$(dig +short MX "$d" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
    spf="$(dig +short TXT "$d" 2>/dev/null | tr -d '"' | grep -i 'v=spf1' | head -1)"
    dmarc="$(dig +short TXT "_dmarc.$d" 2>/dev/null | grep -ci 'v=DMARC1')"
    [ -n "$mx" ]  && ok "$d  MX=$mx"            || bad "$d  has NO MX in public DNS today"
    [ -n "$spf" ] && ok "$d  SPF=$(echo "$spf" | cut -c1-54)" || skip "$d  no SPF TXT"
    [ "${dmarc:-0}" -ge 1 ] && ok "$d  DMARC present" || skip "$d  no _dmarc TXT"
  done

  sec "BASELINE: mail round-trips (assisted -- run with operator; this is the gold reference)"
  printf '  For EACH domain, capture a PASS now against live prod, then expect the identical\n  PASS at --cutover against the new fleet:\n'
  for d in $DOMAINS; do
    printf '   %s\n' "$d"
    printf '     IN  external(%s, via mutt) -> test@%s ; confirm it lands in the %s mailbox\n' "$EXT_TEST_ADDR" "$d" "$d"
    printf '     OUT swaks --from test@%s --to %s --server mail.mailmasker.org:587 --tls --auth ;\n         then view in the external mailbox + confirm Authentication-Results: dkim=pass\n' "$d" "$EXT_TEST_ADDR"
  done
  printf '\n\033[1m== BASELINE SUMMARY: %d passed, %d failed, %d skipped ==\033[0m\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" = 0 ] && exit 0 || exit 1
fi

DB_NODES="06 07 08"; PGB_NODES="09 10 11"
DB_VIP=10.50.2.130; PGB_VIP=10.50.2.131; API_VIP=10.50.2.132

# External mailbox used as the far end of the mail round-trip checks. It is
# only ever PRINTED as an instruction for the operator -- nothing automated
# sends to it -- so it defaults to a placeholder rather than carrying a real
# personal address in a tracked, public-repo file.
#   EXT_TEST_ADDR='you@example.com' ./migration-readiness-test.sh
EXT_TEST_ADDR="${EXT_TEST_ADDR:-<your-external-mailbox>}"
LEADER=""
for n in $DB_NODES; do
  r="$(S "$(h "$n")" "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null" 2>/dev/null | tr -d '[:space:]')"
  [ "$r" = f ] && { LEADER="$n"; break; }
done
psqll(){ S "$(h "$LEADER")" "sudo -u postgres psql -d homelab -X -tA -c \"$1\"" 2>/dev/null | tr -d '[:space:]'; }

# ---------------------------------------------------------------- DB HA
sec "DB HA  (CT06/07/08, Patroni + etcd + keepalived VIP $DB_VIP)"
[ -n "$LEADER" ] && ok "DB primary present = $(h "$LEADER")" || bad "no DB primary among $DB_NODES"
cnt=0; for n in $DB_NODES; do S "$(h "$n")" "systemctl is-active --quiet patroni" 2>/dev/null && cnt=$((cnt+1)); done
[ "$cnt" = 3 ] && ok "patroni active on all 3" || bad "patroni active on only $cnt/3"
S "$(h "$LEADER")" "ip a | grep -q $DB_VIP" 2>/dev/null && ok "DB VIP $DB_VIP held by the primary" || skip "DB VIP not on the queried primary (may be elsewhere)"

# ---------------------------------------------------------------- pgbouncer
sec "pgbouncer  (CT09/10/11 + VIP $PGB_VIP)"
for p in $PGB_NODES; do
  S "$(h "$p")" "systemctl is-active --quiet pgbouncer" 2>/dev/null && ok "pgbouncer active on $(h "$p")" || bad "pgbouncer DOWN on $(h "$p")"
done
rc=$(S "$(h 09)" "sudo grep -c '\"homelab' /etc/pgbouncer/userlist.txt" 2>/dev/null)
[ "${rc:-0}" -ge 1 ] && ok "userlist has $rc role(s) registered on $(h 09)" || bad "userlist empty on $(h 09)"

# ---------------------------------------------------------------- api + worker
sec "api + worker  (CT12-14 api, CT15-17 worker, api VIP $API_VIP)"
for n in 12 13 14; do
  c=$(S "$(h "$n")" "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/health" 2>/dev/null)
  [ "$c" = 200 ] && ok "api /health 200 on $(h "$n")" || bad "api /health=$c on $(h "$n")"
done
c=$(S "$(h 12)" "curl -s -o /dev/null -w '%{http_code}' http://$API_VIP:3000/health" 2>/dev/null)
[ "$c" = 200 ] && ok "api VIP $API_VIP /health 200" || bad "api VIP /health=$c"
w=$(psqll "SELECT count(*) FROM api.service_registry WHERE feature_name='homelab-worker'")
[ "${w:-0}" -ge 1 ] && ok "$w worker(s) in api.service_registry" || bad "no workers registered"

# ---------------------------------------------------------------- sso + LOGIN KEYSTONE
sec "sso + LOGIN KEYSTONE  (CT18-20)"
for n in 18 19 20; do
  S "$(h "$n")" "ss -ltn | grep -q ':2502'" 2>/dev/null && ok "sso :2502 on $(h "$n")" || bad "sso :2502 DOWN on $(h "$n")"
done
# The keystone: a real credential validates through the api (what sso calls).
# Requires the throwaway smoketest account (first-admin tool). Non-fatal if absent.
# The password comes from the environment, never from a literal in this file.
# It used to be a "__SMOKETEST_PW__" placeholder meant to be edited in before a
# run -- i.e. a slot whose whole purpose was to hold a real credential in a
# tracked file. Pass it per-run instead:  SMOKETEST_PW='...' ./migration-readiness-test.sh
if psqll "SELECT 1 FROM api.users WHERE email='smoketest@test.mailmasker.org'" | grep -q 1; then
  if [ -z "${SMOKETEST_PW:-}" ]; then
    skip "login keystone: set SMOKETEST_PW in the environment to enable"
  else
  # Build the JSON here, then ship it as one single-quoted argument -- the
  # previous inline version nested three levels of quoting through ssh and was
  # unreadable (and unverifiable) by inspection.
  # Assumes the password contains no literal " or \ (true of the generated
  # smoketest credential); this is a readiness probe, not a general client.
  payload=$(printf '{"email":"smoketest@test.mailmasker.org","password":"%s"}' "$SMOKETEST_PW")
  code=$(S "$(h 18)" "curl -s -o /dev/null -w '%{http_code}' -X POST http://$API_VIP:3000/api/v1/auth/login -H 'Content-Type: application/json' -d '$payload'" 2>/dev/null)
  [ "$code" = 200 ] && ok "login keystone: sso-host -> api VIP login 200" || skip "login keystone: got $code"
  fi
else
  skip "login keystone: no smoketest account (create via homelab-api-create-admin)"
fi

# ---------------------------------------------------------------- audit
sec "audit  (CT24-26)"
for n in 24 25 26; do S "$(h "$n")" "ss -ltn | grep -q ':2513'" 2>/dev/null && ok "audit :2513 on $(h "$n")" || bad "audit :2513 DOWN on $(h "$n")"; done
[ "$(psqll "SELECT to_regclass('audit.queue') IS NOT NULL")" = t ] && ok "audit.queue exists" || bad "audit.queue missing"
[ "$(psqll "SELECT has_table_privilege('homelab_api_runtime','audit.queue','INSERT')")" = t ] && ok "api_runtime can INSERT audit.queue (login not fail-closed)" || bad "api_runtime lacks audit.queue INSERT"

# ---------------------------------------------------------------- domain-admin
sec "domain-admin  (CT21-23)"
for n in 21 22 23; do S "$(h "$n")" "ss -ltn | grep -q ':2511'" 2>/dev/null && ok "domain-admin :2511 on $(h "$n")" || bad "domain-admin :2511 DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM information_schema.tables WHERE table_schema='domainadmin'")" -ge 1 ] 2>/dev/null && ok "domainadmin schema present" || bad "domainadmin schema missing"

# ---------------------------------------------------------------- dns / PowerDNS
sec "dns / PowerDNS  (CT03-05, shared powerdns DB)"
for n in 03 04 05; do IP "$n" "sudo ss -ulnp | grep -q ':53 '" 2>/dev/null && ok "pdns :53 on CT$n" || bad "pdns :53 DOWN on CT$n"; done
AK="$(S "$(h 21)" "sudo awk '/^powerdns:/{f=1} f&&/api_key:/{print \$2; exit}' /etc/homelab/domain-admin/config.yml" 2>/dev/null)"
c=$(S "$(h 21)" "curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: $AK' http://10.50.2.147:8081/api/v1/servers" 2>/dev/null)
[ "$c" = 200 ] && ok "PowerDNS API reachable from domain-admin (200)" || bad "PowerDNS API from domain-admin = $c"

# ---------------------------------------------------------------- mail: dovecot
sec "mail: dovecot  (VM62-64)"
for n in 62 63 64; do S "$(vm "$n")" "ss -ltn | grep -qE ':(993|143) '" 2>/dev/null && ok "dovecot IMAP up on $(vm "$n")" || bad "dovecot IMAP DOWN on $(vm "$n")"; done
[ "$(psqll "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'homelab_dovecot_runtime_%'")" = 3 ] && ok "3 dovecot per-node roles" || bad "dovecot roles != 3"

# ---------------------------------------------------------------- mail: postfix
sec "mail: postfix  (CT39-41)"
for n in 39 40 41; do S "$(h "$n")" "ss -ltn | grep -q ':25 '" 2>/dev/null && ok "postfix :25 on $(h "$n")" || bad "postfix :25 DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'homelab_postfix_runtime_%'")" = 3 ] && ok "3 postfix per-node roles" || bad "postfix roles != 3"

# ---------------------------------------------------------------- web: roundcube
sec "web: roundcube  (CT42-44)"
for n in 42 43 44; do S "$(h "$n")" "systemctl is-active --quiet nginx" 2>/dev/null && ok "roundcube nginx up on $(h "$n")" || bad "roundcube nginx DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM information_schema.tables WHERE table_schema='roundcube'")" -ge 10 ] 2>/dev/null && ok "roundcube schema has vendor tables" || bad "roundcube schema incomplete"

# ---------------------------------------------------------------- web: drive
sec "web: drive  (VM65-67)"
for n in 65 66 67; do S "$(vm "$n")" "ss -ltn | grep -q ':2501 '" 2>/dev/null && ok "drive :2501 on $(vm "$n")" || bad "drive :2501 DOWN on $(vm "$n")"; done
[ "$(psqll "SELECT count(*) FROM information_schema.tables WHERE table_schema='drive'")" -ge 1 ] 2>/dev/null && ok "drive schema present" || bad "drive schema missing"
[ "$(psqll "SELECT has_table_privilege('homelab_drive_runtime','audit.queue','INSERT')")" = t ] && ok "drive_runtime audit.queue INSERT granted" || bad "drive_runtime missing audit grant"

# ---------------------------------------------------------------- web: accountmanage
sec "web: accountmanage  (CT27-29)"
for n in 27 28 29; do S "$(h "$n")" "ss -ltn | grep -q ':2503 '" 2>/dev/null && ok "accountmanage :2503 on $(h "$n")" || bad "accountmanage :2503 DOWN on $(h "$n")"; done
[ "$(S "$(h 18)" "sudo grep -c 'client_id: accountmanage' /etc/homelab/sso/config.yml" 2>/dev/null)" -ge 1 ] && ok "accountmanage registered as an sso client" || bad "accountmanage not an sso client"

# ---------------------------------------------------------------- feature: invite
sec "feature: invite  (CT30-32)"
for n in 30 31 32; do S "$(h "$n")" "ss -ltn | grep -q ':2514 '" 2>/dev/null && ok "invite :2514 on $(h "$n")" || bad "invite :2514 DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM information_schema.tables WHERE table_schema='invite'")" -ge 1 ] 2>/dev/null && ok "invite schema present" || bad "invite schema missing"

# ---------------------------------------------------------------- feature: block-link
sec "feature: block-link  (CT33-35)"
for n in 33 34 35; do S "$(h "$n")" "ss -ltn | grep -q ':2515 '" 2>/dev/null && ok "block-link :2515 on $(h "$n")" || bad "block-link :2515 DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM information_schema.tables WHERE table_schema='block_link'")" -ge 1 ] 2>/dev/null && ok "block_link schema present" || bad "block_link schema missing"

# ---------------------------------------------------------------- mailbridge
sec "mailbridge  (CT36-38)"
for n in 36 37 38; do S "$(h "$n")" "ss -ltn | grep -q ':2510 '" 2>/dev/null && ok "mailbridge :2510 on $(h "$n")" || bad "mailbridge :2510 DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM pg_roles WHERE rolname='homelab_mailbridge_runtime'")" = 1 ] && ok "mailbridge runtime role present" || bad "mailbridge role missing"

# ---------------------------------------------------------------- add-on: postfix-block-link
sec "add-on: postfix-block-link  (CT39-41 milter)"
for n in 39 40 41; do S "$(h "$n")" "systemctl is-active --quiet homelab-postfix-block-link && ss -ltn | grep -q ':8892 '" 2>/dev/null && ok "pbl milter active :8892 on $(h "$n")" || bad "pbl milter DOWN on $(h "$n")"; done
[ "$(psqll "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'homelab_postfix_block_link_runtime_%'")" = 3 ] && ok "3 pbl per-node roles" || bad "pbl roles != 3"

# ---------------------------------------------------------------- add-on: roundcube-invite
sec "add-on: roundcube-invite  (CT42-44 plugin)"
for n in 42 43 44; do S "$(h "$n")" "sudo grep -q invite_sender /etc/roundcube/config.inc.php" 2>/dev/null && ok "invite_sender plugin on $(h "$n")" || bad "invite_sender NOT registered on $(h "$n")"; done

# ======================= TIERS BELOW ADDED AS INSTALLED =======================

# ---------------------------------------------------------------- MIGRATION-TIME
sec "MIGRATION-TIME end-to-end  (--cutover; needs edge/haproxy/public DNS live)"
if [ "$CUTOVER" = 0 ]; then
  skip "public vhost: https://drive.mailmasker.org reachable + login"
  skip "public vhost: https://mail.mailmasker.org (roundcube) reachable + SSO login"
  skip "inbound per domain: from $EXT_TEST_ADDR -> <addr>@<domain>, delivered to the dovecot mailbox"
  skip "outbound+DKIM per domain: swaks from <addr>@<domain> -> $EXT_TEST_ADDR, DKIM-Signature present + Authentication-Results dkim=pass"
  printf '  (run with --cutover once edge/haproxy/public DNS + DKIM records are live)\n'
  printf '  planned, per allowed delivery domain (forge.name, mailmasker.org, ...):\n'
  printf '    IN : mutt (as %s) -> <user>@<domain> ; confirm via: doveadm search -u <user>@<domain> ALL\n' "$EXT_TEST_ADDR"
  printf '    OUT: swaks --from <user>@<domain> --to %s --server mail.mailmasker.org --tls ; confirm in that mailbox that DKIM passed\n' "$EXT_TEST_ADDR"
else
  # Enumerate the allowed delivery domains from domainadmin.domains (post-ETL).
  DOMAINS="$(psqll "SELECT string_agg(domain_name, ' ') FROM domainadmin.domains WHERE mail_enabled AND active")"
  for pub in drive.mailmasker.org mail.mailmasker.org login.mailmasker.org; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$pub/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && ok "public vhost https://$pub -> $c" || bad "public vhost https://$pub unreachable ($c)"
  done
  if [ -z "$DOMAINS" ]; then skip "no mail_enabled domains in domainadmin.domains yet (run after the domain ETL)"; else
    for d in $DOMAINS; do
      skip "TODO inbound  gmail -> test@$d (send via mutt, confirm with doveadm search -u test@$d ALL)"
      skip "TODO outbound swaks --from test@$d --to $EXT_TEST_ADDR --server mail.mailmasker.org --tls (confirm DKIM=pass in that mailbox)"
    done
  fi
fi

# ---------------------------------------------------------------- summary
printf '\n\033[1m== SUMMARY: %d passed, %d failed, %d skipped ==\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] && exit 0 || exit 1
