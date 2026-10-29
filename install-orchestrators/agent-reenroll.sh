#!/bin/bash
# ============================================================================
# agent re-enrolment -- RUN ON THIS HOST (desktop). Repairs fleet nodes whose
# homelab-agent credential has become unusable.
#
# WHY THIS IS NEEDED, AND WHY IT WILL BE NEEDED AGAIN.
#
# The agent authenticates with a single-use refresh token and rotates it on
# every 60s heartbeat: the API revokes the old session, mints a new pair, and
# the agent writes the result to /etc/homelab/agent/credential.yml. It holds no
# password -- only that token -- so if the rotated credential is ever not
# durably stored, the host is locked out PERMANENTLY and silently. It cannot
# re-login, and nothing retries except the refresh that can no longer succeed.
#
# It runs under hypnotoad with TWO workers, and both run the heartbeat timer
# against the same file. When their timers collide, one worker's refresh
# consumes the token while the other is still holding it; last-writer-wins on
# the file does the rest. That is why this strikes a handful of hosts at
# apparently random times (14 of 51 over ~10 days, 2026-10-29) rather than all
# at once -- and why re-enrolling only resets the clock. The real fix is in
# homelab-agent: one heartbeat owner, or a lock around rotation, plus a
# recovery path. See post-cutover item 36.
#
# HOW TO SPOT IT. credential.yml's mtime: a healthy agent rewrites it every
# 60s, so anything older than a couple of minutes is wedged. Note that the
# token is REVOKED, not expired -- expires_at stays in the future and
# `systemctl is-active homelab-agent` says active, so nothing looks wrong.
# Confirm with /api/v1/auth/introspect: {"error":"session revoked"}.
#
# WHAT IT BREAKS, silently: anything needing a system_agent credential.
# Certificate publishing from the issuer (certs spool and never reach the
# store), service-registry heartbeats, and Apple-profile signing.
#
# USAGE
#   ./agent-reenroll.sh --stale             # find and repair every wedged node
#   ./agent-reenroll.sh 46                  # just prod-homelab46
#   ./agent-reenroll.sh --stale --dry-run   # report, change nothing
#   ./agent-reenroll.sh 31 --force          # repair even if it looks healthy
#
# Idempotent. Only ever deletes credential.yml -- NEVER config.yml, so each
# host keeps its own api_base/advertise_host (which matter: the edge nodes are
# not addressed like the rest). The enrolment answers already in debconf are
# reused; only a fresh one-time code is added.
# ============================================================================
set -uo pipefail

API_VIP=10.50.2.132
DB_NODES="06 07 08"
DRY=0
FORCE=0
WANT=""

for a in "$@"; do
    case "$a" in
        --stale)   WANT="stale" ;;
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
        --help|-h) sed -n '2,42p' "$0"; exit 0 ;;
        *)         WANT="$WANT $a" ;;
    esac
done
[ -z "${WANT// /}" ] && { echo "nothing to do -- pass node numbers or --stale (see --help)"; exit 1; }

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ip_for(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
svc_for(){ printf '10.50.2.%d' "$((144 + 10#$1))"; }
name_for(){ printf 'prod-homelab%02d' "$((10#$1))"; }
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# "system_agent" | "session revoked" | "no-credential" | "unreachable"
agent_state(){
    local ip="$1" out
    out=$(ssh -o ConnectTimeout=6 -o BatchMode=yes "$ip" '
        T=$(sudo grep "^token:" /etc/homelab/agent/credential.yml 2>/dev/null | sed "s/^token:[[:space:]]*//")
        [ -z "$T" ] && { echo "no-credential"; exit 0; }
        curl -s --max-time 8 -H "Authorization: Bearer $T" \
            http://'"$API_VIP"':3000/api/v1/auth/introspect \
          | grep -oE "system_agent|\"error\":\"[^\"]*\"" | head -1
    ' 2>/dev/null)
    printf '%s' "${out:-unreachable}"
}

# --- which nodes ------------------------------------------------------------
NODES=""
if [ "${WANT// /}" = "stale" ]; then
    echo "Scanning the fleet for wedged agents (introspect against the API)..."
    for n in $(seq 0 69); do
        nn=$(printf '%02d' "$n"); ip=$(ip_for "$nn")
        up "$ip" || continue
        st=$(agent_state "$ip")
        case "$st" in
            system_agent)   printf '  %s%-16s ok%s\n' "$D" "$(name_for "$nn")" "$O" ;;
            no-credential|unreachable) ;;
            *) printf '  %s%-16s %s%s\n' "$Y" "$(name_for "$nn")" "$st" "$O"; NODES="$NODES $nn" ;;
        esac
    done
else
    for n in $WANT; do NODES="$NODES $(printf '%02d' "$((10#$n))")"; done
fi

NODES="${NODES# }"
[ -z "$NODES" ] && { echo; echo "${G}Nothing wedged. All agents authenticate.${O}"; exit 0; }
echo
echo "To re-enrol:$NODES"
[ "$DRY" = 1 ] && { echo "(--dry-run: stopping here)"; exit 0; }

# --- the DB primary mints the codes ----------------------------------------
# Direct SQL rather than `homelab-cli admin agent enroll`, which needs an
# interactive site_admin login this script cannot do. Same table, same
# mechanism the agent postinst redeems against.
LEADER=""
for n in $DB_NODES; do
    ip=$(ip_for "$n")
    [ "$(ssh -o ConnectTimeout=6 "$ip" 'sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()"' 2>/dev/null | tr -d ' ')" = "f" ] \
        && { LEADER="$ip"; echo "DB primary: $(name_for "$n") ($ip)"; break; }
done
[ -z "$LEADER" ] && { echo "${R}ERROR${O} no Postgres primary reachable among $DB_NODES"; exit 1; }

mint(){   # $1 hostname -> echoes the code
    local code; code=$(openssl rand -hex 16)
    printf "INSERT INTO api.agent_enrollment_codes (code,hostname,issued_by,expires_at) VALUES ('%s','%s','agent-reenroll',NOW()+INTERVAL '20 minutes');" \
        "$code" "$1" \
      | ssh "$LEADER" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" >/dev/null 2>&1 \
      || return 1
    printf '%s' "$code"
}

FAILED=""
for nn in $NODES; do
    hn=$(name_for "$nn"); ip=$(ip_for "$nn")
    echo
    echo "=== $hn ($ip) ==="

    if ! up "$ip"; then echo "  ${Y}skip${O} not answering on :22"; continue; fi

    st=$(agent_state "$ip")
    if [ "$st" = "system_agent" ] && [ "$FORCE" = 0 ]; then
        echo "  ${G}ok${O} already authenticates -- leaving it alone (--force to re-enrol anyway)"
        continue
    fi
    echo "  before: $st"

    code=$(mint "$hn") || { echo "  ${R}FAIL${O} could not mint a code"; FAILED="$FAILED $hn"; continue; }

    # credential.yml ONLY. config.yml is left alone so the host keeps its own
    # api_base/advertise_host; the postinst's "already enrolled, leaving it
    # untouched" branch is keyed on the credential's existence, which is
    # exactly what makes deleting it the whole trigger.
    ssh "$ip" "sudo systemctl stop homelab-agent >/dev/null 2>&1 || true
               sudo rm -f /etc/homelab/agent/credential.yml" || true

    ssh "$ip" "sudo debconf-set-selections" <<EOF
homelab-agent homelab-agent/enrollment_code password $code
EOF

    ssh "$ip" "sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure homelab-agent" 2>&1 \
        | sed 's/^/    /' | grep -iE "redeem|enroll|credential|ERROR|start" | head -6

    # The code is single-use and short-lived, but it has served its purpose
    # the moment it is redeemed -- so clear it out of debconf rather than
    # leaving a (dead) credential-shaped answer on the host.
    ssh "$ip" "echo 'homelab-agent homelab-agent/enrollment_code password' | sudo debconf-set-selections" || true

    ssh "$ip" "sudo systemctl start homelab-agent >/dev/null 2>&1 || true"
    sleep 3
    after=$(agent_state "$ip")
    if [ "$after" = "system_agent" ]; then
        echo "  ${G}ok${O}   now authenticates as system_agent"
    else
        echo "  ${R}FAIL${O} still '$after'"
        FAILED="$FAILED $hn"
    fi
done

echo
if [ -n "$FAILED" ]; then
    echo "${R}Did not come back:${O}$FAILED"
    echo "Check 'journalctl -u homelab-agent' on those hosts."
    exit 1
fi
echo "${G}All re-enrolled.${O}"
echo
echo "If prod-homelab46 was among them, its certificate publish spool should"
echo "now drain on the next timer run -- or force it:"
echo "  ssh 10.20.2.190 'sudo /usr/bin/homelab-cert-publish --drain'"
echo "  ssh 10.20.2.190 'sudo ls /var/lib/homelab/cert-publish/'   # expect empty"
