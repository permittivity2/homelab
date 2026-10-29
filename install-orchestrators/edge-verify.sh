#!/bin/bash
# ============================================================================
# Verify ONE internet edge node is actually serving. Read-only.
#
#   ./edge-verify.sh 01
#
# WHY IT CHECKS FROM OUTSIDE. The edge is the only tier where "the service is
# running" and "the internet can reach it" are different facts. The public
# .66/.68 arrive by DHCP from AT&T reservations keyed to the edge NIC MACs, and
# only one of 00/01/02 is ever powered on -- so a swap can leave a node with
# every unit active and no public address, or an address that pfSense-routed
# clients still ARP to the previous node. Local checks cannot see any of that,
# so the external half runs from `offsite` (off-network VM, curl/openssl, no
# browser) by PUBLIC HOSTNAME -- which exercises DNS, the address, and the
# service in one go, the way a real user does.
#
# Exits non-zero if anything that should work does not.
# ============================================================================
set -uo pipefail

NN=$(printf '%02d' "$((10#${1:?usage: edge-verify.sh <00|01|02>}))")
CTID=$((400 + 10#$NN))
MGMT=10.20.2.$((144 + 10#$NN))
PVE=10.20.1.8

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
PASS=0; FAIL=0; WARN=0
ok(){   PASS=$((PASS+1)); echo "  ${G}ok${O}   $*"; }
bad(){  FAIL=$((FAIL+1)); echo "  ${R}FAIL${O} $*"; }
warn(){ WARN=$((WARN+1)); echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }

step "exactly one edge is running, and it is prod-homelab$NN"
RUNNING=$(ssh -o ConnectTimeout=8 "$PVE" "sudo pct list" 2>/dev/null \
    | awk '$1 ~ /^(400|401|402)$/ && $2 == "running" {print $1}' | paste -sd, -)
[ "$RUNNING" = "$CTID" ] && ok "pct $CTID running, and it is the only edge up" \
    || bad "expected only $CTID running, got '${RUNNING:-none}' -- two edges up means a public IP conflict"

step "the node itself"
if timeout 6 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null; then
    ok "answers on :22 ($MGMT)"
else
    bad "not answering on :22 ($MGMT) -- nothing below can run"
    echo; echo "  $PASS passed, $FAIL failed"; exit 1
fi

PUB=$(ssh -o ConnectTimeout=8 "$MGMT" 'ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1 | grep -E "^23\." | sort | paste -sd, -' 2>/dev/null)
case "$PUB" in
    *23.116.91.66*) ok "holds the public addresses ($PUB)" ;;
    "")             bad "holds NO public address -- the DHCP reservation has not landed yet" ;;
    *)              warn "public addresses are '$PUB' (expected to include .66)" ;;
esac

step "services"
for u in nginx haproxy dnsdist homelab-agent; do
    if ssh -o ConnectTimeout=6 "$MGMT" "systemctl is-active --quiet $u" 2>/dev/null; then ok "$u active"
    else bad "$u NOT active"; fi
done
ssh -o ConnectTimeout=6 "$MGMT" 'sudo nginx -t' >/dev/null 2>&1 && ok "nginx config valid" || bad "nginx config does NOT validate"
ssh -o ConnectTimeout=6 "$MGMT" 'sudo haproxy -c -f /etc/haproxy/haproxy.cfg' >/dev/null 2>&1 && ok "haproxy config valid" || bad "haproxy config does NOT validate"

step "the agent can authenticate"
# A node parked for weeks can come back with a refresh token past its 30-day
# life, which no amount of restarting fixes -- agent-reenroll.sh is the repair.
ST=$(ssh -o ConnectTimeout=8 "$MGMT" '
    T=$(sudo grep "^token:" /etc/homelab/agent/credential.yml 2>/dev/null | sed "s/^token:[[:space:]]*//")
    [ -z "$T" ] && { echo "no-credential"; exit 0; }
    curl -s --max-time 8 -H "Authorization: Bearer $T" \
        http://10.50.2.132:3000/api/v1/auth/introspect \
      | grep -oE "system_agent|\"error\":\"[^\"]*\"" | head -1' 2>/dev/null)
[ "$ST" = "system_agent" ] && ok "introspects as system_agent" \
    || bad "agent state is '${ST:-unreachable}' -- run agent-reenroll.sh $NN"

step "certificates are present and current"
ssh -o ConnectTimeout=8 "$MGMT" '
  n=0; soon=0
  for d in /etc/letsencrypt/live/*/; do
    [ -f "$d/fullchain.pem" ] || continue
    n=$((n+1))
    e=$(date -d "$(openssl x509 -enddate -noout -in "$d/fullchain.pem" | cut -d= -f2)" +%s)
    [ $(( (e - $(date +%s)) / 86400 )) -lt 14 ] && soon=$((soon+1))
  done
  echo "$n $soon"' 2>/dev/null | {
    read -r n soon
    [ "${n:-0}" -gt 0 ] && ok "$n certificate lineage(s) installed" || bad "NO certificates installed -- TLS will fail"
    [ "${soon:-0}" = 0 ] && ok "none expiring inside 14 days" || warn "$soon lineage(s) expire within 14 days"
}

step "from OUTSIDE the network (offsite), by public hostname"
if ! timeout 10 ssh -o ConnectTimeout=6 offsite true 2>/dev/null; then
    warn "offsite is not reachable -- skipping the external half (the half that matters)"
else
    # Each probe hits a path the app actually routes, so the check proves the
    # APP answered rather than just that nginx is listening. invite has no
    # route for "/" (nginx proxies it and Mojolicious 404s), while
    # /setup/mail without a token is a deliberate 410 Gone -- so 410 here is
    # a pass, and a 404 would mean nginx never reached the app.
    probe_http(){ # $1 url  $2 space-separated acceptable codes
        local code
        code=$(timeout 25 ssh -o ConnectTimeout=6 offsite \
            "curl -s -o /dev/null -w '%{http_code}' -m 15 '$1'" 2>/dev/null)
        case " $2 " in
            *" $code "*) ok "$1 -> $code" ;;
            *)
                case "$code" in
                    000|"") bad "$1 unreachable from the internet" ;;
                    *)      bad "$1 -> $code (expected one of: $2)" ;;
                esac ;;
        esac
    }
    probe_http https://myaccount.mailmasker.org/        "200 301 302"
    probe_http https://invite.mailmasker.org/setup/mail "410"
    probe_http https://static.mailmasker.org/           "200 301 302"
    probe_http https://mailmasker.org/                  "200 301 302"
    # Mail ingress: haproxy binds *:25/587/143/993 on this node.
    #
    # :25 CANNOT be probed from offsite -- its provider blocks outbound port 25
    # (verified: it cannot reach gmail-smtp-in.l.google.com:25 either), which is
    # normal for a VPS. The obvious workaround, probing the public address from
    # this workstation, is WORSE: that path crosses pfSense, which keeps an ARP
    # entry for the previous edge node's MAC after a swap, so every public port
    # looks dead from here for a while -- :443 included, while the internet is
    # being served perfectly. That false alarm fired on both prod-homelab01 and
    # prod-homelab02 on 2026-10-29 and cost more time than it saved.
    #
    # So :25 is established from three facts that do not cross pfSense, plus
    # corroboration when the internet happens to supply it:
    #   a) haproxy is bound to 0.0.0.0:25
    #   b) the live nftables ruleset accepts dport 25 in the SAME rule as 587
    #      and 993 -- and those two ARE confirmed reachable from the internet
    #      just below, so that rule demonstrably admits internet traffic
    #   c) :25 answers a real ESMTP banner on the service plane
    # and (d) any genuine internet sender seen in haproxy's own smtp_in log.
    ssh -o ConnectTimeout=6 "$MGMT" 'sudo ss -lnt 2>/dev/null | grep -q "0.0.0.0:25"' 2>/dev/null \
        && ok "haproxy is bound to 0.0.0.0:25" || bad "nothing is listening on 0.0.0.0:25"

    NFT25=$(ssh -o ConnectTimeout=6 "$MGMT" 'sudo nft list chain inet filter input 2>/dev/null | grep -E "dport \{[^}]*\b25\b[^}]*\}.*accept"' 2>/dev/null)
    if printf '%s' "$NFT25" | grep -q 587 && printf '%s' "$NFT25" | grep -q 993; then
        ok "the firewall admits :25 in the same accept as :587/:993 (both internet-verified below)"
    elif [ -n "$NFT25" ]; then
        ok "the firewall admits :25"
    else
        bad "no input rule accepts dport 25 -- inbound mail is firewalled off"
    fi

    banner=$(timeout 12 bash -c "exec 3<>/dev/tcp/10.50.2.$((144 + 10#$NN))/25; head -1 <&3" 2>/dev/null)
    printf '%s' "$banner" | grep -qi esmtp \
        && ok "SMTP :25 answers on the service plane ($(printf '%s' "$banner" | head -c 44)...)" \
        || bad "SMTP :25 gave no ESMTP banner on the service plane -- inbound mail is DOWN"

    EXT=$(ssh -o ConnectTimeout=8 "$MGMT" 'sudo journalctl -u haproxy --since "-30min" --no-pager 2>/dev/null \
        | grep smtp_in | sed "s/.*haproxy\[[0-9]*\]: //" | awk "{print \$1}" | cut -d: -f1 \
        | grep -vE "^(10\.|127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168\.)" | sort -u | head -3' 2>/dev/null)
    [ -n "$EXT" ] && ok "real internet senders have reached :25 through this node ($(printf '%s' "$EXT" | paste -sd, -))" \
        || echo "      ${D}(no internet sender on :25 in the last 30min -- normal on a quiet node, not a failure)${O}"

    # The IMAP greeting arrives AFTER the TLS handshake, so stdin must stay open
    # long enough to read it; </dev/null closes first and reports a false
    # failure on a working server.
    imap=$(timeout 30 ssh -o ConnectTimeout=6 offsite \
        "timeout 12 bash -c '(printf \"a1 LOGOUT\r\n\"; sleep 3) | openssl s_client -quiet -connect mail.mailmasker.org:993 -servername mail.mailmasker.org 2>/dev/null | head -1'" 2>/dev/null)
    printf '%s' "$imap" | grep -q '^\* OK' \
        && ok "IMAPS :993 answers ($(printf '%s' "$imap" | head -c 40)...)" \
        || bad "IMAPS :993 did not answer -- mail clients are DOWN"

    sub=$(timeout 20 ssh -o ConnectTimeout=6 offsite \
        "timeout 10 bash -c 'exec 3<>/dev/tcp/mail.mailmasker.org/587; head -1 <&3'" 2>/dev/null)
    printf '%s' "$sub" | grep -qi esmtp && ok "submission :587 answers from the internet" \
        || bad "submission :587 gave no banner -- sending is DOWN"
fi

step "result for prod-homelab$NN"
echo "  $PASS passed, $FAIL failed, $WARN warning(s)"
if [ "$FAIL" = 0 ]; then echo "  ${G}prod-homelab$NN is serving.${O}"
else echo "  ${R}prod-homelab$NN is NOT fully serving -- do not swap away from it.${O}"; fi
exit "$FAIL"
