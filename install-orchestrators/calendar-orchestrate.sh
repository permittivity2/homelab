#!/bin/bash
# ============================================================================
# Install homelab-calendar on prod-homelab50/51/52 (post-cutover #74).
#
#   ./calendar-orchestrate.sh --dry-run
#   ./calendar-orchestrate.sh
#   ./calendar-orchestrate.sh --verify
#
# Same shape as search-orchestrate.sh / block-link-orchestrate.sh:
#   * homelab-agent must already be enrolled on the three nodes
#     (agent-enroll-orchestrate.sh 50 51 52): the app registers itself with
#     homelab-api using the agent credential.
#   * the public name, cert, vhosts and SSO client come first
#     (web-name-provision.sh calendar.mailmasker.org 2519 50 51 52); the SSO
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

NODES="10.20.2.194 10.20.2.195 10.20.2.196"
NODE1=10.20.2.194
DB_NODES="10.20.2.150 10.20.2.151 10.20.2.152"
PGB_NODES="10.20.2.153 10.20.2.154 10.20.2.155"
SSO_NODE=10.20.2.162
SSO_INTERNAL=http://10.50.2.162:2502
NAME=calendar.mailmasker.org
PORT=2519
PENDING=/var/lib/homelab-database/pending/homelab_calendar-bootstrap.sql
CONFIG=/etc/homelab/calendar/config.yml
SSO_CONF=/etc/homelab/sso/config.yml
SCRATCH="${TMPDIR:-/tmp}/calendar-orchestrate.$$"

MAIL_NODES="10.20.2.183 10.20.2.184 10.20.2.185"     # prod-homelab39/40/41 (postfix + the block-link milter)
MILTER_CONFIG=/etc/homelab/postfix-block-link/config.yml

DRIVE_NODE=10.20.2.209                               # vm65: its mailer: block is the one the calendar copies
DRIVE_CONFIG=/etc/homelab/drive/config.yml

DRY=0; VERIFY_ONLY=0; MAIL_LINKS=0; MAILER=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        --mail-links) MAIL_LINKS=1 ;;
        --mailer)  MAILER=1 ;;
        *) echo "unknown argument '$a' (usage: calendar-orchestrate.sh [--dry-run] [--verify] [--mail-links] [--mailer])"; exit 1 ;;
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

# ---------------------------------------------------- --mail-links (phase 3)
# The mail side of "Add to calendar" links: the milter role's grants on the
# two calendar tables (applied HERE on the leader: a fleet host's postinst
# cannot reach the DB), the calendar: block in the milter's config on the
# three mail nodes, and a restart. Run before or right after upgrading
# homelab-postfix-block-link to >= 0.2.4; idempotent.
if [ "$MAIL_LINKS" = 1 ]; then
    PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"
    step "grants for the milter role(s) on $PRIMARY"
    ROLES=$(psql_primary "SELECT string_agg(rolname, ' ') FROM pg_roles WHERE rolname LIKE 'homelab_postfix_block_link%'")
    [ -n "$ROLES" ] || die "no homelab_postfix_block_link* role on $PRIMARY"
    for role in $ROLES; do
        # #85 (milter >= 0.2.5): INSERT on itip_inbox too (calendar migration 007 must have run).
        if psql_primary "SELECT has_table_privilege('$role','calendar.mail_links','INSERT') AND has_table_privilege('$role','calendar.account_settings','SELECT') AND has_table_privilege('$role','calendar.itip_inbox','INSERT')" 2>/dev/null | grep -q t; then
            ok "$role already has the calendar grants (mail_links, account_settings, itip_inbox)"
        elif on "$PRIMARY" "sudo -u postgres psql -d homelab -v ON_ERROR_STOP=1 -q -c \"GRANT USAGE ON SCHEMA calendar TO \\\"$role\\\"; GRANT SELECT ON calendar.account_settings TO \\\"$role\\\"; GRANT INSERT ON calendar.mail_links TO \\\"$role\\\"; GRANT USAGE ON SEQUENCE calendar.mail_links_id_seq TO \\\"$role\\\"; GRANT INSERT ON calendar.itip_inbox TO \\\"$role\\\"; GRANT USAGE ON SEQUENCE calendar.itip_inbox_id_seq TO \\\"$role\\\";\"" >/dev/null 2>&1; then
            ok "$role: SELECT account_settings, INSERT mail_links + itip_inbox (+ sequences) granted"
        else bad "$role: could not grant"; fi
    done
    step "the calendar: block in the milter's config on $MAIL_NODES"
    for n in $MAIL_NODES; do
        up "$n" || { bad "$n down"; continue; }
        v=$(on "$n" "dpkg-query -W -f='\${Version}' homelab-postfix-block-link 2>/dev/null")
        if on "$n" "sudo grep -q '^calendar:' $MILTER_CONFIG"; then ok "$n config already has the calendar: block (milter $v)"
        else
            on "$n" "sudo cp -a $MILTER_CONFIG $MILTER_CONFIG.bak-\$(date +%Y%m%d-%H%M%S) && printf '\n# Add-to-calendar links (post-cutover #74 phase 3); calendar-orchestrate.sh --mail-links\ncalendar:\n  public_base_url: https://$NAME\n  link_ttl_days: 30\n  excerpt_chars: 16000\n' | sudo tee -a $MILTER_CONFIG >/dev/null && sudo perl -MYAML::XS -e 'YAML::XS::LoadFile(q{$MILTER_CONFIG})'" \
                && ok "$n calendar: block written (milter $v)" || { bad "$n could not write the block"; continue; }
        fi
        on "$n" "sudo systemctl restart homelab-postfix-block-link" >/dev/null 2>&1; sleep 2
        s=$(on "$n" "systemctl is-active homelab-postfix-block-link" 2>/dev/null)
        [ "$s" = active ] && ok "$n milter active after restart" || bad "$n milter is '$s' after restart -- mail is tempfailing, look now: ssh $n 'journalctl -u homelab-postfix-block-link -n 30 --no-pager'"
    done
    step "result"
    [ "$RC" = 0 ] && echo "  ${G}mail side ready: consenting accounts get the link on the next inbound message.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------ --mailer (#79)
# Reminders and share notices need a submission account. Drive's mailer: block
# (noreply@, the edge submission VIP, its password) is copied node to node
# over ssh -- never printed, never on a command line -- into the calendar's
# config on each pool node, validated, and the app restarted. Idempotent.
if [ "$MAILER" = 1 ]; then
    step "drive's mailer: block ($DRIVE_NODE) -> the calendar's config on $NODES"
    up "$DRIVE_NODE" || die "$DRIVE_NODE (drive) is not up"
    on "$DRIVE_NODE" "sudo awk '/^mailer:/{f=1; print; next} f&&/^[^ #]/{exit} f' $DRIVE_CONFIG" > "$SCRATCH/mailer.yml" 2>/dev/null
    grep -q '^mailer:' "$SCRATCH/mailer.yml" && grep -q 'smtp_host:' "$SCRATCH/mailer.yml" && grep -q 'smtp_password:' "$SCRATCH/mailer.yml" \
        || die "could not read a complete mailer: block from $DRIVE_NODE:$DRIVE_CONFIG"
    HOST=$(sed -n 's/^ *smtp_host: *//p' "$SCRATCH/mailer.yml" | tr -d '"'); FROM=$(sed -n 's/^ *email: *//p' "$SCRATCH/mailer.yml" | tr -d '"')
    note "from $FROM via $HOST (the password is not shown)"
    for n in $NODES; do
        up "$n" || { bad "$n down"; continue; }
        if on "$n" "sudo grep -q '^mailer:' $CONFIG"; then ok "$n config already has a mailer: block (not touched)"
        else
            { printf '\n# Reminders and share notices (post-cutover #79); calendar-orchestrate.sh --mailer (copied from drive)\n'; cat "$SCRATCH/mailer.yml"; } \
                | on_in "$n" "sudo cp -a $CONFIG $CONFIG.bak-\$(date +%Y%m%d-%H%M%S) && sudo tee -a $CONFIG >/dev/null && sudo perl -MYAML::XS -e 'my \$c = YAML::XS::LoadFile(q{$CONFIG}); exit((ref \$c->{mailer} eq q{HASH} && \$c->{mailer}{smtp_host}) ? 0 : 1)'" \
                && ok "$n mailer: block written and parsed" || { bad "$n could not write the block (a .bak-* copy of the config is beside it)"; continue; }
            on "$n" "sudo systemctl restart homelab-calendar" >/dev/null 2>&1; sleep 3
        fi
        h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
        [ "$h" = 200 ] && ok "$n /health -> 200" || bad "$n /health -> '${h:-no answer}' -- look: ssh $n 'sudo journalctl -u homelab-calendar -n 30 --no-pager'"
        # Since THIS start of the unit: an earlier start (the upgrade's) warned before the block existed.
        on "$n" "sudo journalctl -u homelab-calendar --since \"\$(systemctl show homelab-calendar -p ActiveEnterTimestamp --value)\" --no-pager 2>/dev/null | grep -q 'no mailer: configured'" \
            && bad "$n still warns about a missing mailer" || ok "$n no 'no mailer' warning since the unit's last start"
    done
    step "result"
    [ "$RC" = 0 ] && echo "  ${G}reminders can be sent from all three nodes.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ]; then
    PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"

    step "packages, units, registration"
    for n in $NODES; do
        v=$(on "$n" "dpkg-query -W -f='\${Version}' homelab-calendar 2>/dev/null")
        [ -n "$v" ] && ok "$n homelab-calendar $v" || bad "$n homelab-calendar not installed"
        s=$(on "$n" "systemctl is-active homelab-calendar" 2>/dev/null)
        [ "$s" = active ] && ok "$n homelab-calendar active" || bad "$n homelab-calendar is '$s'"
        s=$(on "$n" "systemctl is-active homelab-agent" 2>/dev/null)
        [ "$s" = active ] && ok "$n homelab-agent active" || bad "$n homelab-agent is '$s' (the app cannot register without it)"
        h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
        [ "$h" = 200 ] && ok "$n /health -> 200" || bad "$n /health -> '${h:-no answer}'"
        r=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/" 2>/dev/null)
        [ "$r" = 302 ] && ok "$n / -> 302 (to sign-in)" || bad "$n / -> '${r:-no answer}'"
        m=$(on "$n" "free -m | awk '/Mem:/{print \$3\"/\"\$2}'" 2>/dev/null); note "$n memory used/total MB: $m"
    done
    REG=$(psql_primary "SELECT count(*) FROM api.service_registry WHERE feature_name='homelab-calendar'")
    [ "${REG:-0}" = 3 ] && ok "all three nodes in the service registry" || bad "${REG:-0}/3 nodes in the service registry"

    step "one pool, one secret"
    SEC1=$(on "$NODE1" "sudo sed -n 's/^  secret: //p' $CONFIG | tr -d '\"'" 2>/dev/null)
    if [ -z "$SEC1" ]; then bad "no session secret in $CONFIG on $NODE1"
    else
        same=1; for n in $NODES; do [ "$(on "$n" "sudo sed -n 's/^  secret: //p' $CONFIG | tr -d '\"'" 2>/dev/null)" = "$SEC1" ] || same=0; done
        [ "$same" = 1 ] && ok "identical session secret on all three nodes" || bad "the session secret DIFFERS between nodes -- sign-in fails 2 times in 3"
    fi
    CS=$(on "$SSO_NODE" "sudo awk '/client_id: calendar\$/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
    AS=$(on "$NODE1" "sudo awk '/^sso:/{f=1} f&&/client_secret:/{print \$2; exit}' $CONFIG" 2>/dev/null)
    [ -n "$CS" ] && [ "$CS" = "$AS" ] && ok "the app's client_secret matches SSO's 'calendar' client" || bad "the app's client_secret does not match SSO's (or the client is missing)"
    for n in $NODES; do
        rh=$(on "$n" "sudo sed -n 's/^  host: //p' $CONFIG | tail -1" 2>/dev/null)
        [ "$rh" = "$(svc "$n")" ] && ok "$n registry.host = $rh" || bad "$n registry.host is '$rh', expected $(svc "$n")"
    done

    step "schema and grants"
    TBL=$(psql_primary "SELECT count(*) FROM information_schema.tables WHERE table_schema='calendar'")
    [ "${TBL:-0}" -ge 13 ] && ok "$TBL tables in the calendar schema" || bad "only ${TBL:-0} tables in the calendar schema (expected 13 incl. schema_migrations; 0.1.8 added reminders, reminder_addresses, reminder_queue; 0.1.10 mail_link_events)"
    psql_primary "SELECT has_table_privilege('homelab_calendar_runtime','audit.queue','INSERT')" | grep -q t \
        && ok "runtime role may write audit.queue" || bad "runtime role cannot write audit.queue (shares and deletions log a warning instead of an audit line)"
    psql_primary "SELECT has_table_privilege('homelab_calendar_runtime','calendar.reminder_queue','UPDATE')" | grep -q t \
        && ok "runtime role may claim reminder_queue rows" || bad "runtime role cannot update calendar.reminder_queue (default privileges missing?)"
    psql_primary "SELECT count(*) FROM calendar.calendars WHERE deleted_at IS NULL" | sed 's/^/      calendars: /'
    psql_primary "SELECT count(*) FROM calendar.events WHERE deleted_at IS NULL" | sed 's/^/      events: /'
    psql_primary "SELECT count(*) FROM calendar.reminders" | sed 's/^/      events with a reminder: /'
    psql_primary "SELECT state || ': ' || count(*) FROM calendar.reminder_queue GROUP BY state ORDER BY state" | sed 's/^/      reminder queue  /'
    psql_primary "SELECT coalesce(job_state, 'untouched') || ': ' || count(*) FROM calendar.mail_links WHERE expires_at > now() GROUP BY job_state ORDER BY 1" | sed 's/^/      mail links  /'

    step "the runner (#79/#80)"
    for n in $NODES; do
        if on "$n" "sudo grep -q '^mailer:' $CONFIG"; then ok "$n has a mailer: block (reminders can be sent)"; else bad "$n has no mailer: block -- run: calendar-orchestrate.sh --mailer"; fi
        on "$n" "sudo journalctl -u homelab-calendar --since '-1 hour' --no-pager 2>/dev/null | grep -c 'calendar runner:.*failed'" 2>/dev/null | { read -r c; [ "${c:-0}" = 0 ] && ok "$n no runner failures in the last hour" || bad "$n $c runner failure line(s) in the last hour: ssh $n 'sudo journalctl -u homelab-calendar --since -1h --no-pager | grep runner'"; }
    done

    step "from the internet (offsite)"
    H=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$NAME/ 2>/dev/null" 2>/dev/null)
    [ "$H" = 302 ] && ok "https://$NAME/ -> 302 (to sign-in)" || bad "https://$NAME/ -> '${H:-no answer}'"
    L=$(off "curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 https://$NAME/login 2>/dev/null" 2>/dev/null)
    case "$L" in https://login.mailmasker.org/oauth/authorize*client_id=calendar*) ok "/login -> homelab-sso as client 'calendar'" ;; *) bad "/login -> '${L:-nothing}'" ;; esac
    J=$(off "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$NAME/vendor/fullcalendar/index.global.min.js 2>/dev/null" 2>/dev/null)
    [ "$J" = 200 ] && ok "the FullCalendar bundle is served" || bad "bundle -> '${J:-no answer}'"
    HL=$(off "curl -s --max-time 15 https://$NAME/health 2>/dev/null" 2>/dev/null)
    [ "$HL" = ok ] && ok "/health through the edge: ok" || bad "/health through the edge: '${HL:-no answer}'"

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}homelab-calendar is installed and answering on all three nodes.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"
for n in $NODES; do
    up "$n" || die "$n does not answer on :22"
    on "$n" "test -f /etc/homelab/agent/credential.yml" || die "$n has no homelab-agent credential -- run agent-enroll-orchestrate.sh 50 51 52 first"
    on "$n" "grep -q apt-homelab /etc/apt/sources.list.d/homelab.list" 2>/dev/null || die "$n has no fleet apt source (/etc/apt/sources.list.d/homelab.list)"
    ok "$n up, agent enrolled, apt source present"
done
PRIMARY=$(find_primary) || die "could not find the Patroni leader among $DB_NODES"
ok "Patroni leader: $PRIMARY"
SSO_SECRET=$(on "$SSO_NODE" "sudo awk '/client_id: calendar\$/{f=1} f&&/client_secret:/{print \$2; exit}' $SSO_CONF" 2>/dev/null)
[ -n "$SSO_SECRET" ] || die "SSO ($SSO_NODE) has no 'calendar' client -- run web-name-provision.sh $NAME $PORT 50 51 52 first"
ok "read the 'calendar' client secret off SSO (not logged)"
for n in $NODES; do on "$n" "apt-cache policy homelab-calendar 2>/dev/null | grep -q Candidate" || on "$n" "sudo apt-get update -qq" >/dev/null 2>&1; done
CAND=$(on "$NODE1" "apt-cache policy homelab-calendar 2>/dev/null | sed -n 's/.*Candidate: //p'")
[ -n "$CAND" ] && [ "$CAND" != "(none)" ] && ok "homelab-calendar $CAND is available from the fleet apt repo" || die "homelab-calendar is not in the apt repo as seen from $NODE1 (build-package.sh -d calendar X.Y.Z)"

if [ "$DRY" = 1 ]; then
    step "would do"
    cat <<PLANNED
  1. each of $NODES: apt-get install homelab-svc-hosts
  2. $NODE1: debconf preseed (db/pgbouncer .svc.homelab, api http://api.svc.homelab:3000, :$PORT,
     advertise $(svc $NODE1), public https://$NAME, sso https://login.mailmasker.org / $SSO_INTERNAL,
     client secret from SSO, one generated session secret) then apt-get install homelab-calendar
     -> stops at tier 3 with the role SQL in $PENDING
  3. from HERE: run the SQL on $PRIMARY; SCRAM into $PGB_NODES; audit grant on $PRIMARY
  4. $NODE1: dpkg-reconfigure homelab-calendar -> migrations + start; /health
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
step "2. homelab-calendar on $NODE1 (expected to stop for the DB runbook)"
SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n=')
preseed(){ # $1 node
    on "$1" "cat <<SEED | sudo debconf-set-selections
homelab-calendar homelab-calendar/db_host string db.svc.homelab
homelab-calendar homelab-calendar/pgbouncer_host string pgbouncer.svc.homelab
homelab-calendar homelab-calendar/api_base string http://api.svc.homelab:3000
homelab-calendar homelab-calendar/listen_port string $PORT
homelab-calendar homelab-calendar/advertise_host string $(svc "$1")
homelab-calendar homelab-calendar/public_base_url string https://$NAME
homelab-calendar homelab-calendar/default_timezone string America/Chicago
homelab-calendar homelab-calendar/sso_base_url string https://login.mailmasker.org
homelab-calendar homelab-calendar/sso_internal_base_url string $SSO_INTERNAL
homelab-calendar homelab-calendar/sso_client_secret password $SSO_SECRET
homelab-calendar homelab-calendar/session_secret password $SESSION_SECRET
SEED"
}
if on "$NODE1" "test -f $CONFIG"; then
    ok "$CONFIG already exists on $NODE1 (not rewriting it)"
else
    preseed "$NODE1"
    on "$NODE1" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-calendar" >"$SCRATCH/install1.log" 2>&1
    on "$NODE1" "test -f $CONFIG" && ok "config written on $NODE1" || { tail -20 "$SCRATCH/install1.log" | sed 's/^/      /'; die "no $CONFIG on $NODE1"; }
fi

# ----------------------------------------------------------- 3. the runbook
step "3. the DB runbook, from here"
if psql_primary "SELECT 1 FROM pg_roles WHERE rolname='homelab_calendar_runtime'" | grep -q 1; then
    ok "roles already exist (idempotent)"
else
    on "$NODE1" "sudo cat $PENDING" > "$SCRATCH/role.sql" 2>/dev/null
    [ -s "$SCRATCH/role.sql" ] || die "could not read $PENDING off $NODE1"
    ok "fetched the generated role SQL ($(wc -l < "$SCRATCH/role.sql") lines)"
    scp -q -o ConnectTimeout=15 "$SCRATCH/role.sql" "$PRIMARY:/tmp/homelab_calendar-role.sql" || die "could not copy the SQL to $PRIMARY"
    if on "$PRIMARY" "sudo -u postgres psql -d homelab -X -v ON_ERROR_STOP=1 -q -f /tmp/homelab_calendar-role.sql && rm -f /tmp/homelab_calendar-role.sql" >/dev/null 2>&1; then
        ok "roles and schema created on $PRIMARY"
    else
        on "$PRIMARY" "rm -f /tmp/homelab_calendar-role.sql" >/dev/null 2>&1
        die "the role SQL failed on $PRIMARY"
    fi
fi
step "   register the runtime role with each pgbouncer"
SCRAM=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -tAc \"SELECT rolpassword FROM pg_authid WHERE rolname='homelab_calendar_runtime'\"" 2>/dev/null)
[ -n "$SCRAM" ] || die "could not read the runtime SCRAM secret from $PRIMARY"
for p in $PGB_NODES; do
    up "$p" || { warn "$p is not up -- register by hand later"; continue; }
    # Always add-or-replace (the tool is idempotent): a stale line after a
    # password reset makes /health answer 503 through the pooler.
    if on "$p" "sudo homelab-bootstrap-pgbouncer-entry --role homelab_calendar_runtime --scram-secret '$SCRAM' --pgbouncer-host localhost" >/dev/null 2>&1; then ok "$p has the current SCRAM for homelab_calendar_runtime"
    else bad "$p registration failed"; fi
    g=$(on "$p" "stat -c %U:%G /etc/pgbouncer/userlist.txt" 2>/dev/null)
    [ "$g" = root:postgres ] || bad "$p userlist.txt is $g, must stay root:postgres"
done
step "   audit grant (the postinst cannot reach the DB from a fleet host)"
if psql_primary "SELECT has_table_privilege('homelab_calendar_runtime','audit.queue','INSERT')" | grep -q t; then ok "already granted"
elif on "$PRIMARY" "sudo -u postgres psql -d homelab -v ON_ERROR_STOP=1 -q -c \"GRANT USAGE ON SCHEMA audit TO homelab_calendar_runtime; GRANT INSERT ON audit.queue TO homelab_calendar_runtime; GRANT USAGE ON SEQUENCE audit.queue_id_seq TO homelab_calendar_runtime;\"" >/dev/null 2>&1; then ok "granted INSERT on audit.queue"
else bad "could not grant audit.queue (shares and deletions will log a warning instead)"; fi

# ----------------------------------------------------------- 4. finish node 1
step "4. finish $NODE1 (migrations + start)"
out=$(on "$NODE1" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-calendar" 2>&1)
printf '%s\n' "$out" | grep -iE "applied|migration|WARNING|configured" | sed 's/^/      /' | head -6
h=$(on "$NODE1" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
[ "$h" = 200 ] && ok "$NODE1 /health -> 200" || die "$NODE1 /health -> '${h:-no answer}'. Check: ssh $NODE1 'journalctl -u homelab-calendar -n 40 --no-pager'"

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
        scp -q -o ConnectTimeout=15 "$SCRATCH/config-$n.yml" "$n:/tmp/calendar-config.yml" || die "$n: copy failed"
        on "$n" "sudo adduser --system --group --home /var/lib/homelab --no-create-home --shell /usr/sbin/nologin homelab >/dev/null 2>&1 || true;
                 sudo install -d -m 755 /etc/homelab/calendar && sudo install -o root -g homelab -m 640 /tmp/calendar-config.yml $CONFIG && rm -f /tmp/calendar-config.yml" \
            && ok "$n config placed (registry.host $(svc "$n"))" || die "$n: could not place the config"
    fi
    on "$n" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-calendar" >"$SCRATCH/install-$n.log" 2>&1
    h=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$PORT/health" 2>/dev/null)
    [ "$h" = 200 ] && ok "$n /health -> 200" || { tail -10 "$SCRATCH/install-$n.log" | sed 's/^/      /'; bad "$n /health -> '${h:-no answer}'"; }
done

step "verify"
exec "$0" --verify
