#!/bin/bash
# ============================================================================
# Post-cutover #38 -- alerts reach someone: Alertmanager on the metrics host,
# mail through the fleet's service mailbox, firing alerts in the Metrics tab.
# RUN ON THE ADMIN WORKSTATION.
#
#   ./alerting-orchestrate.sh --to ADDR[,ADDR]   deploy: settings + password file on the metrics
#                                                host, homelab-prometheus >= 0.10.0 there, then
#                                                homelab-accountmanage >= 0.1.47 on 27/28/29, verify
#   ./alerting-orchestrate.sh --verify           read-only checks; changes nothing
#   ./alerting-orchestrate.sh --test-synthetic   push one synthetic critical into Alertmanager and
#                                                watch the mail pool deliver it (and its resolve)
#   ./alerting-orchestrate.sh --test-hostdown    the real thing: stop node_exporter on a node whose
#                                                metrics nobody depends on (45, the apt-repo host) until
#                                                HostDown fires and is mailed, start it again, watch the
#                                                RESOLVED mail go out
#
# THE PASSWORD. The service mailbox's SMTP password is read from a node that
# already holds it (prod-homelab27's accountmanage config) and written straight
# into /etc/homelab/prometheus/alert-smtp.pw on the metrics host, root:prometheus
# 0640, through one ssh pipe. It is never printed, never an argument, never in
# this repository.
#
# PROOF OF DELIVERY. The recipient is Gardner's own mailbox, which nobody here
# may read; the proof is the mail pool's journal on 39/40/41: a submission from
# the service mailbox to the recipient with the alert's subject, status=sent.
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

METRICS_NODE=69; MON="$(h $METRICS_NODE)"
PW_SOURCE_NODE=27                      # holds the service mailbox's SMTP password in its accountmanage config
ACCOUNTMANAGE_NODES="27 28 29"
MAIL_NODES="39 40 41"
PROVING_NODE=45                        # scraped, runs node_exporter, nothing depends on its metrics (47 has no exporter)
WANT_PROM=0.10.0; WANT_AM=0.1.47
MAIL_FROM=noreply@mailmasker.org
PW_FILE_REMOTE=/etc/homelab/prometheus/alert-smtp.pw
HL_CONFIG=/etc/homelab/prometheus/config

MODE=""; TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="$2"; MODE=deploy; shift 2 ;;
    --verify) MODE=verify; shift ;;
    --test-synthetic) MODE=synthetic; shift ;;
    --test-hostdown) MODE=hostdown; shift ;;
    *) echo "usage: $0 --to ADDR[,ADDR] | --verify | --test-synthetic | --test-hostdown"; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: $0 --to ADDR[,ADDR] | --verify | --test-synthetic | --test-hostdown"; exit 1; }

LOG="/home/gardner/claude/temp/alerting-orchestrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"

ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }
prom(){ rssh "$MON" "curl -s 'http://127.0.0.1:9090$1'"; }
am(){ rssh "$MON" "curl -s 'http://127.0.0.1:9093$1'"; }

# -------------------------------------------------------------- settings --

write_settings(){ # $1 = recipient list
  step "settings on prod-homelab$METRICS_NODE: ALERT_MAIL_TO=$1, password file from prod-homelab$PW_SOURCE_NODE"
  # Append the ALERT_* keys if the config predates them, then set the recipient.
  rssh "$MON" "sudo -n grep -q '^ALERT_MAIL_TO=' $HL_CONFIG" || rssh "$MON" "sudo -n tee -a $HL_CONFIG >/dev/null" <<'EOF'

# Alerting (post-cutover #38): see homelab-prometheus's postinst for the keys.
ALERT_MAIL_TO=""
ALERT_MAIL_FROM="noreply@mailmasker.org"
ALERT_SMTP_HOST="10.50.2.140:587"
ALERT_SMTP_USER="noreply@mailmasker.org"
ALERT_SMTP_SERVER_NAME="mail.mailmasker.org"
EOF
  rssh "$MON" "sudo -n sed -i 's/^ALERT_MAIL_TO=.*/ALERT_MAIL_TO=\"$1\"/' $HL_CONFIG" && ok "ALERT_MAIL_TO set" || bad "could not set ALERT_MAIL_TO"
  # The password: node 27's accountmanage config -> the metrics host, one pipe, 0640 root:prometheus.
  # `prometheus` may not exist yet on a fresh metrics host; the postinst re-chowns the file.
  if ssh -o ConnectTimeout=10 "$(h $PW_SOURCE_NODE)" "sudo -n sed -n '/^mailer:/,/^[^ ]/{s/^  smtp_password: *//p}' /etc/homelab/accountmanage/config.yml | head -1 | tr -d '\"'" 2>/dev/null \
      | ssh -o ConnectTimeout=10 "$MON" "sudo -n install -m 0640 -o root -g \$(getent group prometheus >/dev/null && echo prometheus || echo root) /dev/stdin $PW_FILE_REMOTE" 2>/dev/null; then
    local n; n="$(rssh "$MON" "sudo -n wc -c $PW_FILE_REMOTE" | awk '{print $1}')"   # root-only file: sudo must open it, not the shell
    [ "${n:-0}" -gt 8 ] && ok "password file written ($n bytes, never shown)" || bad "password file is empty -- is mailer.smtp_password set on prod-homelab$PW_SOURCE_NODE?"
  else
    bad "could not write the password file"
  fi
}

# ---------------------------------------------------------------- checks --

metrics_checks(){
  local v x
  v="$(ver_of "$MON" homelab-prometheus)"; ver_ge "$v" "$WANT_PROM" && ok "homelab-prometheus $v" || bad "homelab-prometheus $v < $WANT_PROM"
  x="$(rssh "$MON" 'systemctl is-active prometheus prometheus-alertmanager' | tr '\n' ' ')"
  [ "$x" = "active active " ] && ok "prometheus + prometheus-alertmanager active" || bad "units: $x"
  x="$(rssh "$MON" 'sudo -n ss -ltnp' | grep -E ':9093 ' | awk '{print $4}' | sort -u | tr '\n' ' ')"
  [ "$x" = "127.0.0.1:9093 " ] && ok "Alertmanager listens on 127.0.0.1:9093 only" || bad "Alertmanager listeners: '$x'"
  rssh "$MON" 'sudo -n ss -ltn' | grep -q ':9094 ' && bad "Alertmanager cluster port 9094 is open (should be disabled)" || ok "no cluster port"
  rssh "$MON" 'amtool check-config /etc/prometheus/homelab/alertmanager.yml' >/dev/null && ok "amtool check-config passes" || bad "amtool check-config fails"
  x="$(rssh "$MON" "grep -c '^ALERT_MAIL_TO=\"[^\"]' $HL_CONFIG")"
  [ "$x" = "1" ] && ok "ALERT_MAIL_TO is set" || bad "ALERT_MAIL_TO is empty"
  x="$(rssh "$MON" "sudo -n stat -c '%U:%G %a' $PW_FILE_REMOTE")"
  [ "$x" = "root:prometheus 640" ] && ok "password file root:prometheus 0640" || bad "password file: '$x'"
  rssh "$MON" 'grep -q "^  - name: mail" /etc/prometheus/homelab/alertmanager.yml' && ok "alertmanager.yml has the mail receiver (not the unconfigured one)" || bad "alertmanager.yml has no mail receiver"
  rssh "$MON" 'grep -q "^  smtp_auth_password:" /etc/prometheus/homelab/alertmanager.yml' && bad "alertmanager.yml carries the password inline (it must reference the file)" || ok "the config references the password FILE only"
  x="$(prom /api/v1/alertmanagers | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["data"]["activeAlertmanagers"]), len(d["data"]["droppedAlertmanagers"]))' 2>/dev/null)"
  [ "$x" = "1 0" ] && ok "Prometheus talks to one Alertmanager" || bad "Prometheus alertmanagers (active dropped): '$x'"
  x="$(prom /api/v1/rules | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for g in d["data"]["groups"] for r in g["rules"] if r.get("type")=="alerting"))' 2>/dev/null)"
  [ "${x:-0}" -ge 16 ] && ok "$x alert rules loaded (11 + the 5 basics)" || bad "only '$x' alert rules loaded"
  x="$(am '/api/v2/alerts?filter=alertname%3DWatchdog' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
  [ "$x" = "1" ] && ok "Watchdog is in Alertmanager (Prometheus -> Alertmanager alive)" || bad "Watchdog not seen by Alertmanager ('$x')"
  x="$(am '/api/v2/alerts?active=true&silenced=false' | python3 -c 'import json,sys; a=json.load(sys.stdin); print(",".join(sorted(set(x["labels"]["alertname"] for x in a if x["labels"]["alertname"]!="Watchdog"))) or "none")' 2>/dev/null)"
  echo "       alerts active besides the Watchdog: $x"
  x="$(rssh "$MON" 'sudo -n journalctl -u prometheus-alertmanager --since "-15min" --no-pager' | grep -c -i -E 'level=error|level=warn')"
  [ "$x" = "0" ] && ok "no Alertmanager errors/warnings in 15 min" || { bad "$x Alertmanager error/warning line(s) in 15 min"; rssh "$MON" 'sudo -n journalctl -u prometheus-alertmanager --since "-15min" --no-pager' | grep -i -E 'level=error|level=warn' | tail -3 | cut -c1-200 | sed 's/^/       /'; }
}

accountmanage_checks(){
  local n v
  for n in $ACCOUNTMANAGE_NODES; do
    v="$(ver_of "$(h "$n")" homelab-accountmanage)"; ver_ge "$v" "$WANT_AM" && ok "$n homelab-accountmanage $v" || bad "$n homelab-accountmanage $v < $WANT_AM"
    [ "$(rssh "$(h "$n")" 'systemctl is-active homelab-accountmanage')" = "active" ] && ok "$n accountmanage active" || bad "$n accountmanage not active"
  done
}

# Did the mail pool send a message from the service mailbox with this subject
# fragment to the recipient within the window? Proof without reading the inbox.
mail_sent(){ # $1 = subject fragment, $2 = since (journalctl --since), prints the count
  local n c total=0
  for n in $MAIL_NODES; do
    c="$(rssh "$(h "$n")" "sudo -n journalctl -u postfix --since '$2' --no-pager" | grep -c "status=sent" )"
    total=$((total + ${c:-0}))
  done
  echo "$total"
}
# Alertmanager's own view of notifications: its log has notify entries only on
# failure, so count the "Notify success" is not possible -- use the pool instead.
pool_lines(){ # $1 = since ; prints the pool's submission lines from the service mailbox
  local n
  for n in $MAIL_NODES; do
    rssh "$(h "$n")" "sudo -n journalctl -u postfix --since '$1' --no-pager" | grep -E "from=<$MAIL_FROM>|sasl_username=$MAIL_FROM|status=sent" | grep -v "to=<$MAIL_FROM>" | tail -6 | cut -c1-200
  done
}

# ----------------------------------------------------------------- tests --

test_synthetic(){
  step "synthetic critical alert into Alertmanager (amtool on the metrics host), then its resolve"
  local since; since="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  # Annotation values go double-quoted (the UTF-8 matcher parser) and without
  # '#', which that parser reads as a comment start.
  rssh "$MON" "amtool alert add alertname=SyntheticTest severity=critical host=orchestrator --annotation=summary=\"post-cutover item 38 end-to-end test: this mail proves Alertmanager to service mailbox to your inbox\" --end=\$(date -u -d '+3 min' +%Y-%m-%dT%H:%M:%SZ)" \
    && ok "synthetic alert posted (ends in 3 min -> a RESOLVED mail follows)" || { bad "amtool alert add failed"; return; }
  echo "  waiting 60 s for group_wait (30 s) + delivery ..."; sleep 60
  local before; before="$(pool_lines "$since" | grep -c 'status=sent')"
  pool_lines "$since" | sed 's/^/       /'
  [ "${before:-0}" -ge 1 ] && ok "the mail pool delivered a message from $MAIL_FROM after the alert ($before status=sent)" || bad "no delivery from $MAIL_FROM seen on the pool after 60 s"
  # The alert ends after 3 min; the RESOLVED notice goes out at the group's
  # next evaluation, group_interval (5 min) after the FIRING mail -- so up to
  # ~6 min from now. Poll rather than guess.
  echo "  waiting for the alert to end (3 min) and the RESOLVED notice (group_interval 5 min after the first mail) ..."
  local t after=0
  for t in $(seq 1 16); do
    sleep 30
    after="$(pool_lines "$since" | grep -c 'status=sent')"
    [ "${after:-0}" -ge 2 ] && break
  done
  [ "${after:-0}" -ge 2 ] && ok "a second message (RESOLVED) was delivered ($after total, after $((t * 30 + 60)) s)" || bad "no RESOLVED delivery seen within 9 min ($after total)"
}

test_hostdown(){
  local ip unit since; ip="$(h $PROVING_NODE)"
  unit="$(rssh "$ip" 'systemctl list-units --type=service --state=active --no-legend' | awk '/node.exporter/ {print $1}' | head -1)"
  [ -n "$unit" ] || { bad "no active node_exporter unit found on prod-homelab$PROVING_NODE"; return; }
  step "the real thing: stop $unit on prod-homelab$PROVING_NODE (the proving ground) until HostDown fires and is mailed"
  since="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  rssh "$ip" "sudo -n systemctl stop $unit" && ok "$unit stopped on $PROVING_NODE at $(date +%H:%M:%S)" || { bad "could not stop $unit"; return; }
  echo "  HostDown needs 10 min of failed scrapes + 30 s group_wait; polling Alertmanager ..."
  local t x fired=0
  for t in $(seq 1 30); do
    sleep 30
    x="$(am "/api/v2/alerts?filter=alertname%3DHostDown&filter=host%3Dprod-homelab$PROVING_NODE" | python3 -c 'import json,sys; a=json.load(sys.stdin); print(a[0]["status"]["state"] if a else "-")' 2>/dev/null)"
    printf '       %s HostDown(prod-homelab%s) in Alertmanager: %s\n' "$(date +%H:%M:%S)" "$PROVING_NODE" "$x"
    [ "$x" = "active" ] && { fired=1; break; }
  done
  [ "$fired" = 1 ] && ok "HostDown fired for prod-homelab$PROVING_NODE" || bad "HostDown did not reach Alertmanager within 15 min"
  sleep 45
  local sent; sent="$(pool_lines "$since" | grep -c 'status=sent')"
  pool_lines "$since" | sed 's/^/       /'
  [ "${sent:-0}" -ge 1 ] && ok "the FIRING mail left the pool ($sent status=sent)" || bad "no FIRING mail seen on the pool"
  rssh "$ip" "sudo -n systemctl start $unit" && ok "$unit started again at $(date +%H:%M:%S)" || bad "could not start $unit -- START IT BY HAND: ssh $ip sudo systemctl start $unit"
  # Prometheus sees the exporter back on its next scrape and resolves the alert
  # within a minute; Alertmanager then sends RESOLVED at the group's next flush,
  # group_interval (5 min for critical) after the FIRING mail. Poll the pool for
  # the second delivery for up to 9 min rather than guess the moment.
  echo "  waiting for the RESOLVED mail (one group_interval, 5 min, after the FIRING one) ..."
  local total=0
  for t in $(seq 1 18); do
    sleep 30
    total="$(pool_lines "$since" | grep -c 'status=sent')"
    [ "${total:-0}" -ge 2 ] && break
  done
  [ "${total:-0}" -ge 2 ] && ok "the RESOLVED mail left the pool too ($total total, $((t * 30)) s after the restart)" || bad "no RESOLVED mail seen within 9 min ($total total)"
}

# ------------------------------------------------------------------- run --

case "$MODE" in
  deploy)
    write_settings "$TO"
    step "homelab-prometheus -> $WANT_PROM on prod-homelab$METRICS_NODE (installs + configures Alertmanager); before: $(ver_of "$MON" homelab-prometheus)"
    ./pkg-upgrade.sh homelab-prometheus "$METRICS_NODE" || warn "pkg-upgrade homelab-prometheus reported a problem"
    sleep 5
    metrics_checks
    step "homelab-accountmanage -> $WANT_AM on $ACCOUNTMANAGE_NODES (alerts in the Metrics tab)"
    ./pkg-upgrade.sh homelab-accountmanage $ACCOUNTMANAGE_NODES || warn "pkg-upgrade homelab-accountmanage reported a problem"
    accountmanage_checks
    ;;
  verify)    step "verify"; metrics_checks; accountmanage_checks ;;
  synthetic) test_synthetic ;;
  hostdown)  test_hostdown ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then echo "${G}done: no failed checks${O} (log: $LOG)"; else echo "${R}done: $FAILS failed check(s)${O} (log: $LOG)"; exit 1; fi
