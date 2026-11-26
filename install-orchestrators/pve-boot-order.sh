#!/bin/bash
# ============================================================================
# The boot order of the fleet on pve2 -- RUN ON THE ADMIN WORKSTATION.
# Post-cutover #41. Nothing but Proxmox's own per-guest settings is used:
# `onboot` and `startup=order=N[,up=S][,down=S]`, set with pct/qm over ssh.
# No script, unit or drop-in lands on pve2 (Gardner, 2026-11-22: "pve2 should
# be kept as close to normal ProxMox install as possible").
#
#   ./pve-boot-order.sh --dry-run          # the full table, CHANGE marks, records today's values; changes nothing
#   ./pve-boot-order.sh --apply            # set onboot + startup where they differ, then --verify
#   ./pve-boot-order.sh --undo FILE        # put back the values a --dry-run/--apply recorded
#   ./pve-boot-order.sh --verify           # every invariant, and the resulting boot sequence
#   ./pve-boot-order.sh --runbook          # the steps of the scheduled reboot
#   ./pve-boot-order.sh --after-boot       # what to check after pve2 came back, from here
#
# HOW PROXMOX BOOTS GUESTS (read from its code, 2026-11-12): startall takes
# the guests with onboot=1, sorts by `order` (a missing order sorts last),
# starts each order group in parallel (max_workers = 8 here) and waits for
# every start task of the group -- plus each guest's `up` seconds -- before
# the next group. So a tier whose members share one order starts together;
# a guest that must come after another needs a HIGHER order. `up` is a plain
# sleep after the start, which is why the storage VMs get distinct orders:
# six 8 GB VMs reading their boot disks off the one spinning pool at the same
# instant is what `up=20` on each, in sequence, avoids. stopall runs the
# orders descending, `down` seconds per guest (default 180) before it forces.
# A start that fails (a NAS away at boot) is logged and the run goes on.
#
# THE ORDER (the fleet fact; edit here, nowhere else). THREE WAVES, one per storage
# (post-cutover #41 waves plan, after the first real reboot showed 66 boots at once
# off one spinning disk): wave 1 from pve2's NVMe has every service up in minutes;
# wave 2 from the NAS flash and wave 3 from the spinner follow, paced so each guest
# finishes its own boot before the next starts -- ONE container at a time with 30 s
# after each, VMs one at a time with 90 s after each ("no storms!"). Health over speed.
#   wave 1 (1-110, local-lvm):   ns03 ntp vpn01 | DB 406 407 (up 60, down 300) | pooler 409 | api 412, sso 418
#                                | 403 415 421 424 427 430 433 436 445 446 447 450 453 | dovecot 462, drive 465
#                                | postfix 439, roundcube 442 | edge 400 | metrics 469, search 470
#   wave 2 (200-222, nfs-speedy): one at a time, 30 s each: 404 416 422 425 428 431 434 437 448 451 440 443 410 413 419 edge 401
#                                | then VMs 463, 466, 471 (90 s each)
#   wave 3 (300-343, spinner):    DB 408 (down 300), then one at a time: 405 417 423 426 429 432 435 438 449 452 441 444 411 414 420 edge 402
#                                | VMs 464, 467, 472, mirrors 129 (90 s each) | harness 461 | NAS legacy 117 122 125 100
#   never (onboot=0)              spares 454-460, vm68, proxy01 109, 107 111 112, 300-360,
#                                 old VMs 102-106 110 113-115 118 121 128 200, templates
# ============================================================================
set -u
MODE="${1:---dry-run}"; ARG="${2:-}"
PVE=pve2; NODE=proxmox2
# -n: ssh must never read stdin, or a set inside the `while read` loop over the
# inventory eats the rest of the inventory (the first --apply set one guest).
pve(){ ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$PVE" "sudo $*" 2>/dev/null; }
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; O=$'\e[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
chg(){ echo "  ${Y}>>${O}   $*"; CHANGES=$((CHANGES+1)); }
FAILS=0; CHANGES=0
ITEM=/home/gardner/claude/general/homelab_issues_and_fixes/open/2026-11-02_post-cutover-41_pve2-reboot-fleet-startup/evidence

# id|tier label|order|up|down   (order "" = never starts: onboot=0, startup left as it is)
WANT=(
# --- wave 1: pve2's NVMe (local-lvm). Every service up from the fast disk before the spinner is touched. ---
"116|dns ns03|1|10|"
"108|time ntp|1|10|"
"126|vpn01|1|5|"
"406|database|30|60|300" "407|database|30|60|300"
"409|pooler|40|5|"
"412|api|50|15|" "418|sso|50|15|"
"403|auth dns|60||" "415|worker|60||"
"421|app|60||" "424|app|60||" "427|app|60||" "430|app|60||" "433|app|60||" "436|app|60||"
"445|static+apt|60||" "446|cert issuer|60||" "447|notes|60||" "450|calendar|60||" "453|ai|60||"
"462|dovecot vm (active)|80|20|" "465|drive vm|83|20|"
"439|postfix|88|5|" "442|roundcube|88|5|"
"400|edge|90|5|"
"469|metrics vm|100|20|" "470|search vm|101|20|"
# --- wave 2: the NAS flash (nfs-speedy). Second members. ONE container at a time, 30 s after each; VMs one at a time, 90 s after each. ---
"404|auth dns|200|30|" "416|worker|201|30|" "422|app|202|30|" "425|app|203|30|" "428|app|204|30|" "431|app|205|30|"
"434|app|206|30|" "437|app|207|30|" "448|notes|208|30|" "451|calendar|209|30|" "440|postfix|210|30|" "443|roundcube|211|30|"
"410|pooler|212|30|" "413|api|213|30|" "419|sso|214|30|" "401|edge|215|30|"
"463|dovecot vm|220|90|" "466|drive vm|221|90|" "471|search vm|222|90|"
# --- wave 3: the spinner (local-spinner). Third members, standbys, the rest; same pacing. ---
"408|database|300|30|300"
"405|auth dns|301|30|" "417|worker|302|30|" "423|app|303|30|" "426|app|304|30|" "429|app|305|30|" "432|app|306|30|"
"435|app|307|30|" "438|app|308|30|" "449|notes|309|30|" "452|calendar|310|30|" "441|postfix|311|30|" "444|roundcube|312|30|"
"411|pooler|313|30|" "414|api|314|30|" "420|sso|315|30|" "402|edge|316|30|"
"464|dovecot vm|320|90|" "467|drive vm|321|90|" "472|search vm|322|90|" "129|mirrors vm|323|90|"
"461|harness|330|30|"
"117|legacy nas administrator|340|10|" "122|legacy nas aptcacher|341|10|" "125|legacy nas forwarder01|342|10|" "100|legacy nas plex|343|10|"
)
NEVER="454 455 456 457 458 459 460 468 109 107 111 112 300 301 302 303 304 305 306 307 308 309 310 311 312 313 314 315 316 317 318 319 320 321 322 323 324 325 326 327 328 329 330 331 332 333 334 335 336 337 338 339 340 341 342 343 344 345 346 347 348 349 350 360 102 103 104 105 106 110 113 114 115 118 121 128 200 99907 99908 99909 99910 99911 99912 99913"

startup_of(){ local o="$1" u="$2" d="$3"; local s="order=$o"; [ -n "$u" ] && s="$s,up=$u"; [ -n "$d" ] && s="$s,down=$d"; echo "$s"; }
# one pass over pve2 for every guest's type, name, status, onboot, startup
inventory(){ pve 'perl -e '"'"'
  my %t; for (`pvesh get /cluster/resources --type vm --output-format json 2>/dev/null` =~ /\{[^{}]*\}/g) { my ($id)=/"vmid":(\d+)/; my ($s)=/"status":"([^"]+)"/; my ($n)=/"name":"([^"]*)"/; my ($ty)=/"type":"([^"]+)"/; $t{$id}=[$ty eq "lxc" ? "pct" : "qm", $n, $s] if $id }
  for my $id (sort { $a <=> $b } keys %t) { my ($c,$n,$s)=@{$t{$id}}; my %k = map { /^(\S+?):\s*(.*)$/ ? ($1=>$2) : () } `$c config $id 2>/dev/null`; print join("|", $id, $c, $n, $s, $k{onboot}//"", $k{startup}//"", $k{template}//""), "\n" }'"'"; }

declare -A W_ORDER W_UP W_DOWN W_TIER
for w in "${WANT[@]}"; do IFS='|' read -r id tier order up down <<<"$w"; W_ORDER[$id]=$order; W_UP[$id]=$up; W_DOWN[$id]=$down; W_TIER[$id]=$tier; done
declare -A NEV; for n in $NEVER; do NEV[$n]=1; done

case "$MODE" in
--runbook)
cat <<'RB'
THE SCHEDULED REBOOT OF pve2 (post-cutover #41, phase 5) -- Gardner present.
Before:
  1. ./pve-boot-order.sh --verify                       -> green
  2. ./fleet-version-audit.sh ; ./fleet-running-audit.sh -> green
  3. ssh 10.20.2.150 'sudo patronictl -c /etc/patroni/config.yml list'  -> one leader, two streaming, one timeline
  4. ./nfs-mounts-orchestrate.sh --verify ; ./db-unit-policy.sh --verify -> green
  5. ssh pve2 'pvesh get /cluster/tasks' / the GUI: no backup (vzdump) running; NAS up (ssh pve2 'ls /mnt/pve/nas-vms')
  6. tell the house: a few minutes without mail, DNS and the web.
The reboot:
  7. ssh pve2 'sudo systemctl reboot'   (stopall runs the orders descending; the DB tier has 300 s)
  8. watch from offsite: ssh offsite 'while ! curl -s -m 5 -o /dev/null https://www.mailmasker.org/; do date; sleep 15; done'
     and from here: until ssh pve2 true; do sleep 10; done
After pve2 answers:
  9. ./pve-boot-order.sh --after-boot   (every expected guest running, none of the never list, the startall task log,
     agents, patroni, VIPs, the NFS-bound services by name, mounts, the audits, alerts after ten minutes)
 10. ./edge-verify.sh 00 ; 01 ; 02   ./dns-ipv6-orchestrate.sh --verify   ./smtps-orchestrate.sh --verify
 11. the first real numbers (the startall task log's timings) replace the up= guesses in this file if needed.
If a tier did not come up: ssh pve2 'sudo pct start N' / 'sudo qm start N' by hand, in the order above; ./pve-boot-order.sh --undo FILE puts every flag back.
RB
exit 0 ;;
--dry-run|--apply|--verify)
    echo "=== pve2 ($NODE): guests, today vs wanted ==="
    inv=$(inventory) || { bad "pve2 unreachable"; exit 1; }
    [ -n "$inv" ] || { bad "empty inventory"; exit 1; }
    ts=$(date +%Y%m%d-%H%M%S); rec="$ITEM/pve-boot-order-before-$ts.txt"; mkdir -p "$ITEM"
    [ "$MODE" != --verify ] && { printf 'id|cmd|onboot|startup\n' > "$rec"; }
    declare -A SEEN
    while IFS='|' read -r id cmd name status onboot startup tpl; do
        SEEN[$id]=1
        [ "$MODE" != --verify ] && printf '%s|%s|%s|%s\n' "$id" "$cmd" "$onboot" "$startup" >> "$rec"
        if [ -n "${W_ORDER[$id]:-}" ]; then
            want=$(startup_of "${W_ORDER[$id]}" "${W_UP[$id]}" "${W_DOWN[$id]}")
            if [ "${onboot:-0}" = 1 ] && [ "$startup" = "$want" ]; then ok "$id $cmd ${name:0:22} (${W_TIER[$id]}): onboot=1 $want"
            else
                chg "$id $cmd ${name:0:22} (${W_TIER[$id]}): onboot=${onboot:-unset} startup=${startup:-unset}  ->  onboot=1 $want"
                [ "$MODE" = --apply ] && { pve "$cmd set $id --onboot 1 --startup '$want'" >/dev/null && ok "   set" || bad "   could not set $id"; }
                [ "$MODE" = --verify ] && bad "$id not as wanted"
            fi
        elif [ -n "${NEV[$id]:-}" ] || [ "$tpl" = 1 ]; then
            # A guest that is RUNNING today but on the never list is a stale table
            # (2026-11-23: notes, calendar and ai had moved onto "spares" 47-53 and
            # were left off after the first boot). Decide; never silently.
            if [ "$status" = running ] && [ "$tpl" != 1 ]; then bad "$id $cmd ${name:0:22} is RUNNING today but on the never-start list -- a spare in use? move it into WANT or stop it"
            elif [ "${onboot:-0}" = 0 ]; then ok "$id $cmd ${name:0:22}: never starts (onboot=${onboot:-unset})"
            else
                chg "$id $cmd ${name:0:22}: onboot=$onboot  ->  0 (never starts)"
                [ "$MODE" = --apply ] && { pve "$cmd set $id --onboot 0" >/dev/null && ok "   set" || bad "   could not set $id"; }
                [ "$MODE" = --verify ] && bad "$id must not start on boot"
            fi
        else
            bad "$id $cmd ${name:0:22} ($status, onboot=${onboot:-unset}): not in the table -- decide (add to WANT or NEVER)"
        fi
    done <<<"$inv"
    for id in "${!W_ORDER[@]}"; do [ -n "${SEEN[$id]:-}" ] || bad "$id is in the table but not on pve2"; done
    echo "=== the resulting boot sequence (expected guests, by order; VMs one by one) ==="
    for w in "${WANT[@]}"; do IFS='|' read -r id tier order up down <<<"$w"; printf '%4d %s %s\n' "$order" "$id" "$tier"; done | sort -n -k1,1 -k2,2 | awk '{o=$1; $1=""; sub(/^ /,""); if (o!=last) {printf "\n  order %-4s", o; last=o} printf " %s", $1}' ; echo; echo
    case "$MODE" in
        --dry-run) echo "=== result: dry run, $CHANGES change(s) would be made, $FAILS problem(s); today's values recorded in $rec ==="; ;;
        --apply)   echo "=== applied $CHANGES change(s), $FAILS problem(s); the previous values are in $rec (--undo $rec puts them back) ==="; exec "$0" --verify ;;
        --verify)  [ "$FAILS" = 0 ] && echo "=== result: every guest as wanted; the order above is what a pve2 boot will do ===" || echo "=== result: $FAILS problem(s) ==="; exit $(( FAILS > 0 )) ;;
    esac ;;
--undo)
    [ -f "$ARG" ] || { echo "usage: $0 --undo FILE (a pve-boot-order-before-*.txt)"; exit 1; }
    echo "=== restoring onboot/startup from $ARG ==="
    tail -n +2 "$ARG" | while IFS='|' read -r id cmd onboot startup; do
        args=""; [ -n "$onboot" ] && args="--onboot $onboot" || args="--delete onboot"
        [ -n "$startup" ] && args="$args --startup '$startup'" || args="$args --delete startup"
        pve "$cmd set $id $args" >/dev/null && ok "$id: $args" || bad "$id: could not restore ($args)"
    done
    echo "=== done ===" ;;
--after-boot)
    echo "=== pve2 after a boot: $(ssh -o ConnectTimeout=10 -o BatchMode=yes pve2 'uptime -s; uptime -p' 2>/dev/null | paste -sd' ' -) ==="
    inv=$(inventory) || { bad "pve2 unreachable"; exit 1; }
    while IFS='|' read -r id cmd name status onboot startup tpl; do
        if [ -n "${W_ORDER[$id]:-}" ]; then [ "$status" = running ] && ok "$id ${name:0:22} running" || bad "$id ${name:0:22} (${W_TIER[$id]}) is $status"
        elif [ "$status" = running ]; then bad "$id ${name:0:22} is running but is not expected to start"; fi
    done <<<"$inv"
    echo "--- the startall task of this boot"
    pve 'f=$(ls -t /var/log/pve/tasks/*/UPID:*:startall:* 2>/dev/null | head -1); [ -n "$f" ] && { echo "$f"; grep -E -i "error|fail|warn|timeout" "$f" | head -8; grep -c -E "^Starting " "$f" | sed "s/^/starts: /"; } || echo "no startall task log found"' | sed 's/^/  /'
    echo "--- agents, patroni, VIPs, the NFS-bound services"
    # only where the agent is installed (the harness 461 has none); a node that does not even answer dpkg is reported as unreachable
    for w in "${WANT[@]}"; do IFS='|' read -r id tier order up down <<<"$w"; case "$id" in 4[0-6][0-9]|47[0-2]) n=$((id-400)); ip=$(printf '10.20.2.%d' $((144+n)));
        # "none" = reachable, no agent package (dpkg prints nothing for one that is not installed, which would look like an unreachable node)
        inst=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$ip" 'dpkg-query -W -f "\${db:Status-Status}" homelab-agent 2>/dev/null || echo none' 2>/dev/null)
        case "$inst" in installed) code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:2520/health"); [ "$code" = 200 ] || bad "agent on $id ($ip): $code";; "") bad "$id ($ip): unreachable over ssh";; *) ;; esac;; esac; done; ok "agents answered where installed (any that did not are listed above)"
    pl=$(ssh -o ConnectTimeout=10 -o BatchMode=yes 10.20.2.150 'sudo patronictl -c /etc/patroni/config.yml list 2>/dev/null' 2>/dev/null); echo "$pl" | grep -q -E "Leader.*running" && [ "$(echo "$pl" | grep -c -E "Replica.*(streaming|running)")" -ge 2 ] && ok "patroni: a leader and two replicas" || bad "patroni: $(echo "$pl" | paste -sd' ' - | cut -c1-200)"
    # the TL column only: the Lag columns hold numbers too (three nodes on timeline 4 with lag 0 once counted as two)
    tl=$(echo "$pl" | grep -E "Leader|Replica" | awk -F"|" '{gsub(/ /,"",$6); if ($6 != "") print $6}' | sort -u | wc -l); [ "$tl" = 1 ] && ok "one timeline" || bad "timelines: $tl ($(echo "$pl" | grep -E "Leader|Replica" | awk -F"|" '{gsub(/ /,"",$6); print $6}' | paste -sd, -))"
    for v in "10.50.2.130 06 07 08" "10.50.2.131 09 10 11" "10.50.2.132 12 13 14" "10.50.2.140 00 01 02"; do set -- $v; vip=$1; shift; holders=0; for n in "$@"; do ip=$(printf '10.20.2.%d' $((144+10#$n))); ssh -o ConnectTimeout=5 -o BatchMode=yes "$ip" "ip -4 -o addr show | grep -q '$vip/'" 2>/dev/null && holders=$((holders+1)); done; [ "$holders" = 1 ] && ok "$vip has one holder" || bad "$vip has $holders holders"; done
    for s in "dovecot 62 63 64" "homelab-drive 65 66 67" "homelab-search 70 71 72" "homelab-search-indexer 70 71 72" "pgbouncer 09 10 11" "patroni 06 07 08" "etcd 06 07 08"; do set -- $s; svc=$1; shift; for n in "$@"; do ip=$(printf '10.20.2.%d' $((144+10#$n))); st=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$ip" "systemctl is-active $svc" 2>/dev/null); [ "$st" = active ] || bad "$svc on $n: ${st:-unreachable}"; done; done; ok "services checked by name (dovecot, drive, search, indexer, pgbouncer, patroni, etcd)"
    "$(dirname "$0")/nfs-mounts-orchestrate.sh" --verify 2>&1 | grep -E "FAIL|every store" | sed 's/^/  /'
    "$(dirname "$0")/fleet-version-audit.sh" 2>&1 | grep -E -i "CONSISTENT|behind|half" | head -3 | sed 's/^/  /'
    "$(dirname "$0")/fleet-running-audit.sh" 2>&1 | grep -E "FLEET RUNNING|MISSING|UNEXPECTED|DRIFT" | head -5 | sed 's/^/  /'
    al=$(curl -s -m 10 'http://10.50.2.213:9090/api/v1/query?query=ALERTS%7Balertstate%3D~%22pending%7Cfiring%22%2Calertname!%3D%22Watchdog%22%7D' | grep -o '"alertname":"[^"]*"' | sort -u | paste -sd' ' -); [ -z "$al" ] && ok "no alert pending or firing but the Watchdog" || echo "  ${Y}alerts${O}: $al (wait ten minutes after the boot before reading this)"
    echo "--- run by hand: ./edge-verify.sh 00 | 01 | 02 ; ./dns-ipv6-orchestrate.sh --verify ; ./smtps-orchestrate.sh --verify ; the CT61 harness --quick"
    echo "=== result: $FAILS problem(s) ==="; exit $(( FAILS > 0 )) ;;
*) echo "usage: $0 --dry-run|--apply|--undo FILE|--verify|--runbook|--after-boot"; exit 1 ;;
esac
