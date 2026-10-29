#!/bin/bash
# ============================================================================
# Roll out the fix for post-cutover item 37: homelab-agent locking itself out
# while rotating its own credential.
#
#   homelab-agent      0.1.9   fleet-wide  -- refresh near expiry, not every
#                                             60s, and export health metrics
#   homelab-api        0.1.63  12/13/14    -- atomic rotation + a grace window
#                                             that makes a lost response
#                                             recoverable (migration 020)
#   homelab-prometheus 0.7.1   vm69        -- alert rules on agent health
#
# ORDER IS DELIBERATE, and it is the one judgement call in this script.
#
# The agent goes FIRST. Until 0.1.9 every host rotated its credential 1440
# times a day; 0.1.9 makes that about once a day. Deploying it first shrinks
# the exposure of the API change that follows by three orders of magnitude --
# if anything were wrong with the new rotation path, it would meet ~51
# rotations a day instead of ~73,000.
#
# The cost of that order is that restarting an agent can itself interrupt a
# rotation, which is the very failure being fixed, and the API's safety net is
# not in place yet. That window is ~100ms of each 60s cycle and only one worker
# is ever in it, so across 51 hosts the expectation is well under one casualty
# -- and the repair is one command (agent-reenroll.sh --stale), which this
# script runs at the end regardless.
#
# The alternative order -- API first, so the net exists before any agent
# restarts -- exposes a brand-new rotation path to 73,000 rotations a day
# before anyone has looked at it. That is the worse bet, so: agent, then API,
# with the new rotation path exercised deliberately by api/t/sessions.t rather
# than by production traffic.
# ============================================================================
set -uo pipefail

# Two stages on purpose. Stage 1 puts the new API on ONE node of the three and
# stops, so the new rotation path can be exercised by api/t/sessions.t before
# the whole pool depends on it. --finish-api does the other two.
#   ./deploy-2026-10-29-refresh-fix.sh              # stage 1
#   ./deploy-2026-10-29-refresh-fix.sh --finish-api # stage 2
FINISH_API=0
[ "${1:-}" = "--finish-api" ] && FINISH_API=1

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }

ip_for(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
name_for(){ printf 'prod-homelab%02d' "$((10#$1))"; }
reachable(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }
ver(){ ssh -o ConnectTimeout=6 "$1" "dpkg-query -W -f='\${Version}' $2" 2>/dev/null; }

upgrade(){   # $1 node-number  $2 package
    local nn="$1" pkg="$2" ip; ip=$(ip_for "$nn")
    if ! reachable "$ip"; then echo "  ${D}skip${O} $(name_for "$nn") not answering on :22"; return 0; fi
    if ! ssh -o ConnectTimeout=6 "$ip" "dpkg -l $pkg 2>/dev/null | grep -q '^ii'"; then
        echo "  ${D}skip${O} $(name_for "$nn") does not have $pkg"; return 0
    fi
    ssh -o ConnectTimeout=10 "$ip" \
        "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade $pkg" \
        >/dev/null 2>&1
    echo "  $(name_for "$nn") $pkg $(ver "$ip" "$pkg")"
}

if [ "$FINISH_API" = 1 ]; then
    step "homelab-api 0.1.63 -- finishing the pool (prod-homelab13, 14)"
    # One at a time, checking in between: this is the fleet's control plane,
    # and two nodes down at once is an outage rather than a rolling upgrade.
    for n in 13 14; do
        upgrade "$n" homelab-api
        sleep 5
        if ssh "$(ip_for "$n")" 'systemctl is-active --quiet homelab-api'; then
            ok "$(name_for "$n") homelab-api active"
        else
            bad "$(name_for "$n") homelab-api NOT active -- STOPPING, fix this before the next node"
            exit 1
        fi
    done
    step "the pool, as deployed"
    for n in 12 13 14; do echo "  $(name_for "$n") homelab-api $(ver "$(ip_for "$n")" homelab-api)"; done
    echo
    echo "Pool complete."
    exit 0
fi

# ------------------------------------------------------------------ 1. agent
step "homelab-agent 0.1.9 -- fleet-wide"
echo "Refreshes inside a margin of real expiry (default 1h on a 24h token)"
echo "instead of every 60s, and writes health metrics so a wedged agent stops"
echo "being invisible."
for n in $(seq 0 69); do upgrade "$n" homelab-agent; done

step "agents are heartbeating, and now say so in metrics"
sleep 20
HB_OK=0; HB_BAD=""
for n in $(seq 0 69); do
    nn=$(printf '%02d' "$n"); ip=$(ip_for "$nn")
    reachable "$ip" || continue
    ssh -o ConnectTimeout=6 "$ip" 'test -f /etc/homelab/agent/credential.yml' 2>/dev/null || continue
    if ssh -o ConnectTimeout=6 "$ip" 'systemctl is-active --quiet homelab-agent' 2>/dev/null; then
        HB_OK=$((HB_OK+1))
    else
        HB_BAD="$HB_BAD $(name_for "$nn")"
    fi
done
ok "$HB_OK agent(s) active"
[ -n "$HB_BAD" ] && bad "not active:$HB_BAD"
echo "  metrics file on a sample host:"
ssh 10.20.2.175 'sudo head -3 /var/lib/prometheus/node-exporter/homelab_agent.prom 2>/dev/null || echo "    (not written yet -- give it one heartbeat interval)"' | sed 's/^/    /'

# -------------------------------------------------------------------- 2. api
step "homelab-api 0.1.63 -- prod-homelab12 FIRST, then verify, then the rest"
echo "Migration 020 adds refresh_tokens.successor_id/rotated_at. Idempotent"
echo "(ADD COLUMN IF NOT EXISTS), so it is harmless that all three nodes run it."
upgrade 12 homelab-api
sleep 5
for u in homelab-api; do
    ssh 10.20.2.156 "systemctl is-active --quiet $u" && ok "prod-homelab12 $u active" || bad "prod-homelab12 $u NOT active"
done
echo "  migration applied?"
ssh 10.20.2.152 "sudo -u postgres psql -d homelab -tAc \"SELECT count(*) FROM information_schema.columns WHERE table_schema='api' AND table_name='refresh_tokens' AND column_name IN ('successor_id','rotated_at')\"" \
  | tr -d ' ' | sed 's/^/    columns present: /'

step "exercise the new rotation path for real, before the other two nodes"
echo "api/t/sessions.t covers the grace window AND its four refusals (logout"
echo "stays final, a consumed successor is refused, outside the window is"
echo "refused, an unknown token is refused). It self-cleans its accounts."
if ssh 10.20.2.156 'test -r /etc/homelab/api/config.yml'; then
    echo "  run it from a checkout with:"
    echo "    cd ~/claude/general/github-repos/homelab/git/api"
    echo "    HOMELAB_API_CONFIG=<a copy of a node config> prove -I lib -I ../common/lib t/sessions.t"
fi

warn "prod-homelab13/14 are still on the old version -- the pool is MIXED."
warn "That is safe (the change is additive, and the migration is already"
warn "applied cluster-wide), but finish it once you have run sessions.t:"
warn "    $0 --finish-api"

# ------------------------------------------------------------- 3. prometheus
step "homelab-prometheus 0.7.1 -- prod-homelabvm69 (alert rules)"
upgrade 69 homelab-prometheus
sleep 5
ssh 10.20.2.213 'systemctl is-active --quiet prometheus' && ok "prometheus active" || bad "prometheus NOT active"
echo "  rules loaded:"
ssh 10.20.2.213 'curl -s http://127.0.0.1:9090/api/v1/rules | grep -o "HomelabAgent[A-Za-z]*" | sort -u' 2>/dev/null | sed 's/^/    /'

# ------------------------------------------------------------------ 4. sweep
step "any agent casualties from the restarts?"
echo "A restart can land mid-rotation, which is the failure being fixed -- so"
echo "this checks for it rather than assuming. Repairs anything it finds."
"$(dirname "$0")/agent-reenroll.sh" --stale

echo
echo "Done. What changed, in one line each:"
echo "  * an interrupted rotation is now recoverable instead of terminal"
echo "  * rotations dropped from ~1440/host/day to ~1"
echo "  * a wedged agent is visible within 10 minutes instead of 4 days"
