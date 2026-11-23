#!/bin/bash
# ============================================================================
# The systemd unit policy of the DB tier (patroni + etcd on 06/07/08) -- RUN
# ON THE ADMIN WORKSTATION. Post-cutover #41 I.
#
#   ./db-unit-policy.sh --verify     # what the three nodes have vs what they should
#   ./db-unit-policy.sh --apply      # write the override files + daemon-reload (NO restarts)
#
# WHY. database/scripts/ha-bootstrap.sh writes these override files once, at
# bring-up; the live nodes were bootstrapped with the old content (only
# TimeoutStartSec). This brings them to the current content without a
# bootstrap: patroni restarts on failure after 5 s (not 100 ms), stops within
# 240 s (fits pve2's down=300 for the DB tier) and is ordered after etcd so it
# stops before it; etcd restarts on failure. Restart= and TimeoutStopSec=
# take effect on daemon-reload; the After= ordering at the next boot. Nothing
# here restarts patroni or etcd. The heredocs MUST match ha-bootstrap.sh.
# The DB tier's keepalived (the .130 VIP) is the stock package, not
# homelab-keepalived, so its restart-policy drop-in is written here too.
# ============================================================================
set -u
NODES="06 07 08"
MODE="${1:---verify}"
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }
R=$'\e[31m'; G=$'\e[32m'; O=$'\e[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
FAILS=0

ETCD_OVERRIDE='[Service]
TimeoutStartSec=300
Restart=on-failure
RestartSec=5'
KEEPALIVED_RESTART='[Service]
Restart=on-failure
RestartSec=5'
PATRONI_OVERRIDE='[Unit]
After=etcd.service
[Service]
TimeoutStartSec=300
Restart=on-failure
RestartSec=5
TimeoutStopSec=240'

for n in $NODES; do
    ip=$(ip_of "$n")
    echo "=== prod-homelab$n ($ip) ==="
    if [ "$MODE" = "--apply" ]; then
        rssh "$ip" "sudo install -d /etc/systemd/system/etcd.service.d /etc/systemd/system/patroni.service.d /etc/systemd/system/keepalived.service.d \
            && printf '%s\n' '$ETCD_OVERRIDE' | sudo tee /etc/systemd/system/etcd.service.d/override.conf >/dev/null \
            && printf '%s\n' '$PATRONI_OVERRIDE' | sudo tee /etc/systemd/system/patroni.service.d/override.conf >/dev/null \
            && printf '%s\n' '$KEEPALIVED_RESTART' | sudo tee /etc/systemd/system/keepalived.service.d/20-homelab-restart.conf >/dev/null \
            && sudo systemctl daemon-reload" && ok "override files written, systemd reloaded" || bad "could not write the override files"
    fi
    live_e=$(rssh "$ip" "sudo cat /etc/systemd/system/etcd.service.d/override.conf 2>/dev/null")
    live_p=$(rssh "$ip" "sudo cat /etc/systemd/system/patroni.service.d/override.conf 2>/dev/null")
    [ "$live_e" = "$ETCD_OVERRIDE" ] && ok "etcd override.conf is current" || bad "etcd override.conf differs: $(echo "$live_e" | paste -sd'|' -)"
    [ "$live_p" = "$PATRONI_OVERRIDE" ] && ok "patroni override.conf is current" || bad "patroni override.conf differs: $(echo "$live_p" | paste -sd'|' -)"
    props=$(rssh "$ip" "systemctl show -p Restart,RestartUSec,TimeoutStopUSec patroni.service | paste -sd' ' -; systemctl show -p Restart,RestartUSec etcd.service | paste -sd' ' -; systemctl show -p After patroni.service | grep -o 'etcd.service' | head -1")
    case "$props" in
        *"Restart=on-failure RestartUSec=5s TimeoutStopUSec=4min"*"Restart=on-failure RestartUSec=5s"*etcd.service*) ok "systemd sees patroni (on-failure, 5 s, stop 4 min, after etcd) and etcd (on-failure, 5 s)" ;;
        *) bad "systemd does not show the policy yet: $(echo "$props" | paste -sd' ' -)" ;;
    esac
    live_k=$(rssh "$ip" "sudo cat /etc/systemd/system/keepalived.service.d/20-homelab-restart.conf 2>/dev/null")
    [ "$live_k" = "$KEEPALIVED_RESTART" ] && ok "keepalived restart drop-in is current" || bad "keepalived restart drop-in differs: $(echo "$live_k" | paste -sd'|' -)"
    kp=$(rssh "$ip" "systemctl show -p Restart,RestartUSec keepalived.service | paste -sd' ' -")
    [ "$kp" = "Restart=on-failure RestartUSec=5s" ] && ok "systemd sees keepalived (on-failure, 5 s)" || bad "keepalived policy not in force: $kp"
    act=$(rssh "$ip" "systemctl is-active patroni etcd keepalived | paste -sd' ' -")
    [ "$act" = "active active active" ] && ok "patroni, etcd and keepalived active" || bad "patroni/etcd/keepalived: $act"
done
echo "=== result ==="
[ "$FAILS" = 0 ] && echo "  DB-tier unit policy in force on all three nodes." || echo "  $FAILS problem(s) -- see FAIL lines."
exit $(( FAILS > 0 ))
