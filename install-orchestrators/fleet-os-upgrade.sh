#!/bin/bash
# ============================================================================
# Bring the OS packages of fleet nodes up to date, ONE NODE AT A TIME, with the
# checks pkg-upgrade.sh makes -- RUN ON THE ADMIN WORKSTATION (post-cutover #97).
#
#   ./fleet-os-upgrade.sh --dry-run NN [NN ...]   # what each node would upgrade; changes nothing
#   ./fleet-os-upgrade.sh NN [NN ...]             # upgrade, restart the node's apps, audit it
#   ./fleet-os-upgrade.sh --no-restart NN [...]   # upgrade only, restart nothing (the DB tier)
#
# WHY. The containers have no unattended-upgrades, so between deliberate
# sweeps every node drifts on its own: fleet-running-audit.sh found postfix at
# two versions, openssh-server at three, systemd newer on the edges. This is
# the deliberate sweep, with the safety the one-package tool has:
#   * nodes holding a floating address (a VIP) go last, backups before masters;
#   * per node: apt-get update, then `apt-get upgrade` only (never full-upgrade:
#     no removals, no new packages), conffiles kept (--force-confold), phased
#     updates INCLUDED (otherwise Ubuntu's phasing re-creates drift by design),
#     run detached on the node with its log in /var/log/homelab-os-upgrade.log
#     so an openssh-server restart mid-way cannot lose it;
#   * then (unless --no-restart) the node's homelab-* services and the stock
#     daemons listed in RESTARTABLE are restarted one by one, so the new libc
#     and perl are what actually runs -- one node per pool at a time means no
#     outage; patroni, etcd, keepalived and the agent are never restarted here;
#   * then: dpkg clean, no new failed unit, every unit that was active still
#     is, the addresses unchanged, and fleet-running-audit.sh on the node shows
#     nothing but DRIFT (which the sweep itself is curing). Stops at the first
#     node that fails a check.
# The order of nodes is yours: give one pool at a time (the holders are sorted
# last inside the list you give). Nothing here reboots anything.
# ============================================================================
set -uo pipefail

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }

DRY=0; RESTART=1; NODES=()
for a in "$@"; do
    case "$a" in
        --dry-run)    DRY=1 ;;
        --no-restart) RESTART=0 ;;
        [0-9]|[0-9][0-9]) NODES+=("$(printf '%02d' "$((10#$a))")") ;;
        *) echo "unknown argument '$a' (usage: fleet-os-upgrade.sh [--dry-run] [--no-restart] NN [NN ...])"; exit 1 ;;
    esac
done
[ ${#NODES[@]} -gt 0 ] || { echo "usage: fleet-os-upgrade.sh [--dry-run] [--no-restart] NN [NN ...]"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
svc_of(){ printf '10.50.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }
addrs(){ rssh "$(ip_of "$1")" 'ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1 | sort'; }
floating(){ local n=$1; addrs "$n" | grep -E '^10\.50\.[0-3]\.' | grep -vx "$(svc_of "$n")" || true; }
active_services(){ rssh "$(ip_of "$1")" 'systemctl list-units --type=service --state=active --no-legend --plain | awk "{print \$1}" | sort'; }
failed_units(){ rssh "$(ip_of "$1")" 'systemctl --failed --no-legend --plain | awk "{print \$1}" | sort'; }

# Stock daemons this tool may restart after an upgrade (only those active on the node).
# Never: patroni, etcd, keepalived (a restart moves a VIP), homelab-agent (it would re-enrol
# nothing but it is the thing reporting health), ssh (restarted by its own package already).
RESTARTABLE='^(postfix|opendkim|nginx|php[0-9.]+-fpm|dovecot|pdns|dnsdist|haproxy|pgbouncer|prometheus(-[a-z0-9-]+)?|grafana-server|bad_ips)\.service$'

step "order: nodes without a floating address first, holders last"
HOLD=(); PLAIN=()
for n in "${NODES[@]}"; do
    ip=$(ip_of "$n")
    timeout 5 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null || { warn "prod-homelab$n does not answer on :22 -- skipped"; continue; }
    f=$(floating "$n")
    if [ -n "$f" ]; then HOLD+=("$n"); echo "  prod-homelab$n holds $(echo "$f" | paste -sd' ' -)"; else PLAIN+=("$n"); echo "  prod-homelab$n"; fi
done
ORDER=("${PLAIN[@]}" "${HOLD[@]}")
[ ${#ORDER[@]} -gt 0 ] || { echo "no reachable node"; exit 1; }

FAILS=0; DONE=0; SKIP=0
for n in "${ORDER[@]}"; do
    ip=$(ip_of "$n")
    step "prod-homelab$n ($ip)"
    UPG=$(rssh "$ip" 'sudo apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1' | sort)
    CNT=$(printf '%s\n' "$UPG" | grep -c . || true)
    if [ "$CNT" = 0 ]; then ok "nothing to upgrade"; SKIP=$((SKIP+1)); continue; fi
    echo "  $CNT package(s): $(printf '%s\n' "$UPG" | paste -sd' ' - | cut -c1-300)$([ ${#UPG} -gt 300 ] && echo ' ...')"
    if [ "$DRY" = 1 ]; then note "dry run: nothing changed"; continue; fi

    BEFORE_A=$(addrs "$n"); BEFORE_S=$(active_services "$n"); BEFORE_F=$(failed_units "$n")
    # detached on the node: an openssh-server restart mid-upgrade must not lose the run
    rssh "$ip" 'sudo rm -f /var/log/homelab-os-upgrade.log; sudo bash -c "nohup env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::Get::Always-Include-Phased-Updates=true upgrade > /var/log/homelab-os-upgrade.log 2>&1; echo EXIT=\$? >> /var/log/homelab-os-upgrade.log" >/dev/null 2>&1 &'
    RC=""
    for _ in $(seq 1 240); do   # up to 20 minutes
        sleep 5
        last=$(rssh "$ip" 'tail -1 /var/log/homelab-os-upgrade.log 2>/dev/null')
        case "$last" in EXIT=*) RC=${last#EXIT=}; break ;; esac
    done
    if [ -z "$RC" ]; then bad "the upgrade did not finish in 20 minutes -- look: ssh $ip 'tail /var/log/homelab-os-upgrade.log'"; FAILS=$((FAILS+1)); break; fi
    rssh "$ip" 'grep -E "^(E:|W:|dpkg: (error|warning))" /var/log/homelab-os-upgrade.log' | sed 's/^/    /'
    if [ "$RC" != 0 ]; then bad "apt-get upgrade exited $RC (log: /var/log/homelab-os-upgrade.log on the node)"; FAILS=$((FAILS+1)); break; fi
    AUDIT=$(rssh "$ip" 'sudo dpkg --audit 2>/dev/null'); [ -z "$AUDIT" ] && ok "upgrade done, dpkg clean" || { bad "dpkg --audit is not clean:"; echo "$AUDIT" | sed 's/^/    /'; FAILS=$((FAILS+1)); break; }
    LEFT=$(rssh "$ip" 'apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1 | paste -sd" " -'); [ -z "$LEFT" ] && ok "nothing left upgradable" || warn "still upgradable (held back?): $LEFT"
    rssh "$ip" 'ls /var/run/reboot-required >/dev/null 2>&1 && echo "  (the node says a reboot is required -- that is #41, not this tool)"'

    if [ "$RESTART" = 1 ]; then
        TO_RESTART=$(printf '%s\n' "$BEFORE_S" | grep -E "^homelab-.*\.service$|$RESTARTABLE" | grep -v -E '^homelab-agent\.service$' || true)
        if [ -n "$TO_RESTART" ]; then
            for u in $TO_RESTART; do
                rssh "$ip" "sudo systemctl restart $u" </dev/null
                sleep 2
                st=$(rssh "$ip" "systemctl is-active $u"); [ "$st" = active ] && ok "restarted $u" || { bad "$u is '$st' after the restart"; FAILS=$((FAILS+1)); }
            done
            [ "$FAILS" = 0 ] || break
        else note "no app to restart here"; fi
    else note "--no-restart: services keep running the old libraries until their next restart"; fi

    sleep 3
    AFTER_S=$(active_services "$n"); AFTER_F=$(failed_units "$n"); AFTER_A=$(addrs "$n")
    LOST=$(comm -23 <(printf '%s\n' "$BEFORE_S") <(printf '%s\n' "$AFTER_S") | grep -E '.' || true)
    [ -z "$LOST" ] && ok "every service that was active still is" || { bad "service(s) no longer active: $(echo "$LOST" | paste -sd' ' -)"; FAILS=$((FAILS+1)); break; }
    NEWF=$(comm -13 <(printf '%s\n' "$BEFORE_F") <(printf '%s\n' "$AFTER_F") | grep -E '.' || true)
    [ -z "$NEWF" ] && ok "no new failed unit" || { bad "newly failed: $(echo "$NEWF" | paste -sd' ' -)"; FAILS=$((FAILS+1)); break; }
    if [ "$BEFORE_A" = "$AFTER_A" ]; then ok "addresses unchanged ($(echo "$AFTER_A" | paste -sd' ' -))"
    else bad "addresses changed:"; diff <(printf '%s\n' "$BEFORE_A") <(printf '%s\n' "$AFTER_A") | sed 's/^/      /'; FAILS=$((FAILS+1)); break; fi
    # the running audit on this node: anything but DRIFT is a stop
    AOUT=$("$HERE/fleet-running-audit.sh" "$n" 2>&1)
    ABAD=$(printf '%s\n' "$AOUT" | awk '/^DRIFT/{d=1} /^(MISSING|UNEXPECTED|LEFTOVERS|NOTES)/{d=0} /^  FAIL/ && !d' )
    [ -z "$ABAD" ] && ok "running audit: nothing but drift" || { bad "running audit:"; echo "$ABAD" | sed 's/^/    /'; FAILS=$((FAILS+1)); break; }
    DONE=$((DONE+1))
done

echo
if [ "$FAILS" = 0 ]; then echo "${G}done${O}: $DONE upgraded, $SKIP had nothing to do"; exit 0
else echo "${R}stopped${O} after a failure: $DONE upgraded, $SKIP skipped, $FAILS failed"; exit 1; fi
