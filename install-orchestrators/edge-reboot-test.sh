#!/usr/bin/env bash
# edge-reboot-test.sh NN -- reboot ONE edge (from inside its container, no pct)
# and prove the three-live setup rides through it (post-cutover item 44).
#
#   ./edge-reboot-test.sh 02     # then 01, then 00 (00 last: it normally holds .140)
#
# From `ssh offsite` it requests real site names with curl --resolve (which
# pins HOST:443 to one edge address while keeping the Host header and TLS name
# correct), BEFORE, DURING and AFTER the reboot:
#   before  every site answers on all three addresses
#   during  the other two edges keep answering; DNS stops handing out the
#           rebooting edge's address (ifportup health check)
#   after   it answers again on its own address; exactly one edge holds
#           10.50.2.140; keepalived, haproxy, dnsdist and nginx are active;
#           the node holds exactly its own public address
set -uo pipefail
N=${1:-}; HERE="$(cd "$(dirname "$0")" && pwd)"
declare -A SSH_IP=([00]=10.20.2.144 [01]=10.20.2.145 [02]=10.20.2.146)
declare -A PUB=([00]=23.116.91.66 [01]=23.116.91.67 [02]=23.116.91.68)
[ -n "${SSH_IP[$N]:-}" ] || { echo "usage: $0 00|01|02"; exit 1; }
H=${SSH_IP[$N]}; ME=${PUB[$N]}
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILED=1; }
step() { printf '\n=== %s ===\n' "$*"; }
FAILED=0

# a handful of different vhosts, taken from the edge's own site list
SITES=$(ssh -n "$H" "sudo grep -E '^[[:space:]]+- domain:' /etc/homelab/webproxy/sites.yml | awk '{print \$3}'" | grep -vE '^\*' | head -40)
PICK=$(printf '%s\n' "$SITES" | awk 'NR%3==1' | head -6 | tr '\n' ' ')
echo "sites tested: $PICK"

# code <site> <ip>  -> HTTP status from offsite ("000" = no answer)
code() { ssh -n -o ConnectTimeout=8 offsite "curl -s -o /dev/null -m 8 -w '%{http_code}' --resolve $1:443:$2 https://$1/" 2>/dev/null; }
sweep() {   # ip -> "good bad"
    local ip=$1 s c g=0 b=0
    for s in $PICK; do c=$(code "$s" "$ip"); case "$c" in 2??|3??|401|403|404) g=$((g+1)) ;; *) b=$((b+1)); echo "    $s @$ip -> $c" ;; esac; done
    echo "$g $b"
}
holders() { local m c=0; for m in 00 01 02; do ssh -n -o ConnectTimeout=8 "${SSH_IP[$m]}" "ip -4 -o addr show dev eth4 | grep -q ' 10.50.2.140/'" 2>/dev/null && { echo "  $m holds 10.50.2.140"; c=$((c+1)); }; done; [ "$c" -eq 1 ] && ok "exactly one edge holds 10.50.2.140" || bad "$c edges hold 10.50.2.140"; }

step "before: every site on all three addresses (curl --resolve from offsite)"
for m in 00 01 02; do r=$(sweep "${PUB[$m]}" | tail -1); set -- $r; [ "$2" = 0 ] && ok "${PUB[$m]}: $1/$1 sites answer" || bad "${PUB[$m]}: $2 site(s) failed"; done
holders

step "reboot prod-homelab$N from inside ($H)"
ssh -n "$H" 'sudo systemctl reboot' >/dev/null 2>&1 || true
T0=$(date +%s)

step "during: the other edges keep serving; DNS drops $ME"
sleep 3
for m in 00 01 02; do [ "$m" = "$N" ] && continue
    r=$(sweep "${PUB[$m]}" | tail -1); set -- $r; [ "$2" = 0 ] && ok "${PUB[$m]} still answers ($1/$1)" || bad "${PUB[$m]}: $2 failed during the reboot"
done
NSD=23.116.91.66; [ "$ME" = 23.116.91.66 ] && NSD=23.116.91.68   # ask the nameserver that is NOT rebooting
echo "  during the reboot .140 is held by:"; sleep 4; holders
DROPPED=0
for i in 1 2 3 4 5 6; do
    ans=$(ssh -n offsite "dig +short +time=3 +tries=1 A $(printf '%s' "$PICK" | awk '{print $1}') @$NSD" 2>/dev/null | tr '\n' ' ')
    case " $ans " in *" $ME "*) sleep 5 ;; *) DROPPED=1; break ;; esac
done
[ "$DROPPED" = 1 ] && ok "DNS stopped returning $ME while it was down (answer: $ans)" \
    || echo "  note DNS still listed $ME (the node may have come back before the health check noticed; answer: $ans)"

step "wait for $ME to answer HTTPS again"
UP=0
for i in $(seq 1 60); do
    c=$(code "$(printf '%s' "$PICK" | awk '{print $1}')" "$ME")
    case "$c" in 2??|3??|401|403|404) UP=1; break ;; esac
    sleep 5
done
[ "$UP" = 1 ] && ok "$ME answers again $(( $(date +%s) - T0 )) s after the reboot command" || { bad "$ME did not answer within 5 minutes"; exit 1; }
sleep 20   # let keepalived, certsync and the agent settle

step "after: all sites on $ME, node state, .140"
r=$(sweep "$ME" | tail -1); set -- $r; [ "$2" = 0 ] && ok "$ME: $1/$1 sites answer" || bad "$ME: $2 site(s) failed"
ssh -n "$H" 'for s in keepalived haproxy dnsdist nginx; do printf "%s=%s " $s "$(systemctl is-active $s)"; done; echo; ip -4 -o addr show scope global | awk "{print \$2, \$4}" | tr "\n" ";"; echo; uptime -p' 2>/dev/null | sed 's/^/  /'
svc=$(ssh -n "$H" 'for s in keepalived haproxy dnsdist nginx; do systemctl is-active $s; done | grep -vc "^active$"' 2>/dev/null)
[ "$svc" = 0 ] && ok "keepalived, haproxy, dnsdist, nginx all active" || bad "$svc service(s) not active"
n23=$(ssh -n "$H" "ip -4 -o addr show scope global | grep -c ' 23\.116\.91\.'" 2>/dev/null)
mine=$(ssh -n "$H" "ip -4 -o addr show scope global | grep -c ' $ME/'" 2>/dev/null)
[ "$n23" = 1 ] && [ "$mine" = 1 ] && ok "holds exactly its own public address $ME" || bad "public addresses wrong (count $n23, own $mine)"
holders
r=$(ssh -n jumper "timeout 10 bash -c 'exec 3<>/dev/tcp/$ME/25; head -n1 <&3'" 2>/dev/null | head -1)
case "$r" in 220*) ok "SMTP banner on $ME:25 from jumper: ${r%$'\r'}" ;; *) bad "no SMTP banner on $ME:25 (got '$r')" ;; esac
for ns in 66 68; do
    a=$(ssh -n offsite "dig +short +time=3 +tries=2 A ns1.mailmasker.org @23.116.91.$ns" 2>/dev/null)
    [ -n "$a" ] && ok "DNS answers on .$ns" || bad "no DNS answer on .$ns"
done
echo; echo "Full per-node check: $HERE/edge-verify.sh $N"
[ "$FAILED" = 0 ] && echo "REBOOT TEST PASSED for prod-homelab$N" || { echo "REBOOT TEST FAILED for prod-homelab$N"; exit 1; }
