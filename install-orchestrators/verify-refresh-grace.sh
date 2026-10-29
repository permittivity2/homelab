#!/bin/bash
# ============================================================================
# Verify the refresh-token grace window on a LIVE api node, then clean up
# after itself.
#
# WHY THIS EXISTS. api/t/sessions.t covers the grace window, but it skips
# unless HOMELAB_API_CONFIG points at a real config -- and a real config holds
# the database password and the JWT secret, which is not something to copy onto
# a workstation to run a test. So the grace-window subtests, as shipped in
# 0.1.63, had never actually executed anywhere.
#
# This probe closes that gap from the outside: it drives the deployed HTTP API
# with a throwaway account and asserts the observable behaviour. It needs no
# config and no secret -- only the node's address.
#
# WHAT IT ASSERTS (the whole point of migration 020):
#   1. a normal rotation still works
#   2. replaying the CONSUMED token inside the window returns THE SAME
#      successor, flagged recovered -- this is the lockout fix
#   3. the replay mints NOTHING (no new session), so a retry loop converges
#   4. the successor is genuinely usable
#   5. once the successor is ITSELF rotated, the original is refused
#   6. a token revoked by LOGOUT is not recoverable -- logout stays final,
#      which is the one way this change could have gone badly wrong
#
#   ./verify-refresh-grace.sh            # against prod-homelab12
#   ./verify-refresh-grace.sh 10.50.2.157
# ============================================================================
set -uo pipefail

NODE="${1:-10.50.2.156}"
BASE="http://$NODE:3000/api/v1"
DB_NODES="06 07 08"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
PASS=0; FAIL=0
ok(){   PASS=$((PASS+1)); echo "  ${G}ok${O}   $*"; }
bad(){  FAIL=$((FAIL+1)); echo "  ${R}FAIL${O} $*"; }
info(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }

# JSON field extraction without jq (not installed fleet-wide); perl is.
jfield(){ perl -MMojo::JSON=decode_json -e '
    my $j = eval { decode_json(do { local $/; <STDIN> }) } || {};
    my $v = $j->{$ARGV[0]};
    $v = $v ? "true" : "false" if ref $v eq "JSON::PP::Boolean" || ref $v eq "Mojo::JSON::_Bool";
    print defined $v ? $v : "";' "$1" 2>/dev/null; }

post(){ curl -s -m 15 -H 'Content-Type: application/json' -X POST "$BASE$1" -d "$2"; }

EMAIL="grace-probe-$(date +%s)-$$@test.mailmasker.org"
PW='GraceProbe1Aa!!'

# --- find the primary up front, so cleanup is never orphaned ---------------
LEADER=""
for n in $DB_NODES; do
    ip=10.20.2.$((144 + 10#$n))
    [ "$(ssh -o ConnectTimeout=6 "$ip" 'sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()"' 2>/dev/null | tr -d ' ')" = "f" ] \
        && { LEADER="$ip"; break; }
done
[ -z "$LEADER" ] && { echo "${R}ERROR${O} no Postgres primary reachable"; exit 1; }

sql(){ ssh -o ConnectTimeout=10 "$LEADER" "sudo -u postgres psql -d homelab -X -q -tA -v ON_ERROR_STOP=1 -c \"$1\"" 2>/dev/null | tr -d ' '; }

cleanup(){
    step "cleanup"
    # Guarded by the probe's own address shape, so this can only ever reach
    # the account this run created.
    local removed
    removed=$(sql "
        WITH victim AS (SELECT id FROM api.users WHERE email = '$EMAIL')
           , s AS (DELETE FROM api.sessions       WHERE user_id IN (SELECT id FROM victim) RETURNING 1)
           , t AS (UPDATE api.refresh_tokens SET successor_id = NULL WHERE user_id IN (SELECT id FROM victim) RETURNING 1)
           , r AS (DELETE FROM api.refresh_tokens WHERE user_id IN (SELECT id FROM victim) RETURNING 1)
           , ur AS (DELETE FROM api.user_roles    WHERE user_id IN (SELECT id FROM victim) RETURNING 1)
        SELECT (SELECT count(*) FROM s) || '/' || (SELECT count(*) FROM r) || '/' || (SELECT count(*) FROM ur);")
    sql "DELETE FROM api.users WHERE email = '$EMAIL';" >/dev/null
    local left; left=$(sql "SELECT count(*) FROM api.users WHERE email = '$EMAIL';")
    if [ "$left" = "0" ]; then ok "probe account removed (sessions/tokens/roles: $removed)"
    else bad "probe account $EMAIL STILL PRESENT -- remove it by hand"; fi
}
trap cleanup EXIT

echo "Probing $BASE"
echo "Throwaway account: $EMAIL"

step "1. register + login"
rc=$(post /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}")
# /auth/register answers {"email":...,"id":N} on success.
if [ -n "$(printf '%s' "$rc" | jfield id)" ]; then
    ok "registered (id $(printf '%s' "$rc" | jfield id))"
else
    bad "could not register: $(printf '%s' "$rc" | head -c 200)"; exit 1
fi

LOGIN=$(post /auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}")
R0=$(printf '%s' "$LOGIN" | jfield refresh_token)
A0=$(printf '%s' "$LOGIN" | jfield token)
[ -n "$R0" ] && ok "logged in, hold refresh token R0" || { bad "no refresh token from login"; exit 1; }

SESS_BEFORE=$(sql "SELECT count(*) FROM api.sessions WHERE user_id = (SELECT id FROM api.users WHERE email='$EMAIL');")
info "sessions after login: $SESS_BEFORE"

step "2. a normal rotation still works"
ROT1=$(post /auth/refresh "{\"refresh_token\":\"$R0\"}")
R1=$(printf '%s' "$ROT1" | jfield refresh_token)
A1=$(printf '%s' "$ROT1" | jfield token)
REC1=$(printf '%s' "$ROT1" | jfield recovered)
[ -n "$R1" ] && [ "$R1" != "$R0" ] && ok "R0 rotated into a different token R1" || bad "rotation did not return a new token"
[ "$REC1" != "true" ] && ok "first rotation is not flagged recovered" || bad "a FIRST rotation was flagged recovered"
[ "$(sql "SELECT count(*) FROM api.refresh_tokens WHERE token='$R0' AND successor_id IS NOT NULL AND rotated_at IS NOT NULL;")" = "1" ] \
    && ok "the breadcrumb was written (successor_id + rotated_at)" \
    || bad "no successor_id/rotated_at recorded -- the node is NOT running 0.1.63"

step "3. replaying the CONSUMED token returns THE SAME successor"
echo "  This is the lockout fix. Pre-0.1.63 this was a 401 with no way back."
SESS_MID=$(sql "SELECT count(*) FROM api.sessions WHERE user_id = (SELECT id FROM api.users WHERE email='$EMAIL');")
ROT2=$(post /auth/refresh "{\"refresh_token\":\"$R0\"}")
R1B=$(printf '%s' "$ROT2" | jfield refresh_token)
REC2=$(printf '%s' "$ROT2" | jfield recovered)
[ "$R1B" = "$R1" ] && ok "same successor handed back, not a new one" || bad "expected R1 again, got '${R1B:0:12}...'"
[ "$REC2" = "true" ] && ok "flagged recovered, so the client can log it" || bad "replay was not flagged recovered"
SESS_AFTER=$(sql "SELECT count(*) FROM api.sessions WHERE user_id = (SELECT id FROM api.users WHERE email='$EMAIL');")
[ "$SESS_AFTER" = "$SESS_MID" ] && ok "minted no new session ($SESS_MID -> $SESS_AFTER): a retry loop converges" \
    || bad "session count grew $SESS_MID -> $SESS_AFTER; a retry loop would spawn sessions"

step "4. the successor actually works"
INTRO=$(curl -s -m 10 -H "Authorization: Bearer $(printf '%s' "$ROT2" | jfield token)" "$BASE/auth/introspect")
printf '%s' "$INTRO" | grep -q "$EMAIL" && ok "the recovered access token introspects as the right user" \
    || bad "recovered access token did not introspect: $(printf '%s' "$INTRO" | head -c 160)"

step "5. once the successor is itself rotated, the original is refused"
ROT3=$(post /auth/refresh "{\"refresh_token\":\"$R1\"}")
R2=$(printf '%s' "$ROT3" | jfield refresh_token)
[ -n "$R2" ] && ok "R1 rotated into R2" || bad "could not rotate R1"
ROT4=$(post /auth/refresh "{\"refresh_token\":\"$R0\"}")
if [ -z "$(printf '%s' "$ROT4" | jfield refresh_token)" ]; then
    ok "R0 now refused -- grace does not chain backwards indefinitely"
else
    bad "R0 STILL accepted after its successor was rotated"
fi

step "6. logout stays final (the dangerous failure mode)"
echo "  If logout were recoverable, signing out would take 5 minutes to mean"
echo "  anything. It must record NO successor."
post /auth/logout "{\"refresh_token\":\"$R2\"}" >/dev/null
SUCC=$(sql "SELECT coalesce(successor_id::text,'none') FROM api.refresh_tokens WHERE token='$R2';")
[ "$SUCC" = "none" ] && ok "logout recorded no successor" || bad "logout recorded successor_id=$SUCC"
ROT5=$(post /auth/refresh "{\"refresh_token\":\"$R2\"}")
if [ -z "$(printf '%s' "$ROT5" | jfield refresh_token)" ]; then
    ok "a logged-out token is NOT recoverable"
else
    bad "a logged-out token was recovered -- logout is broken"
fi

step "result"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && echo "  ${G}The grace window behaves as designed on $NODE.${O}" \
                || echo "  ${R}Do not finish the pool until this is understood.${O}"
exit "$FAIL"
