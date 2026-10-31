#!/bin/bash
# ============================================================================
# Wire search.mailmasker.org into the edge: certificate lineage, certsync to
# the live edge node, nginx vhost, and the SSO client registration.
#
#   ./search-vhost-provision.sh --dry-run
#   ./search-vhost-provision.sh
#   ./search-vhost-provision.sh --verify
#
# ORDER MATTERS AND IS NOT ALPHABETICAL.
#   DNS -> issue (DNS-01 needs the name to resolve)
#       -> publish + certsync (the edge must HOLD the cert)
#       -> vhost + apply-sites (which configures HTTPS against that cert)
# Adding the vhost first gives nginx a site whose certificate does not exist
# yet, and homelab-webproxy-apply-sites skips a vhost that already has HTTPS
# configured -- so a half-configured one is awkward to repair in place.
#
# THE EXPECTED END STATE IS A 502, NOT A 200. Nothing listens on :2517 yet --
# the homelab-search package does not exist until Phase 2 of the plan. A 502
# served over a VALID certificate for search.mailmasker.org is exactly right:
# it proves DNS, issuance, certsync, nginx and the proxy path all work, and
# leaves only the application missing. --verify asserts that, rather than
# pretending a 200 is achievable today.
#
# ONLY ONE EDGE NODE IS EVER POWERED ON (prod-homelab00/01/02 are manual
# one-at-a-time, same MACs, so two up is a public address conflict). This
# configures whichever one is currently up and says so; the other two pick the
# vhost up on their next pass through edge-rotate.sh, which is the established
# way edge config drift is reconciled here.
#
# NEVER JUDGE THE EDGE FROM THE ADMIN WORKSTATION. pfSense's ARP cache makes a
# healthy edge node look dead from inside, :443 included. Every public check
# below runs from `ssh offsite`.
# ============================================================================
set -uo pipefail

NAME=search.mailmasker.org
PORT=2517
ISSUER=10.20.2.190                       # prod-homelab46, the central cert issuer
EDGES="10.20.2.144 10.20.2.145 10.20.2.146"
SSO_NODES="10.20.2.162 10.20.2.163 10.20.2.164"
UPSTREAMS="10.50.2.214:${PORT}, 10.50.2.215:${PORT}, 10.50.2.216:${PORT}"
CERT_CONF=/etc/homelab/cert-server/cert-server.yml
SITES=/etc/homelab/webproxy/sites.yml
SSO_CONF=/etc/homelab/sso/config.yml
CERTSYNC_CONF=/etc/homelab/certsync/certsync.yml

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: search-vhost-provision.sh [--dry-run] [--verify])"; exit 1 ;;
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

# Which edge node is actually up? Exactly one should be.
find_edge(){
    local ip up=""
    for ip in $EDGES; do
        timeout 4 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null && up="$up $ip"
    done
    printf '%s' "${up# }"
}

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ]; then
    EDGE=$(find_edge)
    step "$NAME end to end"

    R1=$(dig +short +time=3 "$NAME" A @10.50.2.147 2>/dev/null | head -1)
    [ "$R1" = 23.116.91.66 ] && ok "DNS (authoritative): $R1" || bad "DNS authoritative returned '${R1:-nothing}'"

    if on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME"; then
        S=$(on "$ISSUER" "sudo openssl x509 -in /etc/letsencrypt/live/$NAME/cert.pem -noout -subject -enddate 2>/dev/null | tr '\n' ' '" 2>/dev/null)
        ok "issuer holds the lineage: $S"
    else
        bad "issuer has no /etc/letsencrypt/live/$NAME"
    fi

    if [ -z "$EDGE" ]; then
        bad "no edge node is up -- cannot check the vhost"
    else
        ok "edge node up: $EDGE"
        on "$EDGE" "sudo test -d /etc/letsencrypt/live/$NAME" \
            && ok "edge holds the certificate (certsync)" \
            || bad "edge does NOT hold the certificate -- certsync has not delivered it"
        on "$EDGE" "grep -q '$NAME' $SITES" \
            && ok "$NAME is in sites.yml" || bad "$NAME is not in sites.yml"
        on "$EDGE" "test -e /etc/nginx/sites-enabled/$NAME" \
            && ok "nginx vhost enabled" || bad "no enabled nginx vhost for $NAME"
        on "$EDGE" "sudo nginx -t" >/dev/null 2>&1 \
            && ok "nginx config valid" || bad "nginx config INVALID"
    fi

    step "from the public internet (offsite), never from this workstation"
    # A 502 is success here: TLS and proxying work, the app does not exist yet.
    H=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$NAME/ 2>/dev/null" 2>/dev/null)
    case "$H" in
        502|503|504) ok "https://$NAME/ -> $H (expected: TLS and proxy work, no app on :$PORT yet)" ;;
        200|30?|40?) ok "https://$NAME/ -> $H (something is answering on :$PORT)" ;;
        *)           bad "https://$NAME/ -> '${H:-no answer}'" ;;
    esac
    V=$(off "curl -s -o /dev/null -w '%{ssl_verify_result}' --max-time 15 https://$NAME/ 2>/dev/null" 2>/dev/null)
    [ "$V" = 0 ] && ok "certificate verifies from the internet (ssl_verify_result=0)" \
                 || bad "certificate does NOT verify from the internet (ssl_verify_result=$V)"
    CN=$(off "echo | openssl s_client -servername $NAME -connect $NAME:443 2>/dev/null | openssl x509 -noout -subject 2>/dev/null" 2>/dev/null)
    printf '%s' "$CN" | grep -q "$NAME" && ok "served cert is for $NAME ($CN)" \
                                        || bad "served cert subject is '$CN'"

    step "SSO client"
    for n in $SSO_NODES; do
        on "$n" "sudo grep -q 'client_id: search' $SSO_CONF" \
            && ok "$n has the 'search' client" || bad "$n is MISSING the 'search' client"
    done
    SEC=$(on "$(echo $SSO_NODES | awk '{print $1}')" "sudo awk '/client_id: search/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
    SAME=1
    for n in $SSO_NODES; do
        s=$(on "$n" "sudo awk '/client_id: search/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
        [ "$s" = "$SEC" ] || SAME=0
    done
    [ -n "$SEC" ] && [ "$SAME" = 1 ] \
        && ok "the same client_secret on all three SSO nodes" \
        || bad "the client_secret differs between SSO nodes (2 requests in 3 would fail)"

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}$NAME is wired in: DNS, cert, vhost and SSO client. Only the app is missing.${O}" \
                  || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"
R1=$(dig +short +time=3 "$NAME" A @10.50.2.147 2>/dev/null | head -1)
[ "$R1" = 23.116.91.66 ] || die "$NAME does not resolve authoritatively (got '${R1:-nothing}').
DNS-01 issuance needs the zone to answer first. Add the A record, then re-run."
ok "DNS resolves authoritatively: $R1"

EDGE=$(find_edge)
case "$(echo "$EDGE" | wc -w)" in
    0) die "no edge node is up. Exactly one of prod-homelab00/01/02 must be running." ;;
    1) ok "exactly one edge node is up: $EDGE" ;;
    *) die "MORE THAN ONE edge node is up ($EDGE). They share MACs, so this is a
public address conflict -- fix that before changing edge config." ;;
esac

for ip in 10.20.2.214 10.20.2.215 10.20.2.216; do
    timeout 4 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null \
        && ok "$ip up" || warn "$ip not reachable (the vhost will 502 until it is)"
done

# ---------------------------------------------------------------------- dry run
if [ "$DRY" = 1 ]; then
    step "would do"
    cat <<PLANNED
  1. $ISSUER:$CERT_CONF  -- add lineage:
         - name: $NAME
           domains: [$NAME]
     then: homelab-cert-issue --lineage $NAME   (DNS-01), then publish
  2. $EDGE:$CERTSYNC_CONF -- add the certsync target (it does NOT pull
     everything published; each host declares its own lineages):
         - lineage: $NAME
           mode: letsencrypt
           reload: nginx
     then force homelab-certsync
  3. $EDGE:$SITES -- add:
         - domain: $NAME
           upstreams: [$UPSTREAMS]
     then: homelab-webproxy-apply-sites
  4. $SSO_NODES -- add to clients: (same generated secret on all three)
         - client_id: search
           client_secret: <generated>
           redirect_uri: https://$NAME/oauth/callback
     then restart homelab-sso on each
PLANNED
    note "expected end state: https://$NAME/ -> 502 over a valid certificate"
    note "dry run: nothing changed."
    exit 0
fi

# ------------------------------------------------------------ 1. cert lineage
step "1. certificate lineage on the issuer"
if on "$ISSUER" "sudo grep -q 'name: $NAME' $CERT_CONF"; then
    ok "lineage already configured (idempotent)"
else
    # Inserted before silverlinings.llc to keep the list's rough alphabetical
    # order; the file is hand/tool-managed and a backup is taken first.
    if on "$ISSUER" "sudo cp -a $CERT_CONF ${CERT_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
        sudo perl -i -pe 'print \"  - name: $NAME\n    domains: [$NAME]\n\" if /^  - name: silverlinings\.llc\$/' $CERT_CONF &&
        sudo grep -q 'name: $NAME' $CERT_CONF"; then
        ok "lineage added to $CERT_CONF"
    else
        bad "could not add the lineage"; die "stopping before issuance"
    fi
fi

step "   issue it (DNS-01, so no inbound :80/:443 needed)"
if on "$ISSUER" "sudo /usr/bin/homelab-cert-issue --lineage $NAME" >/dev/null 2>&1; then
    ok "homelab-cert-issue completed"
else
    warn "homelab-cert-issue returned non-zero -- checking whether the cert exists anyway"
fi
if on "$ISSUER" "sudo test -d /etc/letsencrypt/live/$NAME"; then
    ok "lineage present: $(on "$ISSUER" "sudo openssl x509 -in /etc/letsencrypt/live/$NAME/cert.pem -noout -enddate" 2>/dev/null)"
else
    die "issuance did not produce /etc/letsencrypt/live/$NAME. Check:
  ssh $ISSUER 'sudo journalctl -u homelab-cert-server -n 50 --no-pager'"
fi
on "$ISSUER" "sudo /usr/bin/homelab-cert-publish --drain" >/dev/null 2>&1 \
    && ok "published to the fleet certificate store" \
    || warn "publish --drain returned non-zero; the timer will retry"

# --------------------------------------------------------------- 2. certsync
step "2. deliver it to the live edge node ($EDGE)"
# certsync does NOT pull everything the issuer publishes -- each host declares
# which lineages it installs, in its own /etc/homelab/certsync/certsync.yml
# targets list. Publishing a new lineage and then forcing certsync is not
# enough; without this entry certsync simply never asks for it and logs nothing
# about the lineage at all, which reads exactly like a delivery failure.
if on "$EDGE" "sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF"; then
    ok "certsync already targets $NAME (idempotent)"
else
    if on "$EDGE" "sudo cp -a $CERTSYNC_CONF ${CERTSYNC_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
        printf '  - lineage: %s\n    mode: letsencrypt\n    reload: nginx\n' '$NAME' | sudo tee -a $CERTSYNC_CONF >/dev/null &&
        sudo grep -q 'lineage: $NAME' $CERTSYNC_CONF"; then
        ok "added $NAME to the edge's certsync targets"
    else
        bad "could not add the certsync target"; die "stopping"
    fi
fi

on "$EDGE" "sudo systemctl start homelab-certsync" >/dev/null 2>&1
if on "$EDGE" "sudo test -d /etc/letsencrypt/live/$NAME"; then
    ok "edge now holds the certificate"
else
    die "certsync did not deliver $NAME to $EDGE. Check:
  ssh $EDGE 'sudo journalctl -u homelab-certsync -n 40 --no-pager'"
fi

# ------------------------------------------------------------------ 3. vhost
step "3. nginx vhost on the edge"
if on "$EDGE" "grep -q 'domain: $NAME' $SITES"; then
    ok "$NAME already in sites.yml (idempotent)"
else
    if on "$EDGE" "sudo cp -a $SITES ${SITES}.bak-\$(date +%Y%m%d-%H%M%S) &&
        printf '  - domain: %s\n    upstreams: [%s]\n' '$NAME' '$UPSTREAMS' | sudo tee -a $SITES >/dev/null &&
        grep -q 'domain: $NAME' $SITES"; then
        ok "added to $SITES"
    else
        bad "could not add the site"; die "stopping"
    fi
fi
if out=$(on "$EDGE" "sudo /usr/bin/homelab-webproxy-apply-sites" 2>&1); then
    printf '%s\n' "$out" | grep -iE "$NAME|new site|configured" | sed 's/^/      /' | head -5
    ok "apply-sites ran"
else
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
    bad "apply-sites failed"
fi
on "$EDGE" "sudo nginx -t" >/dev/null 2>&1 && ok "nginx config valid" || bad "nginx config INVALID"

# -------------------------------------------------------------- 4. SSO client
step "4. SSO client 'search' on all three SSO nodes"
note "a per-host secret would break 2 requests in 3, so one secret is generated"
note "here and written identically to all three."
SECRET=""
for n in $SSO_NODES; do
    if on "$n" "sudo grep -q 'client_id: search' $SSO_CONF"; then
        SECRET=$(on "$n" "sudo awk '/client_id: search/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
        ok "$n already registered (reusing its secret)"
    fi
done
if [ -z "$SECRET" ]; then
    SECRET=$(head -c 24 /dev/urandom | base64 | tr -d '\n=' | cut -c1-32)
    ok "generated a new client_secret"
fi
for n in $SSO_NODES; do
    if on "$n" "sudo grep -q 'client_id: search' $SSO_CONF"; then
        continue
    fi
    if on "$n" "sudo cp -a $SSO_CONF ${SSO_CONF}.bak-\$(date +%Y%m%d-%H%M%S) &&
        printf '  - client_id: search\n    client_secret: %s\n    redirect_uri: https://%s/oauth/callback\n' '$SECRET' '$NAME' | sudo tee -a $SSO_CONF >/dev/null &&
        sudo grep -q 'client_id: search' $SSO_CONF"; then
        ok "$n registered"
    else
        bad "$n could not be updated"
    fi
done
for n in $SSO_NODES; do
    on "$n" "sudo systemctl restart homelab-sso" >/dev/null 2>&1
    s=$(on "$n" "systemctl is-active homelab-sso" 2>/dev/null)
    [ "$s" = active ] && ok "$n homelab-sso active after restart" || bad "$n homelab-sso is '$s'"
done

step "the client_secret -- keep this, Phase 2 needs it"
echo
echo "    client_id:     search"
echo "    client_secret: $SECRET"
echo "    redirect_uri:  https://$NAME/oauth/callback"
echo
note "It is only on the three SSO nodes right now. The homelab-search package"
note "will ask for it via debconf at install time. It is NOT recorded in this"
note "repo or in any log on purpose."

step "verify"
exec "$0" --verify
