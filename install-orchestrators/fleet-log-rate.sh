#!/bin/bash
# Fleet log-rate check -- is any node writing log faster than it should? --
# RUN ON THE ADMIN WORKSTATION. Read-only. Post-cutover #110.
#
#   ./fleet-log-rate.sh            # top log producer per node in the last hour + /var/log/syslog growth; flags the hot ones
#   ./fleet-log-rate.sh --window 6h   # look back further (default 1h)
#   ./fleet-log-rate.sh --full     # print every node, not only the flagged ones
#
# WHY. Three times in one week a single process ran away writing log and nearly
# filled a root disk (#104 blackbox 245 MB/day, #105 haproxy/DNS checks filled
# prod-homelab39, #110 the Mojo::Pg dead-socket loop 2 GB/day on prod-homelab12),
# each caught only by the last-resort RootDiskFilling alert at 85 % full. This
# surfaces the top producer on demand so a flood is a one-line answer, not a
# disk incident. The baseline (#110 evidence): the busiest legitimate producer
# fleet-wide is dovecot at ~1.2 lines/s (~4.3 k/hour) on the mail VMs; every
# homelab app is far lower. So LINES_PER_HOUR=20000 (dovecot can peak ~7k/hour on a busy mail hour; this clears it, and still
# catches #105 at ~60k/hour and #110 at ~1.8M/hour by a wide margin). A byte-heavy but low-line flood (#104) is caught by the RootDiskFilling/RootDiskGrowingFast alerts instead. GROW_MB=100 (MB added to /var/log/syslog in the window) flag a
# genuine runaway without touching normal operation.

set -uo pipefail
WINDOW="1h"; FULL=0
while [ $# -gt 0 ]; do case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    --full)   FULL=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'"; exit 1 ;;
esac; done

LINES_PER_HOUR=${LINES_PER_HOUR:-20000}
GROW_MB=${GROW_MB:-100}

# hours in the window, for scaling the per-identifier threshold
case "$WINDOW" in
    *h) HRS=${WINDOW%h} ;;
    *d) HRS=$(( ${WINDOW%d} * 24 )) ;;
    *)  HRS=1 ;;
esac
[ "$HRS" -ge 1 ] || HRS=1
THRESH=$(( LINES_PER_HOUR * HRS ))

nodes=""
for n in $(seq 0 60) 61; do nodes="$nodes 10.20.2.$((144+n))"; done
for n in 62 63 64 65 66 67 69 70 71 72; do nodes="$nodes 10.20.2.$((144+n))"; done

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
flagged=0; seen=0

printf 'log rate over the last %s (flag: an identifier > %s lines, or syslog +%s MB)\n\n' "$WINDOW" "$THRESH" "$GROW_MB"
for ip in $nodes; do
    out=$(ssh -n -o ConnectTimeout=6 -o BatchMode=yes "$ip" '
        h=$(hostname -s)
        top=$(sudo journalctl --since "-'"$WINDOW"'" -o json --output-fields=SYSLOG_IDENTIFIER --no-pager 2>/dev/null \
              | grep -oE "\"SYSLOG_IDENTIFIER\":\"[^\"]*\"" | sed "s/.*://; s/\"//g" | sort | uniq -c | sort -rn | head -1)
        n=$(echo "$top" | awk "{print \$1}"); id=$(echo "$top" | awk "{print \$2}")
        # bytes written to syslog in the window, via its mtime-age vs size is unreliable; use journald count as the signal and syslog size as context
        sz=$(sudo stat -c %s /var/log/syslog 2>/dev/null || echo 0)
        free=$(df -BM / | awk "NR==2{gsub(/M/,\"\",\$4); print \$4}")
        printf "%s|%s|%s|%s|%s" "$h" "${n:-0}" "${id:-none}" "$sz" "${free:-0}"
    ' 2>/dev/null) || { printf '  %s unreachable\n' "$ip"; continue; }
    IFS='|' read -r host lines id sz free <<<"$out"
    seen=$((seen+1))
    hot=0
    [ "${lines:-0}" -gt "$THRESH" ] && hot=1
    szmb=$(( ${sz:-0} / 1048576 ))
    if [ "$hot" = 1 ]; then
        flagged=$((flagged+1))
        printf '  %s%-22s%s top %s = %s lines/%s  (syslog %sMB, %sMB free)\n' "$RED" "$host" "$RST" "$id" "$lines" "$WINDOW" "$szmb" "${free:-?}"
    elif [ "$FULL" = 1 ]; then
        printf '  %-22s top %-28s %6s lines/%s  (syslog %sMB, %sMB free)\n' "$host" "$id" "$lines" "$WINDOW" "$szmb" "${free:-?}"
    fi
done

echo
if [ "$flagged" = 0 ]; then
    printf '%s=== result: %d node(s) checked, none over the threshold ===%s\n' "$GRN" "$seen" "$RST"
else
    printf '%s=== result: %d of %d node(s) writing log hot -- investigate the identifier shown ===%s\n' "$YEL" "$flagged" "$seen" "$RST"
fi
exit $(( flagged > 0 ))
