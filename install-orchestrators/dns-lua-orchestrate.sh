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
# to the edge addresses for it). All three edges are live since 2026-11-06
# (00=.66, 01=.67, 02=.68), so EDGES lists all three.
#
# IPv6 (post-cutover #64). When install-orchestrators/.edge-ipv6 exists (one
# "public-IPv4 IPv6" pair per line, written by dns-ipv6-orchestrate.sh), every
# WEB name (checked on 443; not mail.*) also carries a Lua AAAA record in the
# same LUA rrset. The up-set is still decided by the IPv4 health check -- the
# DNS nodes have no IPv6 of their own -- and then mapped to the edges' IPv6
# addresses, so an edge that drops out of the A answer drops out of the AAAA
# answer too. mail.* stays A-only (haproxy binds IPv4 only, item for later).
# Without the file nothing about AAAA happens, which was the behaviour before.
#
# SAFETY. Originals are saved to $STATE before anything changes; --revert
# restores them. The LUA record is added BEFORE the A record is removed, so a
# name is never missing. pdns is restarted one node at a time (dnsdist skips a
# node that is down), because PowerDNS only serves a new record type at an
# existing name after a restart.
set -euo pipefail

DNS_NODE=${DNS_NODE:-10.20.2.147}                  # any PowerDNS node (shared database)
PDNS_NODES=${PDNS_NODES:-"10.20.2.147 10.20.2.148 10.20.2.149"}
EDGES=${EDGES:-"23.116.91.66 23.116.91.67 23.116.91.68"}   # addresses held by a live edge TODAY (see above)
ALL_EDGES=${ALL_EDGES:-"23.116.91.66 23.116.91.67 23.116.91.68"}   # every address a candidate A record may hold
TTL=${TTL:-120}
STATE=${DNS_LUA_STATE:-$HOME/.local/state/homelab/dns-lua-original-records.txt}
NS_IPS=${NS_IPS:-"23.116.91.66 23.116.91.68"}      # the two nameserver addresses
ONLY=${ONLY:-.}      # regex on the record name, to convert a few names first

# IPv6: the edges' addresses, as dns-ipv6-orchestrate.sh recorded them.
EDGE_IPV6_FILE=${EDGE_IPV6_FILE:-$(cd "$(dirname "$0")" && pwd)/.edge-ipv6}
declare -A V6=()
if [ -s "$EDGE_IPV6_FILE" ]; then
    while read -r v4 v6 _; do
        case "$v4" in ''|'#'*) continue ;; esac
        [ -n "$v6" ] && V6[$v4]=$v6
    done < "$EDGE_IPV6_FILE"
fi
IPV6_ON=0; [ "${#V6[@]}" -gt 0 ] && IPV6_ON=1

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

lua_contents() {   # name -> the LUA record content(s), one per line: A, then AAAA for a web name when IPv6 is on
    local port=443 a m=""
    [ "${1%%.*}" = mail ] && port=25
    printf "A \"ifportup(%s, {%s}, {selector='all', backupSelector='all', minimumFailures=2})\"\n" "$port" "$EDGE_LUA"
    [ "$IPV6_ON" = 1 ] && [ "$port" = 443 ] || return 0
    # The same IPv4 health check, then each healthy address mapped to its
    # IPv6 twin. A Lua record whose code starts with ";" is a statement block
    # and must return the answer set.
    for a in $EDGES; do [ -n "${V6[$a]:-}" ] && m="$m['$a']='${V6[$a]}',"; done
    [ -n "$m" ] || return 0
    printf "AAAA \";local up=ifportup(%s, {%s}, {selector='all', backupSelector='all', minimumFailures=2}) local m={%s} local r={} for _,a in ipairs(up) do if m[a] then r[#r+1]=m[a] end end return r\"\n" "$port" "$EDGE_LUA" "${m%,}"
}

content_args() {  # name -> every content, double-quoted and escaped for the remote shell, space-separated
    lua_contents "$1" | sed 's/"/\\"/g; s/^/"/; s/$/"/' | paste -sd' ' -
}

has_aaaa() { printf '%s\n' "$1" | grep -q '^AAAA '; }

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
    [ "$IPV6_ON" = 1 ] && echo "  (IPv6 on: web names also get a Lua AAAA record; map from $EDGE_IPV6_FILE)" \
                       || echo "  (IPv6 off: no $EDGE_IPV6_FILE, A records only)"
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
        rn "sudo pdnsutil rrset add '$z' '$fq' LUA $TTL $(content_args "$fq") >/dev/null && sudo pdnsutil rrset delete '$z' '$fq' A >/dev/null" \
            && { ok "$fq"; CONVERTED=$((CONVERTED+1)); } || bad "$fq"
        case " $ZONES " in *" $z "*) ;; *) ZONES="$ZONES $z" ;; esac
    done <<< "$CAND"
    [ "$CONVERTED" -gt 0 ] || echo "  (no plain A records left to convert)"
    for z in $ZONES; do rn "sudo pdnsutil zone increase-serial '$z' >/dev/null"; done

    step "refresh the Lua records that already exist (EDGES='$EDGES'; IPv6 $([ "$IPV6_ON" = 1 ] && echo on || echo off))"
    REFRESHED=0; NEWTYPE=0
    while IFS='|' read -r z name; do
        [ -n "$z" ] || continue
        want=$(lua_contents "${name%.}" | sort)
        have=$(rn "sudo pdnsutil zone list '$z' 2>/dev/null | awk -v n='${name%.}' '\$1==n && \$4==\"LUA\" {sub(/^[^ ]+[ \t]+[0-9]+[ \t]+IN[ \t]+LUA[ \t]+/, \"\"); print}'" | sort)
        [ "$have" = "$want" ] && continue
        # Gaining (or losing) the AAAA record changes the set of answer TYPES
        # at the name, which PowerDNS serves only after a restart.
        if has_aaaa "$want" && ! has_aaaa "$have"; then NEWTYPE=1; fi
        if has_aaaa "$have" && ! has_aaaa "$want"; then NEWTYPE=1; fi
        rn "sudo pdnsutil rrset replace '$z' '${name%.}' LUA $TTL $(content_args "${name%.}") >/dev/null" \
            && { ok "${name%.} updated$(has_aaaa "$want" && echo ' (A + AAAA)')"; REFRESHED=$((REFRESHED+1)); } || bad "${name%.} update"
        case " $ZONES " in *" $z "*) ;; *) ZONES="$ZONES $z" ;; esac
    done < <(rn 'for z in $(sudo pdnsutil zone list-all 2>/dev/null | grep -v "\.invalid$"); do
                   sudo pdnsutil zone list "$z" 2>/dev/null | awk -v z="$z" "\$4==\"LUA\" {print z\"|\"\$1}"
               done' | sort -u)
    [ "$REFRESHED" -eq 0 ] && echo "  (none needed changing)"
    [ "$REFRESHED" -gt 0 ] && for z in $ZONES; do rn "sudo pdnsutil zone increase-serial '$z' >/dev/null"; done

    # A new record type at an existing name needs a restart to be served; a
    # changed address list inside an existing Lua record does not.
    if [ "$CONVERTED" -gt 0 ] || [ "$NEWTYPE" = 1 ]; then
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
            # IPv6: a web name must answer AAAA with an edge's IPv6 twin, asked
            # over IPv4 and -- when the nameserver has one -- over IPv6.
            [ "$IPV6_ON" = 1 ] && [ "${n%%.*}" != mail ] || continue
            ans6=$(ssh -n -o ConnectTimeout=8 offsite "dig +short +time=4 +tries=1 AAAA ${n%.} @$ns" 2>/dev/null | tr '\n' ' ')
            good=0
            for e in $EDGES; do [ -n "${V6[$e]:-}" ] && case " $ans6 " in *" ${V6[$e]} "*) good=1 ;; esac; done
            [ "$good" = 1 ] && ok "${n%.} AAAA @$ns -> $ans6" || bad "${n%.} AAAA @$ns -> '${ans6}' (no edge IPv6)"
            if [ -n "${V6[$ns]:-}" ]; then
                ans6=$(ssh -n -o ConnectTimeout=8 offsite "dig -6 +short +time=4 +tries=1 AAAA ${n%.} @${V6[$ns]}" 2>/dev/null | tr '\n' ' ')
                good=0
                for e in $EDGES; do case " $ans6 " in *" ${V6[$e]} "*) good=1 ;; esac; done
                [ "$good" = 1 ] && ok "${n%.} AAAA over IPv6 @${V6[$ns]} -> $ans6" || bad "${n%.} AAAA over IPv6 @${V6[$ns]} -> '${ans6}'"
            fi
        done
    done
    ;;
esac

[ "$FAILED" = 0 ] || { echo; echo "SOME STEPS FAILED"; exit 1; }
