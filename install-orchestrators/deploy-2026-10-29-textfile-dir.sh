#!/bin/bash
# ============================================================================
# homelab-node-exporter 0.4.1 -- fix the textfile collector directory.
#
# WHY. The agent health metrics added for post-cutover item 37 are published
# as node_exporter textfile *.prom files in /var/lib/prometheus/node-exporter,
# which must be group-writable by `homelab`. 0.4.0's postinst did:
#
#     chgrp homelab "$DIR" 2>/dev/null && chmod 0775 "$DIR" 2>/dev/null || true
#
# -- so where the chgrp did not take, the chmod was skipped as well and both
# were swallowed. On prod-homelab46 that left a root:root 0755 directory, and
# prod-homelab46 is the CERTIFICATE ISSUER: the one host whose silence actually
# cost something in the 2026-10-28 lockouts was the one host publishing no
# agent metrics. 0.4.1 separates the two calls, uses 2775 so group ownership is
# inherited, warns loudly if either fails, and prints the resulting mode.
#
# Restarts prometheus-node-exporter, NOT homelab-agent -- so this carries none
# of the mid-rotation risk the agent rollout did.
# ============================================================================
set -uo pipefail

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
step(){ echo; echo "=== $* ==="; }

ip_for(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
name_for(){ printf 'prod-homelab%02d' "$((10#$1))"; }
reachable(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

step "homelab-node-exporter 0.4.1 -- fleet-wide"
for n in $(seq 0 69); do
    nn=$(printf '%02d' "$n"); ip=$(ip_for "$nn")
    reachable "$ip" || { echo "  ${D}skip${O} $(name_for "$nn") not answering on :22"; continue; }
    ssh -o ConnectTimeout=6 "$ip" "dpkg -l homelab-node-exporter 2>/dev/null | grep -q '^ii'" \
        || { echo "  ${D}skip${O} $(name_for "$nn") has no homelab-node-exporter"; continue; }
    out=$(ssh -o ConnectTimeout=10 "$ip" \
        "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade homelab-node-exporter 2>&1 | grep -E 'textfile collector|WARNING'" 2>/dev/null)
    printf '  %-16s %s\n' "$(name_for "$nn")" "${out:-(no output)}"
done

step "every agent host now writing its metrics file?"
MISS=""
for n in $(seq 0 69); do
    nn=$(printf '%02d' "$n"); ip=$(ip_for "$nn")
    reachable "$ip" || continue
    ssh -o ConnectTimeout=6 "$ip" 'test -f /etc/homelab/agent/credential.yml' 2>/dev/null || continue
    if ssh -o ConnectTimeout=6 "$ip" 'test -s /var/lib/prometheus/node-exporter/homelab_agent.prom' 2>/dev/null; then :
    else MISS="$MISS $(name_for "$nn")"; fi
done
if [ -z "$MISS" ]; then ok "all agent hosts have a homelab_agent.prom"
else
    bad "no metrics file on:$MISS"
    echo "       (the agent writes it on its next heartbeat -- re-check in a minute;"
    echo "        if it stays missing, look at the directory's group and mode)"
fi

step "and prometheus can see them"
# The value array is ["<unix-time>","<count>"], so pull the LAST quoted field
# of it. An earlier version anchored on "$ -- which never matches, because the
# array closes with ]. It printed nothing and exited 1 on a successful run.
echo -n "  hosts reporting homelab_agent_up: "
ssh -o ConnectTimeout=8 10.20.2.213 'curl -s --data-urlencode "query=count(homelab_agent_up)" http://127.0.0.1:9090/api/v1/query' 2>/dev/null \
  | sed -n 's/.*"value":\[[^,]*,"\([0-9]*\)".*/\1/p'
echo
exit 0
