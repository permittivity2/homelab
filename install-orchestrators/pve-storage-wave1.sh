#!/bin/bash
# ============================================================================
# Move the first member of every pool (and the singletons that matter) from the
# spinning pool to the NVMe, one guest at a time -- RUN ON THE ADMIN
# WORKSTATION. Post-cutover #41, waves plan step 2.
#
#   ./pve-storage-wave1.sh --dry-run             # every wave-1 guest: where its volumes are, what would be done
#   ./pve-storage-wave1.sh --apply NN [NN ...]   # move these (guest numbers: 403, 462 ...), in the order given, stop at the first failure
#   ./pve-storage-wave1.sh --verify              # every wave-1 guest on local-lvm, nothing of it left on the spinner
#
# Nothing but Proxmox's own commands: pct shutdown / move-volume / start / set,
# qm disk move (online) / set. No script lands on pve2.
#
# A CONTAINER: shutdown (graceful, 90 s, then stop) -> `pct move-volume N
# rootfs local-lvm` (the source is KEPT as unused0) -> start -> wait for SSH,
# the units that were active before, the agent's /health where installed ->
# only then `pct set N --delete unused0`. About a minute; the two pool-mates
# carry the pool meanwhile. If anything fails the guest is left as it is and
# the rollback is printed (the source is still there).
#
# A VM: `qm disk move N scsi0 local-lvm` runs with the VM online (a live
# mirror, no interruption) -> the VM still answers -> its cloud-init CD on the
# spinner is detached when cloud-init inside is disabled or pinned to None
# (checked first; it is then dead weight that would still tie the VM's start
# to the other disk) -> `qm set N --delete unused0`.
#
# THE DATABASE MEMBERS AND EDGE 00 are deliberately not special-cased here:
# move 407 (a replica) like any container; before 406, switch the leader to 07
# by hand (patronictl switchover) and switch back after; 400 last (keepalived
# moves .140 to 01 for the minute, the DNS steering drops .66). The order the
# plan gives: 403 415 421 424 427 430 433 436 447 450 453 446 445 409 412 418
# 439 442 470 469 465 462 407 406 400.
# ============================================================================
set -u
MODE="${1:---dry-run}"; shift || true
PVE=pve2
pve(){ ssh -n -o ConnectTimeout=15 -o BatchMode=yes "$PVE" "sudo $*" 2>/dev/null; }
rssh(){ ssh -n -o ConnectTimeout=6 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; O=$'\e[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
note(){ echo "  ${Y}>>${O}   $*"; }
FAILS=0
WAVE1="403 415 421 424 427 430 433 436 447 450 453 446 445 409 412 418 439 442 470 469 465 462 407 406 400"
ip_of(){ printf '10.20.2.%d' "$((144 + $1 - 400))"; }
UNITS='homelab-|nginx|postfix|dovecot|pdns|dnsdist|haproxy|keepalived|pgbouncer|patroni|etcd|opendkim|php|prometheus|grafana|bad-ips'

guest_type(){ pve "pct config $1 >/dev/null 2>&1 && echo pct || echo qm"; }
volumes(){ # id -> "key=storage:volid" for every disk/rootfs line, and unused ones
    pve "$(guest_type "$1") config $1" | awk -F': ' '/^(rootfs|scsi[0-9]+|virtio[0-9]+|sata[0-9]+|ide[0-9]+|unused[0-9]+):/ {split($2,a,","); print $1"="a[1]}'
}
active_units(){ rssh "$1" "systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null | awk '{print \$1}' | grep -E '$UNITS' | sort | paste -sd' ' -"; }
wait_ssh(){ for i in $(seq 1 40); do rssh "$1" true && return 0; sleep 3; done; return 1; }
agent_health(){ local ip=$1; local inst; inst=$(rssh "$ip" 'dpkg-query -W -f "\${db:Status-Status}" homelab-agent 2>/dev/null || echo none'); [ "$inst" = installed ] || { echo "n/a"; return; }; curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:2520/health"; }

case "$MODE" in
--dry-run|--verify)
    echo "=== wave 1 on pve2: where every guest's volumes are ==="
    for id in $WAVE1; do
        t=$(guest_type "$id"); vols=$(volumes "$id" | paste -sd' ' -); name=$(pve "$t config $id" | awk -F': ' '/^(hostname|name):/ {print $2}' | head -1)
        # only ATTACHED volumes decide (an unusedN on the spinner is a leftover copy a snapshot
        # still references -- 462 465 469 after the first run -- not something the boot needs)
        attached=$(echo "$vols" | tr ' ' '\n' | grep -v '^unused' | paste -sd' ' -); leftover=$(echo "$vols" | tr ' ' '\n' | grep '^unused' | paste -sd' ' -)
        case "$attached" in
            *"=local-spinner:"*) [ "$MODE" = --verify ] && bad "$id $t ${name:0:20}: still on the spinner: $attached" || note "$id $t ${name:0:20}: $attached  -> move to local-lvm" ;;
            *"=local-lvm:"*) ok "$id $t ${name:0:20}: on local-lvm ($attached)${leftover:+; leftover copy on the spinner: $leftover}" ;;
            *) bad "$id $t ${name:0:20}: unexpected: $vols" ;;
        esac
    done
    pve "pvesm status" | awk '/^local-lvm/ {printf "  local-lvm: %.0f GB free\n", $6/1048576}'
    echo "=== result: $FAILS problem(s) ==="; exit $(( FAILS > 0 )) ;;
--apply)
    [ $# -gt 0 ] || { echo "usage: $0 --apply NN [NN ...]"; exit 1; }
    for id in "$@"; do
        case " $WAVE1 " in *" $id "*) ;; *) bad "$id is not a wave-1 guest"; exit 1;; esac
        t=$(guest_type "$id"); ip=$(ip_of "$id"); name=$(pve "$t config $id" | awk -F': ' '/^(hostname|name):/ {print $2}' | head -1)
        echo "=== $id $t $name ($ip) $(date +%T) ==="
        vols=$(volumes "$id" | paste -sd' ' -)
        case "$vols" in *"=local-spinner:"*) ;; *) ok "already on local-lvm: $vols"; continue;; esac
        before=$(active_units "$ip"); [ -n "$before" ] && ok "active before: $before" || note "no unit list before (ssh?)"
        if [ "$t" = pct ]; then
            t0=$(date +%s)
            pve "pct shutdown $id --timeout 90" >/dev/null; st=$(pve "pct status $id"); [ "$st" = "status: stopped" ] || { pve "pct stop $id" >/dev/null; st=$(pve "pct status $id"); }
            [ "$st" = "status: stopped" ] && ok "stopped ($(( $(date +%s)-t0 )) s)" || { bad "could not stop $id: $st"; exit 1; }
            out=$(pve "pct move-volume $id rootfs local-lvm 2>&1 | tail -3"); vols=$(volumes "$id" | paste -sd' ' -)
            case "$vols" in "rootfs=local-lvm:"*) ok "rootfs moved: $vols ($(( $(date +%s)-t0 )) s)";; *) bad "move failed: $out"; echo "  rollback: nothing to do, the guest is still on the spinner; start it: ssh pve2 sudo pct start $id"; exit 1;; esac
            pve "pct start $id" >/dev/null
            wait_ssh "$ip" && ok "up again, SSH answers ($(( $(date +%s)-t0 )) s since the shutdown)" || { bad "no SSH within 2 min"; echo "  rollback: ssh pve2 'sudo pct stop $id; sudo pct set $id --delete rootfs --rootfs \$(sudo pct config $id | grep ^unused0: | cut -d\" \" -f2),size=8G; sudo pct start $id'"; exit 1; }
            for i in $(seq 1 40); do after=$(active_units "$ip"); [ "$after" = "$before" ] && break; sleep 3; done
            [ "$after" = "$before" ] && ok "every unit that was active is active again" || bad "units differ: before [$before] after [$after]"
            ah=$(agent_health "$ip"); case "$ah" in 200|n/a) ok "agent health: $ah";; *) bad "agent health: $ah";; esac
            if [ "$FAILS" = 0 ]; then pve "pct set $id --delete unused0" >/dev/null && ok "spinner copy removed" || bad "could not remove unused0"; else echo "  the spinner copy is kept as unused0 until this is understood"; exit 1; fi
        else
            t0=$(date +%s)
            out=$(pve "qm disk move $id scsi0 local-lvm 2>&1 | tail -2"); vols=$(volumes "$id" | paste -sd' ' -)
            case "$vols" in *"scsi0=local-lvm:"*) ok "scsi0 mirrored online to local-lvm ($(( $(date +%s)-t0 )) s)";; *) bad "move failed: $out"; exit 1;; esac
            rssh "$ip" true && ok "the VM still answers" || { bad "the VM does not answer SSH after the move"; exit 1; }
            after=$(active_units "$ip"); [ "$after" = "$before" ] && ok "every unit that was active is active" || bad "units differ: before [$before] after [$after]"
            ci=$(rssh "$ip" 'ls /etc/cloud/cloud-init.disabled 2>/dev/null; grep -l -E "datasource_list:\s*\[\s*None\s*\]" /etc/cloud/cloud.cfg.d/*.cfg 2>/dev/null' | paste -sd' ' -)
            cd0=$(pve "qm config $id" | awk -F': ' '/^ide0:/ {print $2}')
            if [ -n "$ci" ] && [[ "$cd0" == local-spinner:* ]]; then pve "qm set $id --delete ide0" >/dev/null && ok "cloud-init CD on the spinner detached (cloud-init inside is off: $ci); applies at the VM's next restart" || bad "could not detach ide0"
            elif [[ "$cd0" == local-spinner:* ]]; then note "cloud-init CD left on the spinner: cloud-init inside is NOT known to be off ($cd0)"; fi
            if [ "$FAILS" = 0 ]; then pve "qm set $id --delete unused0" >/dev/null && ok "spinner copy removed" || bad "could not remove unused0"; else echo "  the spinner copy is kept as unused0"; exit 1; fi
        fi
    done
    echo "=== done: $FAILS problem(s) ==="; exit $(( FAILS > 0 )) ;;
*) echo "usage: $0 --dry-run | --apply NN [NN ...] | --verify"; exit 1 ;;
esac
