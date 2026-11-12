#!/bin/bash
# ============================================================================
# Post-cutover #68 -- OpenDKIM "key data is not secure": the DKIM key hand-off
# through root. RUN ON THE ADMIN WORKSTATION.
#
#   ./opendkim-keys-orchestrate.sh            deploy on the signers 39 -> 40 -> 41 (re-runnable),
#                                             then homelab-domain-admin everywhere else, then verify
#   ./opendkim-keys-orchestrate.sh --verify   read-only checks + one signed message per signer
#
# WHAT IT ROLLS OUT (packages must already be built + published):
#   homelab-domain-admin >= 0.1.45  the data plane writes a staging tree under
#                                   /var/lib/homelab/opendkim and has root mirror it into
#                                   /etc/opendkim (sudo /usr/sbin/homelab-opendkim-install, no
#                                   arguments) -- FIRST on each signer
#   homelab-postfix >= 0.1.29       RequireSafeKeys yes; /etc/opendkim/keys opendkim:opendkim,
#                                   dirs 0700, keys 0600, tables 0640; homelab OUT of group
#                                   opendkim -- SECOND (its postinst keeps the legacy layout
#                                   when it finds an older domain-admin, so the order is
#                                   enforced there too)
#
# PROOF per signer: the live tree is opendkim-only and matches the staging
# tree; a real message submitted through THAT node's 587 is DKIM-signed (the
# delivered copy carries the signature; the node's opendkim journal shows
# "DKIM-Signature field added") with NO "key data is not secure" line. The
# admin-only domain-admin nodes stop logging "cannot write
# /etc/opendkim/KeyTable" every minute.
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

SIGNERS="39 40 41"
ADMIN_ONLY="21 22 23"
WANT_DA=0.1.45; WANT_PF=0.1.30

TEST_ACCOUNT="${TEST_ACCOUNT:-testaccountforclaude@mailmasker.org}"
PW_FILE="${TEST_ACCOUNT_PW_FILE:-/home/gardner/claude/general/homelab_issues_and_fixes/post-cutover/secrets/testaccountforclaude.pw}"
[ -r "$PW_FILE" ] || { echo "ERROR: cannot read the test account password file $PW_FILE (set TEST_ACCOUNT_PW_FILE)"; exit 1; }
CHECK=./files/mail-reply-alias-check.py

MODE=deploy
case "${1:-}" in
    "") ;;
    --verify) MODE=verify ;;
    *) echo "usage: $0 [--verify]"; exit 1 ;;
esac

LOG="/home/gardner/claude/temp/opendkim-keys-orchestrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"
SRC_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"

ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }

# --------------------------------------------------------------- checks --

node_checks(){ # $1 = NN (a signer)
  local ip v x live staged; ip="$(h "$1")"
  v="$(ver_of "$ip" homelab-domain-admin)"; ver_ge "$v" "$WANT_DA" && ok "$1 homelab-domain-admin $v" || bad "$1 homelab-domain-admin $v < $WANT_DA"
  v="$(ver_of "$ip" homelab-postfix)";      ver_ge "$v" "$WANT_PF" && ok "$1 homelab-postfix $v" || bad "$1 homelab-postfix $v < $WANT_PF"
  x="$(rssh "$ip" 'systemctl is-active opendkim postfix homelab-domain-admin' | tr '\n' ' ')"
  [ "$x" = "active active active " ] && ok "$1 opendkim, postfix, domain-admin active" || bad "$1 units: $x"
  x="$(rssh "$ip" 'grep -c "^RequireSafeKeys yes" /etc/opendkim.conf')"
  [ "$x" = "1" ] && ok "$1 RequireSafeKeys yes" || bad "$1 RequireSafeKeys is not yes"
  x="$(rssh "$ip" 'ps -o user= -C opendkim' | sort -u | tr -d ' \n')"
  [ "$x" = "opendkim" ] && ok "$1 opendkim runs as opendkim (UserID)" || bad "$1 opendkim runs as '$x' -- the safe-keys check needs the executing uid to own the keys"
  x="$(rssh "$ip" 'getent group opendkim | cut -d: -f4')"
  [ -z "$x" ] && ok "$1 group opendkim has no members (homelab is out)" || bad "$1 group opendkim still has members: $x"
  live="$(rssh "$ip" 'sudo -n find /etc/opendkim/keys -name "*.private" | wc -l')"
  staged="$(rssh "$ip" 'sudo -n find /var/lib/homelab/opendkim/keys -name "*.private" 2>/dev/null | wc -l')"
  [ "$live" -gt 0 ] && [ "$live" = "$staged" ] && ok "$1 $live keys live = $staged staged" || bad "$1 keys: $live live, $staged staged"
  x="$(rssh "$ip" 'sudo -n find /etc/opendkim/keys -name "*.private" \( ! -user opendkim -o ! -group opendkim -o ! -perm 0600 \) | wc -l')"
  [ "$x" = "0" ] && ok "$1 every live key is opendkim:opendkim 0600" || bad "$1 $x live key(s) not opendkim:opendkim 0600"
  x="$(rssh "$ip" 'sudo -n find /etc/opendkim/keys -type d \( ! -user opendkim -o ! -perm 0700 \) | wc -l')"
  [ "$x" = "0" ] && ok "$1 every key directory is opendkim 0700" || bad "$1 $x key directory(ies) not opendkim 0700"
  x="$(rssh "$ip" 'sudo -n stat -c "%U:%G %a" /etc/opendkim/KeyTable /etc/opendkim/SigningTable' | sort -u | tr '\n' ' ')"
  [ "$x" = "opendkim:opendkim 640 " ] && ok "$1 tables opendkim:opendkim 0640" || bad "$1 tables: $x"
  x="$(rssh "$ip" 'sudo -n grep -c . /etc/opendkim/KeyTable')"
  [ "$x" = "$live" ] && ok "$1 KeyTable names $x keys, all installed" || bad "$1 KeyTable has $x lines for $live live keys"
  x="$(rssh "$ip" 'sudo -n grep -c "/etc/opendkim/keys/" /etc/opendkim/KeyTable')"
  [ "$x" = "$live" ] && ok "$1 KeyTable paths point at the live tree" || bad "$1 KeyTable: $x of $live lines point at /etc/opendkim/keys"
  x="$(rssh "$ip" 'sudo -n stat -c "%U:%G %a" /var/lib/homelab/opendkim')"
  [ "$x" = "homelab:homelab 700" ] && ok "$1 staging tree homelab:homelab 0700" || bad "$1 staging tree: $x"
  x="$(rssh "$ip" 'sudo -n find /var/lib/homelab/opendkim/keys -name "*.private" ! -perm 0600 | wc -l')"
  [ "$x" = "0" ] && ok "$1 every staged key is 0600" || bad "$1 $x staged key(s) not 0600"
  rssh "$ip" 'sudo -n grep -q "/usr/sbin/homelab-opendkim-install \"\"" /etc/sudoers.d/homelab-domain-admin' && ok "$1 sudoers allows the installer, no arguments" || bad "$1 sudoers lacks the installer rule"
  rssh "$ip" 'sudo -n test ! -e /var/lib/homelab/opendkim/.install-pending' && ok "$1 no pending hand-off" || bad "$1 a hand-off is pending (last install failed; see the domain-admin journal)"
  x="$(rssh "$ip" 'sudo -n journalctl -u homelab-domain-admin --since "-10min" --no-pager' | grep -c -E 'opendkim-install failed|table rebuild failed')"
  [ "$x" = "0" ] && ok "$1 no hand-off errors in the domain-admin journal (10 min)" || bad "$1 $x hand-off error line(s) in the domain-admin journal"
}

sign_check(){ # $1 = NN -- one real message through this node's 587, then its opendkim journal
  local ip tag out x; ip="$(h "$1")"
  tag="dkim68 $1 $(date +%H%M%S)"
  step "[$1] a real signature: message through prod-homelab$1's 587 as the test account"
  out="$(python3 "$CHECK" --password-file "$PW_FILE" --account "$TEST_ACCOUNT" reply \
          --node-ip "$ip" --src-ip "$SRC_IP" --to "$TEST_ACCOUNT" \
          --in-reply-to "<dkim68-$(date +%s)-$1@check.homelab.invalid>" --subject "$tag" \
          --body "post-cutover #68 signing check through prod-homelab$1" --delete-after 2>&1)"
  printf '%s\n' "$out" | sed 's/^/       /'
  # The delivered copy's DKIM-Signature header is the proof that the key
  # loaded and signed (OpenDKIM logs successful signatures only with
  # SyslogSuccess, which this config does not set); the journal must then
  # be free of the two failure lines.
  printf '%s' "$out" | grep -q 'DKIM-Signature: .*d=mailmasker.org' && ok "$1 the delivered copy carries a DKIM signature (d=mailmasker.org)" || bad "$1 no DKIM signature on the delivered copy"
  x="$(rssh "$ip" 'sudo -n journalctl -u opendkim --since "-3min" --no-pager' | grep -c 'not secure')"
  [ "$x" = "0" ] && ok "$1 no 'key data is not secure' line" || bad "$1 $x 'key data is not secure' line(s) in the last 3 min"
  x="$(rssh "$ip" 'sudo -n journalctl -u opendkim --since "-3min" --no-pager' | grep -c 'error loading key')"
  [ "$x" = "0" ] && ok "$1 no 'error loading key' line" || bad "$1 $x 'error loading key' line(s) in the last 3 min"
  python3 "$CHECK" --password-file "$PW_FILE" --account "$TEST_ACCOUNT" setting off >/dev/null 2>&1 || warn "could not switch the test account's reply-from-alias setting back off"
}

admin_only_checks(){
  local n ip v x
  for n in $ADMIN_ONLY; do
    ip="$(h "$n")"
    v="$(ver_of "$ip" homelab-domain-admin)"; ver_ge "$v" "$WANT_DA" && ok "$n homelab-domain-admin $v" || bad "$n homelab-domain-admin $v < $WANT_DA"
    # Since the unit's last start only: the minutes before the upgrade still
    # hold the old code's once-a-minute error and must not count against it.
    x="$(rssh "$ip" 'sudo -n journalctl -u homelab-domain-admin --since "$(systemctl show -p ActiveEnterTimestamp --value homelab-domain-admin)" --no-pager' | grep -c 'DKIM table rebuild failed')"
    [ "$x" = "0" ] && ok "$n no 'DKIM table rebuild failed' line since its last start (non-signer skips the data plane)" || bad "$n still logs 'DKIM table rebuild failed' ($x since its last start)"
  done
}

# --------------------------------------------------------------- deploy --

deploy_signer(){ # $1 = NN
  local ip t x before; ip="$(h "$1")"
  before="$(ver_of "$ip" homelab-domain-admin)"
  step "[$1] homelab-domain-admin -> $WANT_DA (staging tree + the root installer); before: $before"
  ./pkg-upgrade.sh homelab-domain-admin "$1" || warn "pkg-upgrade homelab-domain-admin $1 reported a problem"
  if ver_ge "$before" "$WANT_DA"; then
    ok "$1 domain-admin was already $before -- its hand-off happened earlier (re-run)"
  else
    step "[$1] waiting for the first hand-off (service restart, 5 s, materialize, installer)"
    for t in $(seq 1 24); do
      x="$(rssh "$ip" 'sudo -n journalctl -u homelab-domain-admin --since "-5min" --no-pager' | grep -c 'homelab-opendkim-install:')"
      [ "$x" -ge 1 ] && break
      sleep 5
    done
    rssh "$ip" 'sudo -n journalctl -u homelab-domain-admin --since "-5min" --no-pager' | grep -E 'homelab-opendkim-install|materialized|opendkim' | tail -4 | cut -c1-200 | sed 's/^/       /'
    [ "$x" -ge 1 ] && ok "$1 the installer ran" || bad "$1 no installer run in 2 min"
  fi
  x="$(rssh "$ip" 'sudo -n find /etc/opendkim/keys -name "*.private" ! -user opendkim | wc -l')"
  [ "$x" = "0" ] && ok "$1 every live key now belongs to opendkim" || bad "$1 $x live key(s) still not owned by opendkim"
  step "[$1] homelab-postfix -> $WANT_PF (RequireSafeKeys yes, homelab out of group opendkim); before: $(ver_of "$ip" homelab-postfix)"
  ./pkg-upgrade.sh homelab-postfix "$1" || warn "pkg-upgrade homelab-postfix $1 reported a problem"
  rssh "$ip" 'sudo -n journalctl -u opendkim -b --no-pager' | tail -3 | cut -c1-200 | sed 's/^/       /'
  node_checks "$1"
  sign_check "$1"
}

# ------------------------------------------------------------------ run --

case "$MODE" in
  verify)
    for n in $SIGNERS; do step "verify prod-homelab$n"; node_checks "$n"; sign_check "$n"; done
    step "verify the admin-only domain-admin nodes"; admin_only_checks
    ;;
  deploy)
    for n in $SIGNERS; do
      deploy_signer "$n"
      if [ "$FAILS" -gt 0 ]; then echo; echo "${R}stopping before the next signer: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1; fi
    done
    step "homelab-domain-admin -> $WANT_DA everywhere else it is installed"
    ./pkg-upgrade.sh homelab-domain-admin --all || warn "pkg-upgrade homelab-domain-admin --all reported a problem"
    sleep 70   # one materialize tick on the admin-only nodes
    admin_only_checks
    ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then echo "${G}done: no failed checks${O} (log: $LOG)"; else echo "${R}done: $FAILS failed check(s)${O} (log: $LOG)"; exit 1; fi
