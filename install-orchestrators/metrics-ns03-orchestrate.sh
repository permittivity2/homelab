#!/bin/bash
# ============================================================================
# Put ns03 -- the sole resolver, NOT a fleet member -- under the fleet's
# Prometheus/Grafana. RUN ON THE ADMIN WORKSTATION. Post-cutover #66.
#
#   ./metrics-ns03-orchestrate.sh            # do it; ONE pdns-recursor restart
#                                            # only if the webserver config is new
#   ./metrics-ns03-orchestrate.sh --verify   # read-only checks
#
# WHAT IT DOES, in order (every step idempotent):
#   [1] monitoring node: homelab-prometheus >= 0.9.0 and homelab-grafana >= 0.7.0
#       (pkg-upgrade.sh if behind), then STATIC_TARGETS gains ns03's two
#       entries (metrics-static-targets.sh) -- ns03 has no homelab-agent, so
#       the fleet API will never list it and the pull would never find it.
#   [2] ns03: /etc/homelab/node-exporter/config pre-seeded with
#       MONITORING_HOSTS=<monitoring node's 10.20 address> (it reaches ns03 on
#       the 10.20 plane), then homelab-node-exporter installed from the homelab
#       repo ns03 already subscribes to, --no-install-recommends so no agent
#       comes along (512 MB box, and the user wants it agentless). The package
#       opens :9100 and :8082 to that one address by appending to the existing
#       `inet filter input` chain -- never a full ruleset reload: bad-ips'
#       badipv4 set lives in the same table and a reload flushes it.
#   [3] ns03: pdns-recursor's built-in webserver for its Prometheus /metrics:
#       `include-dir=/etc/powerdns/recursor.d` added to recursor.conf (backed up
#       first, the file's own convention) and recursor.d/10-metrics.conf with
#       webserver on 10.20.0.140:8082, allow-from the monitoring node only, no
#       api-key (REST API stays off). Checked with `pdns_recursor --config=check`
#       before anything is restarted; a failed check reverts both files.
#   [4] ns03: ONE `systemctl restart pdns-recursor` if [3] changed anything (a
#       webserver cannot be enabled live). DNS for every network blips for
#       about a second; dig is checked immediately after.
#   [5] ns03: queries by CLIENT and by NAME. The recursor's /metrics has no
#       per-client numbers, but `rec_control top-remotes` / `top-queries` /
#       `top-servfail-*` / `top-timeouts` rank the last 10,000 queries.
#       files/ns03/recursor-top-metrics (Perl) turns those into node_exporter
#       textfile metrics every 60 s (recursor-top-metrics.timer, root: the
#       control socket is pdns's, the textfile dir root's). Read-only against
#       the recursor; nothing to restart.
#   [6] verify from the monitoring node: both ns03 targets up, the
#       homelab-resolver rule group loaded, the rankings fresh, /metrics NOT
#       reachable from here.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_NODE="${METRICS_NODE:-69}"
MON_IP="10.20.2.$((144 + 10#$METRICS_NODE))"      # reaches ns03 on the 10.20 plane
NS03=ns03                                          # ~/.ssh/config alias, 10.20.0.140
NS03_IP=10.20.0.140
RECURSOR_PORT=8082
ENTRIES=("node=ns03:$NS03_IP:9100" "pdns-recursor=ns03:$NS03_IP:$RECURSOR_PORT")
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
N(){ ssh -o ConnectTimeout=8 "$NS03" "$@"; }
M(){ ssh -o ConnectTimeout=8 "$MON_IP" "$@"; }

METRICS_CONF="$(cat <<EOF
# Managed by install-orchestrators/metrics-ns03-orchestrate.sh (post-cutover #66,
# 2026-11-09). The recursor's built-in webserver, for its Prometheus /metrics
# only: no api-key, so the REST API stays off; reachable from the fleet's
# monitoring host alone (the host firewall opens $RECURSOR_PORT to the same address
# through homelab-node-exporter's drop-in). webserver-allow-from is separate from
# allow-from, which is the DNS client ACL. Changing anything here needs a
# pdns-recursor restart -- a house-wide DNS blip of about a second.
webserver=yes
webserver-address=$NS03_IP
webserver-port=$RECURSOR_PORT
webserver-allow-from=$MON_IP/32
webserver-loglevel=none
EOF
)"

verify(){
    local rc=0
    say "[verify] ns03 itself"
    N "echo \"  node-exporter: \$(systemctl is-active prometheus-node-exporter 2>/dev/null) (\$(dpkg-query -W -f='\${Version}' homelab-node-exporter 2>/dev/null))\"
       echo \"  pdns-recursor: \$(systemctl is-active pdns-recursor)\"
       echo \"  listeners: \$(ss -ltnH | awk '{print \$4}' | grep -E ':(9100|$RECURSOR_PORT)\$' | paste -sd' ' -)\"
       echo \"  firewall: \$(sudo -n nft list chain inet filter input | grep -c homelab-metrics-allow) metrics-allow rule(s): \$(sudo -n nft list chain inet filter input | grep homelab-metrics-allow | sed 's/^[[:space:]]*//' | cut -c1-90)\"
       echo \"  recursor.d: \$(ls /etc/powerdns/recursor.d/ 2>/dev/null | paste -sd' ' -); include-dir: \$(grep -c '^include-dir=' /etc/powerdns/recursor.conf)\"
       echo \"  memory: \$(free -m | awk 'NR==2{print \$7\" MB available of \"\$2}')\"
       echo \"  dig @127.0.0.1 mailmasker.org: \$(dig +short +time=2 +tries=1 @127.0.0.1 mailmasker.org A | head -1)\"
       echo \"  rankings: timer \$(systemctl is-active recursor-top-metrics.timer 2>/dev/null); recursor_top.prom \$(stat -c '%y' /var/lib/prometheus/node-exporter/recursor_top.prom 2>/dev/null | cut -c1-19 || echo MISSING), \$(grep -c '^pdns_recursor_top_remote_share' /var/lib/prometheus/node-exporter/recursor_top.prom 2>/dev/null) client row(s)\""
    say "[verify] from the monitoring node ($MON_IP)"
    M "printf '  node_ metrics: %s\n' \"\$(curl -s -m 5 http://$NS03_IP:9100/metrics | grep -c '^node_')\"
       printf '  recursor metrics: %s\n' \"\$(curl -s -m 5 http://$NS03_IP:$RECURSOR_PORT/metrics | grep -E '^pdns_recursor_(questions|cache_hits|servfail_answers) ' | paste -sd' ' -)\"
       for i in \$(seq 1 30); do curl -sf -m 2 localhost:9090/-/ready >/dev/null && break; sleep 2; done
       # Right after a restart the last scrape may predate the webserver (15 s
       # interval, 30 s file_sd refresh): give both targets up to 60 s to come up.
       for i in \$(seq 1 12); do
           n=\$(curl -s -m 5 localhost:9090/api/v1/targets | python3 -c 'import sys,json; print(len([t for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"] if t[\"labels\"].get(\"host\")==\"ns03\" and t[\"health\"]==\"up\"]))')
           [ \"\$n\" = 2 ] && break; sleep 5
       done
       curl -s -m 5 localhost:9090/api/v1/targets | python3 -c '
import sys, json
ts = [t for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"] if t[\"labels\"].get(\"host\") == \"ns03\"]
for t in sorted(ts, key=lambda t: t[\"labels\"][\"job\"]):
    print(\"  target %-14s %-20s %s %s\" % (t[\"labels\"][\"job\"], t[\"labels\"][\"instance\"], t[\"health\"], t.get(\"lastError\", \"\")[:70]))
if len([t for t in ts if t[\"health\"] == \"up\"]) != 2: print(\"  !! expected 2 ns03 targets up, saw\", len([t for t in ts if t[\"health\"] == \"up\"])); sys.exit(1)'" || rc=1
    M "curl -s -m 5 localhost:9090/api/v1/rules | python3 -c '
import sys, json
gs = {g[\"name\"]: len(g[\"rules\"]) for g in json.load(sys.stdin)[\"data\"][\"groups\"]}
print(\"  rule groups:\", \" \".join(f\"{k}({v})\" for k, v in gs.items()))
sys.exit(0 if \"homelab-resolver\" in gs else 1)'" || { echo "  !! homelab-resolver rule group missing"; rc=1; }
    say "[verify] /metrics must NOT answer this workstation (allow-from + firewall)"
    if curl -s -m 4 "http://$NS03_IP:$RECURSOR_PORT/metrics" >/dev/null 2>&1; then
        echo "  !! reachable from here -- gating is broken"; rc=1
    else
        echo "  ok: not reachable from here"
    fi
    return $rc
}

if [ "${1:-}" = "--verify" ]; then verify; exit $?; fi

say "[1/6] monitoring node $METRICS_NODE: package versions + STATIC_TARGETS"
PV="$(M "dpkg-query -W -f='\${Version}' homelab-prometheus 2>/dev/null")"
GV="$(M "dpkg-query -W -f='\${Version}' homelab-grafana 2>/dev/null")"
echo "  homelab-prometheus $PV, homelab-grafana $GV"
M "dpkg --compare-versions '$PV' ge 0.9.0" || "$HERE/pkg-upgrade.sh" homelab-prometheus "$METRICS_NODE" || exit 1
M "dpkg --compare-versions '$GV' ge 0.7.0" || "$HERE/pkg-upgrade.sh" homelab-grafana "$METRICS_NODE" || exit 1
"$HERE/metrics-static-targets.sh" "$METRICS_NODE" add "${ENTRIES[@]}" || exit 1

say "[2/6] ns03: homelab-node-exporter (agentless, MONITORING_HOSTS=$MON_IP)"
N "sudo -n install -d -m 755 /etc/homelab/node-exporter
   if ! grep -qx 'MONITORING_HOSTS=\"$MON_IP\"' /etc/homelab/node-exporter/config 2>/dev/null; then
       printf '# ns03 is reached by the monitoring node on the 10.20 plane (metrics-ns03-orchestrate.sh).\nMONITORING_HOSTS=\"%s\"\n' '$MON_IP' | sudo -n tee /etc/homelab/node-exporter/config >/dev/null
       echo '  wrote /etc/homelab/node-exporter/config'
   fi
   sudo -n apt-get update -qq >/dev/null 2>&1
   sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends homelab-node-exporter 2>&1 | grep -E 'WARNING|wrote|firewall|configured|newest' | sed 's/^/  /'
   v=\$(dpkg-query -W -f='\${Version}' homelab-node-exporter); echo \"  homelab-node-exporter \$v\"
   dpkg --compare-versions \"\$v\" ge 0.5.1 || { echo '  !! need 0.5.1 or later (port $RECURSOR_PORT in the firewall set)'; exit 1; }
   # Make sure the live rule carries the pre-seeded address and the recursor port.
   sudo -n nft list chain inet filter input | grep -q 'homelab-metrics-allow' || sudo -n DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-node-exporter | grep -E 'firewall' | sed 's/^/  /'
   sudo -n nft list chain inet filter input | grep homelab-metrics-allow | grep -q '$MON_IP' || { echo '  !! metrics-allow rule does not name $MON_IP'; exit 1; }
   # nft lists consecutive set members as a range (8081, 8082, 8083 -> 8081-8083),
   # so look for the port or a range that covers it.
   sudo -n nft list chain inet filter input | grep homelab-metrics-allow | grep -qE '\b$RECURSOR_PORT\b|\b808[01]-808[2-9]\b' || { echo '  !! metrics-allow rule lacks port $RECURSOR_PORT'; exit 1; }
   echo '  (the chgrp WARNING above is expected: no homelab group here because there is no agent)'" || exit 1

say "[3/6] ns03: recursor webserver config (checked before use)"
CHANGED="$(N "set -e
   sudo -n install -d -m 755 /etc/powerdns/recursor.d
   changed=0
   if ! sudo -n cmp -s /etc/powerdns/recursor.d/10-metrics.conf - <<'EOF'
$METRICS_CONF
EOF
   then
       sudo -n tee /etc/powerdns/recursor.d/10-metrics.conf >/dev/null <<'EOF'
$METRICS_CONF
EOF
       sudo -n chmod 644 /etc/powerdns/recursor.d/10-metrics.conf
       echo '  wrote /etc/powerdns/recursor.d/10-metrics.conf' >&2; changed=1
   fi
   if ! grep -q '^include-dir=' /etc/powerdns/recursor.conf; then
       bak=/etc/powerdns/recursor.conf.bak-\$(date +%Y%m%d-%H%M%S)
       sudo -n cp -p /etc/powerdns/recursor.conf \"\$bak\"
       printf '\n# Drop-in directory (metrics-ns03-orchestrate.sh, post-cutover #66): recursor.d/10-metrics.conf = the Prometheus webserver.\ninclude-dir=/etc/powerdns/recursor.d\n' | sudo -n tee -a /etc/powerdns/recursor.conf >/dev/null
       echo \"  added include-dir to recursor.conf (backup \$bak)\" >&2; changed=1
   fi
   if ! out=\$(sudo -n pdns_recursor --config=check 2>&1); then
       echo '  !! pdns_recursor --config=check FAILED -- reverting:' >&2; echo \"\$out\" | tail -5 | sed 's/^/     /' >&2
       [ -n \"\${bak:-}\" ] && sudo -n cp -p \"\$bak\" /etc/powerdns/recursor.conf
       sudo -n rm -f /etc/powerdns/recursor.d/10-metrics.conf
       exit 1
   fi
   echo '  config check: ok' >&2
   echo \$changed")" || exit 1

say "[4/6] ns03: pdns-recursor restart"
if [ "$CHANGED" = 1 ]; then
    N "t0=\$(date +%s%N); sudo -n systemctl restart pdns-recursor
       for i in \$(seq 1 30); do dig +short +time=1 +tries=1 @127.0.0.1 mailmasker.org A >/dev/null 2>&1 && break; sleep 0.5; done
       printf '  restarted; answering again after %d ms; unit %s\n' \"\$(( (\$(date +%s%N) - t0) / 1000000 ))\" \"\$(systemctl is-active pdns-recursor)\"
       ss -ltnH | awk '{print \$4}' | grep -q '^$NS03_IP:$RECURSOR_PORT\$' && echo '  webserver listening on $NS03_IP:$RECURSOR_PORT' || { echo '  !! webserver not listening'; exit 1; }" || exit 1
else
    echo "  nothing changed in [3], no restart"
fi

say "[5/6] ns03: client / name rankings -> textfile metrics (recursor-top-metrics)"
FILES="$HERE/files/ns03"
scp -q "$FILES/recursor-top-metrics" "$FILES/recursor-top-metrics.service" "$FILES/recursor-top-metrics.timer" "$NS03:/tmp/" || exit 1
N "changed=0
   for f in recursor-top-metrics:/usr/local/sbin/recursor-top-metrics:755 recursor-top-metrics.service:/etc/systemd/system/recursor-top-metrics.service:644 recursor-top-metrics.timer:/etc/systemd/system/recursor-top-metrics.timer:644; do
       src=/tmp/\${f%%:*}; rest=\${f#*:}; dst=\${rest%%:*}; mode=\${rest##*:}
       if ! sudo -n cmp -s \"\$src\" \"\$dst\"; then sudo -n install -m \"\$mode\" \"\$src\" \"\$dst\" && echo \"  installed \$dst\"; changed=1; fi
       rm -f \"\$src\"
   done
   perl -c /usr/local/sbin/recursor-top-metrics 2>&1 | grep -v 'syntax OK' || true
   if [ \$changed = 1 ]; then sudo -n systemctl daemon-reload; fi
   sudo -n systemctl enable --now recursor-top-metrics.timer >/dev/null 2>&1
   sudo -n systemctl start recursor-top-metrics.service && echo \"  ran once: \$(grep -c '^pdns_recursor_top_' /var/lib/prometheus/node-exporter/recursor_top.prom) metric line(s), top client \$(grep '^pdns_recursor_top_remote_share' /var/lib/prometheus/node-exporter/recursor_top.prom | sort -k2 -nr | head -1)\"
   echo \"  timer: \$(systemctl is-active recursor-top-metrics.timer); \$(systemctl list-timers --no-legend recursor-top-metrics.timer | awk '{print \"next \" \$1\" \"\$2\" \"\$3\" \"\$4}')\"" || exit 1

say "[6/6] verify"
verify
