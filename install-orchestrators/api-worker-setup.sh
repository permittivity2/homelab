#!/bin/bash
# Control-plane bring-up — api (CT12/13/14) + worker (CT15/16/17).
# Run with: sudo bash api-worker-setup.sh   (same script on every node)
#
# WHY THIS ISN'T a plain same-script-per-node: homelab-bootstrap-app-role resets
# the DB role password on every run, and homelab-api generates its jwt secret per
# install -- so the 3 api nodes must SHARE one bootstrapped config, likewise the 3
# workers. Pattern: bootstrap ONCE on node 1 (CT12 api / CT15 worker), then CLONE
# node 1's /etc/homelab/<svc>/config.yml onto the other two BEFORE running this
# there (the postinst skips bootstrap when a config already exists).
#
# SEQUENCE (from your desktop):
#   1. sudo bash api-worker-setup.sh   on prod-homelab12   (api bootstrap)
#   2. sudo bash api-worker-setup.sh   on prod-homelab15   (worker bootstrap)
#   3. clone configs (see the commands I gave alongside this script):
#        CT12 /etc/homelab/api/config.yml    -> CT13, CT14
#        CT15 /etc/homelab/worker/config.yml -> CT16, CT17
#   4. sudo bash api-worker-setup.sh   on 13, 14, 16, 17   (install-only; skips bootstrap)
set -euo pipefail

DB_VIP=10.50.2.130        # Postgres VIP (direct, for migrate/bootstrap DDL)
PGB_VIP=10.50.2.131       # pgbouncer VIP (runtime)
API_VIP=10.50.2.132       # api VIP (worker -> api) -- set up right after (next script)
WORKER_BOOTSTRAP_IP=10.50.2.159   # CT15's eth4 (the IP baked into the worker config we clone)

[ "$(id -u)" -eq 0 ] || { echo "run as root:  sudo bash $0"; exit 1; }
THIS="$(hostname -s)"
case "$THIS" in
  prod-homelab12) TIER=api;    MODE=bootstrap ;;
  prod-homelab13|prod-homelab14) TIER=api; MODE=clone ;;
  prod-homelab15) TIER=worker; MODE=bootstrap; OWN_IP=10.50.2.159 ;;
  prod-homelab16) TIER=worker; MODE=clone;     OWN_IP=10.50.2.160 ;;
  prod-homelab17) TIER=worker; MODE=clone;     OWN_IP=10.50.2.161 ;;
  *) echo "ERROR: only for prod-homelab12-17 (got '$THIS')"; exit 1 ;;
esac
echo "==== $THIS : tier=$TIER mode=$MODE ===="
export DEBIAN_FRONTEND=noninteractive

echo "-- apt-homelab source + key --"
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

CFG="/etc/homelab/$TIER/config.yml"

if [ "$MODE" = clone ]; then
  [ -f "$CFG" ] || { echo "ERROR: $CFG not present — clone node-1's config here FIRST (see header sequence)"; exit 1; }
  # The service user must exist so the cloned config is readable the instant the
  # postinst (config-exists branch) starts the daemon -- the clone landed it as
  # root:root, and homelab-common/the package would otherwise create 'homelab'
  # only partway through this same install.
  adduser --system --group --home /var/lib/homelab --no-create-home --shell /usr/sbin/nologin homelab 2>/dev/null || true
  chown root:homelab "$CFG"; chmod 640 "$CFG"
  if [ "$TIER" = worker ]; then
    echo "-- fixing worker registry host -> $OWN_IP --"
    sed -i "s/${WORKER_BOOTSTRAP_IP//./\\.}/$OWN_IP/g" "$CFG"
  fi
  echo "-- install (config present → postinst skips bootstrap) --"
  apt-get install -y --no-install-recommends "homelab-$TIER"
  systemctl enable --now "homelab-$TIER" 2>/dev/null || true
else
  # bootstrap node
  if [ "$TIER" = api ]; then
    debconf-set-selections <<EOF
homelab-api homelab-api/db_host string $DB_VIP
homelab-api homelab-api/pgbouncer_host string $PGB_VIP
EOF
  else
    debconf-set-selections <<EOF
homelab-worker homelab-worker/db_host string $DB_VIP
homelab-worker homelab-worker/pgbouncer_host string $PGB_VIP
homelab-worker homelab-worker/api_base string http://$API_VIP:3000
homelab-worker homelab-worker/listen_port string 2512
homelab-worker homelab-worker/advertise_host string $OWN_IP
homelab-worker homelab-worker/storage_path string /var/lib/homelab/worker-storage
EOF
  fi
  echo "-- install (bootstrap roles + config + migrate) --"
  apt-get install -y --no-install-recommends "homelab-$TIER"
fi

echo
echo "==== $THIS verify ===="
SVC="homelab-$TIER"
echo -n "$SVC active: "; systemctl is-active "$SVC" 2>/dev/null || true
if [ "$TIER" = api ]; then
  echo -n "api /health: "; timeout 5 curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/health 2>/dev/null || echo "(no answer)"
else
  echo -n "worker :2512 listen: "; ss -ltn 2>/dev/null | grep -q ':2512' && echo yes || echo NO
fi
echo -n "DB reachable via pgbouncer VIP $PGB_VIP:6432: "; timeout 4 bash -c "echo > /dev/tcp/$PGB_VIP/6432" 2>/dev/null && echo yes || echo NO
