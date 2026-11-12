#!/bin/bash
# ============================================================================
# Post-cutover #70 -- SMTPS: port 465 (implicit TLS) next to 587 on the mail
# path. RUN ON THE ADMIN WORKSTATION.
#
#   ./smtps-orchestrate.sh             deploy: mail pool 39 -> 40 -> 41, then the edges
#                                      00 -> 01 -> 02, then the check from the internet (re-runnable)
#   ./smtps-orchestrate.sh --verify    read-only checks on every node + the internet check; changes nothing
#   ./smtps-orchestrate.sh --pool      the mail-pool part only
#   ./smtps-orchestrate.sh --edges     the edge part only
#   ./smtps-orchestrate.sh --internet  the check from offsite only
#
# WHAT IT ROLLS OUT (packages must already be built + published):
#   homelab-postfix >= 0.1.28            the smtps stanza (465, wrapper mode) + its OpenDKIM-last override
#   homelab-postfix-block-link >= 0.2.3  the milter first + milter_default_action=tempfail on 465, as on 587
#   homelab-haproxy >= 0.1.13            example config only. The edges' SITE file
#                                        /etc/homelab/haproxy/backends.yml gets its smtps entry HERE,
#                                        copied from the submission entry (:587 -> :465); then
#                                        homelab-haproxy-apply-backends validates and reloads.
#   the edges' base firewall             /etc/nftables.conf's mail accept gains 465 on disk, and the live
#                                        rule is REPLACED by handle in one nft command. Never `nft -f`:
#                                        the file starts with `flush ruleset` and would empty bad-ips'
#                                        table (see edge-firewall-unify.sh).
#
# ORDER: pool first (the edges must never front a port nobody answers), one
# node at a time, each followed by the #67 round trip over its 465 -- PROXY
# line, then TLS, then the same send / record / reply / DKIM checks as over
# 587. Then the edges one at a time (all three are live). Then offsite: a
# verified-TLS banner on every public address, AUTH + a message to the test
# account itself through the public name, relay still refused without AUTH,
# 587 untouched; and the pool's own log must show the smtps sessions.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
FAILS=0

h(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }

MAIL_NODES="39 40 41"
EDGE_NODES="00 01 02"
DB_NODES="06 07 08"
WANT_PF=0.1.28; WANT_BL=0.2.3; WANT_HA=0.1.13
MAIL_HOST=mail.mailmasker.org
MILTER_ORDER="inet:127.0.0.1:8892,inet:localhost:8891"   # postconf -P allows no whitespace

TEST_ACCOUNT="${TEST_ACCOUNT:-testaccountforclaude@mailmasker.org}"
# The test account's password stays in a file outside this repository; the
# checkers read it themselves (the offsite one from its stdin), never an argument.
PW_FILE="${TEST_ACCOUNT_PW_FILE:-/home/gardner/claude/general/homelab_issues_and_fixes/post-cutover/secrets/testaccountforclaude.pw}"
[ -r "$PW_FILE" ] || { echo "ERROR: cannot read the test account password file $PW_FILE (set TEST_ACCOUNT_PW_FILE)"; exit 1; }
CHECK67=./files/mail-reply-alias-check.py
CHECK70=./files/smtps-check.py

MODE=deploy
case "${1:-}" in
    "") ;;
    --verify) MODE=verify ;;
    --pool) MODE=pool ;;
    --edges) MODE=edges ;;
    --internet) MODE=internet ;;
    *) echo "usage: $0 [--verify | --pool | --edges | --internet]"; exit 1 ;;
esac

LOG="/home/gardner/claude/temp/smtps-orchestrate-$(date +%Y%m%d-%H%M%S).log"
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
echo "DB primary = prod-homelab$LEADER ($LEADER_IP); workstation = $SRC_IP"

ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }

# ---------------------------------------------------------------- pool --

pool_checks(){ # $1 = NN
  local ip v x act; ip="$(h "$1")"
  v="$(ver_of "$ip" homelab-postfix)";            ver_ge "$v" "$WANT_PF" && ok "$1 homelab-postfix $v" || bad "$1 homelab-postfix $v < $WANT_PF"
  v="$(ver_of "$ip" homelab-postfix-block-link)"; ver_ge "$v" "$WANT_BL" && ok "$1 homelab-postfix-block-link $v" || bad "$1 homelab-postfix-block-link $v < $WANT_BL"
  act="$(rssh "$ip" 'systemctl is-active postfix opendkim homelab-postfix-block-link' | tr '\n' ' ')"
  [ "$act" = "active active active " ] && ok "$1 postfix, opendkim, milter active" || bad "$1 units: $act"
  rssh "$ip" 'postconf -Mf smtps/inet' | grep -q '^smtps' && ok "$1 master.cf has the smtps service" || bad "$1 no smtps service in master.cf"
  x="$(rssh "$ip" 'postconf -Ph smtps/inet/smtpd_tls_wrappermode')";      [ "$x" = "yes" ] && ok "$1 465: implicit TLS (wrapper mode)" || bad "$1 smtps smtpd_tls_wrappermode = '$x'"
  x="$(rssh "$ip" 'postconf -Ph smtps/inet/syslog_name')";                [ "$x" = "postfix/smtps" ] && ok "$1 465: logs as postfix/smtps (bad-ips matches it)" || bad "$1 smtps syslog_name = '$x'"
  x="$(rssh "$ip" 'postconf -Ph smtps/inet/smtpd_milters')";              [ "$x" = "$MILTER_ORDER" ] && ok "$1 465: block-link first, OpenDKIM last" || bad "$1 smtps smtpd_milters = '$x'"
  x="$(rssh "$ip" 'postconf -Ph smtps/inet/milter_default_action')";      [ "$x" = "tempfail" ] && ok "$1 465: milter_default_action=tempfail (hold mail when the milter is down)" || bad "$1 smtps milter_default_action = '$x'"
  x="$(rssh "$ip" 'postconf -Ph smtps/inet/milter_macro_daemon_name')";   [ "$x" = "ORIGINATING" ] && ok "$1 465: daemon_name ORIGINATING (the #67 rewrite applies)" || bad "$1 smtps milter_macro_daemon_name = '$x'"
  x="$(rssh "$ip" 'postconf -Ph submission/inet/smtpd_milters')";         [ "$x" = "$MILTER_ORDER" ] && ok "$1 587: order unchanged" || bad "$1 submission smtpd_milters = '$x'"
  rssh "$ip" 'sudo -n ss -ltn' | grep -q ':465 ' && ok "$1 listening on 465" || bad "$1 nothing listens on 465"
  rssh "$ip" 'sudo -n postfix check' && ok "$1 postfix check" || bad "$1 postfix check reports a problem"
}

pool_roundtrip(){ # $1 = NN -- the #67 round trip over 465 (needs the #67 fixtures)
  step "round trip through prod-homelab$1's 465: PROXY line, then TLS, then send / record / reply / DKIM"
  if python3 "$CHECK67" --password-file "$PW_FILE" --account "$TEST_ACCOUNT" roundtrip \
        --node-ip "$(h "$1")" --leader-ip "$LEADER_IP" --src-ip "$SRC_IP" --port 465 --local-port 19465; then
    ok "$1 round trip over 465 passed"
  else
    bad "$1 round trip over 465 FAILED (see above)"
  fi
  rssh "$(h "$1")" 'sudo -n journalctl -u postfix --since "-10min" --no-pager' | grep 'postfix/smtps/smtpd' | grep -E 'sasl_username|TLS connection established' | tail -4 | sed 's/^/       /'
}

pool_deploy(){
  step "[pool] the #67 test aliases (needed by the round trip; removed afterwards)"
  ./mail-reply-alias-orchestrate.sh --fixtures || warn "the fixtures step reported a problem"
  local n ip
  for n in $MAIL_NODES; do
    ip="$(h "$n")"
    step "[pool] prod-homelab$n: homelab-postfix -> $WANT_PF, then homelab-postfix-block-link -> $WANT_BL"
    echo "  -- before: postfix $(ver_of "$ip" homelab-postfix), block-link $(ver_of "$ip" homelab-postfix-block-link)"
    ./pkg-upgrade.sh homelab-postfix "$n" || warn "pkg-upgrade homelab-postfix $n reported a problem"
    ./pkg-upgrade.sh homelab-postfix-block-link "$n" || warn "pkg-upgrade homelab-postfix-block-link $n reported a problem"
    pool_checks "$n"
    pool_roundtrip "$n"
    if [ "$FAILS" -gt 0 ]; then
      echo; echo "${R}stopping before the next node: $FAILS check(s) failed on prod-homelab$n${O}"
      ./mail-reply-alias-orchestrate.sh --cleanup || true
      exit 1
    fi
  done
  step "[pool] cleanup: the test aliases and the test account's switch"
  ./mail-reply-alias-orchestrate.sh --cleanup || warn "the cleanup step reported a problem"
}

# ---------------------------------------------------------------- edges --

edge_apply(){ # $1 = NN
  local n=$1 ip out rc; ip="$(h "$n")"
  step "[edge] prod-homelab$n: homelab-haproxy -> $WANT_HA (example config only; the site file is untouched by the package)"
  ./pkg-upgrade.sh homelab-haproxy "$n" || warn "pkg-upgrade homelab-haproxy $n reported a problem"
  step "[edge] prod-homelab$n: the smtps frontend and the firewall accept for 465"
  out=$(ssh -o ConnectTimeout=10 "$ip" 'sudo bash -s' <<'EOF'
set -uo pipefail
STAMP=$(date +%Y%m%d-%H%M%S); CHANGED=0
B=/etc/homelab/haproxy/backends.yml
F=/etc/nftables.conf

# 1. haproxy's site file: the smtps entry is the submission entry with :587 -> :465
if grep -q 'frontend_port: 465' "$B"; then
    echo "backends.yml already has a 465 frontend"
else
    cp -a "$B" "/root/backends.yml.before-smtps-$STAMP"
    perl -0pi -e 's/(  - name: submission\n((?:    [^\n]*\n)+))/ my ($blk,$body)=($1,$2); (my $new=$body) =~ s{frontend_port: 587}{frontend_port: 465}; $new =~ s{:587\b}{:465}g; "$blk  - name: smtps\n$new" /e' "$B"
    grep -q 'frontend_port: 465' "$B" || { echo "could not derive an smtps entry from the submission entry in $B -- restoring"; cp -a "/root/backends.yml.before-smtps-$STAMP" "$B"; exit 2; }
    echo "backends.yml: smtps entry added (copy of the old file: /root/backends.yml.before-smtps-$STAMP)"; CHANGED=1
fi
homelab-haproxy-apply-backends || { echo "homelab-haproxy-apply-backends failed -- haproxy.cfg untouched"; exit 3; }
grep -q '^frontend smtps_in' /etc/haproxy/haproxy.cfg || { echo "haproxy.cfg has no smtps_in frontend after apply"; exit 4; }

# 2. the firewall, on disk ...
if grep -qE 'tcp dport \{[^}]*\b465\b[^}]*\} accept' "$F"; then
    echo "nftables.conf already admits 465"
else
    cp -a "$F" "/root/nftables.conf.before-smtps-$STAMP"
    sed -i -E 's/^([[:space:]]*tcp dport \{ *25, )(587, 143, 993, 80, 443, 53 \} accept)/\1465, \2/' "$F"
    grep -qE 'tcp dport \{[^}]*\b465\b[^}]*\} accept' "$F" || { echo "the mail accept in $F is not the expected line -- restoring; edit by hand"; cp -a "/root/nftables.conf.before-smtps-$STAMP" "$F"; exit 5; }
    nft -c -f "$F" || { echo "$F does not parse after the edit -- restoring"; cp -a "/root/nftables.conf.before-smtps-$STAMP" "$F"; exit 6; }
    echo "nftables.conf: 465 added to the mail accept (copy of the old file: /root/nftables.conf.before-smtps-$STAMP)"; CHANGED=1
fi
# ... and in the kernel: the one mail-accept rule replaced by handle (never nft -f)
if nft list chain inet filter input | grep -v comment | grep -qE 'tcp dport \{[^}]*\b465\b[^}]*\} accept'; then
    echo "the live input chain already admits 465"
else
    H=$(nft -a list chain inet filter input | grep -v comment | grep -E 'tcp dport \{[^}]*\b25\b[^}]*\b587\b[^}]*\} accept' | sed -n 's/.*# handle \([0-9]*\)$/\1/p' | head -1)
    [ -n "$H" ] || { echo "no live mail-accept rule (25 + 587) found to replace"; exit 7; }
    PORTS=$(nft -a list chain inet filter input | grep -E "# handle $H\$" | sed -E 's/.*tcp dport \{([^}]*)\}.*/\1/')
    nft replace rule inet filter input handle "$H" tcp dport "{ $PORTS, 465 }" accept || { echo "nft replace rule failed"; exit 8; }
    echo "live rule (handle $H) replaced: tcp dport { $PORTS, 465 } accept"; CHANGED=1
fi

# 3. what it looks like now
echo "haproxy listens on: $(ss -ltn | awk '$4 ~ /:(25|465|587|143|993)$/ {sub(/.*:/, "", $4); print $4}' | sort -n | tr '\n' ' ')"
echo "smtps_out servers: $(grep -cE '^\s+server smtps[0-9]* .*:465 check send-proxy' /etc/haproxy/haproxy.cfg)"
echo "live mail accept: $(nft list chain inet filter input | grep -v comment | grep -E 'tcp dport \{[^}]*\b465\b' | sed 's/^[[:space:]]*//')"
echo "bad-ips bans in the kernel: $(nft list set inet badips badipv4 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | wc -l)"
[ "$CHANGED" = 1 ] && echo "RESULT: changed" || echo "RESULT: already there"
EOF
  )
  rc=$?
  printf '%s\n' "$out" | sed 's/^/       /'
  if [ $rc -ne 0 ]; then bad "prod-homelab$n: remote step exited $rc"; return; fi
  case "$out" in
    *"RESULT: changed"*) ok "prod-homelab$n: 465 fronted and admitted (changed)" ;;
    *"RESULT: already there"*) ok "prod-homelab$n: already fronting and admitting 465" ;;
    *) bad "prod-homelab$n: no result line" ;;
  esac
}

edge_checks(){ # $1 = NN
  local ip v x; ip="$(h "$1")"
  v="$(ver_of "$ip" homelab-haproxy)"; ver_ge "$v" "$WANT_HA" && ok "$1 homelab-haproxy $v" || bad "$1 homelab-haproxy $v < $WANT_HA"
  [ "$(rssh "$ip" 'systemctl is-active haproxy')" = "active" ] && ok "$1 haproxy active" || bad "$1 haproxy not active"
  rssh "$ip" 'sudo -n grep -c "frontend_port: 465" /etc/homelab/haproxy/backends.yml' | grep -q '^1$' && ok "$1 backends.yml has the smtps frontend" || bad "$1 backends.yml lacks the smtps frontend"
  x="$(rssh "$ip" 'sudo -n grep -cE "^\s+server smtps[0-9]* 10\.50\.2\.[0-9]+:465 check send-proxy" /etc/haproxy/haproxy.cfg')"
  [ "$x" = "3" ] && ok "$1 haproxy.cfg: smtps_out -> the three pool nodes, send-proxy" || bad "$1 haproxy.cfg smtps_out servers = '$x' (want 3)"
  rssh "$ip" 'sudo -n ss -ltnp' | grep -q ':465 .*haproxy' && ok "$1 haproxy listens on 465" || bad "$1 nothing (or not haproxy) listens on 465"
  rssh "$ip" 'sudo -n nft list chain inet filter input' | grep -v comment | grep -qE 'tcp dport \{[^}]*\b465\b[^}]*\} accept' && ok "$1 live firewall admits 465" || bad "$1 live firewall does not admit 465"
  rssh "$ip" 'sudo -n grep -qE "tcp dport \{[^}]*\b465\b[^}]*\} accept" /etc/nftables.conf' && ok "$1 /etc/nftables.conf admits 465 (survives a reboot)" || bad "$1 /etc/nftables.conf lacks 465"
  rssh "$ip" 'sudo -n nft -c -f /etc/nftables.conf' && ok "$1 /etc/nftables.conf parses" || bad "$1 /etc/nftables.conf does not parse"
  x="$(rssh "$ip" 'sudo -n journalctl -u haproxy --since "-5min" --no-pager' | grep -c 'smtps_out.*DOWN')"
  [ "$x" = "0" ] && ok "$1 no smtps_out backend marked DOWN in the last 5 min" || bad "$1 haproxy marked an smtps_out server DOWN $x time(s) in the last 5 min"
}

edges_deploy(){
  local n
  for n in $EDGE_NODES; do
    edge_apply "$n"
    edge_checks "$n"
    if [ "$FAILS" -gt 0 ]; then echo; echo "${R}stopping before the next edge: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1; fi
  done
}

# ------------------------------------------------------------- internet --

internet_check(){
  step "[internet] from offsite: $MAIL_HOST:465 on every public address, then AUTH + a message to the test account"
  local ips args n x
  ips="$(dig +short "$MAIL_HOST" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | sort | tr '\n' ' ')"
  [ -n "$ips" ] || { bad "could not resolve $MAIL_HOST through 1.1.1.1"; return; }
  echo "  $MAIL_HOST -> $ips"
  scp -q "$CHECK70" offsite:/tmp/smtps-check.py || { bad "could not copy the checker to offsite"; return; }
  args="$(printf '{"host":"%s","account":"%s","ips":[%s]}' "$MAIL_HOST" "$TEST_ACCOUNT" "$(printf '"%s",' $ips | sed 's/,$//')")"
  if ssh -o ConnectTimeout=10 offsite "python3 /tmp/smtps-check.py '$args'" < "$PW_FILE"; then
    ok "offsite check passed"
  else
    bad "offsite check FAILED (see above)"
  fi
  ssh -n -o ConnectTimeout=10 offsite 'rm -f /tmp/smtps-check.py' 2>/dev/null
  for n in $MAIL_NODES; do
    x="$(rssh "$(h "$n")" 'sudo -n journalctl -u postfix --since "-10min" --no-pager' | grep -c "postfix/smtps/smtpd.*sasl_username=$TEST_ACCOUNT")"
    echo "       prod-homelab$n: $x authenticated smtps session(s) by the test account in the last 10 min"
  done
}

# ------------------------------------------------------------------ run --

case "$MODE" in
  verify)
    step "verify: mail pool"
    for n in $MAIL_NODES; do pool_checks "$n"; done
    step "verify: edges"
    for n in $EDGE_NODES; do edge_checks "$n"; done
    internet_check
    ;;
  pool)     pool_deploy ;;
  edges)    edges_deploy ;;
  internet) internet_check ;;
  deploy)
    pool_deploy
    edges_deploy
    internet_check
    step "the three edges' firewall files, side by side"
    ./edge-firewall-unify.sh --verify || warn "edge-firewall-unify.sh --verify reported drift"
    ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then echo "${G}done: no failed checks${O} (log: $LOG)"; else echo "${R}done: $FAILS failed check(s)${O} (log: $LOG)"; exit 1; fi
