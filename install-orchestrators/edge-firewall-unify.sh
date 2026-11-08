#!/bin/bash
# ============================================================================
# The edge trio's firewall files, identical (post-cutover loose ends, A3).
#
#   ./edge-firewall-unify.sh --verify        # read-only: every firewall file on 00/01/02, side by side
#   ./edge-firewall-unify.sh [NN ...]        # make the drop-ins canonical on the given edges (default: all three)
#
# WHY. 01 and 02 were provisioned by edge-standby-provision.sh, which wrote
# /etc/nftables.d/20-edge-public.nft: an accept for the mail ports (needed
# while their base file still opened only 22/80/443/53) plus the plex egress
# rule, both with comments. 00 had the mail ports in its base file and the
# plex rule alone, uncommented, in 60-plex-egress.nft. Since 2026-11-02 the
# base file /etc/nftables.conf is byte-identical on all three (mail ports in,
# SSH out), so 20-edge-public.nft only duplicated a rule, and every rotation
# listed the two layouts as drift. The canonical layout is 00's: the base file
# plus files/edge-60-plex-egress.nft as /etc/nftables.d/60-plex-egress.nft,
# and no 20-edge-public.nft.
#
# HOW IT CHANGES A LIVE EDGE. It never runs `nft -f /etc/nftables.conf`: that
# file starts with `flush ruleset`, which empties bad-ips' table until the
# daemon's next reconcile. The files on disk are swapped and checked with
# `nft -c -f` (parse only), and the kernel is brought to the same state in ONE
# nft transaction: add the plain plex rule, delete the two commented rules by
# handle. Established connections are never touched, and the mail-in rule is
# deleted only after the base file's own mail accept is seen in the live chain.
# Safe to re-run: a node already canonical changes nothing.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CANON="$HERE/files/edge-60-plex-egress.nft"
[ -s "$CANON" ] || { echo "missing $CANON"; exit 1; }
CANON_SHA=$(sha256sum "$CANON" | awk '{print $1}')

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
FAILS=0

VERIFY=0; TARGETS=()
for a in "$@"; do
    case "$a" in
        --verify) VERIFY=1 ;;
        00|01|02|0|1|2) TARGETS+=("$(printf '%02d' "$((10#$a))")") ;;
        *) echo "unknown argument '$a' (usage: edge-firewall-unify.sh [--verify] [00|01|02 ...])"; exit 1 ;;
    esac
done
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(00 01 02)

# Every firewall file a node has, as "path sha256", one node per column.
# 15-homelab-vrrp.nft is written by homelab-keepalived with the peer set in
# per-node order (peers, then self) up to 0.1.4, so it differs in order only;
# 0.1.5 sorts it. Anything else differing is drift to look at.
verify(){
    step "firewall files on the three edges (sha256; - = absent)"
    local n ip tmp; tmp=$(mktemp -d)
    for n in 00 01 02; do
        ip=$(ip_of "$n")
        ssh -o ConnectTimeout=10 "$ip" 'sudo sh -c "sha256sum /etc/nftables.conf /etc/nftables.d/* 2>/dev/null"' 2>/dev/null \
            | awk '{print $2, substr($1,1,12)}' | LC_ALL=C sort > "$tmp/$n" || true
        [ -s "$tmp/$n" ] || { bad "prod-homelab$n: could not read its firewall files"; FAILS=$((FAILS+1)); }
    done
    local files; files=$(cat "$tmp"/00 "$tmp"/01 "$tmp"/02 | awk '{print $1}' | LC_ALL=C sort -u)
    printf '  %-42s %-13s %-13s %-13s\n' FILE 00 01 02
    local f h0 h1 h2 diffs=0
    for f in $files; do
        h0=$(awk -v f="$f" '$1==f {print $2}' "$tmp/00"); h1=$(awk -v f="$f" '$1==f {print $2}' "$tmp/01"); h2=$(awk -v f="$f" '$1==f {print $2}' "$tmp/02")
        printf '  %-42s %-13s %-13s %-13s' "$f" "${h0:--}" "${h1:--}" "${h2:--}"
        if [ "$h0" = "$h1" ] && [ "$h1" = "$h2" ]; then echo "  ${D}same${O}"
        elif [ "$f" = /etc/nftables.d/15-homelab-vrrp.nft ]; then echo "  ${Y}differs${O} (peer order; homelab-keepalived 0.1.5 sorts it)"; diffs=$((diffs+1))
        else echo "  ${R}DIFFERS${O}"; diffs=$((diffs+1)); fi
    done
    rm -rf "$tmp"
    [ "$diffs" = 0 ] && ok "the three edges' firewall files are identical" || { warn "$diffs file(s) differ across the trio"; FAILS=$((FAILS+1)); }
    echo "  ${D}canonical 60-plex-egress.nft = $CANON ($CANON_SHA)${O}"
}

apply(){
    local n=$1 ip; ip=$(ip_of "$n")
    step "prod-homelab$n ($ip): canonical drop-ins"
    # The remote script runs as root via `sudo bash -s`. Local expansion only
    # for the canonical checksum; everything the remote side computes is \$.
    local out rc
    out=$(ssh -o ConnectTimeout=10 "$ip" 'sudo bash -s' <<EOF
set -uo pipefail
cd /etc/nftables.d || exit 1
STAMP=\$(date +%Y%m%d)
CHANGED=0

# 1. the files on disk
if [ -f 20-edge-public.nft ]; then
    cp -a 20-edge-public.nft "/root/20-edge-public.nft.removed-\$STAMP" && echo "kept a copy: /root/20-edge-public.nft.removed-\$STAMP"
fi
if [ "\$(sha256sum 60-plex-egress.nft 2>/dev/null | awk '{print \$1}')" != "$CANON_SHA" ]; then
    printf 'add rule inet filter output ip daddr 10.10.0.106 tcp dport 32400 accept\n' > 60-plex-egress.nft.tmp \
      && chmod 644 60-plex-egress.nft.tmp && mv 60-plex-egress.nft.tmp 60-plex-egress.nft && CHANGED=1
    [ "\$(sha256sum 60-plex-egress.nft | awk '{print \$1}')" = "$CANON_SHA" ] || { echo "60-plex-egress.nft does not match the canonical file"; exit 2; }
    echo "wrote 60-plex-egress.nft"
fi
if [ -f 20-edge-public.nft ]; then rm -f 20-edge-public.nft && CHANGED=1 && echo "removed 20-edge-public.nft"; fi
nft -c -f /etc/nftables.conf || { echo "the on-disk firewall configuration does not parse -- NOT touching the kernel"; exit 3; }
echo "on-disk configuration parses (check only)"

# 2. the kernel, in one transaction
IN=\$(nft -a list chain inet filter input  | awk '/homelab-edge-mail-in/ {for(i=1;i<=NF;i++) if(\$i=="handle") print \$(i+1)}')
OUT=\$(nft -a list chain inet filter output | awk '/homelab-plex-egress/   {for(i=1;i<=NF;i++) if(\$i=="handle") print \$(i+1)}')
PLAIN=\$(nft -a list chain inet filter output | grep -F 'ip daddr 10.10.0.106 tcp dport 32400 accept' | grep -vc comment)
BASEMAIL=\$(nft list chain inet filter input | grep -v comment | grep -E 'tcp dport \{[^}]*\b25\b' | grep -Ec '\b587\b.*\b143\b.*\b993\b|\b993\b')
TX=""
[ "\$PLAIN" = 0 ] && TX="\${TX}add rule inet filter output ip daddr 10.10.0.106 tcp dport 32400 accept
"
for h in \$OUT; do TX="\${TX}delete rule inet filter output handle \$h
"; done
if [ -n "\$IN" ]; then
    if [ "\$BASEMAIL" -ge 1 ]; then for h in \$IN; do TX="\${TX}delete rule inet filter input handle \$h
"; done
    else echo "the base file's own mail accept is NOT in the live input chain -- keeping the commented mail-in rule"; exit 4; fi
fi
if [ -n "\$TX" ]; then
    printf '%s' "\$TX" | nft -f - || { echo "nft transaction failed"; exit 5; }
    echo "kernel updated in one transaction:"; printf '%s' "\$TX" | sed 's/^/    /'
    CHANGED=1
else
    echo "kernel already canonical"
fi

# 3. what it looks like now
echo "input accepts for the mail ports: \$(nft list chain inet filter input | grep -Ec 'tcp dport \{[^}]*\b25\b')  (want 1, the base file's)"
echo "plex egress rules: \$(nft list chain inet filter output | grep -Fc '10.10.0.106')  (want 1)"
echo "tables: \$(nft list tables | tr '\n' ' ')"
echo "bad-ips bans in the kernel: \$(nft list set inet badips badipv4 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | wc -l)"
ls -la /etc/nftables.d/
[ "\$CHANGED" = 1 ] && echo "RESULT: changed" || echo "RESULT: already canonical"
EOF
    )
    rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    if [ $rc -ne 0 ]; then bad "prod-homelab$n: remote step exited $rc"; FAILS=$((FAILS+1)); return; fi
    case "$out" in *"RESULT: changed"*) ok "prod-homelab$n: now canonical (changed)" ;; *"RESULT: already canonical"*) ok "prod-homelab$n: already canonical" ;; *) bad "prod-homelab$n: no result line"; FAILS=$((FAILS+1)) ;; esac
}

if [ "$VERIFY" = 1 ]; then
    verify
else
    for n in "${TARGETS[@]}"; do apply "$n"; done
    verify
    echo
    echo "  ${D}now prove each changed edge from the internet: ./edge-verify.sh NN${O}"
fi
[ "$FAILS" = 0 ] && exit 0 || exit 1
