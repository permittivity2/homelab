#!/bin/bash
# ============================================================================
# Prove that an NFS-backed service protects itself when its store is not
# there at boot -- RUN ON THE ADMIN WORKSTATION. Post-cutover #41, phase 1.
#
#   ./nas-guard-test.sh NN                 # e.g. 64 (dovecot standby), 67 (drive), 72 (search)
#   ./nas-guard-test.sh NN --case refused  # the export does not exist (default: the server is unreachable)
#
# WHAT IT DOES, on ONE VM that is not the active member of its tier:
#   1. records the real fstab line of the store, then points it at
#      10.45.0.250 (an address nobody answers: "the NAS is down") or at an
#      export that does not exist ("refused") -- an nft drop would not
#      survive the reboot being tested
#   2. reboots the VM (sudo reboot inside it) and waits for SSH as the
#      ordinary user: with `nofail` the boot must not wait for the store
#   3. checks: the store is NOT mounted, the bound service(s) are NOT active
#      (inactive, not failed, with ActiveEnterTimestampMonotonic=0), nothing
#      was written under the bare mountpoint, the retry timer is armed
#   4. puts the real line back and waits: homelab-mount-retry must mount the
#      store and start the service(s) by itself within a few minutes
#   5. runs nfs-mounts-orchestrate.sh --verify for the host
# Exits 1 on any failed check. The fstab line is restored even on failure.
# ============================================================================
set -u
N="${1:?node number, e.g. 64}"; CASE="${3:-unreachable}"; [ "${2:-}" = "--case" ] && CASE="$3"
ip=$(printf '10.20.2.%d' "$((144 + 10#$N))")
rssh(){ ssh -o ConnectTimeout=8 -o BatchMode=yes "$ip" "$@" 2>/dev/null; }
R=$'\e[31m'; G=$'\e[32m'; O=$'\e[0m'; FAILS=0
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
case "$N" in
    62|63|64) MP=/var/mail/vhosts; SVCS="dovecot.service"; UNIT=var-mail-vhosts.mount ;;
    65|66|67) MP=/var/lib/homelab/drive-storage; SVCS="homelab-drive.service"; UNIT='var-lib-homelab-drive\x2dstorage.mount' ;;
    70|71|72) MP=/srv/mail-ro; SVCS="homelab-search.service homelab-search-indexer.service"; UNIT='srv-mail\x2dro.mount' ;;
    *) echo "not a storage VM: $N"; exit 1 ;;
esac
echo "=== prod-homelabvm$N ($ip): $MP, $SVCS, case: $CASE ==="
line=$(rssh "awk -v m='$MP' '\$1 !~ /^#/ && \$2 == m {print; exit}' /etc/fstab")
[ -n "$line" ] || { bad "no fstab line for $MP"; exit 1; }
case "$CASE" in
    unreachable) broken=$(echo "$line" | sed -E 's/^10\.45\.0\.105:/10.45.0.250:/') ;;
    refused)     broken=$(echo "$line" | sed -E 's#^(10\.45\.0\.105:/[^ ]*)#\1-does-not-exist#') ;;
    *) echo "unknown case $CASE"; exit 1 ;;
esac
echo "  real:   $line"; echo "  broken: $broken"
restore(){ rssh "sudo perl -i -pe 's{^\Q$broken\E\$}{$line}' /etc/fstab; sudo systemctl daemon-reload"; }
trap restore EXIT
rssh "sudo cp -a /etc/fstab /etc/fstab.bak-guardtest; sudo perl -i -pe 's{^\Q$line\E\$}{$broken}' /etc/fstab; sudo systemctl daemon-reload; grep -c -F '$broken' /etc/fstab" | grep -q 1 && ok "fstab line broken for the test" || { bad "could not edit fstab"; exit 1; }
t0=$(date +%s); echo "  rebooting at $(date +%T)"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$ip" "sudo systemctl reboot" >/dev/null 2>&1
sleep 20
for i in $(seq 1 60); do rssh "true" && break; sleep 5; done
up=$(rssh "uptime -s"); t1=$(date +%s)
[ -n "$up" ] && ok "SSH back as the ordinary user $((t1-t0)) s after the reboot order (booted $up): the boot did not wait for the store" || { bad "no SSH within 5 min"; exit 1; }
sleep 15
m=$(rssh "mountpoint -q '$MP' && echo mounted || echo not-mounted"); [ "$m" = not-mounted ] && ok "$MP is not mounted" || bad "$MP is mounted?!"
cnt=$(rssh "sudo find '$MP' -mindepth 1 2>/dev/null | wc -l"); [ "$cnt" = 0 ] && ok "nothing under the bare $MP" || bad "$cnt entries under the bare $MP"
for s in $SVCS; do
    st=$(rssh "systemctl show -p ActiveState -p ActiveEnterTimestampMonotonic -p Result '$s' | paste -sd' ' -")
    case "$st" in *"ActiveState=inactive"*"ActiveEnterTimestampMonotonic=0"*) ok "$s is inactive and has never run this boot ($st)" ;; *) bad "$s: $st" ;; esac
done
tm=$(rssh "systemctl is-active homelab-mount-retry.timer"); [ "$tm" = active ] && ok "homelab-mount-retry.timer is armed" || bad "retry timer: $tm"
ms=$(rssh "systemctl show -p ActiveState -p Result '$UNIT' | paste -sd' ' -"); echo "  mount unit: $ms"
echo "  restoring the real line at $(date +%T); waiting for the retry (every 2 min) ..."
restore; trap - EXIT
t2=$(date +%s); done_at=""
for i in $(seq 1 40); do
    sleep 10
    m=$(rssh "mountpoint -q '$MP' && echo mounted || echo not-mounted")
    all=1; for s in $SVCS; do [ "$(rssh "systemctl is-active '$s'")" = active ] || all=0; done
    if [ "$m" = mounted ] && [ "$all" = 1 ]; then done_at=$(( $(date +%s) - t2 )); break; fi
done
[ -n "$done_at" ] && ok "the store mounted and $SVCS started by themselves ${done_at} s after the line came back" || bad "not recovered within $(( $(date +%s) - t2 )) s: mount=$m"
rssh "sudo journalctl -u homelab-mount-retry --since '15 min ago' --no-pager -o cat" | grep -E "starting" | tail -4 | sed 's/^/  journal: /'
cnt=$(rssh "sudo find '$MP' -maxdepth 1 -mindepth 1 2>/dev/null | wc -l"); [ "$cnt" != 0 ] && ok "the real store is in place ($cnt top-level entries)" || bad "the store looks empty"
echo "=== nfs-mounts-orchestrate.sh --verify for this host ==="
NODES="$N" "$(dirname "$0")/nfs-mounts-orchestrate.sh" --verify 2>&1 | grep -E "FAIL|result|every store" | sed 's/^/  /'
echo "=== result: $([ "$FAILS" = 0 ] && echo "the service protected itself and recovered on its own" || echo "$FAILS check(s) FAILED") ==="
exit $(( FAILS > 0 ))
