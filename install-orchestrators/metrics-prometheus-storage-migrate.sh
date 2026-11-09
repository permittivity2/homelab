#!/bin/bash
# ============================================================================
# Move a Prometheus host's pre-0.8.0 hand storage drop-in into the package's
# config, then upgrade homelab-prometheus -- RUN ON THE ADMIN WORKSTATION.
#
#   ./metrics-prometheus-storage-migrate.sh NN       # e.g. 69 (prod-homelabvm69)
#
# WHY. Before homelab-prometheus 0.8.0 the TSDB path and retention were
# hardcoded in the package's unit drop-in, so a host that keeps its data on
# the nas share needed a later-sorting hand drop-in (zz-homelab-storage.conf,
# metrics-orchestrate.sh step 5, 2026-10-28) overriding ExecStart. 0.8.0 reads
# TSDB_PATH / RETENTION_TIME / RETENTION_SIZE from /etc/homelab/prometheus/config
# and adds RequiresMountsFor itself when the path is a mount point.
#
# WHAT IT DOES.
#   1. copies the hand drop-in's path / retention / size cap into the config,
#      so the upgrade does not append the old 30d defaults instead;
#   2. upgrades homelab-prometheus from the fleet repo (pkg-upgrade.sh);
#   3. removes the hand drop-in, reloads systemd, restarts Prometheus;
#   4. prints the running storage flags -- they must read as before.
# Safe to re-run. The only deletion is the drop-in the package now replaces.
# ============================================================================
set -uo pipefail
NN="${1:?usage: $0 NN   (node number, e.g. 69)}"
NN="$(printf '%02d' "$((10#$NN))")"
IP="10.20.2.$((144 + 10#$NN))"
ZZ=/etc/systemd/system/prometheus.service.d/zz-homelab-storage.conf
CFG=/etc/homelab/prometheus/config
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R(){ ssh -o ConnectTimeout=8 "$IP" "$@"; }

echo "== [1/4] storage values -> $CFG on node $NN ($IP)"
if R "grep -q '^TSDB_PATH=' $CFG"; then
    echo "  already present:"
    R "grep -E '^(TSDB_PATH|RETENTION_TIME|RETENTION_SIZE)=' $CFG" | sed 's/^/    /'
else
    LINE="$(R "sudo -n cat $ZZ 2>/dev/null | grep '^ExecStart=/usr'" || true)"
    TSDB_PATH="$(sed -n 's/.*--storage\.tsdb\.path=\([^ ]*\).*/\1/p' <<<"$LINE")"
    RETENTION_TIME="$(sed -n 's/.*--storage\.tsdb\.retention\.time=\([^ ]*\).*/\1/p' <<<"$LINE")"
    RETENTION_SIZE="$(sed -n 's/.*--storage\.tsdb\.retention\.size=\([^ ]*\).*/\1/p' <<<"$LINE")"
    : "${TSDB_PATH:=/var/lib/prometheus/metrics2}" "${RETENTION_TIME:=30d}" "${RETENTION_SIZE:=0}"
    [ -n "$LINE" ] && SRC="from $ZZ" || SRC="package defaults (no hand drop-in found)"
    printf '%s\n' '' \
        "# TSDB storage (homelab-prometheus 0.8.0 reads these; migrated $(date +%F) $SRC)." \
        "TSDB_PATH=\"$TSDB_PATH\"" "RETENTION_TIME=\"$RETENTION_TIME\"" "RETENTION_SIZE=\"$RETENTION_SIZE\"" \
        | R "sudo -n tee -a $CFG >/dev/null" \
        && echo "  wrote TSDB_PATH=$TSDB_PATH RETENTION_TIME=$RETENTION_TIME RETENTION_SIZE=$RETENTION_SIZE ($SRC)" \
        || { echo "  FAILED to write $CFG"; exit 1; }
fi

echo "== [2/4] upgrade homelab-prometheus"
"$HERE/pkg-upgrade.sh" homelab-prometheus "$NN" || { echo "upgrade failed -- stopping before touching the drop-in"; exit 1; }

echo "== [3/4] retire the hand drop-in"
R "if sudo -n test -f $ZZ; then sudo -n rm -f $ZZ && echo '  removed $ZZ'; else echo '  no hand drop-in present'; fi
   sudo -n systemctl daemon-reload && sudo -n systemctl restart prometheus && echo '  prometheus restarted'"

echo "== [4/4] running flags (must match the old drop-in)"
# Prometheus replays its WAL before it answers; on a TSDB this size that is
# tens of seconds, so wait for /-/ready rather than reading an empty answer.
R "for i in \$(seq 1 60); do curl -sf -m 2 localhost:9090/-/ready >/dev/null && break; sleep 2; done
   echo \"  unit: \$(systemctl is-active prometheus); \$(systemctl show prometheus -p RequiresMountsFor)\"
   curl -s -m 5 localhost:9090/api/v1/status/flags | tr ',' '\n' | grep -E 'storage.tsdb.(path|retention.time|retention.size)' | sed 's/^/  /'
   echo \"  rule groups: \$(curl -s -m 5 localhost:9090/api/v1/rules | grep -o '\"name\":\"[^\"]*\",\"file\"' | cut -d'\"' -f4 | paste -sd' ' -)\"
   echo \"  drop-ins: \$(ls /etc/systemd/system/prometheus.service.d/)\""
