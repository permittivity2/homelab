#!/bin/bash
# ============================================================================
# Install homelab-notes on prod-homelab47/48/49 (post-cutover #71).
#
#   ./notes-orchestrate.sh --dry-run
#   ./notes-orchestrate.sh
#   ./notes-orchestrate.sh --verify
#
# Same shape as search-orchestrate.sh / block-link-orchestrate.sh:
#   * homelab-agent must already be enrolled on the three nodes
#     (agent-enroll-orchestrate.sh 47 48 49): the app registers itself with
#     homelab-api using the agent credential.
#   * the public name, cert, vhosts and SSO client come first
#     (web-name-provision.sh notes.mailmasker.org 2518 47 48 49); the SSO
#     client secret is read off the SSO node here, never pasted.
#   * node 1 installs and stops at tier 3 of homelab-bootstrap-app-role (no
#     guest-to-guest SSH, by design); the runbook is run FROM HERE: the role
#     SQL on the Patroni leader, the SCRAM into each pgbouncer, the audit
#     grant. Then dpkg-reconfigure finishes node 1.
#   * ONE role for the pool: node 1's config is copied to nodes 2 and 3
#     (registry.host rewritten) BEFORE their install, so their postinst skips
#     the bootstrap and only migrates and starts.
# ============================================================================
set -uo pipefail

NODES="10.20.2.191 10.20.2.192 10.20.2.193"
NODE1=10.20.2.191
DB_NODES="10.20.2.150 10.20.2.151 10.20.2.152"
PGB_NODES="10.20.2.153 10.20.2.154 10.20.2.155"
SSO_NODE=10.20.2.162
SSO_INTERNAL=http://10.50.2.162:2502
NAME=notes.mailmasker.org
PORT=2518
PENDING=/var/lib/homelab-database/pending/homelab_notes-bootstrap.sql
CONFIG=/etc/homelab/notes/config.yml
SSO_CONF=/etc/homelab/sso/config.yml
SCRATCH="${TMPDIR:-/tmp}/notes-orchestrate.$$"


DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: notes-orchestrate.sh [--dry-run] [--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
die(){  echo; echo "${R}$*${O}"; rm -rf "$SCRATCH"; exit 1; }
RC=0
mkdir -p "$SCRATCH"; chmod 700 "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

on(){ ssh -n -o ConnectTimeout=15 -o BatchMode=yes "$1" "${@:2}"; }
on_in(){ ssh -o ConnectTimeout=15 -o BatchMode=yes "$1" "${@:2}"; }     # stdin passed through (on() gives ssh -n: no stdin)
off(){ ssh -n -o ConnectTimeout=15 -o BatchMode=yes offsite "$@"; }
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }
svc(){ echo "10.50.2.${1##*.}"; }

find_primary(){
    local n
    for n in $DB_NODES; do
        up "$n" || continue
        [ "$(on "$n" "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery()'" 2>/dev/null)" = f ] && { printf '%s' "$n"; return 0; }
    done
    return 1
}
psql_primary(){ on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"$1\"" 2>/dev/null; }

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ]; then
    PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"

    step "packages, units, registration"
    for n in $NODES; do
        v=$(on "$n" "dpkg-query -W -f='\${Version}' homelab-notes 2>/dev/null")
        [ -n "$v" ] && ok "$n homelab-notes $v" || bad "$n homelab-notes not installed"
        s=$(on "$n" "systemctl is-active homelab-notes" 2>/dev/null)
        [ "$s" = active ] && ok "$n homelab-notes active" || bad "$n homelab-notes is '$s'"
        s=$(on "$n" "systemctl is-active homelab-agent" 2>/dev/null)
        [ "$s" = active ] && ok "$n homelab-agent active" || bad "$n homelab-agent is '$s' (the app cannot register without it)"
        h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
        [ "$h" = 200 ] && ok "$n /health -> 200" || bad "$n /health -> '${h:-no answer}'"
        r=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/" 2>/dev/null)
        [ "$r" = 302 ] && ok "$n / -> 302 (to sign-in)" || bad "$n / -> '${r:-no answer}'"
        m=$(on "$n" "free -m | awk '/Mem:/{print \$3\"/\"\$2}'" 2>/dev/null); note "$n memory used/total MB: $m"
    done
    REG=$(psql_primary "SELECT count(*) FROM api.service_registry WHERE feature_name='homelab-notes'")
    [ "${REG:-0}" = 3 ] && ok "all three nodes in the service registry" || bad "${REG:-0}/3 nodes in the service registry"

    step "one pool, one secret"
    SEC1=$(on "$NODE1" "sudo sed -n 's/^  secret: //p' $CONFIG | tr -d '\"'" 2>/dev/null)
    if [ -z "$SEC1" ]; then bad "no session secret in $CONFIG on $NODE1"
    else
        same=1; for n in $NODES; do [ "$(on "$n" "sudo sed -n 's/^  secret: //p' $CONFIG | tr -d '\"'" 2>/dev/null)" = "$SEC1" ] || same=0; done
        [ "$same" = 1 ] && ok "identical session secret on all three nodes" || bad "the session secret DIFFERS between nodes -- sign-in fails 2 times in 3"
    fi
    CS=$(on "$SSO_NODE" "sudo awk '/client_id: notes\$/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
    AS=$(on "$NODE1" "sudo awk '/^sso:/{f=1} f&&/client_secret:/{print \$2; exit}' $CONFIG" 2>/dev/null)
    [ -n "$CS" ] && [ "$CS" = "$AS" ] && ok "the app's client_secret matches SSO's 'notes' client" || bad "the app's client_secret does not match SSO's (or the client is missing)"
    for n in $NODES; do
        rh=$(on "$n" "sudo sed -n 's/^  host: //p' $CONFIG | tail -1" 2>/dev/null)
        [ "$rh" = "$(svc "$n")" ] && ok "$n registry.host = $rh" || bad "$n registry.host is '$rh', expected $(svc "$n")"
    done

    step "schema and grants"
    TBL=$(psql_primary "SELECT count(*) FROM information_schema.tables WHERE table_schema='notes'")
    [ "${TBL:-0}" -ge 8 ] && ok "$TBL tables in the notes schema" || bad "only ${TBL:-0} tables in the notes schema (expected 8 incl. schema_migrations)"
    psql_primary "SELECT has_table_privilege('homelab_notes_runtime','audit.queue','INSERT')" | grep -q t \
        && ok "runtime role may write audit.queue" || bad "runtime role cannot write audit.queue (shares and deletions log a warning instead of an audit line)"
    psql_primary "SELECT has_table_privilege('homelab_notes_runtime','notes.notes','UPDATE')" | grep -q t \
        && ok "runtime role may change notes" || bad "runtime role cannot update notes.notes (default privileges missing?)"
    psql_primary "SELECT count(*) FROM notes.notebooks WHERE deleted_at IS NULL" | sed 's/^/      notebooks: /'
    psql_primary "SELECT count(*) FROM notes.notes WHERE deleted_at IS NULL" | sed 's/^/      notes: /'
    psql_primary "SELECT count(*) FROM notes.shares WHERE revoked_at IS NULL" | sed 's/^/      live shares: /'

    step "from the internet (offsite)"
    H=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$NAME/ 2>/dev/null" 2>/dev/null)
    [ "$H" = 302 ] && ok "https://$NAME/ -> 302 (to sign-in)" || bad "https://$NAME/ -> '${H:-no answer}'"
    L=$(off "curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 https://$NAME/login 2>/dev/null" 2>/dev/null)
    case "$L" in https://login.mailmasker.org/oauth/authorize*client_id=notes*) ok "/login -> homelab-sso as client 'notes'" ;; *) bad "/login -> '${L:-nothing}'" ;; esac
    J=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$NAME/notes.js 2>/dev/null" 2>/dev/null)
    [ "$J" = 200 ] && ok "the page script is served" || bad "/notes.js -> '${J:-no answer}'"
    C=$(off "curl -s -D - -o /dev/null --max-time 15 https://$NAME/login 2>/dev/null | grep -i -c '^content-security-policy:'" 2>/dev/null)
    [ "${C:-0}" -ge 1 ] && ok "the CSP header is on the pages" || bad "no Content-Security-Policy header on /login"
    HL=$(off "curl -s --max-time 15 https://$NAME/health 2>/dev/null" 2>/dev/null)
    [ "$HL" = ok ] && ok "/health through the edge: ok" || bad "/health through the edge: '${HL:-no answer}'"

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}homelab-notes is installed and answering on all three nodes.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"
for n in $NODES; do
    up "$n" || die "$n does not answer on :22"
    on "$n" "test -f /etc/homelab/agent/credential.yml" || die "$n has no homelab-agent credential -- run agent-enroll-orchestrate.sh 47 48 49 first"
    on "$n" "grep -q apt-homelab /etc/apt/sources.list.d/homelab.list" 2>/dev/null || die "$n has no fleet apt source (/etc/apt/sources.list.d/homelab.list)"
    ok "$n up, agent enrolled, apt source present"
done
PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"
ok "Patroni leader: $PRIMARY"
SSO_SECRET=$(on "$SSO_NODE" "sudo awk '/client_id: notes\$/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
[ -n "$SSO_SECRET" ] || die "SSO ($SSO_NODE) has no 'notes' client -- run web-name-provision.sh $NAME $PORT 47 48 49 first"
ok "read the 'notes' client secret off SSO (not logged)"
for n in $NODES; do on "$n" "apt-cache policy homelab-notes 2>/dev/null | grep -q Candidate" || on "$n" "sudo apt-get update -qq" >/dev/null 2>&1; done
CAND=$(on "$NODE1" "apt-cache policy homelab-notes 2>/dev/null | sed -n 's/.*Candidate: //p'")
[ -n "$CAND" ] && [ "$CAND" != "(none)" ] && ok "homelab-notes $CAND is available from the fleet apt repo" || die "homelab-notes is not in the apt repo as seen from $NODE1 (build-package.sh -d notes X.Y.Z)"

if [ "$DRY" = 1 ]; then
    step "would do"
    cat <<PLANNED
  1. each of $NODES: apt-get install homelab-svc-hosts
  2. $NODE1: debconf preseed (db/pgbouncer .svc.homelab, api http://api.svc.homelab:3000, :$PORT,
     advertise $(svc $NODE1), public https://$NAME, sso https://login.mailmasker.org / $SSO_INTERNAL,
     client secret from SSO, one generated session secret) then apt-get install homelab-notes
     -> stops at tier 3 with the role SQL in $PENDING
  3. from HERE: run the SQL on $PRIMARY; SCRAM into $PGB_NODES; audit grant on $PRIMARY
  4. $NODE1: dpkg-reconfigure homelab-notes -> migrations + start; /health
  5. nodes 2 and 3: node 1's config placed first (registry.host rewritten), then install
PLANNED
    note "dry run: nothing changed."
    exit 0
fi

# ----------------------------------------------------------- 1. svc-hosts
step "1. homelab-svc-hosts on every node"
for n in $NODES; do
    on "$n" "sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-svc-hosts" >/dev/null 2>&1
    r=$(on "$n" "getent hosts db.svc.homelab | awk '{print \$1}'" 2>/dev/null)
    [ -n "$r" ] && ok "$n db.svc.homelab -> $r" || bad "$n still cannot resolve db.svc.homelab"
done
[ "$RC" = 0 ] || die "stopping: the DB names must resolve before installing"

# ----------------------------------------------------------- 2. node 1
step "2. homelab-notes on $NODE1 (expected to stop for the DB runbook)"
SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n=')
preseed(){ # $1 node
    on "$1" "cat <<SEED | sudo debconf-set-selections
homelab-notes homelab-notes/db_host string db.svc.homelab
homelab-notes homelab-notes/pgbouncer_host string pgbouncer.svc.homelab
homelab-notes homelab-notes/api_base string http://api.svc.homelab:3000
homelab-notes homelab-notes/listen_port string $PORT
homelab-notes homelab-notes/advertise_host string $(svc "$1")
homelab-notes homelab-notes/public_base_url string https://$NAME
homelab-notes homelab-notes/default_timezone string America/Chicago
homelab-notes homelab-notes/sso_base_url string https://login.mailmasker.org
homelab-notes homelab-notes/sso_internal_base_url string $SSO_INTERNAL
homelab-notes homelab-notes/sso_client_secret password $SSO_SECRET
homelab-notes homelab-notes/session_secret password $SESSION_SECRET
SEED"
}
if on "$NODE1" "test -f $CONFIG"; then
    ok "$CONFIG already exists on $NODE1 (not rewriting it)"
else
    preseed "$NODE1"
    on "$NODE1" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-notes" >"$SCRATCH/install1.log" 2>&1
    on "$NODE1" "test -f $CONFIG" && ok "config written on $NODE1" || { tail -20 "$SCRATCH/install1.log" | sed 's/^/      /'; die "no $CONFIG on $NODE1"; }
fi

# ----------------------------------------------------------- 3. the runbook
step "3. the DB runbook, from here"
if psql_primary "SELECT 1 FROM pg_roles WHERE rolname='homelab_notes_runtime'" | grep -q 1; then
    ok "roles already exist (idempotent)"
else
    on "$NODE1" "sudo cat $PENDING" > "$SCRATCH/role.sql" 2>/dev/null
    [ -s "$SCRATCH/role.sql" ] || die "could not read $PENDING off $NODE1"
    ok "fetched the generated role SQL ($(wc -l < "$SCRATCH/role.sql") lines)"
    scp -q -o ConnectTimeout=15 "$SCRATCH/role.sql" "$PRIMARY:/tmp/homelab_notes-role.sql" || die "could not copy the SQL to $PRIMARY"
    if on "$PRIMARY" "sudo -u postgres psql -d homelab -X -v ON_ERROR_STOP=1 -q -f /tmp/homelab_notes-role.sql && rm -f /tmp/homelab_notes-role.sql" >/dev/null 2>&1; then
        ok "roles and schema created on $PRIMARY"
    else
        on "$PRIMARY" "rm -f /tmp/homelab_notes-role.sql" >/dev/null 2>&1
        die "the role SQL failed on $PRIMARY"
    fi
fi
step "   register the runtime role with each pgbouncer"
SCRAM=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -tAc \"SELECT rolpassword FROM pg_authid WHERE rolname='homelab_notes_runtime'\"" 2>/dev/null)
[ -n "$SCRAM" ] || die "could not read the runtime SCRAM secret from $PRIMARY"
for p in $PGB_NODES; do
    up "$p" || { warn "$p is not up -- register by hand later"; continue; }
    # Always add-or-replace (the tool is idempotent): a stale line after a
    # password reset makes /health answer 503 through the pooler.
    if on "$p" "sudo homelab-bootstrap-pgbouncer-entry --role homelab_notes_runtime --scram-secret '$SCRAM' --pgbouncer-host localhost" >/dev/null 2>&1; then ok "$p has the current SCRAM for homelab_notes_runtime"
    else bad "$p registration failed"; fi
    g=$(on "$p" "stat -c %U:%G /etc/pgbouncer/userlist.txt" 2>/dev/null)
    [ "$g" = root:postgres ] || bad "$p userlist.txt is $g, must stay root:postgres"
done
step "   audit grant (the postinst cannot reach the DB from a fleet host)"
if psql_primary "SELECT has_table_privilege('homelab_notes_runtime','audit.queue','INSERT')" | grep -q t; then ok "already granted"
elif on "$PRIMARY" "sudo -u postgres psql -d homelab -v ON_ERROR_STOP=1 -q -c \"GRANT USAGE ON SCHEMA audit TO homelab_notes_runtime; GRANT INSERT ON audit.queue TO homelab_notes_runtime; GRANT USAGE ON SEQUENCE audit.queue_id_seq TO homelab_notes_runtime;\"" >/dev/null 2>&1; then ok "granted INSERT on audit.queue"
else bad "could not grant audit.queue (shares and deletions will log a warning instead)"; fi

# ----------------------------------------------------------- 4. finish node 1
step "4. finish $NODE1 (migrations + start)"
out=$(on "$NODE1" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-notes" 2>&1)
printf '%s\n' "$out" | grep -iE "applied|migration|WARNING|configured" | sed 's/^/      /' | head -6
h=$(on "$NODE1" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
[ "$h" = 200 ] && ok "$NODE1 /health -> 200" || die "$NODE1 /health -> '${h:-no answer}'. Check: ssh $NODE1 'journalctl -u homelab-notes -n 40 --no-pager'"

# ----------------------------------------------------------- 5. nodes 2 and 3
step "5. nodes 2 and 3 (node 1's config placed first; one shared role)"
on "$NODE1" "sudo cat $CONFIG" > "$SCRATCH/config.yml" 2>/dev/null
[ -s "$SCRATCH/config.yml" ] || die "could not read $CONFIG off $NODE1"
for n in $NODES; do
    [ "$n" = "$NODE1" ] && continue
    if on "$n" "test -f $CONFIG"; then ok "$n already has a config (left as is)"
    else
        sed "s#^  host: $(svc "$NODE1")\$#  host: $(svc "$n")#" "$SCRATCH/config.yml" > "$SCRATCH/config-$n.yml"
        grep -q "^  host: $(svc "$n")\$" "$SCRATCH/config-$n.yml" || die "could not rewrite registry.host for $n"
        scp -q -o ConnectTimeout=15 "$SCRATCH/config-$n.yml" "$n:/tmp/notes-config.yml" || die "$n: copy failed"
        on "$n" "sudo adduser --system --group --home /var/lib/homelab --no-create-home --shell /usr/sbin/nologin homelab >/dev/null 2>&1 || true;
                 sudo install -d -m 755 /etc/homelab/notes && sudo install -o root -g homelab -m 640 /tmp/notes-config.yml $CONFIG && rm -f /tmp/notes-config.yml" \
            && ok "$n config placed (registry.host $(svc "$n"))" || die "$n: could not place the config"
    fi
    on "$n" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-notes" >"$SCRATCH/install-$n.log" 2>&1
    h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
    [ "$h" = 200 ] && ok "$n /health -> 200" || { tail -10 "$SCRATCH/install-$n.log" | sed 's/^/      /'; bad "$n /health -> '${h:-no answer}'"; }
done

step "verify"
exec "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" --verify
