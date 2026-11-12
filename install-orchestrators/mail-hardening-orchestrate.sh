#!/bin/bash
# ============================================================================
# Post-cutover #65 -- mail-port hardening: no AUTH on 25, no VRFY anywhere,
# HELO required. RUN ON THE ADMIN WORKSTATION.
#
#   ./mail-hardening-orchestrate.sh            deploy homelab-postfix >= 0.1.31 on 39 -> 40 -> 41
#                                              with the checks after each node, then the proofs
#                                              from the internet (re-runnable)
#   ./mail-hardening-orchestrate.sh --verify   read-only: the node checks + the proofs; changes nothing
#
# WHAT IT CHECKS, per node (files/mail-ports-check.py node, PROXY line first):
#   25:  MAIL before HELO -> 503; no AUTH and no VRFY advertised; VRFY -> 502; AUTH -> 503;
#        a normal inbound message to the test account is accepted and arrives (IMAPS)
#   587: no AUTH before STARTTLS; STARTTLS offered; no VRFY; after STARTTLS AUTH offered,
#        VRFY -> 502, login as the test account works
#   465: inside TLS AUTH offered, no VRFY, VRFY -> 502, login works
# then from the internet: 25 through the house hairpin to the public address (offsite's
# provider blocks outbound 25), 587 + 465 on every public address from offsite, and the
# #67 reply round trip through one node (587 and 465) to prove submission end to end.
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
WANT_PF=0.1.31
MAIL_HOST=mail.mailmasker.org
TEST_ACCOUNT="${TEST_ACCOUNT:-testaccountforclaude@mailmasker.org}"
PW_FILE="${TEST_ACCOUNT_PW_FILE:-/home/gardner/claude/general/homelab_issues_and_fixes/post-cutover/secrets/testaccountforclaude.pw}"
[ -r "$PW_FILE" ] || { echo "ERROR: cannot read the test account password file $PW_FILE (set TEST_ACCOUNT_PW_FILE)"; exit 1; }
CHECK=./files/mail-ports-check.py

MODE=deploy
case "${1:-}" in
    "") ;;
    --verify) MODE=verify ;;
    *) echo "usage: $0 [--verify]"; exit 1 ;;
esac

LOG="/home/gardner/claude/temp/mail-hardening-orchestrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"
SRC_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"

ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }

node_checks(){ # $1 = NN
  local ip v x; ip="$(h "$1")"
  v="$(ver_of "$ip" homelab-postfix)"; ver_ge "$v" "$WANT_PF" && ok "$1 homelab-postfix $v" || bad "$1 homelab-postfix $v < $WANT_PF"
  x="$(rssh "$ip" 'systemctl is-active postfix opendkim homelab-postfix-block-link' | tr '\n' ' ')"
  [ "$x" = "active active active " ] && ok "$1 postfix, opendkim, milter active" || bad "$1 units: $x"
  x="$(rssh "$ip" 'postconf -h smtpd_sasl_auth_enable')";   [ "$x" = "no" ]  && ok "$1 main.cf smtpd_sasl_auth_enable = no (port 25 offers no AUTH)" || bad "$1 smtpd_sasl_auth_enable = $x"
  x="$(rssh "$ip" 'postconf -h smtpd_tls_auth_only')";      [ "$x" = "yes" ] && ok "$1 main.cf smtpd_tls_auth_only = yes" || bad "$1 smtpd_tls_auth_only = $x"
  x="$(rssh "$ip" 'postconf -h disable_vrfy_command')";     [ "$x" = "yes" ] && ok "$1 disable_vrfy_command = yes" || bad "$1 disable_vrfy_command = $x"
  x="$(rssh "$ip" 'postconf -h smtpd_helo_required')";      [ "$x" = "yes" ] && ok "$1 smtpd_helo_required = yes" || bad "$1 smtpd_helo_required = $x"
  x="$(rssh "$ip" 'postconf -Ph submission/inet/smtpd_sasl_auth_enable')"; [ "$x" = "yes" ] && ok "$1 587 keeps its own AUTH" || bad "$1 submission smtpd_sasl_auth_enable = '$x'"
  x="$(rssh "$ip" 'postconf -Ph submission/inet/smtpd_tls_auth_only')";    [ "$x" = "yes" ] && ok "$1 587 AUTH is TLS-only" || bad "$1 submission smtpd_tls_auth_only = '$x'"
  x="$(rssh "$ip" 'postconf -Ph smtps/inet/smtpd_sasl_auth_enable')";      [ "$x" = "yes" ] && ok "$1 465 keeps its own AUTH" || bad "$1 smtps smtpd_sasl_auth_enable = '$x'"
  rssh "$ip" 'sudo -n postfix check' && ok "$1 postfix check" || bad "$1 postfix check reports a problem"
}

node_probe(){ # $1 = NN
  step "[$1] the ports themselves, through tunnels to prod-homelab$1 (PROXY line first)"
  if python3 "$CHECK" node --node-ip "$(h "$1")" --src-ip "$SRC_IP" --account "$TEST_ACCOUNT" < "$PW_FILE"; then
    ok "$1 port checks passed"
  else
    bad "$1 port checks FAILED (see above)"
  fi
}

internet_checks(){
  step "[internet] port 25 through the house hairpin to $MAIL_HOST"
  python3 "$CHECK" hairpin --host "$MAIL_HOST" && ok "25 through the edge passed" || bad "25 through the edge FAILED"
  step "[internet] 587 and 465 on every public address, from offsite"
  local ips
  ips="$(dig +short "$MAIL_HOST" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | sort | paste -sd, -)"
  [ -n "$ips" ] || { bad "could not resolve $MAIL_HOST"; return; }
  echo "  $MAIL_HOST -> $ips"
  scp -q "$CHECK" offsite:/tmp/mail-ports-check.py || { bad "could not copy the checker to offsite"; return; }
  if ssh -o ConnectTimeout=10 offsite "python3 /tmp/mail-ports-check.py offsite --host $MAIL_HOST --ips $ips --account $TEST_ACCOUNT" < "$PW_FILE"; then
    ok "offsite checks passed"
  else
    bad "offsite checks FAILED (see above)"
  fi
  ssh -n -o ConnectTimeout=10 offsite 'rm -f /tmp/mail-ports-check.py' 2>/dev/null
  step "[internet] the #67 round trip through prod-homelab39 (587 and 465): submission still works end to end"
  ./mail-reply-alias-orchestrate.sh --fixtures >/dev/null 2>&1 || warn "fixtures step reported a problem"
  ./mail-reply-alias-orchestrate.sh --check 39 | grep -E "round trip|FAIL|^done" || true
  ./mail-reply-alias-orchestrate.sh --cleanup >/dev/null 2>&1 || warn "cleanup step reported a problem"
}

case "$MODE" in
  verify)
    for n in $MAIL_NODES; do step "verify prod-homelab$n"; node_checks "$n"; node_probe "$n"; done
    internet_checks
    ;;
  deploy)
    for n in $MAIL_NODES; do
      step "[$n] homelab-postfix -> $WANT_PF; before: $(ver_of "$(h "$n")" homelab-postfix)"
      ./pkg-upgrade.sh homelab-postfix "$n" || warn "pkg-upgrade homelab-postfix $n reported a problem"
      node_checks "$n"
      node_probe "$n"
      if [ "$FAILS" -gt 0 ]; then echo; echo "${R}stopping before the next node: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1; fi
    done
    internet_checks
    ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then echo "${G}done: no failed checks${O} (log: $LOG)"; else echo "${R}done: $FAILS failed check(s)${O} (log: $LOG)"; exit 1; fi
