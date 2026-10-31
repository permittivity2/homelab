#!/bin/bash
# ============================================================================
# Install homelab-search on prod-homelabvm70/71/72 (item 40, Phase 1).
#
#   ./search-orchestrate.sh --dry-run
#   ./search-orchestrate.sh
#   ./search-orchestrate.sh --verify
#   ./search-orchestrate.sh --reindex     # requeue everything, then watch
#
# WHY THE DB BOOTSTRAP IS DONE FROM HERE, BY HAND, IN THE MIDDLE.
#
# homelab-bootstrap-app-role has three tiers. On a fleet host the DB is on
# another host and there is deliberately NO guest-to-guest SSH trust, so it
# takes tier 3: it writes the config from generated passwords, drops the role
# SQL in /var/lib/homelab-database/pending/, prints a runbook, and stops. That
# is correct and must stay that way -- app hosts must not be able to reach the
# DB primary over SSH.
#
# So the runbook is executed HERE, by the operator's own workstation, which
# legitimately has SSH to both: read the SQL off the search host, run it on
# the Patroni leader, read the SCRAM back, register it with each pgbouncer.
# Nothing in that chain gives a fleet guest access to another.
#
# THE THREE HOSTS SHARE ONE POSTGRES ROLE, like the drive trio. Node 1's
# generated config is copied to nodes 2 and 3 rather than bootstrapping three
# roles for one logical service.
#
# ORDER: homelab-svc-hosts FIRST on every host. Without it db.svc.homelab and
# pgbouncer.svc.homelab do not resolve, and the migrate connection fails with
# a DNS error that reads nothing like a missing package.
# ============================================================================
set -uo pipefail

NODES="10.20.2.214 10.20.2.215 10.20.2.216"
NODE1=10.20.2.214
DB_NODES="10.20.2.150 10.20.2.151 10.20.2.152"       # prod-homelab06/07/08
PGB_NODES="10.20.2.153 10.20.2.154 10.20.2.155"      # prod-homelab09/10/11
PENDING=/var/lib/homelab-database/pending/homelab_search-bootstrap.sql
CONFIG=/etc/homelab/search/config.yml
SCRATCH="${TMPDIR:-/tmp}/search-orchestrate.$$"

DRY=0; VERIFY_ONLY=0; REINDEX=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        --reindex) REINDEX=1 ;;
        *) echo "unknown argument '$a' (usage: search-orchestrate.sh [--dry-run] [--verify] [--reindex])"; exit 1 ;;
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
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# The Patroni leader, found rather than assumed: it moves.
find_primary(){
    local n
    for n in $DB_NODES; do
        up "$n" || continue
        [ "$(on "$n" "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery()'" 2>/dev/null)" = f ] \
            && { printf '%s' "$n"; return 0; }
    done
    return 1
}

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ] || [ "$REINDEX" = 1 ]; then
    PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"

    if [ "$REINDEX" = 1 ]; then
        step "requeue everything"
        note "clears the queue and the mailbox mtime watermarks, so the next"
        note "discovery pass re-enqueues every mailbox and every drive batch."
        on "$NODE1" "sudo -u homelab env HOMELAB_SEARCH_CONFIG=$CONFIG psql_noop 2>/dev/null; true" >/dev/null 2>&1
        on "$PRIMARY" "sudo -u postgres psql -d homelab -q -c \"
            SELECT set_config('homelab.indexer','on',false);
            DELETE FROM search.index_queue;
            UPDATE search.mailboxes SET dir_mtime = NULL;\"" >/dev/null 2>&1 \
            && ok "queue cleared and watermarks reset" || bad "could not reset"
    fi

    step "packages and units"
    for n in $NODES; do
        v=$(on "$n" "dpkg-query -W -f='\${Version}' homelab-search 2>/dev/null")
        [ -n "$v" ] && ok "$n homelab-search $v" || bad "$n homelab-search not installed"
        for u in homelab-search-indexer homelab-search; do
            s=$(on "$n" "systemctl is-active $u" 2>/dev/null)
            [ "$s" = active ] && ok "$n $u active" || bad "$n $u is '$s'"
        done
        g=$(on "$n" "getent passwd vmail | cut -d: -f3" 2>/dev/null)
        [ "$g" = 5000 ] && ok "$n user vmail has uid 5000" \
                        || bad "$n user vmail uid is '${g:-missing}' -- 0700 maildirs read nothing without it"
        for u in homelab-search-indexer homelab-search; do
            ru=$(on "$n" "systemctl show $u -p User --value" 2>/dev/null)
            [ "$ru" = vmail ] && ok "$n $u runs as vmail" || bad "$n $u runs as '$ru', not vmail"
        done
        m=$(on "$n" "id -nG homelab 2>/dev/null | tr ' ' '\n' | grep -c '^vmail\$'" 2>/dev/null)
        [ "${m:-0}" -ge 1 ] && ok "$n user homelab is in vmail" || bad "$n homelab is not in group vmail"
    done

    step "the whole pool must share ONE session secret"
    # The OAuth state lives in the signed session cookie and requests are not
    # sticky across the three nodes, so a per-host secret fails two sign-ins
    # in three -- intermittently, which is the worst way to find out.
    SEC1=$(on "$NODE1" "sudo sed -n 's/^  secret: //p' $CONFIG | tr -d '\"'" 2>/dev/null)
    if [ -z "$SEC1" ]; then
        bad "no session secret in $CONFIG on $NODE1"
    else
        same=1
        for n in $NODES; do
            sx=$(on "$n" "sudo sed -n 's/^  secret: //p' $CONFIG | tr -d '\"'" 2>/dev/null)
            [ "$sx" = "$SEC1" ] || same=0
        done
        [ "$same" = 1 ] && ok "identical session secret on all three nodes" \
                        || bad "the session secret DIFFERS between nodes -- sign-in will fail ~2 times in 3"
    fi

    step "web app answers on :2517"
    for n in $NODES; do
        h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:2517/health" 2>/dev/null)
        [ "$h" = 200 ] && ok "$n /health -> 200" || bad "$n /health -> '${h:-no answer}'"
        r=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:2517/" 2>/dev/null)
        [ "$r" = 302 ] && ok "$n / -> 302 (redirects to sign-in)" || bad "$n / -> '${r:-no answer}'"
    done

    step "schema, isolation and index state"
    EXT=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"SELECT count(*) FROM pg_extension WHERE extname IN ('pg_trgm','unaccent','btree_gin')\"" 2>/dev/null)
    [ "$EXT" = 3 ] && ok "pg_trgm, unaccent, btree_gin present" || bad "only $EXT/3 extensions present"

    on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"SELECT has_table_privilege('homelab_search_runtime','drive.files','SELECT')\"" 2>/dev/null | grep -q t \
        && ok "runtime role can read drive.files" \
        || bad "runtime role cannot read drive.files -- drive indexing will find nothing"

    TBL=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"SELECT count(*) FROM information_schema.tables WHERE table_schema='search'\"" 2>/dev/null)
    [ "${TBL:-0}" -ge 18 ] && ok "$TBL tables in the search schema" || bad "only ${TBL:-0} tables in the search schema"

    # Every table that carries an account_id must have RLS on AND forced.
    NORLS=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"
        SELECT count(*) FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname='search' AND c.relkind='r'
           AND EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema='search' AND table_name=c.relname
                          AND column_name='account_id')
           AND NOT (c.relrowsecurity AND c.relforcerowsecurity)\"" 2>/dev/null)
    [ "$NORLS" = 0 ] && ok "every account-scoped table has RLS enabled AND forced" \
                     || bad "$NORLS account-scoped table(s) are missing forced RLS"

    # The invariant, checked rather than asserted: no child row may belong to a
    # different account than its parent.
    MIX=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"
        SELECT set_config('homelab.indexer','on',false);
        SELECT (SELECT count(*) FROM search.message_bodies b JOIN search.messages m USING (message_id) WHERE b.account_id <> m.account_id)
             + (SELECT count(*) FROM search.message_files  f JOIN search.messages m USING (message_id) WHERE f.account_id <> m.account_id)
             + (SELECT count(*) FROM search.message_addresses a JOIN search.messages m USING (message_id) WHERE a.account_id <> m.account_id)
             + (SELECT count(*) FROM search.attachments  t JOIN search.messages m USING (message_id) WHERE t.account_id <> m.account_id)
             + (SELECT count(*) FROM search.messages m JOIN search.mailboxes x USING (mailbox_id) WHERE m.account_id <> x.account_id)
             + (SELECT count(*) FROM search.drive_item_text d JOIN search.drive_items i USING (drive_item_id) WHERE d.account_id <> i.account_id)\"" 2>/dev/null | tail -1)
    [ "$MIX" = 0 ] && ok "no row belongs to a different account than its parent" \
                   || bad "$MIX cross-account row(s) -- the composite FKs should have made this impossible"

    step "index contents"
    on "$NODE1" "sudo -u homelab env HOMELAB_SEARCH_CONFIG=$CONFIG homelab-search-indexer --status" 2>/dev/null \
        || bad "could not read index status"

    step "queue health"
    on "$PRIMARY" "sudo -u postgres psql -d homelab -c \"
        SELECT set_config('homelab.indexer','on',false);\" -c \"
        SELECT kind, count(*) AS n, count(*) FILTER (WHERE parked) AS parked,
               count(*) FILTER (WHERE claimed_by IS NOT NULL) AS claimed
          FROM search.index_queue GROUP BY kind ORDER BY kind;\" -c \"
        SELECT host, units, items, errors, to_char(started_at,'HH24:MI:SS') AS started
          FROM search.index_runs ORDER BY run_id DESC LIMIT 6;\"" 2>/dev/null | grep -vE '^\s*$|^SET$'

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}homelab-search is installed and indexing on all three hosts.${O}" \
                  || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"
for n in $NODES; do
    up "$n" || die "$n does not answer on :22"
    for m in /srv/mail-ro /srv/drive-ro; do
        o=$(on "$n" "findmnt -rn -o OPTIONS $m" 2>/dev/null)
        [ -n "$o" ] || die "$n has no $m mounted -- run search-hosts-nfs.sh first"
        case "$o" in ro,*|*,ro|*,ro,*) : ;; *) die "$n $m is not mounted ro: $o" ;; esac
    done
    ok "$n up, both stores mounted read-only"
done

PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"
ok "Patroni leader: $PRIMARY"

EXT=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"SELECT count(*) FROM pg_extension WHERE extname IN ('pg_trgm','unaccent','btree_gin')\"" 2>/dev/null)
if [ "$EXT" = 3 ]; then
    ok "pg_trgm, unaccent and btree_gin are present"
else
    warn "only $EXT/3 of pg_trgm/unaccent/btree_gin are installed."
    warn "The migration degrades to btree fallbacks and substring search becomes"
    warn "a sequential scan. On $PRIMARY, once: CREATE EXTENSION pg_trgm;"
fi

if [ "$DRY" = 1 ]; then
    step "would do"
    cat <<PLANNED
  1. each of $NODES:
       apt-get install homelab-svc-hosts     (so db/pgbouncer.svc.homelab resolve)
  2. $NODE1:
       debconf preseed, then apt-get install homelab-search
       -> expected to stop at tier 3 with the role SQL in $PENDING
  3. from HERE (not guest-to-guest):
       read $PENDING off $NODE1
       run it on the Patroni leader $PRIMARY
       read homelab_search_runtime's SCRAM back off $PRIMARY
       register it on each of $PGB_NODES
  4. $NODE1: dpkg-reconfigure homelab-search  -> migrations + indexer start
  5. nodes 2 and 3: install, copy node 1's config (one shared role), reconfigure
PLANNED
    note "dry run: nothing changed."
    exit 0
fi

# ------------------------------------------------------- 1. svc-hosts + node 1
step "1. homelab-svc-hosts on every node"
for n in $NODES; do
    on "$n" "sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && \
             sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-svc-hosts" >/dev/null 2>&1
    r=$(on "$n" "getent hosts db.svc.homelab | awk '{print \$1}'" 2>/dev/null)
    [ -n "$r" ] && ok "$n db.svc.homelab -> $r" || bad "$n still cannot resolve db.svc.homelab"
done
[ "$RC" = 0 ] || die "stopping: the DB names must resolve before installing"

step "2. homelab-search on $NODE1 (expected to stop for the DB runbook)"
on "$NODE1" "cat <<'SEED' | sudo debconf-set-selections
homelab-search homelab-search/db_host string db.svc.homelab
homelab-search homelab-search/pgbouncer_host string pgbouncer.svc.homelab
homelab-search homelab-search/mail_root string /srv/mail-ro
homelab-search homelab-search/drive_root string /srv/drive-ro
homelab-search homelab-search/listen_port string 2517
SEED
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-search" >/dev/null 2>&1
on "$NODE1" "test -f $CONFIG" && ok "config written on $NODE1" || die "no $CONFIG on $NODE1"

# --------------------------------------------------- 3. the DB runbook, by hand
step "3. run the role bootstrap on the leader (from here, never guest-to-guest)"
if on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"SELECT 1 FROM pg_roles WHERE rolname='homelab_search_runtime'\"" 2>/dev/null | grep -q 1; then
    ok "roles already exist (idempotent)"
else
    on "$NODE1" "sudo cat $PENDING" > "$SCRATCH/role.sql" 2>/dev/null
    [ -s "$SCRATCH/role.sql" ] || die "could not read $PENDING off $NODE1"
    ok "fetched the generated role SQL ($(wc -l < "$SCRATCH/role.sql") lines)"
    scp -q -o ConnectTimeout=15 "$SCRATCH/role.sql" "$PRIMARY:/tmp/homelab_search-role.sql" \
        || die "could not copy the SQL to $PRIMARY"
    if on "$PRIMARY" "sudo -u postgres psql -d homelab -v ON_ERROR_STOP=1 -q -f /tmp/homelab_search-role.sql && rm -f /tmp/homelab_search-role.sql" >/dev/null 2>&1; then
        ok "roles and schema created on $PRIMARY"
    else
        on "$PRIMARY" "rm -f /tmp/homelab_search-role.sql" >/dev/null 2>&1
        die "the role SQL failed on $PRIMARY"
    fi
fi

step "   grant the runtime role READ access to drive's two tables"
note "The indexer drives the drive half from drive's own tables (exact, and it"
note "keeps the never-enumerate-the-blob-store rule). Each app's role is scoped"
note "to its own schema, so without this the indexer gets 'permission denied for"
note "schema drive' -- which is correct behaviour, not a bug to route around."
note "SELECT on exactly two tables, nothing wider. Same shape as the existing"
note "homelab-audit-grant-queue-insert cross-feature grant."
if on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"SELECT has_table_privilege('homelab_search_runtime','drive.files','SELECT')\"" 2>/dev/null | grep -q t; then
    ok "already granted (idempotent)"
elif on "$PRIMARY" "sudo -u postgres psql -d homelab -v ON_ERROR_STOP=1 -q -c \"
        GRANT USAGE ON SCHEMA drive TO homelab_search_runtime;
        GRANT SELECT ON drive.files TO homelab_search_runtime;
        GRANT SELECT ON drive.folders TO homelab_search_runtime;\"" >/dev/null 2>&1; then
    ok "granted SELECT on drive.files and drive.folders"
else
    bad "could not grant drive read access"
fi

step "   register the runtime role with each pgbouncer"
SCRAM=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -tAc \"SELECT rolpassword FROM pg_authid WHERE rolname='homelab_search_runtime'\"" 2>/dev/null)
[ -n "$SCRAM" ] || die "could not read the runtime SCRAM secret from $PRIMARY"
ok "read the SCRAM secret (not logged)"
for p in $PGB_NODES; do
    up "$p" || { warn "$p is not up -- register by hand later"; continue; }
    if on "$p" "sudo grep -q homelab_search_runtime /etc/pgbouncer/userlist.txt" 2>/dev/null; then
        ok "$p already has the role"
    elif on "$p" "sudo homelab-bootstrap-pgbouncer-entry --role homelab_search_runtime --scram-secret '$SCRAM' --pgbouncer-host localhost" >/dev/null 2>&1; then
        ok "$p registered"
    else
        bad "$p registration failed"
    fi
done

# ------------------------------------------------- 3b. web-app config blocks
step "3b. web-app config on $NODE1 (sso, session, public_base_url)"
# The config written at first install predates the web app, and postinst will
# not touch an existing config.yml -- so the sso/session/public_base_url blocks
# are appended here, with the client secret read from SSO rather than pasted.
if on "$NODE1" "grep -q '^sso:' $CONFIG" 2>/dev/null; then
    ok "already has the web-app blocks (idempotent)"
else
    SSO_SECRET=$(on 10.20.2.162 "sudo awk '/client_id: search/{f=1} f&&/client_secret:/{print \$2; exit}' /etc/homelab/sso/config.yml" 2>/dev/null)
    [ -n "$SSO_SECRET" ] || die "could not read the 'search' client secret from SSO (10.20.2.162).
Register the client first -- see search-vhost-provision.sh."
    ok "read the SSO client secret for client_id 'search' (not logged)"

    # ONE session secret for the whole pool, generated here. A per-host secret
    # is the trap this fleet has hit before: the OAuth state lives in the
    # signed session cookie, requests are not sticky, so two requests in three
    # would land on a node that cannot read the cookie it is handed and the
    # sign-in would fail intermittently.
    SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n=')

    on "$NODE1" "sudo tee -a $CONFIG >/dev/null <<'SEARCHWEB'

sso:
  base_url: https://login.mailmasker.org
  internal_base_url: http://10.50.2.162:2502
  client_id: search
  client_secret: __SSO_SECRET__
  redirect_uri: https://search.mailmasker.org/oauth/callback

public_base_url: https://search.mailmasker.org

homelab_api:
  base_url: http://api.svc.homelab:3000

session:
  secret: \"__SESSION_SECRET__\"

web_theme:
  base_url: https://static.mailmasker.org
SEARCHWEB
sudo sed -i -e \"s#__SSO_SECRET__#$SSO_SECRET#\" -e \"s#__SESSION_SECRET__#$SESSION_SECRET#\" $CONFIG" \
        && ok "appended the web-app blocks" || bad "could not append the web-app blocks"
fi

step "3c. normalise the web-app config on $NODE1"
# Always run, not guarded by 3b's "already has sso:" check -- an earlier
# version of this script appended a registry: block that cannot work (the app
# runs as vmail and the agent credential is 0600 homelab:homelab), and left
# hypnotoad with no writable pid path. Hosts configured by that version have
# to be repaired, not skipped.
on "$NODE1" "sudo perl -0pi -e 's/\nregistry:\n  host: [^\n]*\n  port: [^\n]*\n//' $CONFIG" 2>/dev/null \
    && ok "no registry: block (it cannot work for this app)" || warn "could not strip registry:"
if on "$NODE1" "grep -q 'pid_file: /run/homelab-search' $CONFIG" 2>/dev/null; then
    ok "hypnotoad pid_file points at the runtime directory"
else
    on "$NODE1" "sudo perl -0pi -e 's#(  listen: \"http://0\.0\.0\.0:2517\"\n  workers: 2\n)#\$1  pid_file: /run/homelab-search/hypnotoad.pid\n#' $CONFIG" 2>/dev/null \
        && ok "pid_file set to /run/homelab-search/hypnotoad.pid" || warn "could not set pid_file"
fi

# ------------------------------------------------------- 4/5. finish all nodes
step "4. finish $NODE1 (migrations + indexer + web app)"
out=$(on "$NODE1" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-search" 2>&1)
printf '%s\n' "$out" | grep -iE "applied|migration|pg_trgm|NOTE|WARNING|configured" | sed 's/^/      /' | head -8
on "$NODE1" "systemctl is-active --quiet homelab-search-indexer" \
    && ok "indexer running on $NODE1" || bad "indexer not running on $NODE1"

step "5. nodes 2 and 3 (same shared role, so node 1's config is copied)"
for n in $NODES; do
    [ "$n" = "$NODE1" ] && continue
    on "$n" "cat <<'SEED' | sudo debconf-set-selections
homelab-search homelab-search/db_host string db.svc.homelab
homelab-search homelab-search/pgbouncer_host string pgbouncer.svc.homelab
homelab-search homelab-search/mail_root string /srv/mail-ro
homelab-search homelab-search/drive_root string /srv/drive-ro
homelab-search homelab-search/listen_port string 2517
SEED
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-search" >/dev/null 2>&1
    # Copy node 1's config: one logical service, one Postgres role. Via the
    # workstation, so no guest-to-guest path is created.
    on "$NODE1" "sudo cat $CONFIG" > "$SCRATCH/config.yml" 2>/dev/null
    [ -s "$SCRATCH/config.yml" ] || { bad "could not read $CONFIG off $NODE1"; continue; }
    scp -q -o ConnectTimeout=15 "$SCRATCH/config.yml" "$n:/tmp/search-config.yml" || { bad "$n copy failed"; continue; }
    on "$n" "sudo install -o root -g homelab -m 640 /tmp/search-config.yml $CONFIG && rm -f /tmp/search-config.yml" \
        && ok "$n config placed" || { bad "$n could not place config"; continue; }
    on "$n" "sudo systemctl restart homelab-search-indexer" >/dev/null 2>&1
    on "$n" "systemctl is-active --quiet homelab-search-indexer" \
        && ok "$n indexer running" || bad "$n indexer not running"
done

step "verify"
exec "$0" --verify
