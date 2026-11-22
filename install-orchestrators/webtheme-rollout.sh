#!/bin/bash
# ============================================================================
# Roll a new homelab-webtheme out to every app that ships its header -- RUN
# ON THE ADMIN WORKSTATION (post-cutover #94).
#
#   ./webtheme-rollout.sh --dry-run
#   ./webtheme-rollout.sh
#   ./webtheme-rollout.sh --verify
#
# WHY. The theme's STYLESHEET is remote (static.mailmasker.org, no rebuild),
# but its header MARKUP is packaged, and a Mojolicious app keeps its compiled
# templates in memory: a webtheme upgrade shows nothing until the app is
# restarted. pkg-upgrade.sh upgrades one package and restarts nothing. This
# does both, pool by pool, one node at a time, waiting for /health after each
# restart. (The developer site on 45 is NOT a consumer at run time: its pages
# are baked at package build time from the repo's webtheme/ templates, so a
# header change reaches it with the next homelab-developer build.)
# ============================================================================
set -uo pipefail

# pool  nodes      unit                  port   health path
POOLS=(
  "accountmanage 27 28 29 homelab-accountmanage 2503 /health"
  "drive         65 66 67 homelab-drive         2501 /health"
  "sso           18 19 20 homelab-sso           2502 /health"
  "invite        30 31 32 homelab-invite        2514 /health"
  "block-link    33 34 35 homelab-block-link    2515 /health"
  "search        70 71 72 homelab-search        2517 /health"
  "calendar      50 51 52 homelab-calendar      2519 /health"
  "notes         47 48 49 homelab-notes         2518 /health"
)

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: webtheme-rollout.sh [--dry-run] [--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
RC=0
h(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
on(){ ssh -n -o ConnectTimeout=15 -o BatchMode=yes "$1" "${@:2}"; }
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }
ver(){ on "$1" "dpkg-query -W -f='\${Version}' homelab-webtheme 2>/dev/null"; }

step "the published version"
PUB=$(on "$(h 47)" "sudo apt-get update -qq >/dev/null 2>&1; apt-cache policy homelab-webtheme 2>/dev/null | sed -n 's/.*Candidate: //p'" 2>/dev/null)
[ -n "$PUB" ] && [ "$PUB" != "(none)" ] && ok "homelab-webtheme $PUB is in the fleet apt repo" || { bad "no homelab-webtheme in the apt repo as seen from 47"; exit 1; }

if [ "$VERIFY_ONLY" = 1 ]; then
    for spec in "${POOLS[@]}"; do
        set -- $spec; pool=$1; unit=$5; port=$6; path=$7
        step "$pool"
        for nn in $2 $3 $4; do
            n=$(h "$nn"); up "$n" || { bad "$n down"; continue; }
            v=$(ver "$n"); [ "$v" = "$PUB" ] && ok "$n webtheme $v" || bad "$n webtheme '${v:-absent}', published $PUB"
            s=$(on "$n" "systemctl is-active $unit" 2>/dev/null); [ "$s" = active ] && ok "$n $unit active" || bad "$n $unit is '$s'"
            # Started after the package landed? (a restart is the whole point)
            since=$(on "$n" "systemctl show $unit -p ActiveEnterTimestamp --value" 2>/dev/null)
            pkg=$(on "$n" "stat -c %y /usr/share/homelab-webtheme/templates/homelab/header.html.ep" 2>/dev/null)
            if [ -n "$since" ] && [ -n "$pkg" ] && [ "$(date -d "$since" +%s)" -ge "$(date -d "$pkg" +%s)" ]; then ok "$n restarted after the template landed"; else bad "$n $unit started before the new header landed (not restarted)"; fi
            c=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:$port$path" 2>/dev/null); [ "$c" = 200 ] && ok "$n $path -> 200" || bad "$n $path -> '${c:-no answer}'"
        done
    done
    step "result"; [ "$RC" = 0 ] && echo "  ${G}every consumer runs webtheme $PUB with a restart after it.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

if [ "$DRY" = 1 ]; then
    step "would do, in this order"
    for spec in "${POOLS[@]}"; do set -- $spec; echo "  $1: $(h $2) $(h $3) $(h $4): apt-get install --only-upgrade homelab-webtheme; systemctl restart $5; wait for :$6$7"; done
    note "dry run: nothing changed."; exit 0
fi

for spec in "${POOLS[@]}"; do
    set -- $spec; pool=$1; unit=$5; port=$6; path=$7
    step "$pool ($unit)"
    for nn in $2 $3 $4; do
        n=$(h "$nn")
        up "$n" || { bad "$n does not answer on :22 -- skipped"; continue; }
        v=$(ver "$n")
        if [ "$v" = "$PUB" ]; then
            note "$n already $v (restarting anyway so the header is the new one)"
        else
            on "$n" "sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade homelab-webtheme" >/dev/null 2>&1
            v=$(ver "$n"); [ "$v" = "$PUB" ] && ok "$n webtheme now $v" || { bad "$n webtheme is '${v:-absent}' after the upgrade -- stopping this pool"; break; }
        fi
        on "$n" "sudo systemctl restart $unit" >/dev/null 2>&1
        c=""; for _ in $(seq 1 20); do c=$(on "$n" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$port$path" 2>/dev/null); [ "$c" = 200 ] && break; sleep 2; done
        [ "$c" = 200 ] && ok "$n $unit restarted, $path -> 200" || { bad "$n $unit did not answer $path after the restart (got '${c:-nothing}') -- stopping this pool; look: ssh $n 'journalctl -u $unit -n 30 --no-pager'"; break; }
    done
done

step "result"
[ "$RC" = 0 ] && echo "  ${G}webtheme $PUB is live on every app.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
exit "$RC"
