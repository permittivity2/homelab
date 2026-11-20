#!/bin/bash
# ============================================================================
# Reboot fleet guests ONE AT A TIME, with checks before, between and after --
# RUN ON THE ADMIN WORKSTATION (post-cutover #97, the reboot after the OS sweep).
#
#   ./fleet-reboot.sh NN [NN ...]            # reboot these, in this order (VIP holders moved last)
#   ./fleet-reboot.sh --dry-run NN [NN ...]  # the prechecks and the order, no reboot
#
# Per node, in this order:
#   PRE   reachable; the guest is running on pve2; the baseline is recorded
#         (active services, failed units, addresses, NFS mounts, uptime); a
#         patroni LEADER is switched over to a streaming replica first and the
#         switchover is waited for -- never a reboot under the leader.
#   REBOOT  `pct reboot` or `qm reboot` through pve2 (graceful: the container's
#         init, the VM's guest agent), then wait for: running on pve2, ssh,
#         a lower uptime (it really rebooted), systemd past "starting".
#   POST  every NFS mount back; a data service (drive, dovecot, search) that
#         started BEFORE its mount is restarted and flagged (#41 F ships the
#         ordering fix; until then this catches the race); every service that
#         was active is active again (waits up to 2 min); no new failed unit;
#         the node's own addresses back (DHCP on an edge is given 2 min); each
#         floating address it held is answered by someone; the agent answers
#         /health; patroni members are streaming again; an edge passes
#         edge-verify.sh from offsite; fleet-running-audit.sh on the node shows
#         no FAIL. Stops at the first node that fails a check.
# Nothing here changes any configuration.
# ============================================================================
set -uo pipefail
export LC_ALL=C   # sort and comm must agree on the order, here and on the nodes

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }

DRY=0; NODES=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        [0-9]|[0-9][0-9]) NODES+=("$(printf '%02d' "$((10#$a))")") ;;
        *) echo "unknown argument '$a' (usage: fleet-reboot.sh [--dry-run] NN [NN ...])"; exit 1 ;;
    esac
done
[ ${#NODES[@]} -gt 0 ] || { echo "usage: fleet-reboot.sh [--dry-run] NN [NN ...]"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PVE=pve2
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
svc_of(){ printf '10.50.2.%d' "$((144 + 10#$1))"; }
gid_of(){ printf '%d' "$((400 + 10#$1))"; }
is_vm(){ [ "$((10#$1))" -ge 62 ]; }
rssh(){ ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$1" "${@:2}" 2>/dev/null; }
pve(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$PVE" "sudo $*" 2>/dev/null; }
up(){ timeout 5 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }
addrs(){ rssh "$(ip_of "$1")" 'ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1 | LC_ALL=C sort'; }
floating(){ addrs "$1" | grep -E '^10\.50\.[0-3]\.' | grep -vx "$(svc_of "$1")" || true; }
# the services that must be active again after a boot: the active ones that are enabled (started at
# boot) -- a bus-activated unit like polkit is active only once something has asked for it
active_services(){ rssh "$(ip_of "$1")" 'LC_ALL=C; systemctl list-units --type=service --state=active --no-legend --plain | awk "{print \$1}" | sort > /tmp/.fr-active; systemctl list-unit-files --type=service --state=enabled,enabled-runtime --no-legend --plain | awk "{print \$1}" | sort > /tmp/.fr-enabled; comm -12 /tmp/.fr-active /tmp/.fr-enabled; grep -E "^homelab-|^bad_ips" /tmp/.fr-active; rm -f /tmp/.fr-active /tmp/.fr-enabled' | sort -u; }
failed_units(){ rssh "$(ip_of "$1")" 'systemctl --failed --no-legend --plain | awk "{print \$1}" | LC_ALL=C sort'; }
nfs_mounts(){ rssh "$(ip_of "$1")" 'findmnt -t nfs,nfs4 -n -o TARGET 2>/dev/null | LC_ALL=C sort'; }
uptime_s(){ rssh "$(ip_of "$1")" 'cut -d. -f1 /proc/uptime'; }
# the port that proves a floating address is answered by whoever holds it now
vip_port(){ case "$1" in 10.50.2.130) echo 5432 ;; 10.50.2.131) echo 6432 ;; 10.50.2.132) echo 3000 ;; 10.50.2.140) echo 993 ;; *) echo 22 ;; esac; }
# data services whose start must follow their NFS mount (service:mountpoint)
DATA_SVC="homelab-drive.service:/var/lib/homelab/drive-storage dovecot.service:/var/mail/vhosts homelab-search.service:/srv/mail-ro homelab-search-indexer.service:/srv/mail-ro prometheus.service:/var/lib/prometheus/metrics2"

ptable(){ rssh "$(ip_of "$1")" 'sudo patronictl -c /etc/patroni/config.yml list 2>/dev/null'; }
prole(){ # NN TABLE -> "Leader running" / "Replica streaming" / ""
    printf '%s\n' "$2" | awk -F'|' -v h="prod-homelab$1" '$2 ~ h {gsub(/^ +| +$/, "", $4); gsub(/^ +| +$/, "", $5); print $4, $5}'
}

step "order: nodes without a floating address first, holders last"
HOLD=(); PLAIN=()
for n in "${NODES[@]}"; do
    ip=$(ip_of "$n")
    up "$ip" || { warn "prod-homelab$n does not answer on :22 -- skipped"; continue; }
    f=$(floating "$n")
    if [ -n "$f" ]; then HOLD+=("$n"); echo "  prod-homelab$n holds $(echo "$f" | paste -sd' ' -)"; else PLAIN+=("$n"); echo "  prod-homelab$n"; fi
done
ORDER=("${PLAIN[@]}" "${HOLD[@]}")
[ ${#ORDER[@]} -gt 0 ] || { echo "no reachable node"; exit 1; }

FAILS=0; DONE=0
for n in "${ORDER[@]}"; do
    ip=$(ip_of "$n"); gid=$(gid_of "$n"); kind=ct; is_vm "$n" && kind=vm
    step "prod-homelab$n ($ip, $kind $gid)"
    st=$(pve "$([ $kind = vm ] && echo qm || echo pct) status $gid" | awk '{print $2}')
    [ "$st" = running ] || { bad "pve2 says the guest is '$st'"; FAILS=1; break; }
    BEFORE_S=$(active_services "$n"); BEFORE_F=$(failed_units "$n"); BEFORE_A=$(addrs "$n"); BEFORE_M=$(nfs_mounts "$n"); UP0=$(uptime_s "$n")
    FLOAT=$(printf '%s\n' "$BEFORE_A" | grep -E '^10\.50\.[0-3]\.' | grep -vx "$(svc_of "$n")" || true)
    OWN=$(printf '%s\n' "$BEFORE_A" | grep -vxF -f <(printf '%s\n' "$FLOAT"; echo "__none__") || true)
    note "active services: $(printf '%s\n' "$BEFORE_S" | grep -c .), failed: $(printf '%s\n' "$BEFORE_F" | grep -c . || true), nfs mounts: $(printf '%s\n' "$BEFORE_M" | grep -c . || true), uptime ${UP0}s$([ -n "$FLOAT" ] && echo ", holds $(echo "$FLOAT" | paste -sd' ' -)")"
    # a patroni leader is switched over first
    if printf '%s\n' "$BEFORE_S" | grep -qx patroni.service; then
        PTABLE=$(ptable "$n"); role=$(prole "$n" "$PTABLE")
        if [ "${role%% *}" = Leader ]; then
            cand=$(printf '%s\n' "$PTABLE" | awk -F'|' '$4 ~ /Replica/ && $5 ~ /streaming/ {gsub(/^ +| +$/, "", $2); print $2; exit}')
            [ -n "$cand" ] || { bad "this is the patroni leader and no streaming replica exists to switch over to"; FAILS=1; break; }
            if [ "$DRY" = 1 ]; then note "dry run: would switch the leader over to $cand before rebooting"
            else
                echo "  patroni leader: switching over to $cand first"
                rssh "$ip" "sudo patronictl -c /etc/patroni/config.yml switchover --leader prod-homelab$n --candidate $cand --force" </dev/null | tail -2 | sed 's/^/    /'
                okrole=0; for _ in $(seq 1 30); do sleep 3; PTABLE=$(ptable "$n"); role=$(prole "$n" "$PTABLE"); case "$role" in "Replica streaming"*) okrole=1; break ;; esac; done
                [ "$okrole" = 1 ] && ok "now a streaming replica; leader is $(printf '%s\n' "$PTABLE" | awk -F'|' '$4 ~ /Leader/ {gsub(/^ +| +$/, "", $2); print $2}')" || { bad "did not become a streaming replica after the switchover: $(printf '%s\n' "$PTABLE" | grep -E 'prod-homelab' | tr -s ' ')"; FAILS=1; break; }
            fi
        elif [ "${role%% *}" = Replica ] && [ "${role#* }" != streaming ]; then bad "patroni replica is '$role', not streaming -- not rebooting it"; FAILS=1; break
        else note "patroni: $role"; fi
    fi
    if [ "$DRY" = 1 ]; then note "dry run: would reboot now"; continue; fi

    # --- reboot ---
    T0=$(date +%s)
    if [ $kind = vm ]; then pve "qm reboot $gid --timeout 180" >/dev/null; else pve "pct reboot $gid --timeout 120" >/dev/null; fi
    for _ in $(seq 1 30); do st=$(pve "$([ $kind = vm ] && echo qm || echo pct) status $gid" | awk '{print $2}'); [ "$st" = running ] && break; sleep 2; done
    [ "$st" = running ] || { bad "the guest is '$st' after the reboot command -- look on pve2"; FAILS=1; break; }
    back=0; for _ in $(seq 1 150); do up "$ip" && back=1 && break; sleep 2; done
    [ "$back" = 1 ] || { bad "no ssh within 5 minutes of the reboot"; FAILS=1; break; }
    UP1=""; for _ in $(seq 1 30); do UP1=$(uptime_s "$n"); [ -n "$UP1" ] && break; sleep 2; done
    if [ -n "$UP1" ] && [ "$UP1" -lt "$UP0" ]; then ok "rebooted (back on ssh after $(( $(date +%s) - T0 )) s, uptime ${UP1}s)"; else bad "uptime did not drop (${UP0}s -> '${UP1}'): it did not reboot?"; FAILS=1; break; fi
    for _ in $(seq 1 90); do ss=$(rssh "$ip" 'systemctl is-system-running 2>/dev/null'); case "$ss" in initializing|starting|"") sleep 2 ;; *) break ;; esac; done
    note "systemd: ${ss:-?}"; sleep 10

    # --- post ---
    for _ in $(seq 1 30); do AFTER_M=$(nfs_mounts "$n"); [ "$AFTER_M" = "$BEFORE_M" ] && break; sleep 2; done
    [ "$AFTER_M" = "$BEFORE_M" ] && ok "nfs mounts back ($(printf '%s\n' "$AFTER_M" | grep -c . || true))" || { bad "nfs mounts differ: before [$(echo "$BEFORE_M" | paste -sd' ' -)] after [$(echo "$AFTER_M" | paste -sd' ' -)]"; FAILS=1; break; }
    # the race #41 F closes: a data service that came up before its mount is restarted now that the mount is there
    for pair in $DATA_SVC; do
        svc=${pair%%:*}; mp=${pair#*:}
        printf '%s\n' "$BEFORE_S" | grep -qx "$svc" || continue
        printf '%s\n' "$AFTER_M" | grep -qx "$mp" || continue
        ts=$(rssh "$ip" "systemctl show -p ActiveEnterTimestampMonotonic --value $svc; systemctl show -p ActiveEnterTimestampMonotonic --value \"\$(systemd-escape -p --suffix=mount $mp)\"" | paste -sd' ' -)
        s_ts=${ts%% *}; m_ts=${ts##* }
        if [ -n "$s_ts" ] && [ -n "$m_ts" ] && [ "$s_ts" != 0 ] && [ "$m_ts" != 0 ] && [ "$s_ts" -lt "$m_ts" ]; then
            warn "$svc started BEFORE $mp was mounted -- restarting it on top of the mount (the ordering fix is #41 F)"
            rssh "$ip" "sudo systemctl restart $svc" </dev/null; sleep 3
        else note "$svc started after $mp was mounted"; fi
    done
    for _ in $(seq 1 60); do AFTER_S=$(active_services "$n"); MISSING=$(comm -23 <(printf '%s\n' "$BEFORE_S") <(printf '%s\n' "$AFTER_S") | grep -E '.' || true); [ -z "$MISSING" ] && break; sleep 2; done
    [ -z "$MISSING" ] && ok "every service that was active is active again ($(printf '%s\n' "$AFTER_S" | grep -c .))" || { bad "not active again: $(echo "$MISSING" | paste -sd' ' -)"; FAILS=1; break; }
    # netplan-configure and systemd-networkd-wait-online fail at every container boot (a Proxmox
    # quirk, no service behind them; fleet-running-audit.sh knows them too): never "new"
    AFTER_F=$(failed_units "$n"); NEWF=$(comm -13 <(printf '%s\n' "$BEFORE_F") <(printf '%s\n' "$AFTER_F") | grep -E '.' | grep -vxE 'netplan-configure\.service|systemd-networkd-wait-online\.service' || true)
    [ -z "$NEWF" ] && ok "no new failed unit$([ -n "$AFTER_F" ] && echo " (as before: $(echo "$AFTER_F" | paste -sd' ' -))")" || { bad "newly failed: $(echo "$NEWF" | paste -sd' ' -)"; FAILS=1; break; }
    for _ in $(seq 1 60); do AFTER_A=$(addrs "$n"); OWN2=$(printf '%s\n' "$AFTER_A" | grep -vE '^10\.50\.[0-3]\.' ; printf '%s\n' "$AFTER_A" | grep -x "$(svc_of "$n")"); OWN2=$(printf '%s\n' "$OWN2" | sort); [ "$OWN2" = "$(printf '%s\n' "$OWN" | sort)" ] && break; sleep 2; done
    [ "$OWN2" = "$(printf '%s\n' "$OWN" | sort)" ] && ok "own addresses back ($(echo "$OWN2" | paste -sd' ' -))" || { bad "own addresses differ: before [$(echo "$OWN" | paste -sd' ' -)] after [$(echo "$OWN2" | paste -sd' ' -)]"; FAILS=1; break; }
    for v in $FLOAT; do
        p=$(vip_port "$v"); holder=$(printf '%s\n' "$AFTER_A" | grep -qx "$v" && echo "this node" || echo "another node")
        if rssh "$ip" "timeout 5 bash -c 'echo > /dev/tcp/$v/$p'" </dev/null; then ok "$v:$p answers (held by $holder)"; else bad "$v:$p does not answer from $ip"; FAILS=1; fi
    done
    [ "$FAILS" = 0 ] || break
    if printf '%s\n' "$BEFORE_S" | grep -qx homelab-agent.service; then
        hc=""; for _ in $(seq 1 15); do hc=$(rssh "$ip" 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:2520/health'); [ "$hc" = 200 ] && break; sleep 2; done
        [ "$hc" = 200 ] && ok "agent /health 200" || { bad "agent /health -> '${hc:-none}'"; FAILS=1; break; }
    fi
    if printf '%s\n' "$BEFORE_S" | grep -qx patroni.service; then
        prole=""; for _ in $(seq 1 60); do PTABLE=$(ptable "$n"); prole=$(prole "$n" "$PTABLE"); case "$prole" in "Replica streaming"*|Leader*) break ;; esac; sleep 3; done
        leader=$(printf '%s\n' "$PTABLE" | awk -F'|' '$4 ~ /Leader/ {gsub(/^ +| +$/, "", $2); print $2}')
        case "$prole" in "Replica streaming"*|Leader*) ok "patroni: $prole (leader: ${leader:-none})" ;; *) bad "patroni member is '$prole' after the reboot: $(printf '%s\n' "$PTABLE" | grep -E 'prod-homelab' | tr -s ' ')"; FAILS=1; break ;; esac
        [ -n "$leader" ] || { bad "no patroni leader"; FAILS=1; break; }
    fi
    case "$n" in 00|01|02)
        sleep 15
        if "$HERE/edge-verify.sh" "$n" >/tmp/fleet-reboot-edge-$n.log 2>&1; then ok "edge-verify $n passed from offsite"; else bad "edge-verify $n failed (log: /tmp/fleet-reboot-edge-$n.log)"; FAILS=1; break; fi ;;
    esac
    AOUT=$("$HERE/fleet-running-audit.sh" "$n" 2>&1)
    ABAD=$(printf '%s\n' "$AOUT" | grep -E '^  FAIL' || true)
    [ -z "$ABAD" ] && ok "running audit clean" || { bad "running audit:"; echo "$ABAD" | sed 's/^/    /'; FAILS=1; break; }
    DONE=$((DONE+1))
done

echo
if [ "$FAILS" = 0 ]; then echo "${G}done${O}: $DONE rebooted$([ "$DRY" = 1 ] && echo ' (dry run: none)')"; exit 0
else echo "${R}stopped${O} after a failure: $DONE rebooted"; exit 1; fi
