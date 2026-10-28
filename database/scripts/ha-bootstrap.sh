#!/bin/bash
# homelab-database-ha-bootstrap -- stand up (or extend) a Patroni + etcd +
# keepalived PostgreSQL HA cluster on THIS node, the install-time-reproducible
# way. Run it on EACH cluster member (identical --members, differing
# --this-node) within the same window so the fresh etcd cluster can form.
#
# It codifies exactly the procedure proven on prod-homelab06/07/08:
#   etcd (3-node v3 DCS) -> Patroni (Debian pg_createcluster/pg_clonecluster)
#   -> keepalived VIP that follows the Patroni leader (REST /leader check).
#
# It does NOT restore data: a fresh HA cluster comes up empty; load data by the
# normal migration dump/restore against the leader (or the VIP) afterwards.
set -eu

SHARE=/usr/share/homelab-database/ha
[ -d "$SHARE" ] || SHARE="$(cd "$(dirname "$0")/../ha" && pwd)"   # run-from-source fallback

# ---- defaults -------------------------------------------------------------
MEMBERS=""; THIS_NODE="$(hostname -s)"; PGVER=""; CLUSTER="main"
REPLPW=""; APP_NETWORK="10.50.0.0/22"
VIP=""; VIP_MASK=""; VIP_IFACE=""
CLUSTER_TOKEN="homelab-pg"; NAMESPACE="/service/"; VRID="51"
WIPE_EXISTING="no"; ASSUME_YES="no"

usage(){ sed -n '2,12p' "$0"; cat <<'USAGE'

Usage: homelab-database-ha-bootstrap --members "n1:ip1,n2:ip2,n3:ip3" \
         --this-node <name> --replication-password <pw> [options]

Required:
  --members LIST            comma-separated name:ip for every cluster member
  --this-node NAME          this node's name (must appear in --members)
  --replication-password PW IDENTICAL on every member

Options:
  --pg-version N            PostgreSQL major (default: autodetect newest installed)
  --cluster NAME            Debian cluster name (default: main)
  --app-network CIDR        pg_hba network for app logins (default: 10.50.0.0/22)
  --vip IP                  VIP to float to the leader (enables keepalived)
  --vip-mask BITS           VIP prefix length (default: this node's prefix)
  --vip-iface IFACE         interface for the VIP (default: iface holding this node's ip)
  --cluster-token TOK       etcd initial-cluster token (default: homelab-pg)
  --namespace NS            Patroni namespace (default: /service/)
  --vrid N                  keepalived virtual_router_id (default: 51)
  --wipe-existing-cluster   drop a pre-existing PG cluster at the data dir (DESTRUCTIVE)
  --yes                     don't prompt
USAGE
}

while [ $# -gt 0 ]; do case "$1" in
  --members) MEMBERS="$2"; shift 2;;
  --this-node) THIS_NODE="$2"; shift 2;;
  --pg-version) PGVER="$2"; shift 2;;
  --cluster) CLUSTER="$2"; shift 2;;
  --replication-password) REPLPW="$2"; shift 2;;
  --app-network) APP_NETWORK="$2"; shift 2;;
  --vip) VIP="$2"; shift 2;;
  --vip-mask) VIP_MASK="$2"; shift 2;;
  --vip-iface) VIP_IFACE="$2"; shift 2;;
  --cluster-token) CLUSTER_TOKEN="$2"; shift 2;;
  --namespace) NAMESPACE="$2"; shift 2;;
  --vrid) VRID="$2"; shift 2;;
  --wipe-existing-cluster) WIPE_EXISTING="yes"; shift;;
  --rebootstrap-live-cluster) ALLOW_REBOOTSTRAP="yes"; shift;;
  --yes|-y) ASSUME_YES="yes"; shift;;
  -h|--help) usage; exit 0;;
  *) echo "unknown arg: $1" >&2; usage; exit 2;;
esac; done

die(){ echo "ERROR: $*" >&2; exit 1; }
[ -n "$MEMBERS" ] || { usage; die "--members required"; }
[ -n "$REPLPW" ] || die "--replication-password required"
[ "$(id -u)" = 0 ] || die "must run as root"

# ---- autodetect pg version ------------------------------------------------
if [ -z "$PGVER" ]; then
  PGVER="$(ls -1 /usr/lib/postgresql 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)"
  [ -n "$PGVER" ] || die "no PostgreSQL found under /usr/lib/postgresql; install postgresql-<ver> first"
fi
[ -x "/usr/lib/postgresql/$PGVER/bin/postgres" ] || die "postgresql-$PGVER server binaries missing"

# ---- derive this node's IP + per-member blocks ----------------------------
THIS_IP=""; INITIAL_CLUSTER=""; ETCD_HOSTS_YAML=""; REPL_HBA_HOSTS=""; UNICAST_PEERS=""
OLDIFS="$IFS"; IFS=','
for m in $MEMBERS; do
  nm="${m%%:*}"; ip="${m##*:}"
  [ -n "$nm" ] && [ -n "$ip" ] || die "bad --members entry: '$m' (want name:ip)"
  INITIAL_CLUSTER="${INITIAL_CLUSTER:+$INITIAL_CLUSTER,}$nm=http://$ip:2380"
  ETCD_HOSTS_YAML="$ETCD_HOSTS_YAML    - $ip:2379
"
  REPL_HBA_HOSTS="$REPL_HBA_HOSTS    - host    replication     replicator      $ip/32          scram-sha-256
"
  if [ "$nm" = "$THIS_NODE" ]; then THIS_IP="$ip"; else UNICAST_PEERS="$UNICAST_PEERS        $ip
"; fi
done
IFS="$OLDIFS"
[ -n "$THIS_IP" ] || die "--this-node '$THIS_NODE' not found in --members"

SCOPE="$PGVER-$CLUSTER"
# VIP iface/mask defaults from this node's address
if [ -n "$VIP" ]; then
  [ -n "$VIP_IFACE" ] || VIP_IFACE="$(ip -4 -o addr show | awk -v ip="$THIS_IP" '$4 ~ ip"/"{print $2; exit}')"
  [ -n "$VIP_MASK" ]  || VIP_MASK="$(ip -4 -o addr show | awk -v ip="$THIS_IP" '$4 ~ ip"/"{split($4,a,"/"); print a[2]; exit}')"
  [ -n "$VIP_IFACE" ] || die "could not detect VIP interface; pass --vip-iface"
fi

# ---- refuse to re-bootstrap a LIVE cluster -------------------------------
# This script is destructive by nature: further down it unconditionally does
# `rm -rf /var/lib/etcd/...` (the DCS holding cluster membership and the
# leader key) and, with --wipe-existing-cluster, `pg_dropcluster` on the data
# directory. Correct for a first bootstrap; catastrophic on a running one.
#
# It needs this guard because debian/homelab-database-ha.postinst calls it on
# EVERY `configure` -- which includes every routine upgrade -- and the three
# production nodes were found (2026-10-28) still carrying
# `wipe_existing: true` in debconf from their original greenfield install.
# A plain `apt upgrade homelab-database-ha` on a database node would
# therefore have wiped etcd and dropped the live PostgreSQL cluster. Nothing
# in the path warned, and nothing reset the flag after bootstrap succeeded.
if [ "$ALLOW_REBOOTSTRAP" != "yes" ] && systemctl is-active --quiet patroni 2>/dev/null; then
  echo "homelab-database-ha: patroni is already running on $THIS_NODE -- refusing to re-bootstrap."
  echo "  A bootstrap would destroy etcd's DCS state and (with --wipe-existing-cluster)"
  echo "  drop the PostgreSQL data directory. Nothing to do on a bootstrapped node."
  echo "  Check the cluster with: patronictl -c /etc/patroni/config.yml list"
  echo "  To rebuild deliberately, stop patroni first, or pass --rebootstrap-live-cluster."
  exit 0
fi

echo "homelab-database HA bootstrap on $THIS_NODE ($THIS_IP)"
echo "  scope=$SCOPE  members=[$INITIAL_CLUSTER]  vip=${VIP:-none}${VIP:+/$VIP_MASK on $VIP_IFACE}"

# ---- ensure packages ------------------------------------------------------
NEED="patroni etcd-server etcd-client python3-etcd python3-dnspython python3-systemd keepalived curl"
MISSING=""
for p in $NEED; do dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
if [ -n "$MISSING" ]; then
  echo "  installing missing packages:$MISSING"
  DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING \
    || die "could not install:$MISSING -- install them and re-run"
fi

render(){ # render <template> <dest>
  NODE="$THIS_NODE" IP="$THIS_IP" CLUSTER_TOKEN="$CLUSTER_TOKEN" INITIAL_CLUSTER="$INITIAL_CLUSTER" \
  SCOPE="$SCOPE" NAMESPACE="$NAMESPACE" PGVER="$PGVER" CLUSTER="$CLUSTER" REPLPW="$REPLPW" \
  APP_NETWORK="$APP_NETWORK" ETCD_HOSTS_YAML="$ETCD_HOSTS_YAML" REPL_HBA_HOSTS="$REPL_HBA_HOSTS" \
  IFACE="$VIP_IFACE" VRID="$VRID" UNICAST_PEERS="$UNICAST_PEERS" VIP="$VIP" VIPMASK="$VIP_MASK" \
  perl -pe 's/\@(\w+)\@/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$1" > "$2"
}

# ---- etcd -----------------------------------------------------------------
echo "  [etcd] configuring 3-node cluster member"
systemctl stop etcd 2>/dev/null || true
rm -rf /var/lib/etcd/default /var/lib/etcd/homelab
install -d -o etcd -g etcd -m 700 /var/lib/etcd/homelab
render "$SHARE/etcd.env.tmpl" /etc/default/etcd
# etcd is Type=notify: a fresh member of a 3-node cluster cannot signal READY
# until quorum (>=2 members) forms. The vendor unit's default start timeout plus
# a BLOCKING start means bootstrapping the FIRST member alone gets killed at the
# timeout, and its half-written data dir then makes every retry die with
# "member ... has already been bootstrapped". Same fix as patroni below: a
# generous start timeout so systemd doesn't kill it mid-wait, and --no-block so
# THIS run returns immediately and the operator can bring up the other members
# (quorum then forms across them, and all three reach READY together).
install -d /etc/systemd/system/etcd.service.d
printf '[Service]\nTimeoutStartSec=300\n' > /etc/systemd/system/etcd.service.d/override.conf
systemctl daemon-reload
systemctl reset-failed etcd 2>/dev/null || true
systemctl enable etcd >/dev/null 2>&1 || true
systemctl restart etcd --no-block
echo "  [etcd] starting (waits for the other members; cluster forms once >=2 are up)"
# An already-joined member MUST restart as state=existing, or etcd fatals with
# "member ... has already been bootstrapped" on the next start (reboot, crash,
# or a manual restart) -- found the hard way. The process just started read
# state=new for THIS initial bootstrap; flip the on-disk env so every later
# start rejoins the existing cluster instead. Only affects future starts, never
# the running process.
sed -i 's/^ETCD_INITIAL_CLUSTER_STATE=.*/ETCD_INITIAL_CLUSTER_STATE=existing/' /etc/default/etcd

# ---- postgresql handoff to Patroni ---------------------------------------
echo "  [pg] disabling Debian postgresql units (Patroni owns Postgres)"
systemctl disable --now "postgresql@$PGVER-$CLUSTER" postgresql 2>/dev/null || true
if [ -d "/var/lib/postgresql/$PGVER/$CLUSTER" ] && [ -f "/var/lib/postgresql/$PGVER/$CLUSTER/PG_VERSION" ]; then
  if [ "$WIPE_EXISTING" = "yes" ]; then
    echo "  [pg] dropping existing cluster $PGVER/$CLUSTER (--wipe-existing-cluster)"
    pg_dropcluster --stop "$PGVER" "$CLUSTER" || die "pg_dropcluster failed"
  else
    die "a PostgreSQL cluster already exists at /var/lib/postgresql/$PGVER/$CLUSTER.
     Patroni must create/clone the cluster itself. Re-run with --wipe-existing-cluster
     to drop it (DESTRUCTIVE -- dump first), or remove it by hand."
  fi
fi

# ---- patroni --------------------------------------------------------------
echo "  [patroni] writing /etc/patroni/config.yml"
install -d /etc/patroni
render "$SHARE/patroni.yml.tmpl" /etc/patroni/config.yml
chown root:postgres /etc/patroni/config.yml; chmod 640 /etc/patroni/config.yml
# The Debian patroni.service is Type=notify with TimeoutSec=30. patroni needs
# python3-systemd (a NEED dep above) to send the readiness notify at all; even
# with it, on a busy node reaching ready can exceed 30s. Without a generous
# start timeout systemd kills+restarts patroni in a loop that manifests as a
# relentless failover storm (learned the hard way). Give it headroom.
install -d /etc/systemd/system/patroni.service.d
printf '[Service]\nTimeoutStartSec=300\n' > /etc/systemd/system/patroni.service.d/override.conf
systemctl daemon-reload
systemctl reset-failed patroni 2>/dev/null || true
systemctl enable patroni >/dev/null 2>&1 || true
systemctl start patroni --no-block
echo "  [patroni] started (bootstraps leader / clones replica via the DCS)"

# ---- keepalived VIP -------------------------------------------------------
if [ -n "$VIP" ]; then
  echo "  [keepalived] writing /etc/keepalived/keepalived.conf (VIP $VIP)"
  install -d /etc/keepalived
  render "$SHARE/keepalived.conf.tmpl" /etc/keepalived/keepalived.conf
  systemctl enable keepalived >/dev/null 2>&1 || true
  systemctl restart keepalived
  echo "  [keepalived] started (VIP $VIP follows the Patroni leader)"
fi

echo
echo "Done on $THIS_NODE. Check the whole cluster with:"
echo "    patronictl -c /etc/patroni/config.yml list"
echo "Run this tool on the OTHER members too (same --members, their --this-node)."
