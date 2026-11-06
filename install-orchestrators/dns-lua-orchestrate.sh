#!/usr/bin/env bash
# dns-lua-orchestrate.sh -- turn the public names that point at the edge into
# health-checked PowerDNS Lua records (post-cutover item 44).
#
#   ./dns-lua-orchestrate.sh --list      # what would change (read-only)
#   ./dns-lua-orchestrate.sh --apply     # convert, then rolling-restart pdns
#   ./dns-lua-orchestrate.sh --verify    # check from offsite (read-only)
#   ./dns-lua-orchestrate.sh --revert    # put the original A records back
#   ONLY='^www\.' ./dns-lua-orchestrate.sh --apply   # only names matching a regex
#
# WHAT IT CONVERTS. Every A record in the fleet's zones whose address is one
# of the edge addresses (EDGES below), EXCEPT ns1.* and ns2.*: the nameserver
# names are the stable identity of the two DNS addresses and stay plain A
# records. A label "mail" is checked on TCP 25 (SMTP); everything else on
# TCP 443 (web).
#
# WHAT A CONVERTED NAME ANSWERS. Every edge address that accepts a TCP
# connection on the check port. An address that stops answering is left out
# within a few seconds; if NONE answers, all are returned (a name that
# answers with nothing is worse than one that points at a dead address).
# `selector='all'` gives every healthy address, in a different order per
# query, so clients spread across the edges with no load balancer.
# minimumFailures=2 keeps one lost packet from dropping an edge.
#
# WHICH ADDRESSES GO IN THE LIST. Only addresses that exist. A listed address
# that nothing holds is skipped once its check has run, but a DNS node answers
# with ALL listed addresses until it has run a first check (after a restart,
# or for a name nobody asked about for an hour), so a phantom address would be
# handed out now and then. Run `EDGES="a b c" ./dns-lua-orchestrate.sh --apply`
# again when an edge is added or removed: it rewrites the address list of every
# Lua record it finds, and converts any new plain A records.
#
# The health check runs on the DNS nodes (homelab-dns 0.2.0 opens TCP 25 out
# to the edge addresses for it). Today only 66 and 68 exist; 67 fails its
# check and is simply never returned until a node holds it.
#
# SAFETY. Originals are saved to $STATE before anything changes; --revert
# restores them. The LUA record is added BEFORE the A record is removed, so a
# name is never missing. pdns is restarted one node at a time (dnsdist skips a
# node that is down), because PowerDNS only serves a new record type at an
# existing name after a restart.
set -euo pipefail

DNS_NODE=${DNS_NODE:-10.20.2.147}                  # any PowerDNS node (shared database)
PDNS_NODES=${PDNS_NODES:-"10.20.2.147 10.20.2.148 10.20.2.149"}
EDGES=${EDGES:-"23.116.91.66 23.116.91.68"}       # addresses held by a live edge TODAY (see above)
ALL_EDGES=${ALL_EDGES:-"23.116.91.66 23.116.91.67 23.116.91.68"}   # every address a candidate A record may hold
TTL=${TTL:-120}
STATE=${DNS_LUA_STATE:-$HOME/.local/state/homelab/dns-lua-original-records.txt}
NS_IPS=${NS_IPS:-"23.116.91.66 23.116.91.68"}      # the two nameserver addresses
ONLY=${ONLY:-.}      # regex on the record name, to convert a few names first

MODE=""
for a in "$@"; do
    case "$a" in
        --list|--apply|--verify|--revert) MODE=$a ;;
        *) echo "unknown argument '$a' (usage: $(basename "$0") --list|--apply|--verify|--revert)"; exit 1 ;;
    esac
done
[ -n "$MODE" ] || { echo "usage: $(basename "$0") --list|--apply|--verify|--revert"; exit 1; }

ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILED=1; }
step() { printf '\n=== %s ===\n' "$*"; }
FAILED=0

rn() { ssh -n -o ConnectTimeout=8 "$DNS_NODE" "$@"; }

EDGE_RE=$(printf '%s' "$ALL_EDGES" | sed 's/\./\\./g; s/ /|/g')
EDGE_LUA=$(printf "'%s'," $EDGES | sed 's/,$//')

# zone|name|ttl|address  for every candidate A record
candidates() {
    rn 'for z in $(sudo pdnsutil zone list-all 2>/dev/null | grep -v "\.invalid$"); do
            sudo pdnsutil zone list "$z" 2>/dev/null | awk -v z="$z" "\$4==\"A\" {print z\"|\"\$1\"|\"\$2\"|\"\$5}"
        done' | grep -E "\|($EDGE_RE)\$" | grep -vE '\|ns[12]\.' | awk -F'|' -v re="$ONLY" '$2 ~ re' | sort
}

lua_content() {   # name -> the LUA record content
    local port=443
    [ "${1%%.*}" = mail ] && port=25
    printf "A \"ifportup(%s, {%s}, {selector='all', backupSelector='all', minimumFailures=2})\"" "$port" "$EDGE_LUA"
}

rolling_restart() {
    local n
    for n in $PDNS_NODES; do
        ssh -o ConnectTimeout=8 "$n" 'sudo systemctl restart pdns; sleep 4; systemctl is-active pdns' | grep -q '^active$' \
            && ok "pdns restarted on $n" || bad "pdns did not come back on $n"
        sleep 8
    done
}

case "$MODE" in
--list)
    step "A records on the edge addresses that would become Lua records (ns1/ns2 stay plain)"
    candidates | while IFS='|' read -r z name ttl addr; do
        printf '  %-22s %-36s %-5s -> %s\n' "$z" "${name%.}" "$ttl" "$([ "${name%%.*}" = mail ] && echo 'LUA, port 25' || echo 'LUA, port 443')"
    done
    ;;

--apply)
    step "save the originals to $STATE"
    mkdir -p "$(dirname "$STATE")"
    CAND=$(candidates || true)
    [ -s "$STATE" ] || : > "$STATE"
    printf '%s\n' "$CAND" | while IFS='|' read -r z name ttl addr; do
        [ -n "$z" ] || continue
        grep -qxF "$z|$name|$ttl|$addr" "$STATE" || printf '%s|%s|%s|%s\n' "$z" "$name" "$ttl" "$addr" >> "$STATE"
    done
    ok "$(wc -l < "$STATE") original record(s) saved"

    step "convert (add the Lua record, then remove the plain A record)"
    ZONES=""; CONVERTED=0
    while IFS='|' read -r z name ttl addr; do
        [ -n "$z" ] || continue
        fq=${name%.}
        # Several A records at one name (more than one edge address) are all
        # replaced by the one Lua record.
        rn "sudo pdnsutil rrset add '$z' '$fq' LUA $TTL \"$(lua_content "$fq" | sed 's/"/\\"/g')\" >/dev/null && sudo pdnsutil rrset delete '$z' '$fq' A >/dev/null" \
            && { ok "$fq"; CONVERTED=$((CONVERTED+1)); } || bad "$fq"
        case " $ZONES " in *" $z "*) ;; *) ZONES="$ZONES $z" ;; esac
    done <<< "$CAND"
    [ "$CONVERTED" -gt 0 ] || echo "  (no plain A records left to convert)"
    for z in $ZONES; do rn "sudo pdnsutil zone increase-serial '$z' >/dev/null"; done

    step "refresh the address list of Lua records that already exist (EDGES='$EDGES')"
    REFRESHED=0
    while IFS='|' read -r z name; do
        [ -n "$z" ] || continue
        want=$(lua_content "${name%.}")
        have=$(rn "sudo pdnsutil zone list '$z' 2>/dev/null | awk -v n='${name%.}' '\$1==n && \$4==\"LUA\" {sub(/^[^ ]+[ \t]+[0-9]+[ \t]+IN[ \t]+LUA[ \t]+/, \"\"); print}'")
        [ "$have" = "$want" ] && continue
        rn "sudo pdnsutil rrset replace '$z' '${name%.}' LUA $TTL \"$(printf '%s' "$want" | sed 's/"/\\"/g')\" >/dev/null" \
            && { ok "${name%.} list updated"; REFRESHED=$((REFRESHED+1)); } || bad "${name%.} list update"
    done < <(rn 'for z in $(sudo pdnsutil zone list-all 2>/dev/null | grep -v "\.invalid$"); do
                   sudo pdnsutil zone list "$z" 2>/dev/null | awk -v z="$z" "\$4==\"LUA\" {print z\"|\"\$1}"
               done' | sort -u)
    [ "$REFRESHED" -eq 0 ] && echo "  (none needed changing)"

    # A new record type at an existing name needs a restart to be served; a
    # changed address list inside an existing Lua record does not.
    if [ "$CONVERTED" -gt 0 ]; then
        step "rolling pdns restart"
        rolling_restart
    fi
    echo; echo "Now run: $0 --verify"
    ;;

--revert)
    [ -s "$STATE" ] || { echo "no saved originals at $STATE"; exit 1; }
    step "restore the original A records"
    ZONES=""
    while IFS='|' read -r z name ttl addr; do
        fq=${name%.}
        rn "sudo pdnsutil rrset add '$z' '$fq' A $ttl '$addr' >/dev/null" && ok "$fq A $addr" || bad "$fq"
        case " $ZONES " in *" $z "*) ;; *) ZONES="$ZONES $z" ;; esac
    done < "$STATE"
    # One LUA record per name; delete it once, after the A records are back.
    cut -d'|' -f1,2 "$STATE" | sort -u | while IFS='|' read -r z name; do
        rn "sudo pdnsutil rrset delete '$z' '${name%.}' LUA >/dev/null" || true
    done
    for z in $ZONES; do rn "sudo pdnsutil zone increase-serial '$z' >/dev/null"; done
    step "rolling pdns restart"
    rolling_restart
    ;;

--verify)
    step "every converted name, asked of both nameservers from offsite"
    NAMES=$(rn 'for z in $(sudo pdnsutil zone list-all 2>/dev/null | grep -v "\.invalid$"); do
                  sudo pdnsutil zone list "$z" 2>/dev/null | awk "\$4==\"LUA\" {print \$1}"
              done' | sort -u)
    [ -n "$NAMES" ] || { echo "no Lua records found"; exit 1; }
    for n in $NAMES; do
        for ns in $NS_IPS; do
            ans=$(ssh -n -o ConnectTimeout=8 offsite "dig +short +time=4 +tries=1 A ${n%.} @$ns" 2>/dev/null | tr '\n' ' ')
            good=0
            for e in $EDGES; do case " $ans " in *" $e "*) good=1 ;; esac; done
            [ "$good" = 1 ] && ok "${n%.} @$ns -> $ans" || bad "${n%.} @$ns -> '${ans}' (no edge address)"
        done
    done
    ;;
esac

[ "$FAILED" = 0 ] || { echo; echo "SOME STEPS FAILED"; exit 1; }
