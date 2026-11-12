#!/bin/bash
# ============================================================================
# Upgrade ONE package to the version the fleet repo publishes, on the given
# nodes, one node at a time, checking each -- RUN ON THE ADMIN WORKSTATION.
#
#   ./pkg-upgrade.sh PACKAGE NN [NN ...]            # e.g. homelab-keepalived 09 10 11 12 13 14
#   ./pkg-upgrade.sh --dry-run PACKAGE NN [NN ...]  # what each node has and would get; changes nothing
#
# WHY. fleet-version-audit.sh says which nodes are behind the published
# versions, and nothing generic brought one package forward: every tier has
# its own orchestrator, and each does far more than an upgrade (edge-rotate
# upgrades every homelab-* package on an edge; the VIP scripts rewrite the
# VRRP configuration). This does only the one upgrade (apt-get --only-upgrade,
# the node's conffiles kept), then checks the version, that every unit of the
# package that was active still is, and that the node's addresses are exactly
# what they were -- so a VIP that moved shows up here, not later.
#
# ORDER. A node holding a floating address (anything beyond its own
# 10.20.2.x / 10.50.2.x pair) goes LAST: VIP backups before the master, the
# HA rule in post-cutover/README.md. Stops at the first node whose check fails.
# ============================================================================
set -uo pipefail

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }

USAGE="usage: pkg-upgrade.sh [--dry-run] PACKAGE NN [NN ...]   |   pkg-upgrade.sh [--dry-run] PACKAGE --all"
DRY=0; ALL=0; PKG=""; NODES=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --all) ALL=1 ;;
        [0-9]|[0-9][0-9]) NODES+=("$(printf '%02d' "$((10#$a))")") ;;
        -*) echo "unknown option '$a' ($USAGE)"; exit 1 ;;
        *) [ -z "$PKG" ] && PKG="$a" || { echo "one package at a time (got '$PKG' and '$a')"; exit 1; } ;;
    esac
done
[ -n "$PKG" ] || { echo "$USAGE"; exit 1; }

ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
svc_of(){ printf '10.50.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }

# --all: every reachable fleet node (00-72) that has the package installed.
# Nobody should be typing 56 node numbers by hand (homelab-node-exporter is on
# every monitored node); spares and powered-off nodes drop out of the scan.
if [ "$ALL" = 1 ]; then
    [ ${#NODES[@]} -eq 0 ] || { echo "--all and explicit node numbers are exclusive"; exit 1; }
    step "scanning nodes 00-72 for $PKG"
    for i in $(seq 0 72); do
        n=$(printf '%02d' "$i"); ip=$(ip_of "$n")
        timeout 3 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null || continue
        st=$(rssh "$ip" "dpkg-query -W -f='\${Status}' $PKG 2>/dev/null")
        case "$st" in *"install ok installed"*) NODES+=("$n") ;; esac
    done
    [ ${#NODES[@]} -gt 0 ] || { echo "  $PKG is installed on no reachable node"; exit 1; }
    echo "  ${#NODES[@]} node(s): ${NODES[*]}"
fi
[ ${#NODES[@]} -gt 0 ] || { echo "$USAGE"; exit 1; }

# this node's global IPv4 addresses, one per line, sorted
addrs(){ rssh "$(ip_of "$1")" 'ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1 | sort'; }
# a service-plane address (10.50.2.0/22, where every fleet VIP lives: .130 DB,
# .131 pgbouncer, .132 api, .140 edge mail) that is not the node's own
floating(){ local n=$1; addrs "$n" | grep -E '^10\.50\.[0-3]\.' | grep -vx "$(svc_of "$n")" || true; }
# installed and candidate versions after an apt-get update
apt_state(){ rssh "$(ip_of "$1")" "sudo apt-get update -qq >/dev/null 2>&1; apt-cache policy $PKG 2>/dev/null | awk '/^  Installed:/ {i=\$2} /^  Candidate:/ {c=\$2} END {print i, c}'"; }
# the package's systemd units that are active right now
active_units(){ rssh "$(ip_of "$1")" "for u in \$(dpkg -L $PKG 2>/dev/null | grep -E '^/(usr/)?lib/systemd/system/[^/]+\.(service|timer)\$' | xargs -rn1 basename); do systemctl is-active --quiet \"\$u\" 2>/dev/null && echo \"\$u\"; done"; }

step "order: nodes without a floating address first, holders last ($PKG)"
HOLD=(); PLAIN=()
for n in "${NODES[@]}"; do
    f=$(floating "$n")
    if [ -n "$f" ]; then HOLD+=("$n"); echo "  prod-homelab$n holds $(echo "$f" | paste -sd' ' -)"; else PLAIN+=("$n"); echo "  prod-homelab$n"; fi
done
ORDER=("${PLAIN[@]}" "${HOLD[@]}")

FAILS=0; DONE=0; SKIP=0
for n in "${ORDER[@]}"; do
    ip=$(ip_of "$n")
    step "prod-homelab$n ($ip)"
    read -r INST CAND <<<"$(apt_state "$n")"
    if [ -z "${INST:-}" ] || [ "$INST" = "(none)" ]; then warn "$PKG is not installed here -- skipped"; SKIP=$((SKIP+1)); continue; fi
    if [ -z "${CAND:-}" ] || [ "$CAND" = "(none)" ]; then bad "apt offers no candidate for $PKG here (is the fleet repo source present?)"; FAILS=$((FAILS+1)); break; fi
    if [ "$INST" = "$CAND" ]; then ok "already $INST (the published version)"; SKIP=$((SKIP+1)); continue; fi
    echo "  installed $INST, published $CAND"
    if [ "$DRY" = 1 ]; then echo "  ${D}dry run: would upgrade${O}"; continue; fi

    BEFORE_A=$(addrs "$n"); BEFORE_U=$(active_units "$n")
    echo "  ${D}active units before: $(echo "$BEFORE_U" | paste -sd' ' -)${O}"
    OUT=$(rssh "$ip" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade -o Dpkg::Options::=--force-confold $PKG 2>&1")
    RC=$?
    printf '%s\n' "$OUT" | grep -vE '^\s*$|^\(Reading database|^Preparing|^Unpacking|^Selecting|^Setting up' | sed 's/^/    /'
    NOW=$(rssh "$ip" "dpkg-query -W -f='\${Version}' $PKG 2>/dev/null")
    if [ $RC -ne 0 ]; then
        # apt-get itself can die after dpkg has finished: the OOM killer in a
        # 512 MB container takes the biggest process, and that is apt-get
        # (seen on prod-homelab00, 2026-11-12, exit 137). If the package is
        # at the published version and dpkg has nothing half-done, the
        # upgrade happened; say so and carry on with the checks below.
        if [ "$NOW" = "$CAND" ] && [ -z "$(rssh "$ip" 'sudo dpkg --audit 2>/dev/null')" ]; then
            warn "apt-get exited $RC (SIGKILL = 137: the OOM killer in a small container?) but $PKG $NOW is installed and dpkg is clean"
        else
            bad "apt-get exited $RC"; FAILS=$((FAILS+1)); break
        fi
    fi
    [ "$NOW" = "$CAND" ] && ok "now $NOW" || { bad "version is '$NOW' after the upgrade, wanted $CAND"; FAILS=$((FAILS+1)); break; }

    sleep 3    # units restarted by the postinst settle
    AFTER_U=$(active_units "$n")
    LOST=$(comm -23 <(printf '%s\n' "$BEFORE_U" | sort) <(printf '%s\n' "$AFTER_U" | sort) | grep -E '.' || true)
    [ -z "$LOST" ] && ok "every unit that was active still is" || { bad "unit(s) no longer active: $(echo "$LOST" | paste -sd' ' -)"; FAILS=$((FAILS+1)); break; }

    AFTER_A=$(addrs "$n")
    if [ "$BEFORE_A" = "$AFTER_A" ]; then ok "addresses unchanged ($(echo "$AFTER_A" | paste -sd' ' -))"
    else bad "addresses changed:"; diff <(printf '%s\n' "$BEFORE_A") <(printf '%s\n' "$AFTER_A") | sed 's/^/      /'; FAILS=$((FAILS+1)); break; fi
    DONE=$((DONE+1))
done

echo
if [ "$FAILS" = 0 ]; then echo "${G}done${O}: $DONE upgraded, $SKIP already current or absent"; exit 0
else echo "${R}stopped${O} after a failure: $DONE upgraded, $SKIP skipped, $FAILS failed"; exit 1; fi
