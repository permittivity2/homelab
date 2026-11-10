#!/bin/bash
# ============================================================================
# Static scrape targets on a homelab-prometheus host -- RUN ON THE ADMIN
# WORKSTATION.
#
#   ./metrics-static-targets.sh NN show
#   ./metrics-static-targets.sh NN add    JOB=HOST:ADDRESS:PORT [...]
#   ./metrics-static-targets.sh NN remove JOB=HOST:ADDRESS:PORT [...]
#
#   e.g.  ./metrics-static-targets.sh 69 add node=ns03:10.20.0.140:9100 pdns-recursor=ns03:10.20.0.140:8082
#
# WHY. Prometheus's targets come from the fleet API (homelab-prometheus-pull,
# every two minutes), so a host without homelab-agent -- ns03, the sole
# resolver, is the case this was written for (post-cutover #66) -- can only be
# scraped through STATIC_TARGETS in /etc/homelab/prometheus/config, which
# homelab-prometheus >= 0.9.0 renders into targets-static/<job>.json. This
# edits that one key, runs dpkg-reconfigure homelab-prometheus (renders the
# files, restarts prometheus), waits for /-/ready and shows the static
# targets' health. Idempotent; `show` changes nothing.
# ============================================================================
set -uo pipefail
NN="${1:?usage: $0 NN show|add|remove [JOB=HOST:ADDRESS:PORT ...]}"
ACTION="${2:?usage: $0 NN show|add|remove [JOB=HOST:ADDRESS:PORT ...]}"
shift 2
NN="$(printf '%02d' "$((10#$NN))")"
IP="10.20.2.$((144 + 10#$NN))"
CFG=/etc/homelab/prometheus/config
R(){ ssh -o ConnectTimeout=8 "$IP" "$@"; }

VER="$(R "dpkg-query -W -f='\${Version}' homelab-prometheus 2>/dev/null")"
if ! R "dpkg --compare-versions '$VER' ge 0.9.0"; then
    echo "homelab-prometheus on node $NN is '$VER'; STATIC_TARGETS needs 0.9.0 or later (pkg-upgrade.sh homelab-prometheus $NN)"; exit 1
fi

current="$(R "grep -E '^STATIC_TARGETS=' $CFG 2>/dev/null | tail -1 | sed -E 's/^STATIC_TARGETS=\"?//; s/\"?\s*$//'")"
read -r -a cur <<<"$current"

show_health(){
    echo "== static targets on node $NN (host, job, instance, health)"
    # After the restart Prometheus replays its WAL, then file_sd needs up to
    # its 30 s refresh to load the static files: wait for readiness, then for
    # a tier=legacy target to exist (up to ~45 s) before printing health.
    R 'for i in $(seq 1 45); do curl -sf -m 2 localhost:9090/-/ready >/dev/null && break; sleep 2; done
       for i in $(seq 1 9); do curl -s -m 5 localhost:9090/api/v1/targets | grep -q "\"tier\":\"legacy\"" && break; sleep 5; done
       sleep 3; curl -s -m 5 localhost:9090/api/v1/targets' | python3 -c '
import sys, json
ts = [t for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"].get("tier") == "legacy"]
for t in sorted(ts, key=lambda t: (t["labels"]["host"], t["labels"]["job"])):
    print("  %-8s %-14s %-22s %s %s" % (t["labels"]["host"], t["labels"]["job"], t["labels"]["instance"], t["health"], t.get("lastError", "")[:60]))
print("  (none)") if not ts else None'
}

case "$ACTION" in
  show)
    echo "STATIC_TARGETS=\"$current\""
    show_health; exit 0 ;;
  add|remove)
    [ $# -gt 0 ] || { echo "nothing to $ACTION"; exit 2; }
    for e in "$@"; do
        [[ "$e" =~ ^[a-z0-9-]+=[A-Za-z0-9._-]+:.+:[0-9]+$ ]] || { echo "not JOB=HOST:ADDRESS:PORT: $e"; exit 2; }
    done
    declare -A want=()
    for e in "${cur[@]}"; do [ -n "$e" ] && want["$e"]=1; done
    for e in "$@"; do
        if [ "$ACTION" = add ]; then want["$e"]=1; else unset 'want[$e]'; fi
    done
    new="$(printf '%s\n' "${!want[@]}" | sort | paste -sd' ' -)"
    if [ "$new" = "$current" ]; then
        echo "STATIC_TARGETS already \"$current\" -- nothing to change"; show_health; exit 0
    fi
    echo "STATIC_TARGETS: \"$current\" -> \"$new\""
    # The key exists on any 0.9.0+ host (the postinst appends it), so replace
    # it in place; append only if it is somehow missing.
    R "if grep -q '^STATIC_TARGETS=' $CFG; then
           sudo -n sed -i 's|^STATIC_TARGETS=.*|STATIC_TARGETS=\"$new\"|' $CFG
       else
           printf '\nSTATIC_TARGETS=\"%s\"\n' '$new' | sudo -n tee -a $CFG >/dev/null
       fi
       sudo -n DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-prometheus 2>&1 | grep -E 'static targets|WARNING|alert rules'" \
       || { echo "FAILED to apply on node $NN"; exit 1; }
    show_health ;;
  *) echo "unknown action '$ACTION' (show|add|remove)"; exit 2 ;;
esac
