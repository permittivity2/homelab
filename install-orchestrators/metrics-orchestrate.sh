#!/bin/bash
# ============================================================================
# homelab metrics orchestrator -- RUN ON THIS HOST (desktop).
#
# Stands up the fleet's Prometheus + Grafana on ONE host. Written from the
# real 2026-10-28 build of prod-homelabvm69, including the parts that are not
# obvious from the packages:
#
#   * Both packages read a shell-sourced config file whose shipped DEFAULTS
#     point at the retired fleet (api 10.50.2.46, consumers/whitelist
#     10.50.2.61, and Grafana's URL at the *test* domain). Those files are
#     written BEFORE install here so the dead values are never used.
#   * homelab-prometheus-pull needs an ENROLLED homelab-agent credential to
#     ask homelab-api for scrape targets. Without it the target files stay
#     empty and Prometheus scrapes only itself.
#   * homelab-grafana Depends: grafana, which is NOT in the Ubuntu archive.
#     Grafana's own apt repo has to be added first.
#   * The TSDB path and retention are hardcoded in the package's systemd
#     drop-in, so putting the data on a big share needs a bind mount plus a
#     later-sorting drop-in -- not just a mount.
#   * PowerDNS only serves /metrics to IPs in webserver-allow-from, which is
#     maintained from /etc/homelab/dns/metrics-allow-from (default: the dead
#     10.50.2.63).
#
# Not idempotent in the destructive sense, but safe to re-run: every step
# either skips or rewrites declaratively.
#
#   bash metrics-orchestrate.sh 69            # node number (vm69 -> 10.20.2.213)
# ============================================================================
set -uo pipefail

NODE="${1:?usage: metrics-orchestrate.sh <node-number, e.g. 69>}"
MGMT="10.20.2.$((144 + 10#NODE))"
SVC="10.50.2.$((144 + 10#NODE))"
HOSTNAME_F="prod-homelabvm${NODE}"      # adjust if the node is a CT, not a VM

API_VIP="10.50.2.132"                   # homelab-api VIP
DB_LEADER="10.20.2.152"                 # any Patroni member; mints enrollment codes
ACCOUNTMANAGE="10.50.2.171,10.50.2.172,10.50.2.173"   # prod-homelab27/28/29
DNS_NODES="03 04 05"
PUBLIC_URL="https://myaccount.mailmasker.org/grafana/"

# Storage: the TSDB lives on an NFS share from the nas (14T quota), because
# a fleet node's local disk holds under two days of 400k-series data.
NAS_EXPORT="10.45.0.105:/slowvault/nfsexports/metrics"
SHARE_MNT="/srv/metrics"
TSDB_SRC="$SHARE_MNT/prometheus"
TSDB_DST="/var/lib/prometheus/metrics2"
RETENTION_TIME="1y"
RETENTION_SIZE="10TB"

say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
R(){ ssh -o ConnectTimeout=8 "$MGMT" "$@"; }

say "[1/8] deployment config (written BEFORE install -- defaults are dead addresses)"
R "sudo -n install -d -m 0755 /etc/homelab/prometheus /etc/homelab/grafana"
R "sudo -n tee /etc/homelab/prometheus/config >/dev/null" <<EOF
API_HOST="$API_VIP"
API_PORT="3000"
FLEET_CIDR="10.50.2.0/24"
METRICS_CONSUMERS="${ACCOUNTMANAGE//,/ }"
EOF
# NOTE: comma-separated, NOT space. The postinst drops this straight into a
# systemd Environment= line, and systemd splits on whitespace -- a space-
# separated list silently keeps only the FIRST address, so the other
# accountmanage nodes would be unable to authenticate against Grafana.
R "sudo -n tee /etc/homelab/grafana/config >/dev/null" <<EOF
PUBLIC_ROOT_URL="$PUBLIC_URL"
AUTH_PROXY_WHITELIST="$ACCOUNTMANAGE"
EOF

say "[2/8] NFS share for the TSDB"
R "sudo -n install -d -m 0755 $SHARE_MNT
   grep -q '$SHARE_MNT ' /etc/fstab || printf '%s\n' '$NAS_EXPORT  $SHARE_MNT  nfs4  rw,hard,noatime,_netdev  0 0' | sudo -n tee -a /etc/fstab >/dev/null
   mountpoint -q $SHARE_MNT || sudo -n mount $SHARE_MNT
   sudo -n install -d -m 0755 $TSDB_SRC $SHARE_MNT/grafana
   df -h $SHARE_MNT | tail -1"
# The export must already exist on the nas, pinned to THIS host:
#   zfs create slowvault/nfsexports/metrics
#   zfs set quota=14T compression=lz4 slowvault/nfsexports/metrics
#   zfs set sharenfs='rw=<SVC ip>,no_subtree_check,no_root_squash,sync' ...

say "[3/8] install homelab-prometheus (+ agent, node-exporter)"
R "sudo -n apt-get update -qq
   sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y homelab-prometheus homelab-node-exporter"

say "[4/8] enroll the agent -- REQUIRED for target discovery"
CODE="$(openssl rand -hex 16)"
ssh "$DB_LEADER" "sudo -u postgres psql -q -d homelab -v ON_ERROR_STOP=1 -c \
  \"INSERT INTO api.agent_enrollment_codes (code,hostname,issued_by,expires_at) \
    VALUES ('$CODE','$HOSTNAME_F','metrics-orchestrator',NOW()+INTERVAL '2 hours') \
    ON CONFLICT (code) DO NOTHING\""
R "sudo -n systemctl stop homelab-agent 2>/dev/null || true
   sudo -n rm -f /etc/homelab/agent/config.yml /etc/homelab/agent/credential.yml"
R "sudo -n debconf-set-selections" <<EOF
homelab-agent homelab-agent/api_base string http://$API_VIP:3000
homelab-agent homelab-agent/hostname string $HOSTNAME_F
homelab-agent homelab-agent/advertise_host string $SVC
homelab-agent homelab-agent/listen_port string 2520
homelab-agent homelab-agent/enrollment_code password $CODE
EOF
R "sudo -n DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-agent
   test -s /etc/homelab/agent/credential.yml && echo '  credential: present' || echo '  credential: MISSING'"

say "[5/8] move the TSDB onto the share + raise retention"
R "sudo -n systemctl stop prometheus
   sudo -n cp -a $TSDB_DST/. $TSDB_SRC/ 2>/dev/null || true
   sudo -n chown -R prometheus:prometheus $TSDB_SRC
   grep -q '$TSDB_DST' /etc/fstab || printf '%s\n' '$TSDB_SRC  $TSDB_DST  none  bind,_netdev  0 0' | sudo -n tee -a /etc/fstab >/dev/null
   mountpoint -q $TSDB_DST || sudo -n mount $TSDB_DST"
# Sorts AFTER the package's homelab.conf, so this ExecStart wins. The size cap
# makes Prometheus evict rather than hit the ZFS quota (which would turn into
# write errors). RequiresMountsFor stops it starting with the share absent and
# silently writing into the empty local dir under the bind mount.
R "sudo -n tee /etc/systemd/system/prometheus.service.d/zz-homelab-storage.conf >/dev/null" <<EOF
[Unit]
RequiresMountsFor=$TSDB_DST

[Service]
ExecStart=
ExecStart=/usr/bin/prometheus --config.file=/etc/prometheus/homelab/prometheus.yml --storage.tsdb.path=$TSDB_DST --storage.tsdb.retention.time=$RETENTION_TIME --storage.tsdb.retention.size=$RETENTION_SIZE --web.listen-address=0.0.0.0:9090 --web.enable-lifecycle
EOF
R "sudo -n systemctl daemon-reload && sudo -n systemctl start prometheus
   sudo -n systemctl start homelab-prometheus-pull.service
   echo -n '  node targets discovered: '; python3 -c 'import json;print(len(json.load(open(\"/etc/prometheus/homelab/targets/node.json\"))[0][\"targets\"]) if json.load(open(\"/etc/prometheus/homelab/targets/node.json\")) else 0)' 2>/dev/null || sudo -n grep -c targets /etc/prometheus/homelab/targets/node.json"

say "[6/8] let PowerDNS serve /metrics to this host"
for n in $DNS_NODES; do
  ssh "10.20.2.$((144 + 10#n))" "printf '%s\n' '$SVC' | sudo -n tee /etc/homelab/dns/metrics-allow-from >/dev/null
    sudo -n systemctl start homelab-dns-pull.service"
done

say "[7/8] Grafana's apt repo (not in the Ubuntu archive), then install"
R "timeout 30 curl -fsSL -o /tmp/grafana-gpg.key https://apt.grafana.com/gpg.key
   gpg --show-keys --with-fingerprint /tmp/grafana-gpg.key | sed -n 2p
   sudo -n install -d -m 0755 /etc/apt/keyrings
   sudo -n gpg --batch --yes --dearmor -o /etc/apt/keyrings/grafana.gpg /tmp/grafana-gpg.key
   sudo -n chmod 644 /etc/apt/keyrings/grafana.gpg; rm -f /tmp/grafana-gpg.key
   printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' | sudo -n tee /etc/apt/sources.list.d/grafana.list >/dev/null
   printf '%s\n' 'Acquire::https::apt.grafana.com::Proxy \"DIRECT\";' | sudo -n tee /etc/apt/apt.conf.d/99-grafana-direct >/dev/null
   sudo -n apt-get update -qq
   sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y homelab-grafana
   sudo -n systemctl enable --now grafana-server"

say "[8/8] replace Grafana's default admin password"
# grafana-cli is NOT usable for this: it defaults to paths.data
# /usr/share/grafana/data and will report success against a DIFFERENT sqlite
# file than the running server's /var/lib/grafana/grafana.db. Use the API.
R "PW=\$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
   printf '%s\n' \"\$PW\" | sudo -n tee /etc/homelab/grafana/admin-password >/dev/null
   sudo -n chmod 600 /etc/homelab/grafana/admin-password
   curl -s -o /dev/null -w '  password change: HTTP %{http_code}\n' --max-time 20 -u admin:admin -X PUT \
     -H 'Content-Type: application/json' \
     -d \"{\\\"oldPassword\\\":\\\"admin\\\",\\\"newPassword\\\":\\\"\$PW\\\",\\\"confirmNew\\\":\\\"\$PW\\\"}\" \
     http://127.0.0.1:3000/api/user/password
   echo -n '  default admin/admin now: '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 12 -u admin:admin http://127.0.0.1:3000/api/org"

say "finally: point accountmanage at this host"
echo "  On prod-homelab27/28/29, set in /etc/homelab/accountmanage/*.yml:"
echo "    prometheus.base_url: http://$SVC:9090"
echo "    grafana.base_url:    http://$SVC:3000"
echo "  then: systemctl restart homelab-accountmanage"
echo
echo "  Grafana is reached ONLY via $PUBLIC_URL (accountmanage's auth-gated"
echo "  /grafana proxy). There is no direct browser access and no ssh tunnel."
