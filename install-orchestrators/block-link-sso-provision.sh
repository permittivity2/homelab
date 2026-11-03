#!/bin/bash
# ============================================================================
# Sign-in for the blockemail link page (post-cutover item 48). RUN ON THIS
# HOST (the workstation); every step is workstation -> node over ssh, never
# node -> node.
#
#   ./block-link-sso-provision.sh --dry-run   say what would change; change nothing
#   ./block-link-sso-provision.sh             do it
#   ./block-link-sso-provision.sh --verify    read-only checks, end to end
#
# What it does, in this order:
#   1. registers client 'block-link' with homelab-sso on all three SSO nodes,
#      with ONE client secret (a per-node secret fails 2 sign-ins in 3), and
#      restarts homelab-sso one node at a time, each checked before the next
#   2. gives the three block-link nodes the matching sso: block and ONE
#      session secret (requests are not sticky, so a node that cannot read
#      the cookie it is handed would fail 1 sign-in in 3), then restarts
#      homelab-block-link one node at a time, each checked
#   3. --verify: the same secrets everywhere (compared as hashes), both
#      services up, and from offsite: /login leads to homelab-sso, and
#      homelab-sso accepts the client (its form, not "Unknown client").
#
# Needs homelab-block-link >= 0.1.4 on the block-link nodes (older versions
# ignore the sso: block). Safe to re-run: what is already there is reused,
# never regenerated -- a new secret would break the nodes that hold the old.
#
# SECRETS never go on a command line, into this script's output, or into a
# log: they are generated here or read back from where they already are,
# and written through ssh's stdin.
# ============================================================================
set -uo pipefail

SSO_NODES="18 19 20"
BL_NODES="33 34 35"
SSO_INTERNAL_NODE=18            # the server-to-server code exchange, as myaccount and search use
CLIENT_ID=block-link
PUBLIC=https://blockemail.mailmasker.org
REDIRECT=$PUBLIC/oauth/callback
SSO_PUBLIC=https://login.mailmasker.org
SSO_PORT=2502
BL_PORT=2515
SSO_CONF=/etc/homelab/sso/config.yml
BL_CONF=/etc/homelab/block-link/config.yml
MIN_BL_VERSION=0.1.4

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: block-link-sso-provision.sh [--dry-run] [--verify])"; exit 1 ;;
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

mgmt(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }   # ssh address of prod-homelabNN
svc(){  printf '10.50.2.%d' "$((144 + 10#$1))"; }   # its service-plane address
on(){   ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$(mgmt "$1")" "${@:2}"; }
onin(){ ssh    -o BatchMode=yes -o ConnectTimeout=10 "$(mgmt "$1")" "${@:2}"; }   # with stdin
off(){  ssh -n -o BatchMode=yes -o ConnectTimeout=15 offsite "$@"; }

# Values are read with YAML::XS on the node (every homelab-* service already
# depends on it), not with awk, so indentation or quoting can't fool them.
# These print secrets to stdout: only ever captured into a variable or piped
# into sha256sum, never shown.
sso_client_secret(){ on "$1" "sudo perl -MYAML::XS=LoadFile -e '
    my (\$c) = grep { (\$_->{client_id} // q()) eq q($CLIENT_ID) } @{ (LoadFile(shift) // {})->{clients} // [] };
    print \$c->{client_secret} // q() if \$c' $SSO_CONF" 2>/dev/null; }
sso_client_redirect(){ on "$1" "sudo perl -MYAML::XS=LoadFile -e '
    my (\$c) = grep { (\$_->{client_id} // q()) eq q($CLIENT_ID) } @{ (LoadFile(shift) // {})->{clients} // [] };
    print \$c->{redirect_uri} // q() if \$c' $SSO_CONF" 2>/dev/null; }
bl_value(){ on "$1" "sudo perl -MYAML::XS=LoadFile -e '
    my \$c = LoadFile(shift) // {}; my (\$a, \$b) = split /\\./, q($2);
    print \$c->{\$a}{\$b} // q() if ref \$c->{\$a} eq q(HASH)' $BL_CONF" 2>/dev/null; }
hash(){ sha256sum | cut -c1-16; }

wait_health(){ # $1 node $2 port: up to ~30 s for /health to answer 200
    local i code=""
    for i in $(seq 1 15); do
        code=$(on "$1" "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://$(svc "$1"):$2/health" 2>/dev/null)
        [ "$code" = 200 ] && return 0
        sleep 2
    done
    return 1
}

# Can the block-link node itself start a sign-in? /login answering with a
# redirect to homelab-sso proves the sso: block loaded.
bl_login_ok(){
    local loc
    loc=$(on "$1" "curl -s -o /dev/null -w '%{redirect_url}' --max-time 5 http://$(svc "$1"):$BL_PORT/login" 2>/dev/null)
    case "$loc" in "$SSO_PUBLIC/oauth/authorize?"*"client_id=$CLIENT_ID"*) return 0 ;; esac
    return 1
}

verify(){
    step "SSO client '$CLIENT_ID' on the SSO nodes"
    local n h first="" same=1
    for n in $SSO_NODES; do
        h=$(sso_client_secret "$n" | hash)
        if [ "$h" = "$(printf '' | hash)" ]; then bad "prod-homelab$n: no '$CLIENT_ID' client"; same=0; continue; fi
        [ "$(sso_client_redirect "$n")" = "$REDIRECT" ] && ok "prod-homelab$n: registered, redirect $REDIRECT" \
            || bad "prod-homelab$n: '$CLIENT_ID' has the wrong redirect_uri"
        [ -z "$first" ] && first=$h
        [ "$h" = "$first" ] || same=0
        [ "$(on "$n" "systemctl is-active homelab-sso" 2>/dev/null)" = active ] && ok "prod-homelab$n: homelab-sso active" \
            || bad "prod-homelab$n: homelab-sso not active"
    done
    [ "$same" = 1 ] && ok "the same client secret on all three SSO nodes" || bad "the client secret differs between SSO nodes"

    step "block-link nodes"
    local sess_first="" sess_same=1 s
    for n in $BL_NODES; do
        v=$(on "$n" "dpkg-query -W -f='\${Version}' homelab-block-link" 2>/dev/null)
        dpkg --compare-versions "${v:-0}" ge "$MIN_BL_VERSION" && ok "prod-homelab$n: homelab-block-link $v" \
            || bad "prod-homelab$n: homelab-block-link ${v:-missing} (needs >= $MIN_BL_VERSION)"
        [ "$(bl_value "$n" sso.client_id)" = "$CLIENT_ID" ] && ok "prod-homelab$n: sso: block present" \
            || { bad "prod-homelab$n: no sso: block"; continue; }
        [ "$(bl_value "$n" sso.client_secret | hash)" = "$first" ] && ok "prod-homelab$n: its client secret matches SSO's" \
            || bad "prod-homelab$n: its client secret does NOT match SSO's"
        s=$(bl_value "$n" session.secret | hash)
        [ "$s" = "$(printf '' | hash)" ] && bad "prod-homelab$n: no session secret"
        [ -z "$sess_first" ] && sess_first=$s
        [ "$s" = "$sess_first" ] || sess_same=0
        [ "$(on "$n" "systemctl is-active homelab-block-link" 2>/dev/null)" = active ] && ok "prod-homelab$n: homelab-block-link active" \
            || bad "prod-homelab$n: homelab-block-link not active"
        bl_login_ok "$n" && ok "prod-homelab$n: /login leads to homelab-sso as '$CLIENT_ID'" \
            || bad "prod-homelab$n: /login does not lead to homelab-sso"
    done
    [ "$sess_same" = 1 ] && ok "the same session secret on all three block-link nodes" \
        || bad "the session secret differs between block-link nodes (sign-ins would fail 1 in 3)"

    step "from the internet (offsite)"
    local loc page
    loc=$(off "curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 '$PUBLIC/login?next=/l/0000000000000000'" 2>/dev/null)
    case "$loc" in
        "$SSO_PUBLIC/oauth/authorize?"*"client_id=$CLIENT_ID"*) ok "$PUBLIC/login -> homelab-sso's authorize" ;;
        *) bad "$PUBLIC/login -> '${loc:-no redirect}'" ;;
    esac
    if [ -n "$loc" ]; then
        page=$(off "curl -s --max-time 15 '$loc'" 2>/dev/null)
        if printf '%s' "$page" | grep -q 'Unknown client or redirect_uri'; then
            bad "homelab-sso does not know client '$CLIENT_ID' (or its redirect_uri)"
        elif printf '%s' "$page" | grep -q 'name="password"'; then
            ok "homelab-sso accepts '$CLIENT_ID' and shows its sign-in form"
        else
            bad "homelab-sso's answer was neither its form nor its error"
        fi
    fi

    echo
    [ "$RC" = 0 ] && echo "${G}All checks passed.${O}" || echo "${R}Some checks FAILED -- see above.${O}"
    return "$RC"
}

if [ "$VERIFY_ONLY" = 1 ]; then verify; exit $?; fi

# ------------------------------------------------------------------ preflight
step "preflight"
for n in $SSO_NODES $BL_NODES; do
    on "$n" true 2>/dev/null && ok "prod-homelab$n reachable" || die "prod-homelab$n is not reachable over ssh"
done
for n in $BL_NODES; do
    v=$(on "$n" "dpkg-query -W -f='\${Version}' homelab-block-link" 2>/dev/null)
    dpkg --compare-versions "${v:-0}" ge "$MIN_BL_VERSION" \
        || die "prod-homelab$n runs homelab-block-link ${v:-nothing}; install >= $MIN_BL_VERSION there first"
done
ok "homelab-block-link >= $MIN_BL_VERSION on $BL_NODES"
for n in $SSO_NODES; do
    # A new client is appended to the end of the file, so the clients: list
    # has to be the file's last top-level key or the entry would land under
    # whatever key came after it.
    last=$(on "$n" "sudo awk '/^[A-Za-z_][A-Za-z0-9_]*:/{k=\$1} END{print k}' $SSO_CONF" 2>/dev/null)
    [ -n "$(sso_client_secret "$n")" ] && continue
    [ "$last" = "clients:" ] || die "prod-homelab$n: clients: is not the last key in $SSO_CONF (it is '$last'); add the client by hand"
done
ok "SSO configs can take the new client"

# ------------------------------------------------------------- 1. SSO client
step "1. SSO client '$CLIENT_ID' (one secret on all three SSO nodes)"
SECRET=""
for n in $SSO_NODES; do
    s=$(sso_client_secret "$n")
    if [ -n "$s" ]; then
        if [ -n "$SECRET" ] && [ "$s" != "$SECRET" ]; then
            die "prod-homelab$n holds a DIFFERENT '$CLIENT_ID' secret from another SSO node; fix that by hand first"
        fi
        SECRET=$s
        ok "prod-homelab$n already has the client (its secret is reused)"
    fi
done
if [ -z "$SECRET" ]; then
    SECRET=$(head -c 30 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-40)
    ok "generated a new client secret"
fi

CHANGED_SSO=""
for n in $SSO_NODES; do
    [ -n "$(sso_client_secret "$n")" ] && continue
    if [ "$DRY" = 1 ]; then note "would add client '$CLIENT_ID' to prod-homelab$n:$SSO_CONF and restart homelab-sso there"; continue; fi
    on "$n" "sudo cp -a $SSO_CONF $SSO_CONF.bak-\$(date +%Y%m%d-%H%M%S)" || die "prod-homelab$n: could not back up $SSO_CONF"
    printf '  # block-link sign-in (post-cutover item 48), added by block-link-sso-provision.sh\n  - client_id: %s\n    client_secret: %s\n    redirect_uri: %s\n' \
        "$CLIENT_ID" "$SECRET" "$REDIRECT" | onin "$n" "sudo tee -a $SSO_CONF >/dev/null"
    if [ "$(sso_client_secret "$n")" = "$SECRET" ] && [ "$(sso_client_redirect "$n")" = "$REDIRECT" ]; then
        ok "prod-homelab$n: client added"
        CHANGED_SSO="$CHANGED_SSO $n"
    else
        on "$n" "sudo sh -c 'cp -a \$(ls -t $SSO_CONF.bak-* | head -1) $SSO_CONF'"
        die "prod-homelab$n: the new entry did not read back correctly; the backup was put back"
    fi
done
for n in $CHANGED_SSO; do
    on "$n" "sudo systemctl restart homelab-sso" || die "prod-homelab$n: restart failed"
    wait_health "$n" "$SSO_PORT" && ok "prod-homelab$n: homelab-sso restarted and healthy" \
        || die "prod-homelab$n: homelab-sso is not healthy after the restart; stopping before the next node"
done

# ------------------------------------------------------ 2. block-link config
step "2. block-link config (one session secret on all three nodes)"
SESSION=""
for n in $BL_NODES; do
    s=$(bl_value "$n" session.secret)
    if [ -n "$s" ]; then
        if [ -n "$SESSION" ] && [ "$s" != "$SESSION" ]; then
            die "prod-homelab$n holds a DIFFERENT session secret from another block-link node; fix that by hand first"
        fi
        SESSION=$s
        ok "prod-homelab$n already has a session secret (reused)"
    fi
done
if [ -z "$SESSION" ]; then
    SESSION=$(head -c 48 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-48)
    ok "generated a new session secret"
fi

CHANGED_BL=""
for n in $BL_NODES; do
    if [ -n "$(bl_value "$n" sso.client_id)" ]; then
        [ "$(bl_value "$n" sso.client_secret)" = "$SECRET" ] && ok "prod-homelab$n: already configured" \
            || die "prod-homelab$n: has an sso: block whose secret does not match SSO's; fix that by hand"
        continue
    fi
    if [ "$DRY" = 1 ]; then note "would add sso: + session: to prod-homelab$n:$BL_CONF and restart homelab-block-link there"; continue; fi
    on "$n" "sudo cp -a $BL_CONF $BL_CONF.bak-\$(date +%Y%m%d-%H%M%S)" || die "prod-homelab$n: could not back up $BL_CONF"
    printf '\n# Sign-in through homelab-sso (post-cutover item 48), added by\n# block-link-sso-provision.sh. The session secret is the same on every node.\nsso:\n  base_url: %s\n  internal_base_url: http://%s:%s\n  client_id: %s\n  client_secret: "%s"\n  redirect_uri: %s\nsession:\n  secret: "%s"\n' \
        "$SSO_PUBLIC" "$(svc "$SSO_INTERNAL_NODE")" "$SSO_PORT" "$CLIENT_ID" "$SECRET" "$REDIRECT" "$SESSION" \
        | onin "$n" "sudo tee -a $BL_CONF >/dev/null"
    if [ "$(bl_value "$n" sso.client_secret)" = "$SECRET" ] && [ "$(bl_value "$n" session.secret)" = "$SESSION" ]; then
        ok "prod-homelab$n: config added"
        CHANGED_BL="$CHANGED_BL $n"
    else
        on "$n" "sudo sh -c 'cp -a \$(ls -t $BL_CONF.bak-* | head -1) $BL_CONF'"
        die "prod-homelab$n: the new blocks did not read back correctly; the backup was put back"
    fi
done
for n in $CHANGED_BL; do
    on "$n" "sudo systemctl restart homelab-block-link" || die "prod-homelab$n: restart failed"
    wait_health "$n" "$BL_PORT" || die "prod-homelab$n: homelab-block-link is not healthy after the restart; stopping before the next node"
    bl_login_ok "$n" && ok "prod-homelab$n: restarted, healthy, and /login leads to homelab-sso" \
        || die "prod-homelab$n: healthy but /login does not lead to homelab-sso; stopping before the next node"
done

unset SECRET SESSION
if [ "$DRY" = 1 ]; then echo; echo "${Y}Dry run: nothing was changed.${O}"; exit 0; fi

verify
