#!/bin/bash
# ============================================================================
# Install homelab-ai on prod-homelab53 and wire the callers to it (#76).
#
#   ./ai-orchestrate.sh --dry-run
#   ./ai-orchestrate.sh                   # install on 53; tokens for search + calendar
#   ./ai-orchestrate.sh --wire-search     # point search (70/71/72) at it, key moved
#   ./ai-orchestrate.sh --wire-calendar   # point calendar (50/51/52) at it
#   ./ai-orchestrate.sh --verify
#
# ONE node to start (Gardner, 2026-11-14: AI is not critical; callers degrade
# to their non-AI paths when it is down). Same install shape as every pool
# app: tier-3 role bootstrap with the runbook run FROM HERE, never guest to
# guest.
#
# THE KEY MOVES. Search has held the Anthropic key in its own config since
# item 40. This script reads it off the first search node, writes it into
# the AI service's config, and -- in --wire-search, once a homelab-search
# that speaks to the service is installed -- blanks it in the search configs.
# Nothing prints it. Each caller gets its own client token, generated here,
# kept only in the AI config and that caller's config.
# ============================================================================
set -uo pipefail

NODE=10.20.2.197            # prod-homelab53
SVC=10.50.2.197
PORT=2521
DB_NODES="10.20.2.150 10.20.2.151 10.20.2.152"
PGB_NODES="10.20.2.153 10.20.2.154 10.20.2.155"
SEARCH_NODES="10.20.2.214 10.20.2.215 10.20.2.216"
CAL_NODES="10.20.2.194 10.20.2.195 10.20.2.196"
PENDING=/var/lib/homelab-database/pending/homelab_ai-bootstrap.sql
CONFIG=/etc/homelab/ai/config.yml
SEARCH_CONFIG=/etc/homelab/search/config.yml
CAL_CONFIG=/etc/homelab/calendar/config.yml
SEARCH_MIN_VERSION=0.3.9    # first homelab-search that reads ai.service_url
CAL_MIN_VERSION=0.1.4       # first homelab-calendar that reads ai.service_url
SCRATCH="${TMPDIR:-/tmp}/ai-orchestrate.$$"

MODE=install
for a in "$@"; do
    case "$a" in
        --dry-run) MODE=dry ;;
        --verify) MODE=verify ;;
        --wire-search) MODE=wire-search ;;
        --wire-calendar) MODE=wire-calendar ;;
        *) echo "unknown argument '$a' (see the header of $0)"; exit 1 ;;
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
onin(){ ssh -o ConnectTimeout=15 -o BatchMode=yes "$1" "${@:2}"; }     # stdin passes through
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }
find_primary(){ local n; for n in $DB_NODES; do up "$n" || continue; [ "$(on "$n" "sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery()'" 2>/dev/null)" = f ] && { printf '%s' "$n"; return 0; }; done; return 1; }
psql_primary(){ on "$PRIMARY" "sudo -u postgres psql -d homelab -Atc \"$1\"" 2>/dev/null; }
# A client's token as the AI config has it (empty when absent). Read with
# YAML::XS so the structure, not a regex, decides.
client_token(){ on "$NODE" "sudo perl -MYAML::XS -e 'my \$c = YAML::XS::LoadFile(q{$CONFIG}); for (@{\$c->{clients} // []}) { print \$_->{token} if \$_->{name} eq q{$1} }'" 2>/dev/null; }
ver_ge(){ [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
health(){ on "$1" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$2/health" 2>/dev/null; }

# ----------------------------------------------------------------- verify
verify(){
    step "homelab-ai on prod-homelab53"
    v=$(on "$NODE" "dpkg-query -W -f='\${Version}' homelab-ai 2>/dev/null"); [ -n "$v" ] && ok "homelab-ai $v" || bad "homelab-ai not installed"
    s=$(on "$NODE" "systemctl is-active homelab-ai" 2>/dev/null); [ "$s" = active ] && ok "unit active" || bad "unit is '$s'"
    h=$(health "$NODE" "$PORT"); [ "$h" = 200 ] && ok "/health -> 200" || bad "/health -> '${h:-no answer}'"
    on "$NODE" "sudo grep -qE '^  api_key: \".+\"' $CONFIG" && ok "an API key is configured (not shown)" || bad "no API key in $CONFIG"
    for cl in search calendar; do
        tok=$(client_token "$cl")
        if [ -z "$tok" ]; then bad "no client token for '$cl' in $CONFIG"; continue; fi
        p=$(on "$NODE" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Authorization: Bearer $tok' http://127.0.0.1:$PORT/internal/v1/ai/ping" 2>/dev/null)
        [ "$p" = 200 ] && ok "client '$cl' token accepted (/ping 200)" || bad "client '$cl' token refused ('$p')"
    done
    PRIMARY=$(find_primary) || die "could not find the Patroni leader"
    REG=$(psql_primary "SELECT count(*) FROM api.service_registry WHERE feature_name='homelab-ai'"); [ "${REG:-0}" -ge 1 ] && ok "in the service registry" || bad "not in the service registry"
    T=$(psql_primary "SELECT count(*) FROM information_schema.tables WHERE table_schema='ai' AND table_name='requests'"); [ "$T" = 1 ] && ok "ai.requests exists" || bad "ai.requests missing"
    psql_primary "SELECT client || ': ' || count(*) || ' requests, ' || count(*) FILTER (WHERE status=200) || ' ok, last ' || to_char(max(created_at),'MM-DD HH24:MI') FROM ai.requests GROUP BY client ORDER BY client" | sed 's/^/      /'
    m=$(on "$NODE" "free -m | awk '/Mem:/{print \$3\"/\"\$2}'" 2>/dev/null); note "memory used/total MB: $m"

    step "callers"
    for n in $SEARCH_NODES; do
        if on "$n" "sudo grep -qE '^  service_url: http://$SVC:$PORT' $SEARCH_CONFIG" 2>/dev/null; then
            on "$n" "sudo grep -qE '^  api_key: \"\"' $SEARCH_CONFIG" && ok "$n search points at the service, key removed" || bad "$n search points at the service but STILL holds a key"
        else warn "$n search not wired yet (--wire-search after homelab-search >= $SEARCH_MIN_VERSION)"; fi
    done
    for n in $CAL_NODES; do
        if on "$n" "sudo grep -qE '^  service_url: http://$SVC:$PORT' $CAL_CONFIG" 2>/dev/null; then ok "$n calendar points at the service"
        else warn "$n calendar not wired yet (--wire-calendar after homelab-calendar >= $CAL_MIN_VERSION)"; fi
    done
    step "result"
    [ "$RC" = 0 ] && echo "  ${G}homelab-ai is up on 53 with its clients.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
}
[ "$MODE" = verify ] && verify

# ------------------------------------------------------------ wire a caller
# wire NODES CONFIG MIN_VERSION PACKAGE UNIT CLIENT [blank-key]
wire(){
    local nodes="$1" cfg="$2" minv="$3" pkg="$4" unit="$5" client="$6" blank="${7:-}"
    local tok; tok=$(client_token "$client"); [ -n "$tok" ] || die "no '$client' client token in $CONFIG on $NODE -- run the install first"
    for n in $nodes; do
        up "$n" || { bad "$n down"; continue; }
        local v; v=$(on "$n" "dpkg-query -W -f='\${Version}' $pkg 2>/dev/null")
        ver_ge "$v" "$minv" || { bad "$n has $pkg $v; needs >= $minv before it can use the service"; continue; }
        on "$n" "sudo grep -q '^ai:' $cfg" || on "$n" "printf '\nai:\n  enabled: false\n' | sudo tee -a $cfg >/dev/null"
        # service_url + service_token under ai:, replacing earlier values; the
        # key blanked when asked (search), since the service holds it now.
        printf '%s\n' "$tok" | onin "$n" "T=\$(cat); sudo perl -0pi -e '
            my \$t = q{'\"\$T\"'};
            s/^(ai:\n(?:  .*\n)*?)  service_url: .*\n//m; s/^(ai:\n(?:  .*\n)*?)  service_token: .*\n//m;
            s/^(ai:\n)/\$1  service_url: http:\/\/$SVC:$PORT\n  service_token: \"\$t\"\n/m;
            '"$( [ -n "$blank" ] && printf '%s' 's/^(  api_key: )\"[^\"]*\"/$1\"\"/m;' )"'
        ' $cfg" \
            && ok "$n $cfg: service_url + service_token written${blank:+, api_key blanked}" || { bad "$n could not edit $cfg"; continue; }
        on "$n" "sudo systemctl restart $unit" >/dev/null 2>&1
        sleep 2
        local port; port=$(on "$n" "sudo sed -n 's/^  listen: \"http:\/\/[0-9.]*:\([0-9]*\)\"/\1/p' $cfg | head -1" 2>/dev/null)
        local h; h=$(health "$n" "${port:-2517}"); [ "$h" = 200 ] && ok "$n $unit back (/health 200)" || bad "$n $unit /health -> '${h:-no answer}' after the restart"
    done
}
if [ "$MODE" = wire-search ]; then
    step "search -> homelab-ai (key moves out of the search configs)"
    wire "$SEARCH_NODES" "$SEARCH_CONFIG" "$SEARCH_MIN_VERSION" homelab-search homelab-search search blank
    exec "$0" --verify
fi
if [ "$MODE" = wire-calendar ]; then
    step "calendar -> homelab-ai"
    wire "$CAL_NODES" "$CAL_CONFIG" "$CAL_MIN_VERSION" homelab-calendar homelab-calendar calendar
    exec "$0" --verify
fi

# -------------------------------------------------------------- preflight
step "preflight"
up "$NODE" || die "$NODE does not answer on :22"
on "$NODE" "test -f /etc/homelab/agent/credential.yml" || die "$NODE has no homelab-agent credential -- run agent-enroll-orchestrate.sh 53 first"
on "$NODE" "grep -q apt-homelab /etc/apt/sources.list.d/homelab.list" || die "$NODE has no fleet apt source"
ok "$NODE up, agent enrolled, apt source present"
PRIMARY=$(find_primary) || die "could not find the Patroni leader"
ok "Patroni leader: $PRIMARY"
on "$NODE" "sudo apt-get update -qq" >/dev/null 2>&1
CAND=$(on "$NODE" "apt-cache policy homelab-ai 2>/dev/null | sed -n 's/.*Candidate: //p'")
[ -n "$CAND" ] && [ "$CAND" != "(none)" ] && ok "homelab-ai $CAND available" || die "homelab-ai not in the apt repo as seen from $NODE"
KEY=$(on "${SEARCH_NODES%% *}" "sudo perl -MYAML::XS -e 'my \$c = YAML::XS::LoadFile(q{$SEARCH_CONFIG}); print \$c->{ai}{api_key} // q{}'" 2>/dev/null)
[ -n "$KEY" ] && ok "read the Anthropic key off the first search node (not shown; it moves to the service)" || warn "no API key in search's config; the service installs without one"

if [ "$MODE" = dry ]; then
    step "would do"
    cat <<PLANNED
  1. $NODE: apt-get install homelab-svc-hosts; preseed (db/pgbouncer .svc.homelab, api http://api.svc.homelab:3000,
     :$PORT, advertise $SVC, the key from search) and apt-get install homelab-ai -> tier 3, SQL in $PENDING
  2. from HERE: role SQL on $PRIMARY; SCRAM into $PGB_NODES; dpkg-reconfigure -> migrations + start; /health
  3. $NODE:$CONFIG clients: search + calendar tokens (generated here); restart; /ping with each
  then, after the new homelab-search / homelab-calendar are installed:
     $0 --wire-search      (service_url + token into $SEARCH_CONFIG on 70/71/72, api_key blanked, restart)
     $0 --wire-calendar    (same for 50/51/52)
PLANNED
    note "dry run: nothing changed."
    exit 0
fi

# ------------------------------------------------------------------ install
step "1. homelab-svc-hosts, then homelab-ai on $NODE"
on "$NODE" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-svc-hosts" >/dev/null 2>&1
r=$(on "$NODE" "getent hosts db.svc.homelab | awk '{print \$1}'" 2>/dev/null); [ -n "$r" ] && ok "db.svc.homelab -> $r" || die "db.svc.homelab does not resolve on $NODE"
if on "$NODE" "test -f $CONFIG"; then ok "$CONFIG already exists (not rewriting it)"
else
    printf '%s\n' "$KEY" | onin "$NODE" "K=\$(cat); cat <<SEED | sudo debconf-set-selections
homelab-ai homelab-ai/db_host string db.svc.homelab
homelab-ai homelab-ai/pgbouncer_host string pgbouncer.svc.homelab
homelab-ai homelab-ai/api_base string http://api.svc.homelab:3000
homelab-ai homelab-ai/listen_port string $PORT
homelab-ai homelab-ai/advertise_host string $SVC
homelab-ai homelab-ai/api_key password \$K
SEED
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends homelab-ai" >"$SCRATCH/install.log" 2>&1
    on "$NODE" "test -f $CONFIG" && ok "config written" || { tail -20 "$SCRATCH/install.log" | sed 's/^/      /'; die "no $CONFIG on $NODE"; }
fi

step "2. the DB runbook, from here"
if psql_primary "SELECT 1 FROM pg_roles WHERE rolname='homelab_ai_runtime'" | grep -q 1; then ok "roles already exist"
else
    on "$NODE" "sudo cat $PENDING" > "$SCRATCH/role.sql" 2>/dev/null; [ -s "$SCRATCH/role.sql" ] || die "could not read $PENDING off $NODE"
    scp -q -o ConnectTimeout=15 "$SCRATCH/role.sql" "$PRIMARY:/tmp/homelab_ai-role.sql" || die "could not copy the SQL to $PRIMARY"
    on "$PRIMARY" "sudo -u postgres psql -d homelab -X -v ON_ERROR_STOP=1 -q -f /tmp/homelab_ai-role.sql; r=\$?; rm -f /tmp/homelab_ai-role.sql; exit \$r" >/dev/null 2>&1 && ok "roles and schema created" || die "the role SQL failed on $PRIMARY"
fi
SCRAM=$(on "$PRIMARY" "sudo -u postgres psql -d homelab -tAc \"SELECT rolpassword FROM pg_authid WHERE rolname='homelab_ai_runtime'\"" 2>/dev/null); [ -n "$SCRAM" ] || die "could not read the SCRAM secret"
# Always add-or-replace (the tool is idempotent): a role whose password was
# reset keeps its old line otherwise, and /health answers 503 through the pooler.
for p in $PGB_NODES; do
    if on "$p" "sudo homelab-bootstrap-pgbouncer-entry --role homelab_ai_runtime --scram-secret '$SCRAM' --pgbouncer-host localhost" >/dev/null 2>&1; then ok "$p has the current SCRAM for homelab_ai_runtime"
    else bad "$p registration failed"; fi
    g=$(on "$p" "stat -c %U:%G /etc/pgbouncer/userlist.txt" 2>/dev/null); [ "$g" = root:postgres ] || bad "$p userlist.txt is $g, must stay root:postgres"
done
out=$(on "$NODE" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-ai" 2>&1)
printf '%s\n' "$out" | grep -iE "applied|WARNING|configured" | sed 's/^/      /' | head -4
h=$(health "$NODE" "$PORT"); [ "$h" = 200 ] && ok "/health -> 200" || die "/health -> '${h:-no answer}'. Check: ssh $NODE 'journalctl -u homelab-ai -n 40 --no-pager'"

step "3. client tokens (search, calendar)"
for cl in search calendar; do
    if [ -n "$(client_token "$cl")" ]; then ok "client '$cl' already has a token"; continue; fi
    TOK=$(head -c 36 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-44)
    printf '%s\n' "$TOK" | onin "$NODE" "T=\$(cat); sudo perl -MYAML::XS -0pi -e '
        my \$t = q{'\"\$T\"'};
        if (/^clients: \[\]\s*$/m) { s/^clients: \[\]\s*$/clients:\n  - name: $cl\n    token: \"\$t\"\n/m }
        else { s/^(clients:\n(?:  .*\n|\n)*?)(?=^\S|\z)/\$1  - name: $cl\n    token: \"\$t\"\n/m }
        ' $CONFIG && sudo perl -MYAML::XS -e 'YAML::XS::LoadFile(q{$CONFIG})'" \
        && ok "client '$cl' token written (not shown)" || die "could not write the '$cl' client into $CONFIG (config must still parse)"
done
on "$NODE" "sudo systemctl restart homelab-ai" >/dev/null 2>&1; sleep 2
for cl in search calendar; do
    tok=$(client_token "$cl")
    p=$(on "$NODE" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Authorization: Bearer $tok' http://127.0.0.1:$PORT/internal/v1/ai/ping" 2>/dev/null)
    [ "$p" = 200 ] && ok "client '$cl' accepted" || bad "client '$cl' refused ('$p')"
done
step "verify"
exec "$0" --verify
