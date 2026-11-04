#!/bin/bash
# ============================================================================
# Put developer.mailmasker.org (homelab-developer, post-cutover item 49) on
# the internet: the package on prod-homelab45, the DNS name, its certificate,
# and the vhost on the edge -- the live node now, the parked ones through
# edge-standby-sync.sh.
#
#   ./developer-site-provision.sh --dry-run
#   ./developer-site-provision.sh
#   ./developer-site-provision.sh --verify
#
# Safe to re-run: every step checks first and skips what is already done.
#
# ORDER MATTERS (the same as search-vhost-provision.sh):
#   package on 45 (the site exists before anything points at it)
#   -> DNS (DNS-01 issuance needs the name to resolve)
#   -> issue + publish + certsync (the edge must HOLD the cert)
#   -> vhost + apply-sites (which configures HTTPS against that cert)
# A vhost added before its certificate is awkward to repair in place:
# apply-sites skips a vhost that already has HTTPS configured.
#
# The site is plain files served by nginx on 45, beside the apt repository
# and the other static sites there; homelab-developer's postinst reloads
# nginx only after `nginx -t` passes, so a bad config can't take them down.
#
# ONLY ONE EDGE NODE IS EVER POWERED ON. This configures whichever is up;
# edge-standby-sync.sh then adds the same site and lineage to the parked
# ones' files (they materialise on that node's next boot).
#
# NEVER JUDGE THE EDGE FROM THE ADMIN WORKSTATION (pfSense's ARP cache makes
# a healthy edge look dead from inside). Every public check runs from
# `ssh offsite`.
# ============================================================================
set -uo pipefail

NAME=developer.mailmasker.org
HOST=10.20.2.189                         # prod-homelab45, the static-site host
UPSTREAM=10.50.2.189:80                  # ... its service-plane address
PUBLIC_IP=23.116.91.66
DNS_NODE=10.20.2.147                     # prod-homelab03, PowerDNS (native zone, shared DB)
ZONE=mailmasker.org
ISSUER=10.20.2.190                       # prod-homelab46, the central cert issuer
EDGES="10.20.2.144 10.20.2.145 10.20.2.146"
CERT_CONF=/etc/homelab/cert-server/cert-server.yml
SITES=/etc/homelab/webproxy/sites.yml
CERTSYNC_CONF=/etc/homelab/certsync/certsync.yml
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: developer-site-provision.sh [--dry-run] [--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
die(){  echo; echo "${R}$*${O}"; exit 1; }
RC=0

on(){ ssh -n -o ConnectTimeout=10 "$1" "${@:2}"; }
off(){ ssh -n -o ConnectTimeout=15 offsite "$@"; }

find_edge(){
    local ip up=""
    for ip in $EDGES; do
        timeout 4 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null && up="$up $ip"
    done
    printf '%s' "${up# }"
}
resolves(){ dig +short +time=3 "$NAME" A @10.50.2.147 2>/dev/null | head -1; }

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ]; then
    EDGE=$(find_edge)
    step "$NAME on prod-homelab45"
    V=$(on "$HOST" "dpkg-query -W -f='\${Version}' homelab-developer 2>/dev/null")
    [ -n "$V" ] && ok "homelab-developer $V installed" || bad "homelab-developer is not installed on $HOST"
    on "$HOST" "test -L /etc/nginx/sites-enabled/$NAME" && ok "site enabled in nginx" || bad "site not enabled in nginx"
    H=$(on "$HOST" "curl -s -H 'Host: $NAME' http://127.0.0.1/ | grep -c '<h1>Getting started</h1>'")
    [ "$H" = 1 ] && ok "nginx on $HOST serves Getting started for $NAME" || bad "nginx on $HOST does not serve the site"
    for h in static.mailmasker.org projects.thedude.vip; do
        c=$(on "$HOST" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $h' http://127.0.0.1/")
        case "$c" in 200|301|302|403) ok "$h still answers on $HOST ($c)" ;; *) bad "$h answers $c on $HOST" ;; esac
    done

    step "DNS and certificate"
    R1=$(resolves)
    [ "$R1" = "$PUBLIC_IP" ] && ok "DNS (authoritative): $R1" || bad "DNS authoritative returned '${R1:-nothing}'"
    on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME" \
        && ok "issuer holds the lineage: $(on "$ISSUER" "sudo openssl x509 -in /etc/letsencrypt/live/$NAME/cert.pem -noout -enddate" 2>/dev/null)" \
        || bad "issuer has no /etc/letsencrypt/live/$NAME"

    step "the edge"
    if [ -z "$EDGE" ]; then
        bad "no edge node is up -- cannot check the vhost"
    else
        ok "edge node up: $EDGE"
        on "$EDGE" "sudo test -d /etc/letsencrypt/live/$NAME" && ok "edge holds the certificate" || bad "edge does NOT hold the certificate"
        on "$EDGE" "grep -q 'domain: $NAME' $SITES" && ok "$NAME is in sites.yml" || bad "$NAME is not in sites.yml"
        on "$EDGE" "test -e /etc/nginx/sites-enabled/$NAME" && ok "nginx vhost enabled" || bad "no enabled nginx vhost for $NAME"
        on "$EDGE" "sudo nginx -t" >/dev/null 2>&1 && ok "nginx config valid" || bad "nginx config INVALID"
    fi
    "$HERE/edge-standby-sync.sh" --verify >/dev/null 2>&1 \
        && ok "the parked edge nodes carry the site and lineage too" \
        || warn "a parked edge node differs from the live one (run ./edge-standby-sync.sh --verify)"

    step "from the public internet (offsite)"
    chk(){ # $1 path  $2 expected code  $3 what
        local c; c=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$NAME$1" 2>/dev/null)
        [ "$c" = "$2" ] && ok "https://$NAME$1 -> $c ($3)" || bad "https://$NAME$1 -> '${c:-no answer}', expected $2 ($3)"
    }
    chk /                200 "Getting started"
    chk /sign-in         200 "an ability page"
    chk /sign-in.md      200 "the same, as Markdown"
    chk /llms.txt        200 "the index for AI tools"
    chk /skill/SKILL.md  200 "the Claude Code skill"
    chk /no-such-page    404 "the Not found page"
    V=$(off "curl -s -o /dev/null -w '%{ssl_verify_result}' --max-time 15 https://$NAME/" 2>/dev/null)
    [ "$V" = 0 ] && ok "certificate verifies from the internet" || bad "certificate does NOT verify (ssl_verify_result=$V)"
    T=$(off "curl -sI --max-time 15 https://$NAME/sign-in.md | tr -d '\r' | grep -i '^content-type:'" 2>/dev/null)
    printf '%s' "$T" | grep -qi 'text/markdown; charset=utf-8' && ok "Markdown served as $T" || bad "Markdown served as '${T:-nothing}'"
    A=$(off "curl -sI --max-time 15 https://$NAME/llms.txt | tr -d '\r' | grep -i '^access-control-allow-origin:'" 2>/dev/null)
    [ -n "$A" ] && ok "tools may read it from any page ($A)" || bad "no Access-Control-Allow-Origin on llms.txt"
    P=$(off "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 http://$NAME/" 2>/dev/null)
    case "$P" in 30?" https://$NAME/"*) ok "plain HTTP redirects to HTTPS ($P)" ;; *) warn "http://$NAME/ -> '$P'" ;; esac

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}$NAME is live: package, DNS, certificate, edge and the public checks.${O}" \
                  || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"
EDGE=$(find_edge)
case "$(echo "$EDGE" | wc -w)" in
    0) die "no edge node is up. Exactly one of prod-homelab00/01/02 must be running." ;;
    1) ok "exactly one edge node is up: $EDGE" ;;
    *) die "MORE THAN ONE edge node is up ($EDGE). They share MACs, so this is a
public address conflict -- fix that before changing edge config." ;;
esac
timeout 4 bash -c "echo > /dev/tcp/${HOST}/22" 2>/dev/null && ok "prod-homelab45 ($HOST) reachable" || die "prod-homelab45 ($HOST) is not reachable"
on "$HOST" "sudo nginx -t" >/dev/null 2>&1 && ok "nginx on 45 is valid before we start" || die "nginx on 45 is already invalid; fix that first"
PUB=$(curl -fsSL --max-time 20 http://projects.thedude.vip/apt-homelab/dists/unstable/main/binary-amd64/Packages 2>/dev/null \
      | awk '/^Package: homelab-developer$/{p=1} p&&/^Version:/{print $2; exit}')
[ -n "$PUB" ] && ok "homelab-developer $PUB is published in the fleet repo" || die "homelab-developer is not in the published repo yet"

if [ "$DRY" = 1 ]; then
    step "would do"
    cat <<PLANNED
  1. $HOST: apt-get install homelab-developer ($PUB), which enables the
     site in nginx and reloads it (only if nginx -t passes)
  2. $DNS_NODE: pdnsutil rrset add $ZONE $NAME A 3600 $PUBLIC_IP
     (only if absent), then zone increase-serial
  3. $ISSUER:$CERT_CONF -- add lineage $NAME, issue it (DNS-01), publish
  4. $EDGE:$CERTSYNC_CONF -- add the certsync target, run certsync
  5. $EDGE:$SITES -- add:
         - domain: $NAME
           upstream: $UPSTREAM
     then homelab-webproxy-apply-sites
  6. ./edge-standby-sync.sh -- the same site and lineage on the parked nodes
  7. --verify, from offsite
PLANNED
    note "dry run: nothing changed."
    exit 0
fi

# ----------------------------------------------------------- 1. the package
step "1. homelab-developer on prod-homelab45"
HAVE=$(on "$HOST" "dpkg-query -W -f='\${Version}' homelab-developer 2>/dev/null")
if [ "$HAVE" = "$PUB" ]; then
    ok "homelab-developer $HAVE already installed"
else
    on "$HOST" "sudo apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/homelab.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0" >/dev/null 2>&1 \
        || warn "apt-get update for the homelab list returned non-zero"
    if out=$(on "$HOST" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y homelab-developer" 2>&1); then
        ok "installed homelab-developer $(on "$HOST" "dpkg-query -W -f='\${Version}' homelab-developer")"
    else
        printf '%s\n' "$out" | tail -8 | sed 's/^/      /'
        die "the install failed (nginx was not reloaded into a broken state; see above)"
    fi
fi
H=$(on "$HOST" "curl -s -H 'Host: $NAME' http://127.0.0.1/ | grep -c '<h1>Getting started</h1>'")
[ "$H" = 1 ] && ok "nginx on 45 serves the site" || die "nginx on 45 does not serve the site; stopping before DNS"
for h in static.mailmasker.org projects.thedude.vip; do
    c=$(on "$HOST" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $h' http://127.0.0.1/")
    case "$c" in 200|301|302|403) ok "$h still answers ($c)" ;; *) die "$h answers $c on 45 after the install" ;; esac
done

# ------------------------------------------------------------------- 2. DNS
step "2. DNS: $NAME -> $PUBLIC_IP"
# pdnsutil 5 (on the fleet) names these `zone list`, `rrset add` and `zone
# increase-serial`; the older add-record and increase-serial are gone.
if on "$DNS_NODE" "sudo pdnsutil zone list $ZONE 2>/dev/null | grep -qE '^$NAME[[:space:]].*[[:space:]]A[[:space:]]'"; then
    ok "the A record already exists"
else
    if out=$(on "$DNS_NODE" "sudo pdnsutil rrset add $ZONE $NAME A 3600 $PUBLIC_IP && sudo pdnsutil zone increase-serial $ZONE" 2>&1); then
        ok "added the A record and raised the zone's serial"
    else
        printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
        die "could not add the A record"
    fi
fi
for i in 1 2 3 4 5 6; do
    [ "$(resolves)" = "$PUBLIC_IP" ] && break
    sleep 5
done
[ "$(resolves)" = "$PUBLIC_IP" ] && ok "resolves authoritatively: $PUBLIC_IP" || die "$NAME does not resolve authoritatively yet"

# ------------------------------------------------------- 3. the certificate
step "3. certificate lineage on the issuer"
if on "$ISSUER" "sudo grep -q 'name: $NAME' $CERT_CONF"; then
    ok "lineage already configured"
else
    if on "$ISSUER" "sudo cp -a $CERT_CONF ${CERT_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
        sudo perl -i -pe 'print \"  - name: $NAME\n    domains: [$NAME]\n\" if /^  - name: search\.mailmasker\.org\$/' $CERT_CONF &&
        sudo grep -q 'name: $NAME' $CERT_CONF"; then
        ok "lineage added to $CERT_CONF"
    else
        die "could not add the lineage"
    fi
fi
on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME" || {
    on "$ISSUER" "sudo /usr/bin/homelab-cert-issue --lineage $NAME" >/dev/null 2>&1 \
        && ok "issued (DNS-01)" || warn "homelab-cert-issue returned non-zero -- checking for the cert anyway"
}
on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME" \
    && ok "lineage present: $(on "$ISSUER" "sudo openssl x509 -in /etc/letsencrypt/live/$NAME/cert.pem -noout -enddate" 2>/dev/null)" \
    || die "no /etc/letsencrypt/live/$NAME on the issuer. Check:
  ssh $ISSUER 'sudo journalctl -u homelab-cert-server -n 50 --no-pager'"
on "$ISSUER" "sudo /usr/bin/homelab-cert-publish --drain" >/dev/null 2>&1 \
    && ok "published to the fleet certificate store" || warn "publish --drain returned non-zero; the timer will retry"

# ---------------------------------------------------- 4. certsync on the edge
step "4. deliver it to the live edge ($EDGE)"
if on "$EDGE" "sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF"; then
    ok "certsync already targets $NAME"
else
    on "$EDGE" "sudo cp -a $CERTSYNC_CONF ${CERTSYNC_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
        printf '  - lineage: %s\n    mode: letsencrypt\n    reload: nginx\n' '$NAME' | sudo tee -a $CERTSYNC_CONF >/dev/null &&
        sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF" \
        && ok "added $NAME to the edge's certsync targets" || die "could not add the certsync target"
fi
on "$EDGE" "sudo systemctl start homelab-certsync" >/dev/null 2>&1
on "$EDGE" "sudo test -d /etc/letsencrypt/live/$NAME" && ok "edge holds the certificate" \
    || die "certsync did not deliver $NAME to $EDGE. Check:
  ssh $EDGE 'sudo journalctl -u homelab-certsync -n 40 --no-pager'"

# ------------------------------------------------------- 5. vhost on the edge
step "5. nginx vhost on the edge"
if on "$EDGE" "grep -q 'domain: $NAME' $SITES"; then
    ok "$NAME already in sites.yml"
else
    on "$EDGE" "sudo cp -a $SITES ${SITES}.bak-\$(date +%Y%m%d-%H%M%S) &&
        printf '  - domain: %s\n    upstream: %s\n' '$NAME' '$UPSTREAM' | sudo tee -a $SITES >/dev/null &&
        grep -q 'domain: $NAME' $SITES" \
        && ok "added to $SITES" || die "could not add the site"
fi
if out=$(on "$EDGE" "sudo /usr/bin/homelab-webproxy-apply-sites" 2>&1); then
    printf '%s\n' "$out" | grep -i "$NAME" | sed 's/^/      /' | head -5
    ok "apply-sites ran"
else
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
    bad "apply-sites failed"
fi
on "$EDGE" "sudo nginx -t" >/dev/null 2>&1 && ok "nginx config valid" || bad "nginx config INVALID"

# ------------------------------------------------------ 6. the parked edges
step "6. the parked edge nodes"
"$HERE/edge-standby-sync.sh" || bad "edge-standby-sync.sh reported a problem (see above)"

step "verify"
exec "$0" --verify
