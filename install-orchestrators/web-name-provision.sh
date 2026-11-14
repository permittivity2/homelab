#!/bin/bash
# ============================================================================
# Put a new public web name in front of a pool, on ALL THREE live edges.
#
#   ./web-name-provision.sh NAME PORT NN [NN ...] [--client-id ID] [--dry-run|--verify]
#   ./web-name-provision.sh calendar.mailmasker.org 2519 50 51 52 --dry-run
#   ./web-name-provision.sh calendar.mailmasker.org 2519 50 51 52
#   ./web-name-provision.sh calendar.mailmasker.org 2519 50 51 52 --verify
#
# What it does, in the order that works (post-cutover #74; the one-edge
# scripts search-vhost-provision.sh and developer-site-provision.sh die with
# more than one edge up, and since 2026-11-06 all three run):
#   1. DNS: a plain A record on the authoritative server if the name has none,
#      then dns-lua-orchestrate.sh --apply for THIS name only, which turns it
#      into the health-steered Lua record (A + AAAA, all three edges) and does
#      the rolling pdns restart a new record type needs.
#   2. Certificate: the lineage on the issuer (prod-homelab46), issued by
#      DNS-01, published to the fleet store.
#   3. Each edge, one at a time: the certsync target (certsync pulls nothing
#      it was not told to), the cert delivered, the site in sites.yml with the
#      pool's service addresses as upstreams, homelab-webproxy-apply-sites,
#      nginx -t -- then a probe FROM OFFSITE pinned to that edge's own public
#      address (pfSense's ARP cache makes a healthy edge look dead from the
#      workstation). A 502 is right until the app listens.
#   4. The SSO client (client_id = the name's first label unless --client-id):
#      one secret, written identically to all three SSO nodes, restarted one
#      at a time. Nothing is printed: the app's orchestrator reads the secret
#      off the SSO node when it installs.
# Every step is idempotent; --verify checks all of it and changes nothing.
#
# This script never contains a public address: it learns the edges' from
# the records already published (an existing Lua name) and from
# install-orchestrators/.edge-ipv6, and the pool's service addresses from the
# node numbers (prod-homelabNN = 10.50.2.(144+NN)).
# ============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ISSUER=10.20.2.190
DNS_NODE=10.20.2.147
EDGE_NODES="00 01 02"
SSO_NODES="10.20.2.162 10.20.2.163 10.20.2.164"
CERT_CONF=/etc/homelab/cert-server/cert-server.yml
SITES=/etc/homelab/webproxy/sites.yml
SSO_CONF=/etc/homelab/sso/config.yml
CERTSYNC_CONF=/etc/homelab/certsync/certsync.yml
REFERENCE_NAME=search.mailmasker.org     # a name that is already a Lua record

NAME=""; PORT=""; POOL=(); CLIENT_ID=""; DRY=0; VERIFY_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        --client-id) CLIENT_ID="$2"; shift ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *)
            if [ -z "$NAME" ]; then NAME="$1"
            elif [ -z "$PORT" ]; then PORT="$1"
            elif [[ "$1" =~ ^[0-9]{2}$ ]]; then POOL+=("$1")
            else echo "unknown argument '$1'"; exit 1; fi ;;
    esac
    shift
done
[ -n "$NAME" ] && [ -n "$PORT" ] && [ "${#POOL[@]}" -ge 1 ] || { sed -n '4,7p' "$0"; exit 1; }
[[ "$NAME" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || { echo "'$NAME' is not a host name"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "'$PORT' is not a port"; exit 1; }
ZONE="${NAME#*.}"
CLIENT_ID="${CLIENT_ID:-${NAME%%.*}}"
UPSTREAMS=""
for nn in "${POOL[@]}"; do UPSTREAMS="${UPSTREAMS:+$UPSTREAMS, }10.50.2.$((144 + 10#$nn)):$PORT"; done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
die(){  echo; echo "${R}$*${O}"; exit 1; }
RC=0

on(){ ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}"; }
off(){ ssh -n -o ConnectTimeout=15 -o BatchMode=yes offsite "$@"; }
edge_ip(){ echo "10.20.2.$((144 + 10#$1))"; }
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# The edges' public IPv4 addresses, from the file dns-lua-orchestrate.sh keeps
# ("public-IPv4 IPv6" per line), else from the reference name's answers.
public_ipv4s(){
    if [ -s "$HERE/.edge-ipv6" ]; then
        awk 'NF >= 1 && $1 !~ /^#/ { print $1 }' "$HERE/.edge-ipv6"
    else
        dig +short +time=3 "$REFERENCE_NAME" A @10.50.2.147 2>/dev/null | grep -E '^[0-9.]+$'
    fi
}
# One edge address: any one the reference name resolves to.
one_edge_ipv4(){ dig +short +time=3 "$REFERENCE_NAME" A @10.50.2.147 2>/dev/null | grep -E '^[0-9.]+$' | head -1; }
auth_answer(){ dig +short +time=3 "$NAME" "$1" @10.50.2.147 2>/dev/null | grep -vE '^;' | head -3; }
sso_secret(){ on "$1" "sudo awk '/client_id: $CLIENT_ID\$/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null; }

# ----------------------------------------------------------------- verify only
verify(){
    step "$NAME: DNS"
    local pubs; pubs=$(public_ipv4s | tr '\n' ' ')
    local a; a=$(auth_answer A | tr '\n' ' ')
    local hit=0; for ip in $a; do grep -qw -- "$ip" <<<"$pubs" && hit=1; done
    [ "$hit" = 1 ] && ok "authoritative A: $a" || bad "authoritative A returned '${a:-nothing}' (expected an edge address)"
    local aaaa; aaaa=$(auth_answer AAAA | tr '\n' ' ')
    [ -n "$aaaa" ] && ok "authoritative AAAA: $aaaa" || warn "no AAAA (dns-lua-orchestrate.sh --apply publishes one when .edge-ipv6 exists)"
    local pub; pub=$(off "dig +short +time=4 $NAME A @ns1.$ZONE 2>/dev/null | grep -E '^[0-9.]+\$' | head -1" 2>/dev/null)
    [ -n "$pub" ] && ok "from the internet, ns1.$ZONE answers $pub" || bad "from the internet, ns1.$ZONE gave no A for $NAME"

    step "certificate"
    if on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME"; then
        ok "issuer holds the lineage: $(on "$ISSUER" "sudo openssl x509 -in /etc/letsencrypt/live/$NAME/cert.pem -noout -enddate 2>/dev/null")"
    else bad "issuer has no /etc/letsencrypt/live/$NAME"; fi
    on "$ISSUER" "sudo grep -q 'name: $NAME' $CERT_CONF" && ok "lineage in $CERT_CONF" || bad "lineage missing from $CERT_CONF"

    step "the three edges"
    local -a pubarr; read -r -a pubarr <<<"$pubs"
    local i=0
    for nn in $EDGE_NODES; do
        local e; e=$(edge_ip "$nn")
        if ! up "$e"; then bad "edge $nn ($e) does not answer on :22"; i=$((i+1)); continue; fi
        on "$e" "sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF" && ok "edge $nn: certsync target present" || bad "edge $nn: no certsync target for $NAME"
        on "$e" "sudo test -d /etc/letsencrypt/live/$NAME" && ok "edge $nn: holds the certificate" || bad "edge $nn: does NOT hold the certificate"
        on "$e" "grep -q 'domain: $NAME' $SITES" && ok "edge $nn: site in sites.yml" || bad "edge $nn: $NAME not in sites.yml"
        on "$e" "test -e /etc/nginx/sites-enabled/$NAME && grep -q 'listen 443 ssl' /etc/nginx/sites-available/$NAME" \
            && ok "edge $nn: HTTPS vhost enabled" || bad "edge $nn: no HTTPS vhost for $NAME"
        on "$e" "sudo nginx -t" >/dev/null 2>&1 && ok "edge $nn: nginx config valid" || bad "edge $nn: nginx config INVALID"
        local pip="${pubarr[$i]:-}"
        if [ -n "$pip" ]; then
            local h v
            h=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve $NAME:443:$pip https://$NAME/ 2>/dev/null" 2>/dev/null)
            v=$(off "curl -s -o /dev/null -w '%{ssl_verify_result}' --max-time 15 --resolve $NAME:443:$pip https://$NAME/ 2>/dev/null" 2>/dev/null)
            case "$h" in
                200|30?|40?) ok "edge $nn via $pip: https -> $h (an app answers)" ;;
                502|503|504) ok "edge $nn via $pip: https -> $h (TLS and proxy work; nothing on :$PORT yet)" ;;
                *) bad "edge $nn via $pip: https -> '${h:-no answer}'" ;;
            esac
            [ "$v" = 0 ] && ok "edge $nn via $pip: certificate verifies from the internet" || bad "edge $nn via $pip: ssl_verify_result=$v"
        else warn "edge $nn: no public address known (no .edge-ipv6 line); skipped the pinned probe"; fi
        i=$((i+1))
    done

    step "SSO client '$CLIENT_ID'"
    local first="${SSO_NODES%% *}" sec same=1
    sec=$(sso_secret "$first")
    for n in $SSO_NODES; do
        on "$n" "sudo grep -q 'client_id: $CLIENT_ID\$' $SSO_CONF" && ok "$n has the client" || bad "$n is MISSING the client"
        [ "$(sso_secret "$n")" = "$sec" ] || same=0
    done
    [ -n "$sec" ] && [ "$same" = 1 ] && ok "the same client_secret on all three SSO nodes" || bad "the client_secret differs between SSO nodes (2 sign-ins in 3 would fail)"
    on "$first" "sudo grep -q 'redirect_uri: https://$NAME/oauth/callback' $SSO_CONF" && ok "redirect_uri is https://$NAME/oauth/callback" || bad "redirect_uri for $CLIENT_ID is not https://$NAME/oauth/callback"

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}$NAME is wired in on all three edges: DNS, cert, vhosts, SSO client.${O}" \
                  || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
}
[ "$VERIFY_ONLY" = 1 ] && verify

# ------------------------------------------------------------------- preflight
step "preflight"
for nn in $EDGE_NODES; do up "$(edge_ip "$nn")" || die "edge $nn does not answer on :22; all three must be up (edge-rotate.sh if one is parked)"; done
ok "all three edges up"
up "$ISSUER" || die "the issuer $ISSUER is down"
for n in $SSO_NODES; do up "$n" || die "SSO node $n is down"; done
ok "issuer and SSO nodes up"
off "true" >/dev/null 2>&1 || die "offsite does not answer; the public probes need it"
ok "offsite reachable"
REF_IP=$(one_edge_ipv4); [ -n "$REF_IP" ] || die "$REFERENCE_NAME has no A record on $DNS_NODE; cannot learn an edge address"
ok "edge address learned from $REFERENCE_NAME"
A_NOW=$(auth_answer A | tr '\n' ' ')
[ -n "$A_NOW" ] && ok "$NAME already resolves: $A_NOW" || note "$NAME has no A record yet; one will be added"
for nn in "${POOL[@]}"; do up "$(edge_ip "$nn")" && ok "pool node $nn up" || warn "pool node $nn not reachable (the vhost will 502 until it is)"; done

if [ "$DRY" = 1 ]; then
    step "would do"
    cat <<PLANNED
  1. $DNS_NODE: pdnsutil rrset add $ZONE $NAME A 3600 <an edge address>; zone increase-serial
     then: ONLY='^${NAME//./\\.}\$' $HERE/dns-lua-orchestrate.sh --apply   (Lua A+AAAA, rolling pdns restart)
  2. $ISSUER:$CERT_CONF  -- add lineage {name: $NAME, domains: [$NAME]}
     then: homelab-cert-issue --lineage $NAME; homelab-cert-publish --drain
  3. each edge 00 01 02:
       $CERTSYNC_CONF  += {lineage: $NAME, mode: letsencrypt, reload: nginx}; systemctl start homelab-certsync
       $SITES          += {domain: $NAME, upstreams: [$UPSTREAMS]}; homelab-webproxy-apply-sites; nginx -t
       probe from offsite, pinned to that edge's public address
  4. $SSO_NODES: clients += {client_id: $CLIENT_ID, client_secret: <one generated>, redirect_uri: https://$NAME/oauth/callback}
     restart homelab-sso one node at a time
PLANNED
    note "dry run: nothing changed."
    exit 0
fi

# ------------------------------------------------------------------- 1. DNS
step "1. DNS: $NAME in $ZONE"
if [ -z "$A_NOW" ]; then
    on "$DNS_NODE" "sudo pdnsutil rrset add $ZONE $NAME A 3600 $REF_IP >/dev/null 2>&1 && sudo pdnsutil zone increase-serial $ZONE >/dev/null 2>&1" \
        && ok "A record added" || die "could not add the A record on $DNS_NODE"
fi
if [ -n "$(auth_answer A)" ] && ! on "$DNS_NODE" "sudo pdnsutil zone list $ZONE 2>/dev/null | grep -qE '^$NAME\.?\s.*\sLUA\s'" ; then
    if [ -x "$HERE/dns-lua-orchestrate.sh" ]; then
        ONLY="^${NAME//./\\.}\$" "$HERE/dns-lua-orchestrate.sh" --apply >/tmp/web-name-lua.$$ 2>&1 \
            && ok "converted to the health-steered Lua record (A + AAAA)" \
            || { tail -8 /tmp/web-name-lua.$$ | sed 's/^/      /'; warn "dns-lua-orchestrate.sh --apply returned non-zero; check its output above"; }
        rm -f /tmp/web-name-lua.$$
    else warn "no dns-lua-orchestrate.sh beside this script; the plain A record stays"; fi
else ok "already a Lua record"; fi
for i in 1 2 3 4 5 6; do
    PUB=$(off "dig +short +time=4 $NAME A @ns1.$ZONE 2>/dev/null | grep -E '^[0-9.]+\$' | head -1" 2>/dev/null)
    [ -n "$PUB" ] && break; sleep 5
done
[ -n "$PUB" ] && ok "from the internet: $NAME -> $PUB" || die "ns1.$ZONE does not answer for $NAME from offsite; DNS-01 cannot work yet"

# -------------------------------------------------------------- 2. certificate
step "2. certificate lineage on the issuer"
if on "$ISSUER" "sudo grep -q 'name: $NAME' $CERT_CONF"; then
    ok "lineage already configured"
else
    # Inserted before the first lineage whose name sorts after ours, to keep
    # the list readable; after the last one when none does.
    on "$ISSUER" "sudo cp -a $CERT_CONF ${CERT_CONF}.bak-\$(date +%Y%m%d-%H%M%S) && sudo perl -i -0pe '
        my \$e = qq{  - name: $NAME\n    domains: [$NAME]\n};
        if (!s/^(  - name: (\S+)\n)/(\$2 gt q{$NAME} && !\$done++) ? \$e.\$1 : \$1/mge or !\$done) {
            s/^(  - name: \S+\n    domains: \[[^\]]*\]\n)(?!  - name:)/\$1\$e/m or die qq{no lineages list found\n};
        }' $CERT_CONF && sudo grep -q 'name: $NAME' $CERT_CONF" \
        && ok "lineage added to $CERT_CONF" || die "could not add the lineage on $ISSUER"
fi
on "$ISSUER" "sudo /usr/bin/homelab-cert-issue --lineage $NAME" >/dev/null 2>&1 || warn "homelab-cert-issue returned non-zero -- checking whether the cert exists anyway"
on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME" \
    && ok "lineage present: $(on "$ISSUER" "sudo openssl x509 -in /etc/letsencrypt/live/$NAME/cert.pem -noout -enddate" 2>/dev/null)" \
    || die "issuance did not produce /etc/letsencrypt/live/$NAME. Check: ssh $ISSUER 'sudo journalctl -u homelab-cert-server -n 50 --no-pager'"
on "$ISSUER" "sudo /usr/bin/homelab-cert-publish --drain" >/dev/null 2>&1 && ok "published to the fleet certificate store" || warn "publish --drain returned non-zero; the timer will retry"

# -------------------------------------------------------------- 3. each edge
read -r -a PUBS <<<"$(public_ipv4s | tr '\n' ' ')"
i=0
for nn in $EDGE_NODES; do
    E=$(edge_ip "$nn")
    step "3. edge $nn ($E)"
    if on "$E" "sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF"; then ok "certsync target present"
    else
        on "$E" "sudo cp -a $CERTSYNC_CONF ${CERTSYNC_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
            printf '  - lineage: %s\n    mode: letsencrypt\n    reload: nginx\n' '$NAME' | sudo tee -a $CERTSYNC_CONF >/dev/null &&
            sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF" && ok "certsync target added" || die "edge $nn: could not add the certsync target"
    fi
    on "$E" "sudo systemctl start homelab-certsync" >/dev/null 2>&1
    on "$E" "sudo test -d /etc/letsencrypt/live/$NAME" && ok "holds the certificate" \
        || die "edge $nn: certsync did not deliver $NAME. Check: ssh $E 'sudo journalctl -u homelab-certsync -n 40 --no-pager'"
    if on "$E" "grep -q 'domain: $NAME' $SITES"; then ok "site already in sites.yml"
    else
        on "$E" "sudo cp -a $SITES ${SITES}.bak-\$(date +%Y%m%d-%H%M%S) &&
            printf '  - domain: %s\n    upstreams: [%s]\n' '$NAME' '$UPSTREAMS' | sudo tee -a $SITES >/dev/null &&
            grep -q 'domain: $NAME' $SITES" && ok "site added to sites.yml" || die "edge $nn: could not add the site"
    fi
    if out=$(on "$E" "sudo /usr/bin/homelab-webproxy-apply-sites" 2>&1); then
        printf '%s\n' "$out" | grep -iE "$NAME" | sed 's/^/      /' | head -4
        ok "apply-sites ran"
    else printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; die "edge $nn: apply-sites failed"; fi
    on "$E" "sudo nginx -t" >/dev/null 2>&1 && ok "nginx config valid" || die "edge $nn: nginx config INVALID -- stopping before the next edge"
    PIP="${PUBS[$i]:-}"
    if [ -n "$PIP" ]; then
        H=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve $NAME:443:$PIP https://$NAME/ 2>/dev/null" 2>/dev/null)
        V=$(off "curl -s -o /dev/null -w '%{ssl_verify_result}' --max-time 15 --resolve $NAME:443:$PIP https://$NAME/ 2>/dev/null" 2>/dev/null)
        case "$H" in 200|30?|40?|502|503|504) ok "from offsite via $PIP: https -> $H";; *) die "edge $nn: https via $PIP -> '${H:-no answer}' -- stopping before the next edge";; esac
        [ "$V" = 0 ] && ok "certificate verifies from the internet" || die "edge $nn: ssl_verify_result=$V -- stopping"
    else warn "no public address known for edge $nn; probe skipped"; fi
    i=$((i+1))
done

# -------------------------------------------------------------- 4. SSO client
step "4. SSO client '$CLIENT_ID' on all three SSO nodes"
SECRET=""
for n in $SSO_NODES; do s=$(sso_secret "$n"); [ -n "$s" ] && { SECRET="$s"; ok "$n already has the client (reusing its secret)"; }; done
[ -n "$SECRET" ] || { SECRET=$(head -c 30 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-40); ok "generated a client_secret (not shown)"; }
for n in $SSO_NODES; do
    on "$n" "sudo grep -q 'client_id: $CLIENT_ID\$' $SSO_CONF" && continue
    on "$n" "sudo tail -c 200 $SSO_CONF | grep -q 'redirect_uri' || sudo grep -q '^clients:' $SSO_CONF" || die "$n: $SSO_CONF has no clients: list to append to"
    on "$n" "sudo cp -a $SSO_CONF ${SSO_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
        printf '  - client_id: %s\n    client_secret: %s\n    redirect_uri: https://%s/oauth/callback\n' '$CLIENT_ID' '$SECRET' '$NAME' | sudo tee -a $SSO_CONF >/dev/null &&
        sudo perl -MYAML::XS -e 'my \$c = YAML::XS::LoadFile(q{$SSO_CONF}); exit((grep { \$_->{client_id} eq q{$CLIENT_ID} } @{\$c->{clients}}) ? 0 : 1)'" \
        && ok "$n registered" || die "$n: could not register the client (config did not parse back)"
done
for n in $SSO_NODES; do
    on "$n" "sudo systemctl restart homelab-sso" >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:2502/health" 2>/dev/null); [ "$h" = 200 ] && break; sleep 2
    done
    [ "$h" = 200 ] && ok "$n homelab-sso back (/health 200)" || die "$n: homelab-sso did not come back after the restart -- stopping before the next node"
done

step "verify"
exec "$0" "$NAME" "$PORT" "${POOL[@]}" --client-id "$CLIENT_ID" --verify
