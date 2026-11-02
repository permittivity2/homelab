#!/bin/bash
# ============================================================================
# Reconcile the PARKED edge nodes' declarative config against the live one.
#
#   ./edge-standby-sync.sh --dry-run     # say what differs and what it would add
#   ./edge-standby-sync.sh               # add the missing entries
#   ./edge-standby-sync.sh --verify      # report drift only, change nothing
#
# WHY THIS EXISTS, which is a structural problem and not a one-off.
#
# Exactly one of prod-homelab00/01/02 is ever powered on. Every orchestrator
# that adds a public vhost therefore finds THE ONE RUNNING EDGE and provisions
# that node -- search-vhost-provision.sh:151 is the pattern. It cannot do
# anything else: the other two are off.
#
# So every vhost added while a node is parked silently diverges, and the
# divergence is invisible until a failover, which is the one moment it cannot
# be fixed calmly. Found for real: search.mailmasker.org was provisioned onto
# the live edge on 2026-10-31 while 01 and 02 were parked, and neither had the
# site OR the certificate lineage. A failover would have served nothing at all
# for that hostname -- not a stale cert, no vhost.
#
# The fix is to write the DECLARATIVE inputs into the parked nodes' filesystems
# directly through the hypervisor, which is safe because:
#
#   * the containers' ZFS datasets stay mounted while stopped, so this needs no
#     boot and causes no outage;
#   * sites.yml and certsync.yml are INPUTS, not generated nginx config. On the
#     next boot, certsync fetches the lineage and apply-sites generates the
#     vhost from them;
#   * and the ordering cannot break nginx. apply-sites writes an HTTP-ONLY
#     vhost when a certificate is absent and retries on the next run rather
#     than skipping forever (webproxy/t/apply-sites.t:89,100). The worst case
#     is a hostname served over plain HTTP for one boot, never an nginx that
#     refuses to start -- which is what writing a 443 block referencing a
#     missing cert would have caused.
#
# What this deliberately does NOT do: generate nginx config, touch anything
# host-specific (addresses, agent identity, interface files), or remove
# entries. Only additions, so a hand-made local change on a parked node is
# never silently reverted.
# ============================================================================
set -uo pipefail

PVE=10.20.1.8
EDGES="00 10.20.2.144 01 10.20.2.145 02 10.20.2.146"
DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run|--verify) DRY=1 ;;
        *) echo "unknown argument '$a' (usage: edge-standby-sync.sh [--dry-run|--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
pve(){ ssh -o ConnectTimeout=10 "$PVE" "$@"; }

FAILS=0

step "find the live edge"
RUNNING=""; LIVE_IP=""; LIVE_N=""
set -- $EDGES
while [ $# -gt 0 ]; do
    n=$1; ip=$2; shift 2
    st=$(pve "sudo pct status $((400 + 10#$n))" 2>/dev/null | awk '{print $2}')
    [ "$st" = "running" ] && { RUNNING="$RUNNING $n"; LIVE_N=$n; LIVE_IP=$ip; }
done
case "$(echo $RUNNING | wc -w)" in
    0) bad "no edge node is running -- nothing to use as the reference"; exit 1 ;;
    1) ok "live edge is prod-homelab$LIVE_N ($LIVE_IP)" ;;
    *) bad "more than one edge is running ($RUNNING) -- that is a public address conflict"; exit 1 ;;
esac

# The reference, read from the node that is actually serving.
SITES_REF=$(ssh -o ConnectTimeout=10 "$LIVE_IP" "sudo grep -E '^[[:space:]]+- domain:' /etc/homelab/webproxy/sites.yml | awk '{print \$3}'" 2>/dev/null | sort)
CERT_REF=$(ssh  -o ConnectTimeout=10 "$LIVE_IP" "sudo grep -E '^[[:space:]]+- lineage:' /etc/homelab/certsync/certsync.yml | awk '{print \$3}'" 2>/dev/null | sort)
[ -z "$SITES_REF" ] && { bad "could not read sites.yml from the live edge"; exit 1; }
ok "reference: $(echo "$SITES_REF" | wc -l) site(s), $(echo "$CERT_REF" | wc -l) certificate lineage(s)"

for n in 00 01 02; do
    [ "$n" = "$LIVE_N" ] && continue
    CT=$((400 + 10#$n))
    step "prod-homelab$n (pct $CT, parked)"

    ROOT=$(pve "sudo zfs list -H -o mountpoint 2>/dev/null | grep -E '/subvol-$CT-disk-0$'" 2>/dev/null | head -1)
    if [ -z "$ROOT" ] || ! pve "sudo test -d '$ROOT/etc'" 2>/dev/null; then
        bad "cannot reach pct $CT's filesystem (dataset not mounted?) -- skipping"
        FAILS=$((FAILS + 1)); continue
    fi
    ok "filesystem at $ROOT ${D}(mounted while stopped -- no boot needed)${O}"

    SY="$ROOT/etc/homelab/webproxy/sites.yml"
    CY="$ROOT/etc/homelab/certsync/certsync.yml"

    HAVE_S=$(pve "sudo grep -E '^[[:space:]]+- domain:' '$SY' | awk '{print \$3}'" 2>/dev/null | sort)
    HAVE_C=$(pve "sudo grep -E '^[[:space:]]+- lineage:' '$CY' | awk '{print \$3}'" 2>/dev/null | sort)
    MISS_S=$(comm -23 <(printf '%s\n' "$SITES_REF") <(printf '%s\n' "$HAVE_S"))
    MISS_C=$(comm -23 <(printf '%s\n' "$CERT_REF")  <(printf '%s\n' "$HAVE_C"))

    if [ -z "$MISS_S" ] && [ -z "$MISS_C" ]; then
        ok "already matches the live edge -- nothing to add"
        continue
    fi

    [ -n "$MISS_S" ] && { warn "sites missing here:";    printf '%s\n' "$MISS_S" | sed 's/^/      /'; }
    [ -n "$MISS_C" ] && { warn "lineages missing here:"; printf '%s\n' "$MISS_C" | sed 's/^/      /'; }

    if [ "$DRY" = 1 ]; then
        echo "  ${D}would append the above (and nothing else) to sites.yml / certsync.yml${O}"
        continue
    fi

    # Back up once per run, so a mistake is one `cp` away from undone.
    STAMP=$(date +%Y%m%d-%H%M%S)
    pve "sudo cp -a '$SY' '$SY.pre-sync-$STAMP'; sudo cp -a '$CY' '$CY.pre-sync-$STAMP'" 2>/dev/null \
        && ok "backed up both files (.pre-sync-$STAMP)" || { bad "could not back up -- refusing to edit"; FAILS=$((FAILS+1)); continue; }

    # Copy each missing site's WHOLE stanza from the live edge, rather than
    # reconstructing it: the upstream list, max_body_size and websocket flag
    # are part of the entry and guessing them is how a vhost ends up subtly
    # different from the one that has been serving.
    for d in $MISS_S; do
        STANZA=$(ssh -o ConnectTimeout=10 "$LIVE_IP" "sudo awk '/^[[:space:]]+- domain: $d\$/{f=1;print;next} f&&/^[[:space:]]+- domain:/{exit} f&&/^[[:space:]]+[a-z_]+:/{print;next} f{exit}' /etc/homelab/webproxy/sites.yml" 2>/dev/null)
        if [ -z "$STANZA" ]; then bad "could not read the live stanza for $d"; FAILS=$((FAILS+1)); continue; fi
        printf '%s\n' "$STANZA" | pve "sudo tee -a '$SY' >/dev/null" 2>/dev/null \
            && ok "added site $d" || { bad "failed to add site $d"; FAILS=$((FAILS+1)); }
    done

    for l in $MISS_C; do
        printf '  - lineage: %s\n    mode: letsencrypt\n    reload: nginx\n' "$l" \
            | pve "sudo tee -a '$CY' >/dev/null" 2>/dev/null \
            && ok "added lineage $l" || { bad "failed to add lineage $l"; FAILS=$((FAILS+1)); }
    done

    # Re-read and confirm, because "tee succeeded" and "the file now parses
    # with the entry in it" are different claims.
    NOW_S=$(pve "sudo grep -E '^[[:space:]]+- domain:' '$SY' | awk '{print \$3}'" 2>/dev/null | sort)
    NOW_C=$(pve "sudo grep -E '^[[:space:]]+- lineage:' '$CY' | awk '{print \$3}'" 2>/dev/null | sort)
    LEFT_S=$(comm -23 <(printf '%s\n' "$SITES_REF") <(printf '%s\n' "$NOW_S"))
    LEFT_C=$(comm -23 <(printf '%s\n' "$CERT_REF")  <(printf '%s\n' "$NOW_C"))
    if [ -z "$LEFT_S" ] && [ -z "$LEFT_C" ]; then
        ok "verified: now matches the live edge ($(printf '%s\n' "$NOW_S" | wc -l) sites, $(printf '%s\n' "$NOW_C" | wc -l) lineages)"
    else
        bad "still missing after the edit:"; printf '%s\n%s\n' "$LEFT_S" "$LEFT_C" | grep . | sed 's/^/      /'
        FAILS=$((FAILS + 1))
    fi
    DUP=$(printf '%s\n' "$NOW_S" | uniq -d)
    [ -n "$DUP" ] && { bad "duplicate site entries introduced: $DUP"; FAILS=$((FAILS+1)); }
done

step "result"
if [ "$FAILS" = 0 ]; then
    echo "  ${G}the parked edge nodes carry the same sites and lineages as the live one.${O}"
    echo "  ${D}The vhost and its certificate materialise on that node's next boot:"
    echo "   certsync installs the lineage, apply-sites generates the vhost. Prove it"
    echo "   by rotating to the node (edge-rotate.sh 01) and checking the hostname"
    echo "   from offsite -- a config match is not the same as a served page.${O}"
else
    echo "  ${R}$FAILS problem(s) -- see above.${O}"
fi
exit "$FAILS"
