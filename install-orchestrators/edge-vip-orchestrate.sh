#!/usr/bin/env bash
# edge-vip-orchestrate.sh -- make 10.50.2.140 (the internal mail address Roundcube,
# SSO and mailbridge use for IMAP/SMTP) float between the three live edges with
# homelab-keepalived (post-cutover item 44, option C).
#
#   ./edge-vip-orchestrate.sh --status          # who holds .140 (read-only)
#   ./edge-vip-orchestrate.sh --apply 00        # set one edge up (do 00 first)
#   ./edge-vip-orchestrate.sh --apply 02
#   ./edge-vip-orchestrate.sh --apply 01
#
# Before this, .140 was a STATIC systemd-networkd address on one edge
# (eth4.network.d/10-homelab-vip.conf). Three edges with that file would all claim
# it, so this removes the file (WITHOUT reloading the network: the live address
# stays until keepalived owns it) and lets keepalived elect one holder.
#
# Order matters: --apply 00 first (priority 150, it becomes master at once and
# keeps the address it already has), then 02 and 01 as backups that hear 00's
# adverts and stay quiet. VRRP runs as unicast on the service plane (eth4).
set -euo pipefail

VIP=10.50.2.140/22
ROUTER_ID=140            # unique on the L2 (the database VIP group uses 51)
declare -A SSH_IP=([00]=10.20.2.144 [01]=10.20.2.145 [02]=10.20.2.146)
declare -A SVC_IP=([00]=10.50.2.144 [01]=10.50.2.145 [02]=10.50.2.146)
declare -A PRIO=([00]=150 [01]=100 [02]=90)

ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAILED=1; }
FAILED=0

holders() {
    local n c=0
    for n in 00 01 02; do
        if ssh -n -o ConnectTimeout=8 "${SSH_IP[$n]}" "ip -4 -o addr show dev eth4 | grep -q ' 10.50.2.140/'"; then
            printf '  %s holds %s\n' "$n" "${VIP%/*}"; c=$((c+1))
        fi
    done
    [ "$c" -eq 1 ] && ok "exactly one edge holds ${VIP%/*}" || bad "$c edges hold ${VIP%/*} (want exactly 1)"
}

vrrp_yml() {   # node -> vrrp.yml content
    local n=$1 m peers=""
    for m in 00 01 02; do [ "$m" = "$n" ] || peers="$peers  - ${SVC_IP[$m]}"$'\n'; done
    cat <<EOF
enabled: true
instance: EDGE_INTERNAL
router_id: $ROUTER_ID
state: BACKUP
priority: ${PRIO[$n]}
vrrp_interface: eth4
unicast_src: ${SVC_IP[$n]}
peers:
${peers%$'\n'}
auth_pass: hlvrrp
vips:
  - address: $VIP
    interface: eth4
track_services:
  - haproxy
track_weight: -60
EOF
}

case "${1:-}" in
--status) holders ;;
--apply)
    n=${2:-}; [ -n "${SSH_IP[$n]:-}" ] || { echo "usage: $0 --apply 00|01|02"; exit 1; }
    h=${SSH_IP[$n]}
    echo "=== edge $n ($h) ==="
    ssh -n "$h" 'sudo apt-get install -y homelab-keepalived >/dev/null 2>&1; dpkg-query -W -f="homelab-keepalived ${Version}\n" homelab-keepalived'
    vrrp_yml "$n" | ssh "$h" 'sudo tee /etc/homelab/keepalived/vrrp.yml >/dev/null'
    # Remove the static address file; do NOT reload networkd (keeps a live address).
    ssh -n "$h" 'sudo rm -f /etc/systemd/network/eth4.network.d/10-homelab-vip.conf; sudo homelab-keepalived-apply && sudo systemctl enable --now keepalived; sleep 6; systemctl is-active keepalived' \
        | tail -2
    holders
    ;;
*) echo "usage: $0 --status | --apply 00|01|02"; exit 1 ;;
esac
[ "$FAILED" = 0 ] || { echo "SOME CHECKS FAILED"; exit 1; }
