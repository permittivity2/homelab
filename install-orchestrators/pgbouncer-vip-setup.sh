#!/bin/bash
# pgbouncer VIP (keepalived) — run on EACH of prod-homelab09/10/11 (SAME script).
# Floats 10.50.2.131 across the three poolers, tracking the pgbouncer service, so
# clients get ONE stable DB endpoint (10.50.2.131:6432) that survives a pooler
# node (or process) loss. Active/passive: highest-priority healthy node owns it.
#
# Prereq: pgbouncer-node-setup.sh already run on this node (pgbouncer up + the
# apt-homelab source present). Invoke with:  sudo bash pgbouncer-vip-setup.sh
# Order between the three doesn't matter.
set -euo pipefail

VIP=10.50.2.131/22
ROUTER_ID=52          # distinct from the DB cluster's VRRP (51) and the edge's
AUTH_PASS=pgbvrrp     # <=8 chars, identical on all three

[ "$(id -u)" -eq 0 ] || { echo "run as root:  sudo bash $0"; exit 1; }
THIS="$(hostname -s)"
case "$THIS" in
  prod-homelab09) SELF=10.50.2.153; P1=10.50.2.154; P2=10.50.2.155; PRIO=150 ;;  # preferred owner
  prod-homelab10) SELF=10.50.2.154; P1=10.50.2.153; P2=10.50.2.155; PRIO=100 ;;
  prod-homelab11) SELF=10.50.2.155; P1=10.50.2.153; P2=10.50.2.154; PRIO=100 ;;
  *) echo "ERROR: this script is only for prod-homelab09/10/11 (got '$THIS')"; exit 1 ;;
esac
echo "==== pgbouncer VIP setup on $THIS (self=$SELF priority=$PRIO) ===="
export DEBIAN_FRONTEND=noninteractive

[ -f /etc/apt/sources.list.d/homelab.list ] || {
  echo "ERROR: apt-homelab source missing — run pgbouncer-node-setup.sh first."; exit 1; }

echo "-- install homelab-keepalived --"
apt-get update
apt-get install -y --no-install-recommends homelab-keepalived

echo "-- write /etc/homelab/keepalived/vrrp.yml --"
install -d /etc/homelab/keepalived
cat > /etc/homelab/keepalived/vrrp.yml <<YML
# pgbouncer VIP — managed by pgbouncer-vip-setup.sh. Edit + 'homelab-keepalived-apply' to change.
enabled: true
instance: PGBOUNCER_VIP
router_id: $ROUTER_ID
state: BACKUP
priority: $PRIO
vrrp_interface: eth4
unicast_src: $SELF
peers:
  - $P1
  - $P2
auth_pass: $AUTH_PASS
vip: $VIP
vip_interface: eth4
track_services:
  - pgbouncer
track_weight: -60
YML

echo "-- apply (renders keepalived.conf + VRRP firewall, enables+starts keepalived) --"
homelab-keepalived-apply

echo
echo "==== $THIS verify ===="
echo -n "keepalived active: "; systemctl is-active keepalived 2>/dev/null || true
if ip -4 addr show eth4 2>/dev/null | grep -q "${VIP%/*}"; then
  echo "VIP ${VIP%/*}: HELD HERE (this node is master)"
else
  echo "VIP ${VIP%/*}: not here (standby — expected unless this is the highest-priority healthy node)"
fi
