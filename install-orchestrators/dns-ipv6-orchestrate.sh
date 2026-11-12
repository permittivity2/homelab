#!/bin/bash
# ============================================================================
# Post-cutover #64 -- DNS over IPv6: the public nameservers answer on IPv6,
# the zones publish AAAA (ns1/ns2 glue names + the web names), the registry
# gets IPv6 glue, ns03 resolves over IPv6. RUN ON THE ADMIN WORKSTATION.
#
#   ./dns-ipv6-orchestrate.sh --preflight             read-only: is everything in place to start
#   ./dns-ipv6-orchestrate.sh --edges [NN...]         IPv6 on the edges (00 01 02), one at a time, each verified
#   ./dns-ipv6-orchestrate.sh --check [NN...]         read-only: the per-edge checks again (after a transient failure), records the address
#   ./dns-ipv6-orchestrate.sh --zones                 AAAA for ns1/ns2 in every zone (+ rolling pdns restart)
#   ./dns-ipv6-orchestrate.sh --glue --probe DOMAIN   one Namecheap API call on a retired domain, then check the registry
#   ./dns-ipv6-orchestrate.sh --glue                  IPv6 glue for every domain through the Namecheap API
#   ./dns-ipv6-orchestrate.sh --web                   Lua AAAA records for the web names (dns-lua-orchestrate.sh does the writing)
#   ./dns-ipv6-orchestrate.sh --ns03                  ns03 answers and resolves over IPv6 (ONE recursor restart = house-wide blip)
#   ./dns-ipv6-orchestrate.sh --verify                read-only: the repeatable check of all of the above
#   ./dns-ipv6-orchestrate.sh --prefix-changed        the day AT&T hands out a different /60: re-publish everything
#
# HOW THE ADDRESSES WORK. The house IPv6 block is a LEASE from AT&T (today
# 2600:1702:85f0:4340::/60); nothing here hard-codes it. Each node takes a
# SLAAC address from its segment's router advertisement with a FIXED token:
# the node's IPv4 spelled as four groups. So edge 00 (23.116.91.66) is
# <prefix>:23:116:91:66, ns03 on VLAN 60 (10.60.0.140) is <prefix>:10:60:0:140.
# A prefix change moves only the first half of every address, by itself; what
# has to be re-published afterwards (zone AAAA, the Lua maps, ns03's allow-from,
# registry glue) is exactly what --prefix-changed does. The listeners never
# name an address: dnsdist binds [::]:53, the recursor binds ::.
#
# WHAT STAYS IPv4. mail.* (haproxy binds *:port = IPv4 only; outbound mail
# reputation) and the fleet's internal planes (no /64 there). PowerDNS on
# 03/04/05 needs nothing: dnsdist proxies IPv6 clients to it over IPv4 and the
# client address travels in the PROXY protocol header, so the Lua steering
# sees it unchanged.
#
# EDGE FIREWALL. /etc/nftables.conf (byte-identical trio, inet filter, both
# chains policy drop) gets an ICMPv6 accept in INPUT (NDP, RA, PMTU, ping)
# and `meta l4proto ipv6-icmp accept` in OUTPUT; the port rules already match
# both families. Applied like smtps-orchestrate.sh: the file is edited and the
# kernel gets the two rules added live -- never `nft -f /etc/nftables.conf`
# (its `flush ruleset` would empty bad-ips' table). Recapture the edge drift
# reference afterwards (edge-rotate.sh 00 --capture-reference).
#
# WHERE THE ADDRESSES ARE RECORDED. install-orchestrators/.edge-ipv6, one
# "public-IPv4 IPv6" pair per line, committed next to .edge-model. It is what
# dns-lua-orchestrate.sh reads to build the Lua AAAA records, and what --verify
# compares everything against.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
FAILS=0

h(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }
offsite(){ ssh -n -o ConnectTimeout=10 -o BatchMode=yes offsite "$@" 2>/dev/null; }
# retry TRIES PAUSE PATTERN CMD...: run CMD until its output matches the bash
# pattern (up to TRIES times, PAUSE seconds apart); prints the last output and
# returns 0 only on a match. The probes right after a dnsdist restart need this:
# on 2026-11-12 edge 00 answered UDP but not TCP for a few seconds while the
# 512 MB container was under memory pressure (the OOM killer had just fired).
retry(){
  local tries=$1 pause=$2 pat=$3 i x; shift 3
  for ((i = 1; i <= tries; i++)); do
    x=$("$@"); [[ "$x" == $pat ]] && { printf '%s' "$x"; return 0; }
    [ "$i" -lt "$tries" ] && sleep "$pause"
  done
  printf '%s' "$x"; return 1
}

EDGE_NODES="00 01 02"
DNS_NODE=${DNS_NODE:-10.20.2.147}
PDNS_NODES=${PDNS_NODES:-"10.20.2.147 10.20.2.148 10.20.2.149"}
NS03=${NS03:-ns03}
METRICS=${METRICS:-10.20.2.213}
WANT_DD=0.1.6
IPV6_FILE=./.edge-ipv6
LUA=./dns-lua-orchestrate.sh
NAMECHEAP=${NAMECHEAP:-/home/gardner/claude/general/projects/namecheap-api/git/namecheap_dns.pl}
NS1_V4=23.116.91.66; NS2_V4=23.116.91.68
PROBE_NAME=mailmasker.org

# The two firewall rules (no nd-redirect on purpose: a redirect accepted from
# the segment could re-route the node; nothing legitimate sends us one).
ICMP6_IN='icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, mld-listener-query, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept'
ICMP6_OUT='meta l4proto ipv6-icmp accept'

MODE=""; PROBE=""; NODES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preflight|--edges|--check|--zones|--glue|--web|--ns03|--verify|--prefix-changed) MODE=${1#--} ;;
    --probe) PROBE=${2:-}; shift ;;
    0[0-2]) NODES="$NODES $1" ;;
    *) echo "usage: $0 --preflight | --edges [00 01 02] | --check [00 01 02] | --zones | --glue [--probe DOMAIN] | --web | --ns03 | --verify | --prefix-changed"; exit 1 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: $0 --preflight | --edges [00 01 02] | --check [00 01 02] | --zones | --glue [--probe DOMAIN] | --web | --ns03 | --verify | --prefix-changed"; exit 1; }
[ -n "$NODES" ] || NODES=$EDGE_NODES

LOG="/home/gardner/claude/temp/dns-ipv6-orchestrate-$MODE-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"

nc(){ (cd "$(dirname "$NAMECHEAP")" && perl "./$(basename "$NAMECHEAP")" "$@"); }   # the tool finds its lib/ and config from its own directory
ver_of(){ rssh "$1" "dpkg-query -W -f='\${Version}' $2 2>/dev/null"; }
ver_ge(){ dpkg --compare-versions "$1" ge "$2"; }
token_of(){ printf '%s' "$1" | tr . :; }                        # 23.116.91.66 -> 23:116:91:66
v6_of(){ [ -s "$IPV6_FILE" ] && awk -v k="$1" '$1==k {print $2; exit}' "$IPV6_FILE"; }
record_v6(){ # $1 = v4  $2 = v6 : upsert in .edge-ipv6
  local tmp; tmp=$(mktemp)
  { [ -s "$IPV6_FILE" ] && grep -vE "^(#|$1 )" "$IPV6_FILE"; printf '%s %s\n' "$1" "$2"; } | sort -t. -k4,4n > "$tmp"
  { echo "# public IPv4 -> IPv6 of each live edge (post-cutover #64). Written by dns-ipv6-orchestrate.sh --edges;"
    echo "# read by dns-lua-orchestrate.sh (Lua AAAA maps), edge-verify.sh and --verify. Re-made by --prefix-changed."
    cat "$tmp"; } > "$IPV6_FILE"
  rm -f "$tmp"
}
tld_server(){ dig +short NS "${1##*.}." @1.1.1.1 2>/dev/null | head -1; }
registry_glue(){ # $1 = domain -> "host TYPE addr" lines from the TLD server, asked from offsite
  local ns; ns=$(tld_server "$1"); [ -n "$ns" ] || return 1
  offsite "dig +norec +time=4 +tries=2 @$ns $1 NS" | awk '$1 ~ /^ns[12]\./ && ($4=="A" || $4=="AAAA") {sub(/\.$/, "", $1); print $1, $4, $5}' | sort -u
}
edge_pub(){ rssh "$(h "$1")" 'ip -4 -o addr show scope global' | awk '$4 ~ /^23\.116\.91\./ {sub("/.*", "", $4); print $2, $4; exit}'; }  # "NIC v4"
edge_live_v6(){ # $1 = NN $2 = NIC $3 = token
  rssh "$(h "$1")" "ip -6 -o addr show dev $2 scope global -tentative" | awk '{print $4}' | cut -d/ -f1 | grep -- ":$3\$" | head -1
}
zones(){ rssh "$DNS_NODE" 'sudo pdnsutil zone list-all 2>/dev/null' | grep -v '\.invalid$' | sort; }
web_names(){ # every Lua-steered name that is not mail.*
  rssh "$DNS_NODE" 'for z in $(sudo pdnsutil zone list-all 2>/dev/null | grep -v "\.invalid$"); do sudo pdnsutil zone list "$z" 2>/dev/null | awk "\$4==\"LUA\" {print \$1}"; done' \
    | sed 's/\.$//' | grep -v '^mail\.' | sort -u
}
rolling_restart(){
  local n
  for n in $PDNS_NODES; do
    rssh "$n" 'sudo systemctl restart pdns; sleep 4; systemctl is-active pdns' | grep -q '^active$' \
      && ok "pdns restarted on $n" || bad "pdns did not come back on $n"
    sleep 8
  done
}

# ------------------------------------------------------------- preflight --

preflight(){
  step "[preflight] the gateway advertises IPv6 on VLAN 230 (seen from this workstation's bond0.230)"
  local ra; ra=$(ip -6 route show dev bond0.230 2>/dev/null | grep 'proto ra' | grep -E '^2[0-9a-f]{3}:.*/64' | awk '{print $1}' | head -1)
  [ -n "$ra" ] && ok "RA prefix on VLAN 230: $ra" || bad "no RA-learned /64 on bond0.230 -- the gateway is not advertising IPv6"
  step "[preflight] inbound IPv6 from the internet is open (offsite -> jumper's SSH over IPv6)"
  offsite 'timeout 6 bash -c "exec 3<>/dev/tcp/2600:1702:85f0:4340::43/22" && echo open' | grep -q open \
    && ok "offsite reaches jumper on [2600:1702:85f0:4340::43]:22 -- the gateway's Reflexive ACL is Off" \
    || bad "offsite cannot reach jumper over IPv6 -- the gateway blocks inbound IPv6 (Reflexive ACL On?)"
  step "[preflight] offsite can query over IPv6"
  offsite 'dig -6 +short +time=4 @2606:4700:4700::1111 mailmasker.org NS' | grep -q ns1 && ok "dig -6 from offsite works" || bad "dig -6 from offsite failed"
  step "[preflight] the edges"
  local n ip nic v4 sv
  for n in $NODES; do
    ip=$(h "$n"); read -r nic v4 <<<"$(edge_pub "$n")"
    [ -n "$nic" ] && ok "$n public NIC $nic holds $v4 (token ::$(token_of "$v4"))" || bad "$n holds no 23.116.91.x address"
    sv=$(rssh "$ip" 'systemctl --version' | awk 'NR==1{print $2}'); [ "${sv:-0}" -ge 246 ] && ok "$n systemd $sv (Token=static: supported)" || bad "$n systemd $sv < 246"
    rssh "$ip" "grep -q '^IPv6AcceptRA = false' /etc/systemd/network/$nic.network" && ok "$n $nic.network is PVE's (IPv6AcceptRA=false; the drop-in will override it)" || warn "$n $nic.network is not the expected PVE file"
    rssh "$ip" 'sudo -n grep -q "^flush ruleset" /etc/nftables.conf && sudo -n grep -q "icmp type echo-request accept" /etc/nftables.conf && sudo -n grep -q "oifname lo accept" /etc/nftables.conf' \
      && ok "$n /etc/nftables.conf has the anchor lines the edit expects" || bad "$n /etc/nftables.conf is not the expected base file"
    printf '%s\n' "add rule inet filter input $ICMP6_IN" "add rule inet filter output $ICMP6_OUT" | rssh "$ip" 'sudo -n nft -c -f -' && ok "$n the two ICMPv6 rules parse" || bad "$n nft rejects the ICMPv6 rules"
    [ -n "$(edge_live_v6 "$n" "$nic" "$(token_of "$v4")")" ] && warn "$n already has its IPv6 address" || ok "$n no global IPv6 yet (expected before --edges)"
  done
  step "[preflight] homelab-dnsdist $WANT_DD is published"
  rssh "$(h 00)" 'sudo -n apt-get update -qq >/dev/null 2>&1; apt-cache policy homelab-dnsdist' | awk '/Candidate:/ {print $2}' | { read -r c; ver_ge "${c:-0}" "$WANT_DD" && ok "candidate homelab-dnsdist $c" || bad "candidate homelab-dnsdist '${c:-none}' < $WANT_DD -- build/publish it first"; }
  step "[preflight] ns03"
  rssh "$NS03" 'ip -4 -o addr show dev eth5' | grep -q '10\.60\.0\.140' && ok "ns03 eth5 = 10.60.0.140 (VLAN 60, the one VLAN with IPv6)" || bad "ns03 eth5 is not 10.60.0.140"
  rssh "$NS03" 'grep -q "^local-address=" /etc/powerdns/recursor.conf && grep -q "^allow-from=" /etc/powerdns/recursor.conf' && ok "ns03 recursor.conf has local-address and allow-from lines" || bad "ns03 recursor.conf lacks the expected lines"
  rssh "$NS03" 'sudo -n nft list chain inet filter input' | grep -q 'udp dport 53 accept' && ok "ns03 firewall admits 53 for both families (inet rule)" || bad "ns03 firewall: no plain 'udp dport 53 accept'"
  step "[preflight] recursor metrics on the monitoring host"
  local names; names=$(rssh "$METRICS" 'curl -s "http://127.0.0.1:9090/api/v1/label/__name__/values"' | tr ',' '\n' | grep -c -E 'pdns_recursor_(ipv6_questions|ipv6_outqueries|questions)"')
  [ "${names:-0}" = 3 ] && ok "pdns_recursor_ipv6_questions / ipv6_outqueries / questions are scraped" || warn "only $names of the 3 recursor metric names are known to Prometheus"
  step "[preflight] the Namecheap tool accepts IPv6 (the API decides)"
  [ -x "$NAMECHEAP" ] || [ -f "$NAMECHEAP" ] && ok "tool present: $NAMECHEAP" || bad "no $NAMECHEAP"
  perl -I"$(dirname "$NAMECHEAP")/lib" -e 'use Commands::Nameservers; exit(Commands::Nameservers::_valid_ip("2001:db8::1") ? 0 : 1)' && ok "tool validates IPv6 addresses" || bad "tool still refuses IPv6 (lib/Commands/Nameservers.pm)"
}

# ----------------------------------------------------------------- edges --

edge_apply(){ # $1 = NN
  local n=$1 ip nic v4 tok out rc v6; ip="$(h "$n")"
  read -r nic v4 <<<"$(edge_pub "$n")"
  [ -n "$nic" ] || { bad "prod-homelab$n holds no public address -- nothing to do"; return; }
  tok=$(token_of "$v4")
  step "[edge] prod-homelab$n: ICMPv6 in the firewall, then IPv6 on $nic (token ::$tok)"
  out=$(ssh -o ConnectTimeout=10 "$ip" "sudo bash -s -- '$nic' '$tok' '$ICMP6_IN' '$ICMP6_OUT'" <<'EOF'
set -uo pipefail
NIC=$1; TOKEN=$2; IN=$3; OUT=$4
STAMP=$(date +%Y%m%d-%H%M%S); CHANGED=0
F=/etc/nftables.conf

# 1. the firewall, on disk ...
if grep -q 'icmpv6 type' "$F" && grep -q 'ipv6-icmp accept' "$F"; then
    echo "nftables.conf already has the ICMPv6 rules"
else
    cp -a "$F" "/root/nftables.conf.before-ipv6-$STAMP"
    grep -q 'icmpv6 type' "$F" || sed -i -E "s/^([[:space:]]*)(icmp type echo-request accept)\$/\1\2\n\1$IN/" "$F"
    grep -q 'ipv6-icmp accept' "$F" || sed -i -E "s/^([[:space:]]*)(oifname lo accept)\$/\1\2\n\1$OUT/" "$F"
    grep -q 'icmpv6 type' "$F" && grep -q 'ipv6-icmp accept' "$F" || { echo "the anchor lines were not found in $F -- restoring"; cp -a "/root/nftables.conf.before-ipv6-$STAMP" "$F"; exit 5; }
    nft -c -f "$F" || { echo "$F does not parse after the edit -- restoring"; cp -a "/root/nftables.conf.before-ipv6-$STAMP" "$F"; exit 6; }
    echo "nftables.conf: ICMPv6 accepted in input and output (copy of the old file: /root/nftables.conf.before-ipv6-$STAMP)"; CHANGED=1
fi
# ... and in the kernel, two added rules (never nft -f)
if nft list chain inet filter input | grep -q 'icmpv6 type'; then echo "the live input chain already accepts ICMPv6"
else nft add rule inet filter input $IN || { echo "nft add rule (input) failed"; exit 7; }; echo "live input chain: ICMPv6 accepted"; CHANGED=1; fi
if nft list chain inet filter output | grep -q 'ipv6-icmp'; then echo "the live output chain already accepts ICMPv6"
else nft add rule inet filter output $OUT || { echo "nft add rule (output) failed"; exit 8; }; echo "live output chain: ICMPv6 accepted"; CHANGED=1; fi

# 2. the address: a networkd drop-in beside PVE's file (PVE rewrites the
#    .network at every boot; a drop-in survives that, as the nohijack one does)
D=/etc/systemd/network/$NIC.network.d; mkdir -p "$D"; C=$D/20-homelab-ipv6.conf
WANT=$(cat <<CONF
# Managed by install-orchestrators/dns-ipv6-orchestrate.sh (post-cutover #64).
# PVE rewrites $NIC.network on every boot with IPv6AcceptRA=false; this drop-in
# wins. One global IPv6 for this edge: the gateway's advertised prefix plus a
# fixed token spelled like the public IPv4 (<prefix>:$TOKEN), so a prefix
# change moves only the first half of the address, by itself. No DHCPv6 (the
# gateway would hand out a second, arbitrary address), no DNS/domains from the
# RA (the nohijack rule), the default route from the RA on purpose: IPv6 goes
# out the same NIC it comes in on, no NAT.
[Network]
IPv6AcceptRA=yes
IPv6PrivacyExtensions=no
KeepConfiguration=dhcp
[IPv6AcceptRA]
Token=static:::$TOKEN
DHCPv6Client=no
UseDNS=no
UseDomains=no
UseGateway=yes
CONF
)
if [ -f "$C" ] && [ "$(cat "$C")" = "$WANT" ]; then
    echo "drop-in $C already in place"
else
    printf '%s\n' "$WANT" > "$C"; chmod 0644 "$C"
    echo "drop-in $C written"; CHANGED=1
    networkctl reload || { echo "networkctl reload failed"; exit 9; }
fi
A=""
for i in $(seq 1 15); do
    A=$(ip -6 -o addr show dev "$NIC" scope global -tentative 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -- ":$TOKEN\$" | head -1)
    [ -n "$A" ] && break; sleep 2
done
if [ -z "$A" ]; then
    echo "no address after 30 s of reload -- reconfiguring $NIC (KeepConfiguration=dhcp keeps the IPv4 lease)"
    networkctl reconfigure "$NIC"
    for i in $(seq 1 20); do
        A=$(ip -6 -o addr show dev "$NIC" scope global -tentative 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -- ":$TOKEN\$" | head -1)
        [ -n "$A" ] && break; sleep 2
    done
fi
[ -n "$A" ] || { echo "still no IPv6 with token $TOKEN on $NIC"; ip -6 addr show dev "$NIC"; networkctl status "$NIC" | tail -15; exit 10; }
echo "ADDRESS: $A"
R=$(ip -6 route show default dev "$NIC" | head -1); [ -n "$R" ] && echo "default route: $R" || { echo "no IPv6 default route on $NIC"; exit 11; }
ip -4 -o addr show dev "$NIC" scope global | grep -q 'inet 23\.116\.91\.' && echo "IPv4 on $NIC still there" || { echo "IPv4 on $NIC is GONE"; exit 12; }
X=$(ip -6 -o addr show dev eth5 scope global 2>/dev/null | wc -l); [ "$X" = 0 ] && echo "eth5 has no global IPv6 (good)" || echo "WARNING: eth5 has $X global IPv6 address(es)"
echo "global IPv6 on $NIC: $(ip -6 -o addr show dev "$NIC" scope global | awk '{print $4}' | tr '\n' ' ')"
[ "$CHANGED" = 1 ] && echo "RESULT: changed" || echo "RESULT: already there"
EOF
  )
  rc=$?
  printf '%s\n' "$out" | sed 's/^/       /'
  if [ $rc -ne 0 ]; then bad "prod-homelab$n: remote step exited $rc"; return 1; fi
  v6=$(printf '%s\n' "$out" | sed -n 's/^ADDRESS: //p' | head -1)
  [ -n "$v6" ] || { bad "prod-homelab$n: no ADDRESS line"; return 1; }
  case "$out" in *"RESULT: changed"*) ok "prod-homelab$n: IPv6 $v6 on $nic (changed)" ;; *) ok "prod-homelab$n: IPv6 $v6 on $nic (already there)" ;; esac

  step "[edge] prod-homelab$n: reachable over IPv6 from the internet, and nginx answers there (before DNS is touched)"
  retry 3 5 pong offsite "ping -6 -c 2 -W 3 $v6 >/dev/null 2>&1 && echo pong" >/dev/null && ok "offsite pings $v6" || bad "offsite cannot ping $v6 -- inbound IPv6 is not reaching this edge"
  local code; code=$(retry 3 5 '[23]0[0-9]' offsite "curl -6 -s -o /dev/null -w '%{http_code}' -m 15 --resolve '$PROBE_NAME:443:[$v6]' https://$PROBE_NAME/") \
    && ok "https://$PROBE_NAME/ over IPv6 on this edge -> $code" || bad "https://$PROBE_NAME/ over IPv6 on this edge -> '${code:-none}'"

  step "[edge] prod-homelab$n: dnsdist listens on [::]:53 (site file, then homelab-dnsdist -> $WANT_DD applies it in ONE restart)"
  rssh "$ip" 'sudo -n bash -c "
    B=/etc/homelab/dnsdist/backends.yml
    if grep -q \"^listen_addresses:\" \$B && grep -q \"\\[::\\]:53\" \$B; then echo \"backends.yml already lists [::]:53\";
    else cp -a \$B /root/backends.yml.before-ipv6-\$(date +%Y%m%d-%H%M%S);
         perl -0pi -e \"s/^listen_address:[^\\n]*\\n/listen_addresses:\\n  - 0.0.0.0:53\\n  - \\\"[::]:53\\\"\\n/m\" \$B;
         grep -q \"\\[::\\]:53\" \$B && echo \"backends.yml: listen_addresses = 0.0.0.0:53 + [::]:53\" || echo \"COULD NOT EDIT backends.yml\"; fi"' | sed 's/^/       /'
  rssh "$ip" 'sudo -n grep -q "\[::\]:53" /etc/homelab/dnsdist/backends.yml' || { bad "prod-homelab$n: backends.yml does not list [::]:53"; return 1; }
  local v; v=$(ver_of "$ip" homelab-dnsdist)
  if ver_ge "$v" "$WANT_DD"; then
    rssh "$ip" 'sudo -n homelab-dnsdist-apply-backends' | sed 's/^/       /'
  else
    ./pkg-upgrade.sh homelab-dnsdist "$n" || warn "pkg-upgrade homelab-dnsdist $n reported a problem"
  fi
  sleep 2
  edge_checks "$n"
  [ "$FAILS" = 0 ] && record_v6 "$v4" "$v6" && ok "recorded $v4 -> $v6 in $IPV6_FILE"
}

edge_checks(){ # $1 = NN
  local n=$1 ip nic v4 tok v6 x; ip="$(h "$n")"
  read -r nic v4 <<<"$(edge_pub "$n")"
  [ -n "$nic" ] || { bad "$n holds no public IPv4"; return; }
  tok=$(token_of "$v4")
  v6=$(edge_live_v6 "$n" "$nic" "$tok")
  [ -n "$v6" ] && ok "$n $nic has IPv6 $v6" || { bad "$n $nic has no IPv6 with token ::$tok"; return; }
  x=$(v6_of "$v4"); [ -z "$x" ] || [ "$x" = "$v6" ] && ok "$n matches $IPV6_FILE" || bad "$n live $v6 differs from recorded $x -- prefix changed? run --prefix-changed"
  rssh "$ip" "ip -6 route show default dev $nic" | grep -q default && ok "$n IPv6 default route via $nic" || bad "$n no IPv6 default route on $nic"
  rssh "$ip" "test -f /etc/systemd/network/$nic.network.d/20-homelab-ipv6.conf" && ok "$n networkd drop-in present (survives PVE's rewrite at boot)" || bad "$n networkd drop-in missing"
  rssh "$ip" 'sudo -n nft list chain inet filter input' | grep -q 'icmpv6 type' && ok "$n live firewall accepts ICMPv6 in" || bad "$n live firewall does not accept ICMPv6 in"
  rssh "$ip" 'sudo -n nft list chain inet filter output' | grep -q 'ipv6-icmp' && ok "$n live firewall accepts ICMPv6 out" || bad "$n live firewall does not accept ICMPv6 out"
  rssh "$ip" 'sudo -n grep -q "icmpv6 type" /etc/nftables.conf && sudo -n grep -q "ipv6-icmp accept" /etc/nftables.conf' && ok "$n /etc/nftables.conf has both rules (survives a reboot)" || bad "$n /etc/nftables.conf lacks the ICMPv6 rules"
  rssh "$ip" 'sudo -n nft -c -f /etc/nftables.conf' && ok "$n /etc/nftables.conf parses" || bad "$n /etc/nftables.conf does not parse"
  x=$(ver_of "$ip" homelab-dnsdist); ver_ge "$x" "$WANT_DD" && ok "$n homelab-dnsdist $x" || bad "$n homelab-dnsdist $x < $WANT_DD"
  [ "$(rssh "$ip" 'systemctl is-active dnsdist')" = active ] && ok "$n dnsdist active" || bad "$n dnsdist not active"
  rssh "$ip" 'sudo -n ss -lnup' | grep -q '\[::\]:53 ' && ok "$n dnsdist listens on [::]:53 (udp)" || bad "$n nothing listens on [::]:53 udp"
  rssh "$ip" 'sudo -n ss -lntp' | grep -q '\[::\]:53 ' && ok "$n dnsdist listens on [::]:53 (tcp)" || bad "$n nothing listens on [::]:53 tcp"
  rssh "$ip" 'sudo -n ss -lnup' | grep -q '0\.0\.0\.0:53 ' && ok "$n dnsdist still listens on 0.0.0.0:53" || bad "$n IPv4 listener gone"
  x=$(retry 4 5 'ns1.*' offsite "dig -6 +short +time=4 +tries=1 @$v6 $PROBE_NAME SOA") && ok "$n answers SOA over IPv6/UDP from offsite" || bad "$n no SOA over IPv6/UDP from offsite ('$x')"
  x=$(retry 4 5 'ns1.*' offsite "dig -6 +tcp +short +time=4 +tries=1 @$v6 $PROBE_NAME SOA") && ok "$n answers SOA over IPv6/TCP from offsite" || bad "$n no SOA over IPv6/TCP from offsite ('$x')"
  x=$(retry 4 5 '*23.116.91.6*' offsite "dig -6 +short +time=4 +tries=1 @$v6 $PROBE_NAME A | tr '\n' ' '") && ok "$n Lua-steered A answer for an IPv6 client -> $x" || bad "$n Lua answer for an IPv6 client: '$x'"
}

edges_check(){ # --check: the read-only edge checks, recording the address when an edge is clean (a re-run after a transient failure)
  local n nic v4 v6 tok before
  for n in $NODES; do
    step "[check] prod-homelab$n"
    before=$FAILS
    edge_checks "$n"
    if [ "$FAILS" = "$before" ]; then
      read -r nic v4 <<<"$(edge_pub "$n")"; tok=$(token_of "$v4"); v6=$(edge_live_v6 "$n" "$nic" "$tok")
      [ -n "$v6" ] && record_v6 "$v4" "$v6" && ok "recorded $v4 -> $v6 in $IPV6_FILE"
    fi
  done
}

edges_deploy(){
  local n
  for n in $NODES; do
    edge_apply "$n" || true
    if [ "$FAILS" -gt 0 ]; then echo; echo "${R}stopping before the next edge: $FAILS check(s) failed on prod-homelab$n${O}"; exit 1; fi
  done
  echo; echo "all edges done. Next: ./edge-rotate.sh 00 --capture-reference (the /etc/nftables.conf hash changed), then $0 --zones"
}

# ----------------------------------------------------------------- zones --

zones_apply(){ # AAAA for ns1/ns2 in every zone that has the glue A records; replace when the address moved
  local v66 v68 out added
  v66=$(v6_of "$NS1_V4"); v68=$(v6_of "$NS2_V4")
  [ -n "$v66" ] && [ -n "$v68" ] || { bad "no IPv6 recorded for $NS1_V4 / $NS2_V4 in $IPV6_FILE -- run --edges first"; return 1; }
  step "[zones] AAAA ns1 -> $v66, ns2 -> $v68, in every zone with the glue A records (on $DNS_NODE)"
  out=$(ssh -o ConnectTimeout=10 "$DNS_NODE" "sudo bash -s -- '$NS1_V4' '$v66' '$NS2_V4' '$v68'" <<'EOF'
set -uo pipefail
declare -A WANT=([ns1]=$2 [ns2]=$4); declare -A V4=([ns1]=$1 [ns2]=$3)
for z in $(pdnsutil zone list-all 2>/dev/null | grep -v '\.invalid$' | sort); do
    ZCH=0
    for h in ns1 ns2; do
        a4=$(pdnsutil zone list "$z" 2>/dev/null | awk -v n="$h.$z" '$1==n && $4=="A" {print $5}')
        [ "$a4" = "${V4[$h]}" ] || { echo "SKIP $h.$z (A is '${a4:-none}', not ${V4[$h]})"; continue; }
        have=$(pdnsutil zone list "$z" 2>/dev/null | awk -v n="$h.$z" '$1==n && $4=="AAAA" {print $5}' | paste -sd, -)
        if [ -z "$have" ]; then
            pdnsutil rrset add "$z" "$h.$z" AAAA 3600 "${WANT[$h]}" >/dev/null && { echo "ADDED $h.$z AAAA ${WANT[$h]}"; ZCH=1; } || echo "FAILED to add $h.$z AAAA"
        elif [ "$have" != "${WANT[$h]}" ]; then
            pdnsutil rrset replace "$z" "$h.$z" AAAA 3600 "${WANT[$h]}" >/dev/null && { echo "REPLACED $h.$z AAAA $have -> ${WANT[$h]}"; ZCH=1; } || echo "FAILED to replace $h.$z AAAA"
        else
            echo "OK $h.$z AAAA ${WANT[$h]}"
        fi
    done
    [ "$ZCH" = 1 ] && pdnsutil zone increase-serial "$z" >/dev/null
done
EOF
  )
  printf '%s\n' "$out" | sed 's/^/       /'
  printf '%s\n' "$out" | grep -q '^FAILED' && bad "some AAAA writes failed"
  added=$(printf '%s\n' "$out" | grep -c '^ADDED')
  ok "$(printf '%s\n' "$out" | grep -c '^OK') already right, $added added, $(printf '%s\n' "$out" | grep -c '^REPLACED') replaced, $(printf '%s\n' "$out" | grep -c '^SKIP') skipped"
  if [ "$added" -gt 0 ]; then
    step "[zones] rolling pdns restart (a new record TYPE at an existing name is served only after a restart)"
    rolling_restart
  fi
  zones_check
}

zones_check(){
  local v66 v68 z x n=0 f=0
  v66=$(v6_of "$NS1_V4"); v68=$(v6_of "$NS2_V4")
  step "[zones] every zone's ns1/ns2 AAAA, asked of $NS1_V4 from offsite (IPv4 transport)"
  for z in $(zones); do
    x=$(offsite "dig +short +time=4 +tries=1 AAAA ns1.$z @$NS1_V4; dig +short +time=4 +tries=1 AAAA ns2.$z @$NS1_V4" | paste -sd' ' -)
    n=$((n+1))
    [ "$x" = "$v66 $v68" ] && echo "       ok $z" || { bad "$z: ns1/ns2 AAAA -> '$x'"; f=1; }
  done
  [ "$f" = 0 ] && ok "$n zones answer ns1/ns2 AAAA correctly"
  step "[zones] the same over IPv6 transport, asked of ns1 and ns2 themselves"
  x=$(offsite "dig -6 +short +time=4 +tries=1 AAAA ns1.$PROBE_NAME @$v66; dig -6 +short +time=4 +tries=1 AAAA ns2.$PROBE_NAME @$v68" | paste -sd' ' -)
  [ "$x" = "$v66 $v68" ] && ok "ns1/ns2.$PROBE_NAME AAAA over IPv6 -> $x" || bad "over IPv6: '$x'"
}

# ------------------------------------------------------------------ glue --

glue_probe(){ # $1 = a retired domain with IPv4 glue at its registry
  local d=$1 v66 before after i
  v66=$(v6_of "$NS1_V4"); [ -n "$v66" ] || { bad "no IPv6 recorded for $NS1_V4"; return 1; }
  step "[glue] probe on $d: what the registry holds now"
  before=$(registry_glue "$d"); printf '%s\n' "$before" | sed 's/^/       /'
  printf '%s\n' "$before" | grep -q "^ns1.$d A $NS1_V4" || { bad "$d has no IPv4 glue for ns1 at the registry -- pick another probe domain"; return 1; }
  printf '%s\n' "$before" | grep -q "^ns1.$d AAAA" && { ok "$d already has IPv6 glue for ns1"; return 0; }
  step "[glue] probe: namecheap domains.ns.create $d ns1.$d $v66"
  if nc domains.ns.create "$d" "ns1.$d" "$v66" 2>&1 | sed 's/^/       /'; then
    ok "the API accepted an IPv6 address"
  else
    bad "the API refused the IPv6 glue (expected from the tool's history: 'Parameter IP is Invalid')"
    glue_ticket; return 1
  fi
  step "[glue] probe: what the registry holds afterwards (polling up to 3 min)"
  for i in $(seq 1 9); do
    after=$(registry_glue "$d")
    printf '%s\n' "$after" | grep -q "^ns1.$d AAAA $v66" && break
    sleep 20
  done
  printf '%s\n' "$after" | sed 's/^/       /'
  if printf '%s\n' "$after" | grep -q "^ns1.$d AAAA $v66"; then
    if printf '%s\n' "$after" | grep -q "^ns1.$d A $NS1_V4"; then
      ok "ns1.$d now has A AND AAAA glue at the registry -- the API adds, it does not replace. Proceed with --glue."
    else
      bad "ns1.$d has AAAA but the A glue is GONE -- the API REPLACED it. Putting the IPv4 back with ns.update."
      nc domains.ns.update "$d" "ns1.$d" "$v66" "$NS1_V4" 2>&1 | sed 's/^/       /'
      glue_ticket; return 1
    fi
  else
    warn "the API said yes but the registry does not show the AAAA yet -- check again later: dig +norec @$(tld_server "$d") $d NS"
  fi
}

glue_apply(){
  local v66 v68 d g h want n=0 c=0 s=0
  v66=$(v6_of "$NS1_V4"); v68=$(v6_of "$NS2_V4")
  [ -n "$v66" ] && [ -n "$v68" ] || { bad "no IPv6 recorded in $IPV6_FILE"; return 1; }
  step "[glue] IPv6 glue through the Namecheap API for every domain whose registry holds our IPv4 glue"
  for d in $(zones); do
    g=$(registry_glue "$d") || { warn "$d: cannot read the registry"; continue; }
    printf '%s\n' "$g" | grep -q "^ns1.$d A $NS1_V4" || { echo "       skip $d (no in-bailiwick IPv4 glue at the registry)"; s=$((s+1)); continue; }
    n=$((n+1))
    for h in ns1 ns2; do
      want=$v66; [ "$h" = ns2 ] && want=$v68
      if printf '%s\n' "$g" | grep -q "^$h.$d AAAA $want"; then echo "       ok   $h.$d AAAA already at the registry"; continue; fi
      if nc domains.ns.create "$d" "$h.$d" "$want" >/dev/null 2>&1; then ok "$h.$d -> $want (created)"; c=$((c+1)); sleep 2
      else bad "$h.$d -> $want: the API refused"; fi
    done
  done
  ok "$n domain(s) with glue, $c host record(s) created, $s skipped"
  glue_check
}

glue_check(){
  local v66 v68 d g f=0 n=0
  v66=$(v6_of "$NS1_V4"); v68=$(v6_of "$NS2_V4")
  step "[glue] the registries' glue, asked from offsite (A and AAAA for ns1/ns2 of every domain)"
  for d in $(zones); do
    g=$(registry_glue "$d") || { warn "$d: no answer from its TLD server"; continue; }
    printf '%s\n' "$g" | grep -q "^ns1.$d A " || { echo "       --   $d: no in-bailiwick glue (not ours to publish)"; continue; }
    n=$((n+1))
    if printf '%s\n' "$g" | grep -q "^ns1.$d AAAA $v66" && printf '%s\n' "$g" | grep -q "^ns2.$d AAAA $v68" \
       && printf '%s\n' "$g" | grep -q "^ns1.$d A $NS1_V4" && printf '%s\n' "$g" | grep -q "^ns2.$d A $NS2_V4"; then
      echo "       ok   $d: A + AAAA glue for ns1 and ns2"
    else
      bad "$d glue: $(printf '%s\n' "$g" | paste -sd';' -)"; f=1
    fi
  done
  [ "$f" = 0 ] && [ "$n" -gt 0 ] && ok "$n domain(s) carry full dual-stack glue"
  step "[glue] IPv6-only resolution chain from offsite: dig -6 +trace $PROBE_NAME SOA"
  offsite "dig -6 +trace +time=5 +tries=1 $PROBE_NAME SOA 2>&1" | grep -E "^(;; Received .* from .*#53\(|$PROBE_NAME\.\s+[0-9]+\s+IN\s+SOA)" | tail -3 | sed 's/^/       /'
  offsite "dig -6 +trace +time=5 +tries=1 $PROBE_NAME SOA 2>&1" | grep -qE "^$PROBE_NAME\.\s+[0-9]+\s+IN\s+SOA" && ok "the trace reaches our SOA over IPv6 only" || warn "the IPv6-only trace did not end at our SOA (glue not yet visible?)"
}

glue_ticket(){
  local v66 v68 d g
  v66=$(v6_of "$NS1_V4"); v68=$(v6_of "$NS2_V4")
  step "[glue] fallback: the support ticket for Namecheap (the API does not take IPv6 glue)"
  cat <<TICKET
       Subject: IPv6 glue (AAAA) for our personal nameservers

       Hello, please add IPv6 addresses to the personal nameservers registered under
       our account, keeping the existing IPv4 addresses. For every domain below:
         ns1.<domain>  add  $v66   (keep 23.116.91.66)
         ns2.<domain>  add  $v68   (keep 23.116.91.68)
       Domains:
TICKET
  for d in $(zones); do
    g=$(registry_glue "$d") || continue
    printf '%s\n' "$g" | grep -q "^ns1.$d A $NS1_V4" && echo "         $d"
  done
  echo
}

# ------------------------------------------------------------------- web --

web_apply(){
  local names n v4 v6 code f=0 total=0
  [ -s "$IPV6_FILE" ] || { bad "no $IPV6_FILE -- run --edges first"; return 1; }
  names=$(web_names); [ -n "$names" ] || { bad "no Lua-steered web names found"; return 1; }
  step "[web] every web name answers over IPv6 on every edge (offsite, curl -6 --resolve), BEFORE any AAAA is published"
  while read -r v4 v6; do
    case "$v4" in ''|'#'*) continue ;; esac
    for n in $names; do
      total=$((total+1))
      code=$(offsite "curl -6 -s -o /dev/null -w '%{http_code}' -m 15 --resolve '$n:443:[$v6]' https://$n/")
      case "$code" in
        000|"") bad "$n on $v6 ($v4): no TLS answer over IPv6"; f=1 ;;
        *) echo "       ok   $n on $v4 -> $code" ;;
      esac
    done
  done < "$IPV6_FILE"
  [ "$f" = 0 ] && ok "$total name/edge pairs served over IPv6" || { bad "some names do not answer over IPv6 -- not publishing AAAA"; return 1; }
  step "[web] Lua AAAA records next to the Lua A records (dns-lua-orchestrate.sh --apply, IPv6 on via $IPV6_FILE)"
  "$LUA" --apply || bad "dns-lua-orchestrate.sh --apply reported a problem"
  web_check
}

web_check(){
  local names n v6 x f=0
  v6=$(v6_of "$NS1_V4")
  names=$(web_names)
  step "[web] AAAA for every web name, asked of ns1 over IPv6 from offsite (authoritative, no resolver cache)"
  for n in $names; do
    x=$(offsite "dig -6 +short +time=4 +tries=1 AAAA $n @$v6" | tr '\n' ' ')
    [[ "$x" == *:23:116:91:6* ]] && echo "       ok   $n -> $x" || { bad "$n AAAA -> '$x'"; f=1; }
  done
  [ "$f" = 0 ] && ok "$(printf '%s\n' $names | wc -l) web names answer AAAA"
  x=$(offsite "dig +short +time=4 +tries=1 AAAA mail.$PROBE_NAME @$NS1_V4"); [ -z "$x" ] && ok "mail.$PROBE_NAME has no AAAA (mail stays IPv4)" || bad "mail.$PROBE_NAME answers AAAA '$x'"
  step "[web] through a public resolver (negative answers for AAAA cache up to 1 h after publication)"
  for n in $PROBE_NAME myaccount.$PROBE_NAME; do
    x=$(offsite "curl -6 -s -o /dev/null -w '%{http_code} %{remote_ip}' -m 15 https://$n/")
    case "$x" in 200*|301*|302*) ok "https://$n/ over IPv6 via offsite's resolver -> $x" ;; *) warn "https://$n/ over IPv6 via the resolver -> '$x' (resolver cache? retry in an hour)" ;; esac
  done
}

# ------------------------------------------------------------------ ns03 --

ns03_apply(){
  local out rc a p60
  step "[ns03] firewall (ICMPv6 in), IPv6 on eth5 (VLAN 60, token ::10:60:0:140), recursor on :: with IPv6 upstream -- ONE restart"
  out=$(ssh -o ConnectTimeout=10 "$NS03" "sudo bash -s -- '$ICMP6_IN'" <<'EOF'
set -uo pipefail
IN=$1; TOKEN=10:60:0:140; NIC=eth5
STAMP=$(date +%Y%m%d-%H%M%S); CHANGED=0
F=/etc/nftables.conf

# 1. firewall: live first (insert at the top of input), then the file
if nft list chain inet filter input | grep -q 'icmpv6 type'; then echo "live input chain already accepts ICMPv6"
else nft insert rule inet filter input $IN || { echo "nft insert rule failed"; exit 7; }; echo "live input chain: ICMPv6 accepted"; CHANGED=1; fi
if grep -q 'icmpv6 type' "$F"; then echo "nftables.conf already has the ICMPv6 rule"
else
    cp -a "$F" "/root/nftables.conf.before-ipv6-$STAMP"
    sed -i -E "0,/^([[:space:]]*)(iifname \"?lo\"? accept)\$/s//\1\2\n\1$IN/" "$F"
    grep -q 'icmpv6 type' "$F" || { echo "anchor 'iifname lo accept' not found in $F -- restoring"; cp -a "/root/nftables.conf.before-ipv6-$STAMP" "$F"; exit 5; }
    nft -c -f "$F" || { echo "$F does not parse after the edit -- restoring"; cp -a "/root/nftables.conf.before-ipv6-$STAMP" "$F"; exit 6; }
    echo "nftables.conf: ICMPv6 accepted in input (copy: /root/nftables.conf.before-ipv6-$STAMP)"; CHANGED=1
fi

# 2. the address on VLAN 60 (pfsense's RA: SLAAC only, no DHCPv6 there)
D=/etc/systemd/network/$NIC.network.d; mkdir -p "$D"; C=$D/20-homelab-ipv6.conf
WANT=$(cat <<CONF
# Managed by install-orchestrators/dns-ipv6-orchestrate.sh (post-cutover #64).
# PVE rewrites $NIC.network on every boot with IPv6AcceptRA=false; this drop-in
# wins. ns03's one global IPv6, on VLAN 60 (the VLAN with IPv6): pfsense's
# advertised prefix plus the fixed token <prefix>:$TOKEN. The default route
# from the RA is wanted: it is how the recursor reaches IPv6-only nameservers.
[Network]
IPv6AcceptRA=yes
IPv6PrivacyExtensions=no
[IPv6AcceptRA]
Token=static:::$TOKEN
DHCPv6Client=no
UseDNS=no
UseDomains=no
UseGateway=yes
CONF
)
if [ -f "$C" ] && [ "$(cat "$C")" = "$WANT" ]; then echo "drop-in $C already in place"
else printf '%s\n' "$WANT" > "$C"; chmod 0644 "$C"; echo "drop-in $C written"; CHANGED=1; networkctl reload || { echo "networkctl reload failed"; exit 9; }; fi
A=""
for i in $(seq 1 15); do A=$(ip -6 -o addr show dev "$NIC" scope global -tentative 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -- ":$TOKEN\$" | head -1); [ -n "$A" ] && break; sleep 2; done
if [ -z "$A" ]; then networkctl reconfigure "$NIC"; for i in $(seq 1 20); do A=$(ip -6 -o addr show dev "$NIC" scope global -tentative 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -- ":$TOKEN\$" | head -1); [ -n "$A" ] && break; sleep 2; done; fi
[ -n "$A" ] || { echo "no IPv6 with token $TOKEN on $NIC"; ip -6 addr show dev "$NIC"; exit 10; }
echo "ADDRESS: $A"
ip -6 route show default | grep -q default && echo "default route: $(ip -6 route show default | head -1)" || { echo "no IPv6 default route"; exit 11; }
ping -6 -c 2 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "IPv6 egress works (ping 2001:4860:4860::8888)" || { echo "NO IPv6 egress from ns03 (pfsense/gateway) -- not touching the recursor"; exit 13; }
P60=$(python3 -c 'import ipaddress,sys; print(ipaddress.IPv6Network((sys.argv[1], 60), strict=False))' "$A")
echo "PREFIX60: $P60"

# 3. the recursor: bind :: as well, allow the house's IPv6, query upstream over IPv6 too
RC=/etc/powerdns/recursor.conf
cp -a "$RC" "$RC.bak-$STAMP"
RCH=0
grep -qE '^local-address=.*(^|,)::(,|$)' "$RC" || { sed -i -E 's/^(local-address=.*)$/\1,::/' "$RC"; RCH=1; }
for net in "::1/128" "fe80::/10" "fc00::/7" "$P60"; do
    grep -qF -- "$net" "$RC" || { sed -i -E "s|^(allow-from=.*)\$|\1, $net|" "$RC"; RCH=1; }
done
# an older house prefix left in allow-from (a prefix change) is removed
for old in $(grep -oE '2[0-9a-f]{3}(:[0-9a-f]{0,4}){1,7}/60' "$RC" | sort -u); do
    [ "$old" = "$P60" ] || { sed -i -E "s|, ${old}||" "$RC"; echo "removed old prefix $old from allow-from"; RCH=1; }
done
if grep -q '^query-local-address=' "$RC"; then
    grep -qE '^query-local-address=.*::' "$RC" || { sed -i -E 's/^(query-local-address=.*)$/\1, ::/' "$RC"; RCH=1; }
else
    printf '\n# post-cutover #64: ask the internet over IPv6 too (the kernel picks the source)\nquery-local-address=0.0.0.0, ::\n' >> "$RC"; RCH=1
fi
grep -E '^(local-address|allow-from|query-local-address)=' "$RC"
if [ "$RCH" = 1 ]; then
    CHANGED=1
    systemctl restart pdns-recursor; sleep 3
    if systemctl is-active --quiet pdns-recursor && ss -lnup | grep -q '\[::\]:53 '; then
        echo "recursor restarted: listening on [::]:53 too"
    else
        echo "RECURSOR DID NOT COME BACK ON :: -- restoring $RC.bak-$STAMP"
        cp -a "$RC.bak-$STAMP" "$RC"; systemctl restart pdns-recursor; sleep 2; systemctl is-active pdns-recursor
        exit 14
    fi
else
    rm -f "$RC.bak-$STAMP"; echo "recursor.conf already had all of it (no restart)"
fi
echo "listeners: $(ss -lnup | awk '$5 ~ /:53$/ {print $5}' | sort -u | tr '\n' ' ')"
[ "$CHANGED" = 1 ] && echo "RESULT: changed" || echo "RESULT: already there"
EOF
  )
  rc=$?
  printf '%s\n' "$out" | sed 's/^/       /'
  [ $rc -eq 0 ] || { bad "ns03: remote step exited $rc"; return 1; }
  a=$(printf '%s\n' "$out" | sed -n 's/^ADDRESS: //p' | head -1)
  p60=$(printf '%s\n' "$out" | sed -n 's/^PREFIX60: //p' | head -1)
  ok "ns03 IPv6 $a (house prefix $p60)"
  ns03_check
  echo
  echo "  ${Y}Gardner's step:${O} pfsense > Services > Router Advertisement (V60_HOME / opt5) > DNS servers = $a"
  echo "  so VLAN 60 clients learn the resolver over IPv6 (RDNSS). Check here afterwards: resolvectl dns bond0.60"
}

ns03_check(){
  local a x b1 b2
  a=$(rssh "$NS03" 'ip -6 -o addr show dev eth5 scope global -tentative' | awk '{print $4}' | cut -d/ -f1 | grep ':10:60:0:140$' | head -1)
  [ -n "$a" ] && ok "ns03 eth5 IPv6 $a" || { bad "ns03 has no IPv6 with token ::10:60:0:140 on eth5"; return; }
  rssh "$NS03" 'ip -6 route show default' | grep -q default && ok "ns03 IPv6 default route" || bad "ns03 no IPv6 default route"
  rssh "$NS03" 'sudo -n nft list chain inet filter input' | grep -q 'icmpv6 type' && ok "ns03 firewall accepts ICMPv6" || bad "ns03 firewall lacks the ICMPv6 rule"
  rssh "$NS03" 'sudo -n grep -q "icmpv6 type" /etc/nftables.conf' && ok "ns03 /etc/nftables.conf has the rule" || bad "ns03 /etc/nftables.conf lacks the rule"
  [ "$(rssh "$NS03" 'systemctl is-active pdns-recursor')" = active ] && ok "ns03 pdns-recursor active" || bad "ns03 pdns-recursor not active"
  rssh "$NS03" 'sudo -n ss -lnup' | grep -q '\[::\]:53 ' && ok "ns03 recursor listens on [::]:53" || bad "ns03 recursor does not listen on [::]:53"
  x=$(rssh "$NS03" 'grep -E "^allow-from=" /etc/powerdns/recursor.conf'); [[ "$x" == *"$(python3 -c 'import ipaddress,sys; print(ipaddress.IPv6Network((sys.argv[1], 60), strict=False))' "$a")"* ]] && ok "ns03 allow-from has the current house /60" || bad "ns03 allow-from lacks the current /60: $x"
  rssh "$NS03" 'grep -qE "^query-local-address=.*::" /etc/powerdns/recursor.conf' && ok "ns03 queries upstream over IPv6 too" || bad "ns03 query-local-address lacks ::"
  x=$(dig +short +time=4 +tries=1 @"$a" google.com A 2>/dev/null | head -1); [ -n "$x" ] && ok "this workstation (VLAN 60) resolves google.com through [$a] -> $x" || bad "no answer from ns03 over IPv6 ([$a])"
  x=$(dig +short +time=4 +tries=1 @"$a" ns1.mailmasker.org AAAA 2>/dev/null | head -1); [ -n "$x" ] && ok "ns03 over IPv6 resolves ns1.mailmasker.org AAAA -> $x" || warn "ns03 over IPv6 gave no AAAA for ns1.mailmasker.org"
  b1=$(rssh "$NS03" 'sudo -n rec_control get ipv6-outqueries'); dig +short @"$a" ipv6.google.com AAAA >/dev/null 2>&1; dig +short @"$a" www.wikipedia.org AAAA >/dev/null 2>&1; sleep 1
  b2=$(rssh "$NS03" 'sudo -n rec_control get ipv6-outqueries')
  [ "${b2:-0}" -gt "${b1:-0}" ] 2>/dev/null && ok "ns03 sent upstream queries over IPv6 ($b1 -> $b2)" || warn "ipv6-outqueries did not move yet ($b1 -> $b2); the recursor prefers nameservers it already knows as fast"
}

# ---------------------------------------------------------------- verify --

verify(){
  local n x
  step "verify: edges"
  for n in $EDGE_NODES; do edge_checks "$n"; done
  zones_check
  glue_check
  web_check
  step "verify: ns03"
  if rssh "$NS03" 'test -f /etc/systemd/network/eth5.network.d/20-homelab-ipv6.conf'; then ns03_check; else warn "ns03 not done yet (--ns03)"; fi
  step "verify: IPv6 queries are arriving at dnsdist (Prometheus on $METRICS, last hour)"
  x=$(rssh "$METRICS" "curl -s 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=sum by (host) (increase(dnsdist_frontend_queries{frontend=~\"\\\\[.*\\\\]:53\"}[1h]))'" \
       | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(r["metric"].get("host","?"), int(float(r["value"][1]))) for r in d["data"]["result"]]' 2>/dev/null)
  [ -n "$x" ] && printf '%s\n' "$x" | sed 's/^/       /' || warn "no IPv6 frontend series yet (dnsdist not restarted with [::]:53, or no scrape yet)"
  printf '%s\n' "$x" | awk '$2 > 0' | grep -q . && ok "IPv6 DNS queries are being served" || warn "zero IPv6 queries in the last hour (expected until the AAAA/glue are out and resolvers find them)"
}

# -------------------------------------------------------- prefix changed --

prefix_changed(){
  local n nic v4 tok v6 old
  step "[prefix] what the edges hold now"
  for n in $EDGE_NODES; do
    read -r nic v4 <<<"$(edge_pub "$n")"; [ -n "$nic" ] || { bad "$n no public IPv4"; continue; }
    tok=$(token_of "$v4"); v6=$(edge_live_v6 "$n" "$nic" "$tok")
    [ -n "$v6" ] || { bad "$n has no IPv6 with token ::$tok (RA not received?)"; continue; }
    old=$(v6_of "$v4")
    [ "$old" = "$v6" ] && ok "$n unchanged: $v6" || { warn "$n $old -> $v6"; record_v6 "$v4" "$v6"; }
  done
  zones_apply
  step "[prefix] the Lua AAAA maps"
  "$LUA" --apply || bad "dns-lua-orchestrate.sh --apply reported a problem"
  step "[prefix] ns03 allow-from (and its own address follows the RA by itself)"
  ns03_apply
  step "[prefix] what cannot be done from here"
  echo "  1. Registry glue: for every domain, namecheap domains.ns.update <domain> ns1.<domain> <old v6> <new v6> (and ns2),"
  echo "     if the API took IPv6 at --glue; otherwise the ticket below. The old addresses are in git history of $IPV6_FILE."
  echo "  2. bad-ips never-block: NEVER_BLOCK in github-repos/homelab/badips-site.conf carries the house /60; put the new one"
  echo "     there and run ./badips-orchestrate.sh --fleet-conf (then ... --fleet-conf jumper)."
  glue_ticket
}

# ------------------------------------------------------------------- run --

case "$MODE" in
  preflight) preflight ;;
  edges) edges_deploy ;;
  check) edges_check ;;
  zones) zones_apply ;;
  glue) if [ -n "$PROBE" ]; then glue_probe "$PROBE"; else glue_apply; fi ;;
  web) web_apply ;;
  ns03) ns03_apply ;;
  verify) verify ;;
  prefix-changed) prefix_changed ;;
esac

echo
if [ "$FAILS" = 0 ]; then echo "${G}$MODE: all checks passed${O}"; else echo "${R}$MODE: $FAILS check(s) FAILED${O}"; fi
echo "log: $LOG"
exit "$FAILS"
