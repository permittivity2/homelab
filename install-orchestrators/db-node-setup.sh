#!/bin/bash
# homelab DB-tier bring-up — run on EACH of prod-homelab06/07/08 (SAME script).
# Non-interactive (debconf is preseeded below).  Invoke with:  sudo bash db-node-setup.sh
#
# Run it on all THREE nodes within the same ~few-minute window: node 1 starts a
# 3-member etcd cluster and waits for the other two to join before a Patroni
# leader can be elected.
#
# PREREQUISITE: the 10.50 data plane must be open between 06/07/08 (etcd 2379/2380,
# Patroni REST 8008, Postgres 5432, VRRP). If the fleet base firewall is still
# policy-drop, the services install but the cluster never forms. See the message
# that came with this script.
set -euo pipefail

############## settings — IDENTICAL on all three nodes, do not edit per-node ##############
REPL_PW='viuJBp1hWqKuU5hY6suFYRVQeK7Z'
MEMBERS='prod-homelab06:10.50.2.150,prod-homelab07:10.50.2.151,prod-homelab08:10.50.2.152'
VIP='10.50.2.130'
APP_NET='10.50.0.0/22'
##########################################################################################

[ "$(id -u)" -eq 0 ] || { echo "run as root:  sudo bash $0"; exit 1; }
THIS="$(hostname -s)"
case "$THIS" in
  prod-homelab06|prod-homelab07|prod-homelab08) ;;
  *) echo "ERROR: this script is only for prod-homelab06/07/08 (got '$THIS')"; exit 1 ;;
esac
echo "==== homelab DB-tier bring-up on $THIS ===="
export DEBIAN_FRONTEND=noninteractive

echo "-- [1/3] apt-homelab source + signing key --"
install -d -m 0755 /etc/apt/keyrings
cat > /etc/apt/keyrings/homelab.asc <<'KEYEOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=6JWn
-----END PGP PUBLIC KEY BLOCK-----
KEYEOF
echo 'deb [signed-by=/etc/apt/keyrings/homelab.asc] http://projects.thedude.vip/apt-homelab unstable main' \
  > /etc/apt/sources.list.d/homelab.list
apt-get update

echo "-- [2/3] base PostgreSQL (homelab-database) --"
debconf-set-selections <<DBCONF
homelab-database homelab-database/listen_addresses string *
homelab-database homelab-database/allowed_networks string $APP_NET
homelab-database homelab-database/adopt_existing boolean true
homelab-database homelab-database/enable_backups boolean false
DBCONF
apt-get install -y --no-install-recommends homelab-database

echo "-- [3/3] HA layer (auto-bootstraps etcd + Patroni + keepalived VIP $VIP) --"
debconf-set-selections <<HACONF
homelab-database-ha homelab-database-ha/members string $MEMBERS
homelab-database-ha homelab-database-ha/this_node string $THIS
homelab-database-ha homelab-database-ha/vip string $VIP
homelab-database-ha homelab-database-ha/app_network string $APP_NET
homelab-database-ha homelab-database-ha/replication_password password $REPL_PW
homelab-database-ha homelab-database-ha/wipe_existing boolean true
HACONF
apt-get install -y --no-install-recommends homelab-database-ha

echo
echo "==== $THIS finished. ===="
echo "After ALL THREE are done, from any node check the cluster:"
echo "    sudo patronictl -c /etc/patroni/config.yml list"
echo "Expect 1 Leader + 2 Replica (running/streaming), VIP $VIP on the leader."
echo
echo "Then, on the LEADER NODE ONLY, create the shared (empty) homelab DB:"
echo "    sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-database"
