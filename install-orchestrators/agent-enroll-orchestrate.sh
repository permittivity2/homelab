#!/bin/bash
# ============================================================================
# agent enrollment orchestrator -- RUN ON THIS HOST (desktop).
# Installs + enrolls homelab-agent (and homelab-node-exporter) on the fleet
# nodes that are up: prod-homelab06..17. Each gets a one-time enrollment code
# minted on the DB primary (there's no site_admin user yet), preseeded into
# debconf, and redeemed by the agent postinst against the api VIP. Once a host
# has its agent credential, its services (e.g. the retrying workers) also
# self-register into api.service_registry, and the agent heartbeats into
# api.hosts (the fleet view). Driven over passwordless ssh+sudo. Idempotent.
# ============================================================================
set -euo pipefail
LOG="/tmp/agent-enroll-orchestrate.$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "[agent-enroll] logging all output to: $LOG"

# Node list: args override the default (e.g. `bash agent-enroll-orchestrate.sh 09 10 11`
# to re-provision just those), otherwise the full up-so-far fleet.
NODES="${*:-06 07 08 09 10 11 12 13 14 15 16 17}"
DB_NODES="06 07 08"
API_VIP=10.50.2.132

h(){ printf 'prod-homelab%s' "$1"; }
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
can_ssh(){ ssh -o BatchMode=yes -o ConnectTimeout=5 "$(h "$1")" true 2>/dev/null; }

KEYFILE="$(mktemp)"; trap 'rm -f "$KEYFILE"' EXIT
cat >"$KEYFILE" <<'KEOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
=6JWn
-----END PGP PUBLIC KEY BLOCK-----
KEOF

ensure_source(){ # $1 node -- idempotent
  scp -q "$KEYFILE" "$(h "$1"):/tmp/homelab.asc"
  ssh "$(h "$1")" 'sudo install -D -m0644 /tmp/homelab.asc /etc/apt/keyrings/homelab.asc
    echo "deb [signed-by=/etc/apt/keyrings/homelab.asc] http://projects.thedude.vip/apt-homelab unstable main" | sudo tee /etc/apt/sources.list.d/homelab.list >/dev/null
    sudo apt-get update -qq'
}

find_leader(){ local n r
  for n in $DB_NODES; do
    can_ssh "$n" || continue
    r="$(ssh "$(h "$n")" "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null" | tr -d '[:space:]')" || true
    [ "$r" = "f" ] && { printf '%s' "$n"; return 0; }
  done
  return 1
}

# Mint a one-time enrollment code on the DB primary for a hostname; echoes the code.
# Quiet on stdout except the code (caller captures it).
mint_code(){ # $1 hostname  $2 leader-node
  local code; code="$(openssl rand -hex 16)"
  printf "INSERT INTO api.agent_enrollment_codes (code,hostname,issued_by,expires_at) VALUES ('%s','%s','agent-enroll-orchestrator',NOW()+INTERVAL '2 hours') ON CONFLICT (code) DO NOTHING;" "$code" "$1" \
    | ssh "$(h "$2")" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" >/dev/null 2>&1
  printf '%s' "$code"
}

LEADER="$(find_leader)" || { echo "ERROR: no DB primary reachable among $DB_NODES"; exit 1; }
say "DB primary (mints enrollment codes) = $(h "$LEADER")"

for n in $NODES; do
  hn="prod-homelab$n"
  adv="10.50.2.$((144 + 10#$n))"      # 10# forces base-10 so 08/09 aren't read as octal
  say "agent enroll CT$n ($hn, advertise $adv)"
  ensure_source "$n"
  ssh "$(h "$n")" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-agent homelab-node-exporter"
  # Force a CLEAN re-provision. A pre-existing config/credential (e.g. a stale
  # one from the base image pointing at the wrong api_base, or a lapsed
  # refresh_token) makes the agent postinst's "exists -> leave untouched" skip
  # BOTH -- so wipe them, THEN dpkg-reconfigure writes fresh config (api VIP)
  # and enrolls with the freshly-minted code. Idempotent on already-correct nodes.
  ssh "$(h "$n")" "sudo systemctl stop homelab-agent 2>/dev/null || true
    sudo rm -f /etc/homelab/agent/config.yml /etc/homelab/agent/credential.yml"
  code="$(mint_code "$hn" "$LEADER")"
  ssh "$(h "$n")" "sudo debconf-set-selections" <<EOF
homelab-agent homelab-agent/api_base string http://$API_VIP:3000
homelab-agent homelab-agent/hostname string $hn
homelab-agent homelab-agent/advertise_host string $adv
homelab-agent homelab-agent/listen_port string 2520
homelab-agent homelab-agent/enrollment_code password $code
EOF
  ssh "$(h "$n")" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-agent"
  # non-fatal verify (a not-yet-active unit must never abort under set -e;
  # real exporter unit is prometheus-node-exporter -- homelab-node-exporter is config-only).
  ssh "$(h "$n")" "test -s /etc/homelab/agent/credential.yml && echo '  credential: present' || echo '  credential: MISSING'
    echo -n '  agent: '; systemctl is-active homelab-agent 2>/dev/null || true
    echo -n '  node-exporter: '; systemctl is-active prometheus-node-exporter 2>/dev/null || true
    echo -n '  api_base: '; sudo sed -n 's/^  base_url: //p' /etc/homelab/agent/config.yml 2>/dev/null | head -1" || true
done

say "waiting ~70s for agent heartbeats + worker re-registration..."
sleep 70

say "fleet view -- api.hosts"
ssh "$(h "$LEADER")" "sudo -u postgres psql -d homelab -P pager=off -c 'SELECT hostname, address, agent_version, last_heartbeat FROM api.hosts ORDER BY hostname'"
say "service registry -- api.service_registry (workers should appear)"
ssh "$(h "$LEADER")" "sudo -u postgres psql -d homelab -P pager=off -c 'SELECT feature_name, host, port, updated_at FROM api.service_registry ORDER BY feature_name, host'"

echo
echo "DONE. Expect 12 hosts heartbeating and homelab-worker registered (x3)."
