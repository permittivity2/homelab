#!/bin/bash
# ============================================================================
# homelab dns (PowerDNS) orchestrator -- RUN ON THIS HOST (desktop).
# Installs homelab-dns (PowerDNS gpgsql) on CT03/04/05 over passwordless ssh+sudo.
# Dedicated "powerdns" DB + "pdnsuser" role on the HA cluster (NOT the shared
# homelab DB, direct Postgres, no pgbouncer); all 3 role=master off one shared DB.
#
# The one thing that can't be automatic app-side (by design -- app hosts get
# NO admin reach into the DB): creating each feature's DB role on the Postgres
# primary and registering it in pgbouncer. This script does that FROM THE
# DESKTOP (the admin channel -- NOT app->DB ssh trust) IF the desktop can also
# reach the DB nodes (06/07/08) and pgbouncer nodes (09/10/11) passwordlessly.
# If it can't, it prints the exact commands and pauses for you to run them.
#
# Idempotent + fail-fast: safe to re-run. Watch the output.
# ============================================================================
set -euo pipefail

# --- logging: tee everything to a timestamped file for easy post-mortem ------
LOG="/tmp/dns-orchestrate.$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "[dns] logging all output to: $LOG"

DB_NODES="06 07 08"
PGB_NODES="09 10 11"
DB_VIP=10.50.2.130       # Postgres VIP (primary); role SQL + migrate target
PGB_VIP=10.50.2.131      # pgbouncer VIP; app runtime DB endpoint
API_VIP=10.50.2.132      # api VIP (worker -> api); set up by the next script

h(){ printf 'prod-homelab%s' "$1"; }
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
can_ssh(){ ssh -o BatchMode=yes -o ConnectTimeout=5 "$(h "$1")" true 2>/dev/null; }

# --- apt-homelab signing key, pushed to each node ---------------------------
KEYFILE="$(mktemp)"; trap 'rm -f "$KEYFILE"' EXIT
cat >"$KEYFILE" <<'KEOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=6JWn
-----END PGP PUBLIC KEY BLOCK-----
KEOF

add_source(){ # $1 node
  scp -q "$KEYFILE" "$(h "$1"):/tmp/homelab.asc"
  ssh "$(h "$1")" 'set -e
    sudo install -D -m0644 /tmp/homelab.asc /etc/apt/keyrings/homelab.asc
    echo "deb [signed-by=/etc/apt/keyrings/homelab.asc] http://projects.thedude.vip/apt-homelab unstable main" | sudo tee /etc/apt/sources.list.d/homelab.list >/dev/null
    sudo apt-get update -qq'
}

find_leader(){ # echoes DB node num that is the primary, or empty
  local n r
  for n in $DB_NODES; do
    can_ssh "$n" || continue
    r="$(ssh "$(h "$n")" "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null" | tr -d '[:space:]')" || true
    [ "$r" = "f" ] && { printf '%s' "$n"; return 0; }
  done
  return 1
}

# Create the feature's role on the DB primary + register it in pgbouncer.
# $1 feature (homelab_api)  $2 node holding the pending SQL (12/15)
poolers_reachable(){ local p; for p in $PGB_NODES; do can_ssh "$p" || return 1; done; return 0; }

finish_db_side(){
  local feat="$1" srcnode="$2" role="${1}_runtime"
  local sqlf scram leader pscript p

  if ! leader="$(find_leader)" || ! poolers_reachable; then
    manual_db_instructions "$feat" "$srcnode" "$role"; return 0
  fi

  say "$feat: applying role SQL on DB primary $(h "$leader")"
  sqlf="$(mktemp)"
  ssh "$(h "$srcnode")" "sudo cat /var/lib/homelab-database/pending/${feat}-bootstrap.sql" >"$sqlf"
  ssh "$(h "$leader")" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" <"$sqlf"

  say "$feat: reading $role SCRAM from $(h "$leader")"
  scram="$(printf "SELECT rolpassword FROM pg_authid WHERE rolname='%s'" "$role" \
            | ssh "$(h "$leader")" "sudo -u postgres psql -d homelab -tA" | tr -d '[:space:]')"
  [ -n "$scram" ] || { echo "ERROR: empty SCRAM for $role"; exit 1; }

  # SCRAM contains '$' and ':' but never a single-quote, so single-quoting it
  # in a pushed script keeps the pooler's shell from touching it.
  pscript="$(mktemp)"
  printf '#!/bin/bash\nhomelab-bootstrap-pgbouncer-entry --role %q --scram-secret '\''%s'\'' --pgbouncer-host localhost\n' "$role" "$scram" >"$pscript"
  for p in $PGB_NODES; do
    say "$feat: registering $role in pgbouncer on $(h "$p")"
    scp -q "$pscript" "$(h "$p"):/tmp/pgbreg.sh"
    ssh "$(h "$p")" "sudo bash /tmp/pgbreg.sh; rm -f /tmp/pgbreg.sh"
  done
  rm -f "$sqlf" "$pscript"
}

manual_db_instructions(){ # $1 feature $2 srcnode $3 role
  local feat="$1" srcnode="$2" role="$3"
  cat <<MSG

  !! Desktop can't reach the DB/pgbouncer nodes passwordlessly -- do these by
     hand, then press Enter:
       1. On the DB PRIMARY (holder of $DB_VIP):
            # get the SQL from $(h "$srcnode"):
            #   /var/lib/homelab-database/pending/${feat}-bootstrap.sql
            sudo -u postgres psql -d homelab -v ON_ERROR_STOP=1 -f <that-file>
            sudo -u postgres psql -d homelab -tAc \\
              "SELECT rolpassword FROM pg_authid WHERE rolname='$role'"
       2. On EACH pgbouncer node ($PGB_NODES):
            sudo homelab-bootstrap-pgbouncer-entry --role $role \\
              --scram-secret '<SCRAM from step 1>' --pgbouncer-host localhost
MSG
  read -r -p "  [Enter] once the DB + pgbouncer steps are done: " _ </dev/tty
}

install_bootstrap_node(){ # $1 node  $2 pkg  (debconf already preseeded by caller)
  add_source "$1"
  ssh "$(h "$1")" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $2"
}

# Clone node-1's config onto a pool member with the RIGHT ownership: the clone
# lands as root:root, but homelab-<svc>-migrate runs as 'homelab' and must read
# it, so create the service user and set root:homelab 640 before installing.
# $1 src-node  $2 dst-node  $3 tier(api|worker)
place_config(){
  ssh "$(h "$1")" "sudo cat /etc/homelab/$3/config.yml" \
    | ssh "$(h "$2")" "sudo install -D -m600 /dev/stdin /etc/homelab/$3/config.yml"
  ssh "$(h "$2")" "set -e
    sudo adduser --system --group --home /var/lib/homelab --no-create-home --shell /usr/sbin/nologin homelab 2>/dev/null || true
    sudo chown root:homelab /etc/homelab/$3/config.yml
    sudo chmod 640 /etc/homelab/$3/config.yml"
}

# Poll health rather than checking once -- hypnotoad takes a few seconds to bind.
verify_api(){ local n=$1 i code=""
  for i in $(seq 1 20); do
    code="$(ssh "$(h "$n")" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/health 2>/dev/null" || true)"
    [ "$code" = "200" ] && { echo "  CT$n api: active, health=200"; return 0; }
    sleep 1
  done
  echo "  CT$n api: health=${code:-none} NOT healthy after 20s -- ssh $(h "$n") 'journalctl -u homelab-api -n40'"
}
verify_worker(){ local n=$1 i
  for i in $(seq 1 20); do
    if ssh "$(h "$n")" "ss -ltn 2>/dev/null | grep -q ':2512'"; then echo "  CT$n worker: listening :2512"; return 0; fi
    sleep 1
  done
  echo "  CT$n worker: :2512 NOT listening after 20s -- ssh $(h "$n") 'journalctl -u homelab-worker -n40'"
}

# dns nodes 00-05 (edge/internet-facing) are NOT in name resolution like 06-61;
# the desktop reaches them by mgmt IP (Host 10.20.2.* in ~/.ssh/config).
dnsaddr(){ printf 'gardner@10.20.2.%d' "$((144 + 10#$1))"; }
SSHO="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8"
add_source_ip(){ # $1 ssh target
  scp -q $SSHO "$KEYFILE" "$1:/tmp/homelab.asc"
  ssh $SSHO "$1" 'set -e
    sudo install -D -m0644 /tmp/homelab.asc /etc/apt/keyrings/homelab.asc
    echo "deb [signed-by=/etc/apt/keyrings/homelab.asc] http://projects.thedude.vip/apt-homelab unstable main" | sudo tee /etc/apt/sources.list.d/homelab.list >/dev/null
    sudo apt-get update -qq'
}
verify_dns(){ local t=$1 i
  for i in $(seq 1 25); do
    if ssh $SSHO "$t" "ss -ulnp 2>/dev/null | grep -q ':53 '"; then echo "  $t pdns: listening :53"; return 0; fi
    sleep 1
  done
  echo "  $t pdns: :53 NOT listening after 25s -- ssh $t 'journalctl -u pdns -n40'"
}

############################# DNS TIER #############################
LEADER="$(find_leader)" || { echo "ERROR: no DB primary reachable among $DB_NODES"; exit 1; }
say "DB primary = $(h "$LEADER")"

# PowerDNS gets its OWN 'powerdns' DB + 'pdnsuser' role on the HA cluster (NOT the
# shared homelab DB, NOT bootstrap-app-role; PowerDNS connects DIRECT to Postgres,
# no pgbouncer). Create/reset from the desktop admin channel.
PDNS_DB_PW="$(openssl rand -base64 24 | tr -d '/+=')"
say "creating powerdns DB + pdnsuser role on $(h "$LEADER")"
ssh "$(h "$LEADER")" "sudo -u postgres psql -X -v ON_ERROR_STOP=1" <<SQL
DO \$\$ BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname='pdnsuser')
  THEN ALTER ROLE pdnsuser LOGIN PASSWORD '$PDNS_DB_PW';
  ELSE CREATE ROLE pdnsuser LOGIN PASSWORD '$PDNS_DB_PW';
  END IF;
END \$\$;
SQL
ssh "$(h "$LEADER")" "sudo -u postgres psql -X -tAc \"SELECT 1 FROM pg_database WHERE datname='powerdns'\" | grep -q 1 || sudo -u postgres createdb -O pdnsuser powerdns"
ssh "$(h "$LEADER")" "sudo -u postgres psql -d powerdns -X -c 'ALTER SCHEMA public OWNER TO pdnsuser; GRANT ALL ON SCHEMA public TO pdnsuser;'" >/dev/null
echo "  powerdns DB + pdnsuser ready"

API_KEY="$(ssh "$(h 21)" "sudo grep -A3 '^powerdns:' /etc/homelab/domain-admin/config.yml | sed -n 's/^  api_key: //p' | head -1" 2>/dev/null)"
[ -n "$API_KEY" ] || { echo "ERROR: could not read domain-admin's pdns api_key from CT21"; exit 1; }
echo "  reusing domain-admin's PowerDNS api_key (from CT21)"
API_ALLOW="10.50.2.165 10.50.2.166 10.50.2.167 10.50.2.63"

for n in 03 04 05; do
  T="$(dnsaddr "$n")"
  say "DNS node CT$n ($T) -- PowerDNS gpgsql -> shared powerdns DB, role=master"
  ssh $SSHO "$T" true 2>/dev/null || { echo "  ERROR: no ssh to $T"; exit 1; }
  add_source_ip "$T"
  ssh $SSHO "$T" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-svc-hosts" >/dev/null
  # Bind PowerDNS to this node's own 10.50 service-plane IP (NOT 0.0.0.0/loopback)
  # so it never collides with systemd-resolved's 127.0.0.53 stub listener -- no
  # need to disable the stub or repoint resolv.conf. The HTTP API binds this same
  # IP (first of local-address), reachable from domain-admin on 10.50; public DNS
  # serving is fronted by the edge tier later.
  LOCAL_IP="10.50.2.$((144 + 10#$n))"
  ssh $SSHO "$T" "sudo debconf-set-selections" <<EOF
homelab-dns homelab-dns/db_host string db.svc.homelab
homelab-dns homelab-dns/db_port string 5432
homelab-dns homelab-dns/db_name string powerdns
homelab-dns homelab-dns/db_user string pdnsuser
homelab-dns homelab-dns/db_password password $PDNS_DB_PW
homelab-dns homelab-dns/role select master
homelab-dns homelab-dns/disable_axfr boolean true
homelab-dns homelab-dns/local_address string $LOCAL_IP
homelab-dns homelab-dns/enable_api boolean true
homelab-dns homelab-dns/api_allow_from string $API_ALLOW
homelab-dns homelab-dns/api_key password $API_KEY
homelab-dns homelab-dns/api_base string http://api.svc.homelab:3000
homelab-dns homelab-dns/proxy_protocol_from string
EOF
  ssh $SSHO "$T" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-dns"
  # dpkg-reconfigure re-applies the (preseeded) debconf even when the pkg is
  # already installed -- so a re-run actually rewrites the config + restarts pdns.
  ssh $SSHO "$T" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-dns"
  verify_dns "$T"
done

say "verify: powerdns schema present + API reachable from a domain-admin node"
ssh "$(h "$LEADER")" "sudo -u postgres psql -d powerdns -X -tAc \"SELECT 'powerdns public tables: '||count(*) FROM information_schema.tables WHERE table_schema='public'\"" 2>&1 | sed 's/^/  /'
ssh "$(h 21)" "curl -sS -o /dev/null -w '  domain-admin(CT21) -> CT03 PowerDNS API /servers: %{http_code}\n' -H \"X-API-Key: $API_KEY\" http://10.50.2.147:8081/api/v1/servers" 2>&1 | sed 's/^/  /'

echo
echo "DONE. PowerDNS on 03/04/05 (:53; gpgsql -> shared powerdns DB; API :8081 gated by"
echo "allow-from + domain-admin's key). NEXT: point domain-admin's pdns_api_host at a dns"
echo "endpoint (dpkg-reconfigure) + agent-enroll 03/04/05. Public DNS + dnsdist = edge tier."
