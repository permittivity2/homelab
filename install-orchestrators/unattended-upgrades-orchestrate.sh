#!/bin/bash
# ============================================================================
# Unattended SECURITY updates on the fleet's containers -- RUN ON THE ADMIN
# WORKSTATION (post-cutover #97, Phase 6).
#
#   ./unattended-upgrades-orchestrate.sh --dry-run        # who has it, who would get it
#   ./unattended-upgrades-orchestrate.sh                  # install it where it is missing
#   ./unattended-upgrades-orchestrate.sh --verify         # every node in the set runs it, as configured
#   ./unattended-upgrades-orchestrate.sh [--verify] 47 48 # just these nodes
#
# WHY. The 11 VMs have run Ubuntu's unattended-upgrades since they were built;
# the 62 containers never had it, so they got security fixes only when someone
# ran apt -- fleet-running-audit.sh found openssh-server at three versions.
# This installs the package with Ubuntu's stock configuration: the release and
# security pockets only (-updates stays for the deliberate sweep,
# fleet-os-upgrade.sh), no automatic reboot, no automatic autoremove. A daemon
# fixed by a security update restarts when the update lands (its own postinst);
# on a three-node pool that is seconds of one node.
#
# EXCLUDED by decision: the DB tier (06 07 08) and the internet edges (00 01 02),
# where every change stays deliberate. They are never in the default set and
# are refused if named.
# ============================================================================
set -uo pipefail

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
RC=0
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }
EXCLUDED=" 00 01 02 06 07 08 "

DRY=0; VERIFY=0; NODES=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY=1 ;;
        [0-9]|[0-9][0-9]) NODES+=("$(printf '%02d' "$((10#$a))")") ;;
        *) echo "unknown argument '$a' (usage: unattended-upgrades-orchestrate.sh [--dry-run|--verify] [NN ...])"; exit 1 ;;
    esac
done
if [ ${#NODES[@]} -eq 0 ]; then
    for n in $(seq 3 72); do nn=$(printf '%02d' "$n"); case "$EXCLUDED" in *" $nn "*) ;; *) NODES+=("$nn") ;; esac; done
else
    for nn in "${NODES[@]}"; do case "$EXCLUDED" in *" $nn "*) echo "prod-homelab$nn is excluded by decision (DB tier, internet edge)"; exit 1 ;; esac; done
fi

state(){ # NN -> "installed|auto-lists|auto-upgrade|reboot" from the node
    rssh "$(ip_of "$1")" 'printf "%s|%s|%s|%s\n" "$(dpkg-query -W -f="\${db:Status-Status}" unattended-upgrades 2>/dev/null)" "$(apt-config dump 2>/dev/null | sed -n "s/^APT::Periodic::Update-Package-Lists \"\(.*\)\";/\1/p")" "$(apt-config dump 2>/dev/null | sed -n "s/^APT::Periodic::Unattended-Upgrade \"\(.*\)\";/\1/p")" "$(apt-config dump 2>/dev/null | sed -n "s/^Unattended-Upgrade::Automatic-Reboot \"\(.*\)\";/\1/p")"'
}

step "$([ "$VERIFY" = 1 ] && echo verify || { [ "$DRY" = 1 ] && echo 'dry run' || echo install; }): ${#NODES[@]} node(s)"
TODO=()
for nn in "${NODES[@]}"; do
    ip=$(ip_of "$nn")
    timeout 5 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null || { warn "$nn does not answer on :22 -- skipped"; continue; }
    IFS='|' read -r inst lists upg reboot <<<"$(state "$nn")"
    if [ "$inst" = installed ] && [ "$lists" = 1 ] && [ "$upg" = 1 ] && [ "${reboot:-false}" = false ]; then
        if [ "$VERIFY" = 1 ]; then
            # the real test: the tool itself, in dry-run mode, must run clean (origins resolve, lists readable)
            if rssh "$ip" 'sudo unattended-upgrade --dry-run >/dev/null 2>&1'; then ok "$nn installed, lists and upgrades daily, no auto-reboot, dry run clean"
            else bad "$nn installed but 'unattended-upgrade --dry-run' fails -- look: ssh $ip 'sudo unattended-upgrade --dry-run -d | tail'"; fi
        else note "$nn already has it"; fi
    else
        if [ "$VERIFY" = 1 ]; then bad "$nn: unattended-upgrades is '${inst:-absent}', periodic lists='${lists:-}' upgrade='${upg:-}' auto-reboot='${reboot:-false}'"
        else TODO+=("$nn"); echo "  $nn: '${inst:-absent}' -> install"; fi
    fi
done
[ "$VERIFY" = 1 ] && { step result; [ "$RC" = 0 ] && echo "  ${G}every node in the set runs unattended security updates.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"; exit "$RC"; }
[ ${#TODO[@]} -eq 0 ] && { echo "  nothing to install"; exit 0; }
[ "$DRY" = 1 ] && { note "dry run: nothing changed"; exit 0; }

for nn in "${TODO[@]}"; do
    ip=$(ip_of "$nn")
    rssh "$ip" 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null 2>&1' </dev/null
    IFS='|' read -r inst lists upg reboot <<<"$(state "$nn")"
    if [ "$inst" = installed ] && [ "$lists" = 1 ] && [ "$upg" = 1 ]; then ok "$nn installed and enabled (lists and upgrades daily)"
    else bad "$nn after the install: status '${inst:-absent}', lists='${lists:-}', upgrade='${upg:-}'"; fi
done
step result
[ "$RC" = 0 ] && echo "  ${G}installed on ${#TODO[@]} node(s); run --verify for the dry-run check on each.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
exit "$RC"
