#!/bin/bash
# ============================================================================
# Post-cutover #67 -- "reply from the alias a message was sent to".
# RUN ON THE ADMIN WORKSTATION.
#
#   ./mail-reply-alias-orchestrate.sh              deploy everything, verify (re-runnable)
#   ./mail-reply-alias-orchestrate.sh --verify     read-only checks, changes nothing
#   ./mail-reply-alias-orchestrate.sh --fixtures   add the four test aliases -> test account
#   ./mail-reply-alias-orchestrate.sh --cleanup    remove them, switch the test account off
#   ./mail-reply-alias-orchestrate.sh --check NN   functional check against one mail node only
#
# WHAT IT ROLLS OUT (packages must already be built + published):
#   homelab-domain-admin >= 0.1.44   two tables (migration 009) + the per-user switch route
#   grants                           the three milter roles (_39/_40/_41) on the DB primary --
#                                    the milter's bootstrap runs only at first install, so this
#                                    is the ONLY way an existing host gets them (no guest SSH)
#   homelab-postfix >= 0.1.26        OpenDKIM first on 25, last on 587 (postconf -P override)
#   homelab-postfix-block-link >= 0.2.0  the milter: record + rewrite; milter order; tempfail on 587
#   homelab-developer/-cli/-accountmanage  reference, `mail reply-from-alias`, the myaccount card
#
# ORDER MATTERS: tables -> grants -> postfix -> milter, one mail node at a time,
# each followed by a real send/reply round trip through THAT node's 587.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
FAILS=0

h(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }

MAIL_NODES="39 40 41"
DB_NODES="06 07 08"
ACCOUNTMANAGE_NODES="27 28 29"
WANT_DA=0.1.44; WANT_PF=0.1.27; WANT_BL=0.2.2; WANT_DEV=0.1.4; WANT_CLI=0.6.15; WANT_AM=0.1.46

TEST_ACCOUNT="${TEST_ACCOUNT:-testaccountforclaude@mailmasker.org}"
# The test account's password stays in a file outside this repository; only
# the PATH is known here and the checker reads it itself (never an argument).
PW_FILE="${TEST_ACCOUNT_PW_FILE:-/home/gardner/claude/general/homelab_issues_and_fixes/post-cutover/secrets/testaccountforclaude.pw}"
[ -r "$PW_FILE" ] || { echo "ERROR: cannot read the test account password file $PW_FILE (set TEST_ACCOUNT_PW_FILE)"; exit 1; }
FIXTURE_TAG=claude-67-test-fixture
FIXTURES="claude67a@forge.name claude67b@forge.name claude67a@giraffenow.org claude67b@giraffenow.org"
CHECK=./files/mail-reply-alias-check.py
BOOTSTRAP=../postfix-block-link/script/homelab-postfix-block-link-bootstrap-role
ROLES="homelab_postfix_block_link_runtime_39 homelab_postfix_block_link_runtime_40 homelab_postfix_block_link_runtime_41"

MODE=deploy; ONE_NODE=""
case "${1:-}" in
    "") ;;
    --verify) MODE=verify ;;
    --fixtures) MODE=fixtures ;;
    --cleanup) MODE=cleanup ;;
    --check) MODE=check; ONE_NODE="$(printf '%02d' "$((10#${2:-0}))")" ;;
    *) echo "usage: $0 [--verify | --fixtures | --cleanup | --check NN]"; exit 1 ;;
esac

LOG="/home/gardner/claude/temp/mail-reply-alias-orchestrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"

SRC_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"

find_leader(){ local n r
  for n in $DB_NODES; do
    r="$(rssh "$(h "$n")" "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" | tr -d '[:space:]')"
    [ "$r" = "f" ] && { printf '%s' "$n"; return 0; }
  done
  return 1
}
LEADER="$(find_leader)" || { echo "ERROR: no DB primary reachable among $DB_NODES"; exit 1; }
LEADER_IP="$(h "$LEADER")"
psql_leader(){ ssh -o BatchMode=yes "$LEADER_IP" "sudo -u postgres psql -d homelab -X -q -tA -v ON_ERROR_STOP=1"; }   # SQL on stdin
echo "DB primary = prod-homelab$LEADER ($LEADER_IP); workstation = $SRC_IP"

ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }

# ---------------------------------------------------------------- pieces --

check_tables(){
  local t
  t="$(printf "SELECT to_regclass('domainadmin.mail_reply_identity') IS NOT NULL AND to_regclass('domainadmin.mail_received_via') IS NOT NULL;" | psql_leader)"
  [ "$t" = "t" ] && ok "tables domainadmin.mail_reply_identity + mail_received_via exist" || bad "tables missing (domain-admin migration 009 not applied yet)"
}

check_grants(){
  local out r
  out="$(printf "SELECT r || ' ' || has_table_privilege(r,'domainadmin.mail_received_via','INSERT') || has_table_privilege(r,'domainadmin.mail_received_via','SELECT') || has_table_privilege(r,'domainadmin.mail_reply_identity','SELECT') || has_sequence_privilege(r,'domainadmin.mail_received_via_id_seq','USAGE') FROM unnest(ARRAY['%s','%s','%s']) r;" $ROLES | psql_leader)"
  for r in $ROLES; do   # booleans concatenated to text print as true/false
    case "$out" in *"$r truetruetruetrue"*) ok "grants on the #67 tables for $r" ;; *) bad "grants incomplete for $r ($(echo "$out" | grep "$r" || echo 'no row'))" ;; esac
  done
}

apply_grants(){
  local s
  for s in 39 40 41; do
    perl "$BOOTSTRAP" --print-grants --role-suffix "$s" | psql_leader >/dev/null \
      && ok "grants applied for homelab_postfix_block_link_runtime_$s" \
      || bad "grants for homelab_postfix_block_link_runtime_$s failed"
  done
}

node_checks(){ # $1 = NN ; the milter-order / unit / override checks
  local ip v act x; ip="$(h "$1")"
  v="$(ver_of "$ip" homelab-postfix)";            ver_ge "$v" "$WANT_PF" && ok "$1 homelab-postfix $v" || bad "$1 homelab-postfix $v < $WANT_PF"
  v="$(ver_of "$ip" homelab-postfix-block-link)"; ver_ge "$v" "$WANT_BL" && ok "$1 homelab-postfix-block-link $v" || bad "$1 homelab-postfix-block-link $v < $WANT_BL"
  act="$(rssh "$ip" 'systemctl is-active postfix opendkim homelab-postfix-block-link' | tr '\n' ' ')"
  [ "$act" = "active active active " ] && ok "$1 postfix, opendkim, milter active" || bad "$1 units: $act"
  x="$(rssh "$ip" 'postconf -h smtpd_milters')"
  [ "$x" = "inet:localhost:8891, inet:127.0.0.1:8892" ] && ok "$1 25: OpenDKIM first, block-link last" || bad "$1 smtpd_milters = $x"
  x="$(rssh "$ip" 'postconf -h non_smtpd_milters')"
  [ "$x" = "inet:127.0.0.1:8892, inet:localhost:8891" ] && ok "$1 local: block-link first, OpenDKIM last" || bad "$1 non_smtpd_milters = $x"
  x="$(rssh "$ip" 'postconf -Ph submission/inet/smtpd_milters')"   # postconf -P allows no whitespace: comma-only
  [ "$x" = "inet:127.0.0.1:8892,inet:localhost:8891" ] && ok "$1 587: block-link first, OpenDKIM last" || bad "$1 submission smtpd_milters = '$x'"
  x="$(rssh "$ip" 'postconf -Ph submission/inet/milter_default_action')"
  [ "$x" = "tempfail" ] && ok "$1 587: milter_default_action=tempfail (hold mail when the milter is down)" || bad "$1 submission milter_default_action = '$x'"
  x="$(rssh "$ip" 'postconf -Ph submission/inet/milter_macro_daemon_name')"
  [ "$x" = "ORIGINATING" ] && ok "$1 587: daemon_name ORIGINATING" || bad "$1 submission milter_macro_daemon_name = '$x'"
  x="$(rssh "$ip" 'postconf -h milter_default_action')"
  [ "$x" = "accept" ] && ok "$1 25: milter_default_action=accept (inbound fails open)" || bad "$1 main milter_default_action = $x"
  rssh "$ip" 'sudo -n postfix check' && ok "$1 postfix check" || bad "$1 postfix check reports a problem"
  rssh "$ip" 'sudo -n journalctl -u homelab-postfix-block-link -n 5 --no-pager' | grep -q 'listening on' && ok "$1 milter logged 'listening on'" || warn "$1 no fresh 'listening on' line in the last 5 journal lines"
  x="$(rssh "$ip" 'sudo -n journalctl -u homelab-postfix-block-link --since "-30min" --no-pager' | grep -c 'reply-identity: rewrote')"
  echo "       $1 rewrites in the last 30 min: $x"
}

functional_check(){ # $1 = NN
  step "functional check through prod-homelab$1's 587"
  if python3 "$CHECK" --password-file "$PW_FILE" --account "$TEST_ACCOUNT" roundtrip \
        --node-ip "$(h "$1")" --leader-ip "$LEADER_IP" --src-ip "$SRC_IP"; then
    ok "$1 round trip passed"
  else
    bad "$1 round trip FAILED (see above)"
  fi
  rssh "$(h "$1")" 'sudo -n journalctl -u homelab-postfix-block-link --since "-10min" --no-pager' | grep 'reply-identity' | tail -8 | sed 's/^/       /'
}

fixtures_present(){
  printf "SELECT count(*) FROM domainadmin.mail_aliases WHERE created_by = '%s' AND destination = '%s';" "$FIXTURE_TAG" "$TEST_ACCOUNT" | psql_leader
}

add_fixtures(){
  step "test aliases -> $TEST_ACCOUNT (exact rows beat the catch-all; removed by --cleanup)"
  local a sql=""
  for a in $FIXTURES; do
    sql="$sql INSERT INTO domainadmin.mail_aliases (source_pattern, destination, active, send_enabled, created_by) VALUES ('$a', '$TEST_ACCOUNT', true, true, '$FIXTURE_TAG') ON CONFLICT (source_pattern) DO NOTHING;"
  done
  printf '%s' "$sql" | psql_leader >/dev/null && ok "fixture rows present: $(fixtures_present)/4" || bad "could not insert the fixture aliases"
}

remove_fixtures(){
  step "cleanup: fixture aliases, recorded rows and the test account's switch"
  python3 "$CHECK" --password-file "$PW_FILE" --account "$TEST_ACCOUNT" setting off || warn "could not switch the test account off via the api"
  printf "DELETE FROM domainadmin.mail_aliases WHERE created_by = '%s' AND destination = '%s'; DELETE FROM domainadmin.mail_received_via WHERE account = '%s';" \
      "$FIXTURE_TAG" "$TEST_ACCOUNT" "$TEST_ACCOUNT" | psql_leader >/dev/null \
    && ok "fixture rows left: $(fixtures_present)" || bad "cleanup SQL failed"
}

verify_all(){
  step "verify: tables, grants, versions, milter order, switch"
  check_tables; check_grants
  local n ip v
  for n in $MAIL_NODES; do node_checks "$n"; done
  for n in $ACCOUNTMANAGE_NODES; do
    v="$(ver_of "$(h "$n")" homelab-accountmanage)"; ver_ge "$v" "$WANT_AM" && ok "$n homelab-accountmanage $v" || bad "$n homelab-accountmanage $v < $WANT_AM"
  done
  for n in $(seq 0 72); do
    ip="$(h "$n")"; timeout 3 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null || continue
    v="$(ver_of "$ip" homelab-domain-admin)"; [ -n "$v" ] && { ver_ge "$v" "$WANT_DA" && ok "$(printf '%02d' "$n") homelab-domain-admin $v" || bad "$(printf '%02d' "$n") homelab-domain-admin $v < $WANT_DA"; }
  done
  echo "  fixture aliases present: $(fixtures_present)"
  python3 "$CHECK" --password-file "$PW_FILE" --account "$TEST_ACCOUNT" setting show || bad "setting read via the public api failed"
}

# ------------------------------------------------------------------ run --

case "$MODE" in
  verify)   verify_all ;;
  fixtures) add_fixtures ;;
  cleanup)  remove_fixtures ;;
  check)    node_checks "$ONE_NODE"; functional_check "$ONE_NODE" ;;
  deploy)
    step "[1/6] homelab-domain-admin -> $WANT_DA everywhere it is installed (migration 009 = the tables)"
    ./pkg-upgrade.sh homelab-domain-admin --all || warn "pkg-upgrade homelab-domain-admin reported a problem"
    check_tables

    step "[2/6] grants for the three milter roles, on the DB primary (prod-homelab$LEADER)"
    apply_grants; check_grants

    step "[3/6] test aliases"
    [ "$(fixtures_present)" = "4" ] && ok "fixture rows already present" || add_fixtures

    step "[4/6] mail pool, one node at a time: homelab-postfix (milter order) then homelab-postfix-block-link (the milter)"
    for n in $MAIL_NODES; do
      ip="$(h "$n")"
      echo "  -- prod-homelab$n: before: postfix $(ver_of "$ip" homelab-postfix), block-link $(ver_of "$ip" homelab-postfix-block-link)"
      rssh "$ip" 'ls /var/cache/apt/archives/homelab-postfix-block-link_*.deb /var/cache/apt/archives/homelab-postfix_*.deb 2>/dev/null' | sed 's/^/       cached for rollback: /'
      ./pkg-upgrade.sh homelab-postfix "$n" || warn "pkg-upgrade homelab-postfix $n reported a problem"
      ./pkg-upgrade.sh homelab-postfix-block-link "$n" || warn "pkg-upgrade homelab-postfix-block-link $n reported a problem"
      node_checks "$n"
      functional_check "$n"
      if [ "$FAILS" -gt 0 ]; then
        echo; echo "${R}stopping before the next node: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1
      fi
    done

    step "[5/6] developer reference, cli, myaccount"
    ./pkg-upgrade.sh homelab-developer --all || warn "pkg-upgrade homelab-developer reported a problem"
    ./pkg-upgrade.sh homelab-cli --all || warn "pkg-upgrade homelab-cli reported a problem"
    ./pkg-upgrade.sh homelab-accountmanage $ACCOUNTMANAGE_NODES || warn "pkg-upgrade homelab-accountmanage reported a problem"

    step "[6/6] verify"
    verify_all
    ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then echo "${G}done: no failed checks${O} (log: $LOG)"; else echo "${R}done: $FAILS failed check(s)${O} (log: $LOG)"; exit 1; fi
