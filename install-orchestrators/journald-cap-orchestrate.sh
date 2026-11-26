#!/bin/bash
# ============================================================================
# The journal's size cap on the fleet VMs -- RUN ON THE ADMIN WORKSTATION.
# Post-cutover #104.
#
#   ./journald-cap-orchestrate.sh --dry-run   # what each VM has vs what it should
#   ./journald-cap-orchestrate.sh --apply     # fix every VM, one at a time
#   ./journald-cap-orchestrate.sh --verify    # the invariants, nothing changed
#   NODES="69" ./journald-cap-orchestrate.sh --apply     # only these
#
# WHY. The VM template (vm69's lineage, 2026-10-05) carries TWO journald
# settings files:
#   /etc/systemd/journald.conf                   SystemMaxUse=5G  SystemMaxFileSize=1G
#                                                SystemMaxFiles=5 SystemKeepFree=500M
#   /etc/systemd/journald.conf.d/00-homelab.conf SystemMaxUse=256M
# The drop-in wins on SystemMaxUse -- but journald then raises SystemMaxUse to
# at least TWICE SystemMaxFileSize, and that is still 1G from the main file.
# So the real cap was 2 GB, not 256 MB: 2.0 GB of journal on vm69 (two 850 MB
# archived files), 1.5 GB on vm62. The containers are fine (stock main file,
# a 128M drop-in) and are not touched.
#
# WHAT IT OWNS, per VM (62-67, 69-72):
#   - the drop-in, now setting every size the main file sets:
#       SystemMaxUse=256M  SystemMaxFileSize=32M  SystemMaxFiles=8   (8 x 32M)
#     (a dated copy of the old drop-in is left beside it)
#   - after writing it: restart journald, rotate, vacuum down to the cap
#   - /var/log/journal/<id>/ for every <id> that is not this VM's machine-id:
#     the template's own journals (Aug-Oct 2026), copied along by every clone
#     (vm70 carried five directories). Listed with their sizes, then removed.
# Nothing else: syslog and its rotation are rsyslog's and logrotate's.
# ============================================================================
set -u
MODE="${1:---dry-run}"
case "$MODE" in --dry-run|--apply|--verify) ;; *) echo "usage: $0 --dry-run|--apply|--verify"; exit 1 ;; esac
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; O=$'\e[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
chg(){ echo "  ${Y}>>${O}   $*"; CHANGES=$((CHANGES+1)); }
FAILS=0; CHANGES=0
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }

VMS="62 63 64 65 66 67 69 70 71 72"      # 68 is the spare that never starts
[ -n "${NODES:-}" ] && VMS="$NODES"
DROPIN=/etc/systemd/journald.conf.d/00-homelab.conf
WANT_USE=256M; WANT_FILE=32M; WANT_FILES=8
CAP_MB=256; SLACK_MB=64                   # verify: du of /var/log/journal must stay under cap + slack

for n in $VMS; do
    ip=$(ip_of "$n")
    echo "=== prod-homelabvm$n ($ip) ==="
    # One read of everything we judge: the drop-in's three values, the machine
    # id, the journal directories with sizes, the total, journald's state.
    state=$(rssh "$ip" "sudo -n bash -c '
        echo \"use=\$(sed -n \"s/^SystemMaxUse=//p\" $DROPIN 2>/dev/null)\"
        echo \"file=\$(sed -n \"s/^SystemMaxFileSize=//p\" $DROPIN 2>/dev/null)\"
        echo \"files=\$(sed -n \"s/^SystemMaxFiles=//p\" $DROPIN 2>/dev/null)\"
        echo \"mid=\$(cat /etc/machine-id)\"
        echo \"active=\$(systemctl is-active systemd-journald)\"
        echo \"total_mb=\$(du -sm /var/log/journal | cut -f1)\"
        for d in /var/log/journal/*/; do id=\$(basename \"\$d\"); [ \"\$id\" = remote ] && continue; echo \"dir=\$id \$(du -sm \"\$d\" | cut -f1)\"; done
    '") || { bad "unreachable"; continue; }
    use=$(sed -n 's/^use=//p' <<<"$state"); file=$(sed -n 's/^file=//p' <<<"$state"); files=$(sed -n 's/^files=//p' <<<"$state")
    mid=$(sed -n 's/^mid=//p' <<<"$state"); active=$(sed -n 's/^active=//p' <<<"$state"); total=$(sed -n 's/^total_mb=//p' <<<"$state")
    stale=$(sed -n 's/^dir=//p' <<<"$state" | awk -v m="$mid" '$1 != m {print}')

    if [ "$use" = "$WANT_USE" ] && [ "$file" = "$WANT_FILE" ] && [ "$files" = "$WANT_FILES" ]; then
        ok "drop-in sets SystemMaxUse=$use SystemMaxFileSize=$file SystemMaxFiles=$files"
        need_dropin=0
    else
        case "$MODE" in --verify) bad "drop-in is use=${use:-unset} file=${file:-unset} files=${files:-unset} (want $WANT_USE/$WANT_FILE/$WANT_FILES)";;
                        *)        chg "drop-in is use=${use:-unset} file=${file:-unset} files=${files:-unset}; will set $WANT_USE/$WANT_FILE/$WANT_FILES";; esac
        need_dropin=1
    fi
    if [ -z "$stale" ]; then
        ok "only this VM's journal directory (${mid:0:12}...)"
    else
        while read -r id mb; do
            case "$MODE" in --verify) bad "stale journal directory /var/log/journal/$id (${mb} MB, not this machine-id)";;
                            *)        chg "stale journal directory /var/log/journal/$id (${mb} MB) will be removed";; esac
        done <<<"$stale"
    fi
    if [ "$total" -le $((CAP_MB + SLACK_MB)) ]; then ok "journal uses ${total} MB (cap ${CAP_MB} MB)"
    else case "$MODE" in --verify) bad "journal uses ${total} MB, over the ${CAP_MB} MB cap";;
                         *)        chg "journal uses ${total} MB; will rotate and vacuum to ${CAP_MB} MB";; esac; fi
    [ "$active" = active ] && ok "journald active" || bad "journald is $active"

    [ "$MODE" = --apply ] || continue
    out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$ip" "sudo -n bash -s" <<REMOTE 2>&1
set -u
D=$DROPIN
MID=\$(cat /etc/machine-id)
cat > \$D.new <<'EOF'
[Journal]
# post-cutover #104 (journald-cap-orchestrate.sh): the main journald.conf of
# this VM lineage sets SystemMaxFileSize=1G, and journald raises SystemMaxUse
# to at least twice the file size -- so a drop-in that only said
# SystemMaxUse=256M capped nothing (2 GB of journal on vm69). Every size here.
SystemMaxUse=$WANT_USE
SystemMaxFileSize=$WANT_FILE
SystemMaxFiles=$WANT_FILES
EOF
if cmp -s \$D.new \$D; then rm -f \$D.new; echo "drop-in already right"
else [ -f \$D ] && cp -a \$D \$D.bak-\$(date +%F); mv \$D.new \$D; echo "drop-in written (old copy: \$D.bak-\$(date +%F))"; fi
for d in /var/log/journal/*/; do id=\$(basename "\$d"); [ "\$id" = "\$MID" ] && continue; [ "\$id" = remote ] && continue
    echo "removed stale \$(du -sm "\$d" | cut -f1) MB /var/log/journal/\$id"; rm -rf "\$d"; done
systemctl restart systemd-journald && echo "journald restarted"
journalctl --rotate 2>&1
journalctl --vacuum-size=$WANT_USE 2>&1 | tail -1
echo "journal now \$(du -sm /var/log/journal | cut -f1) MB; \$(journalctl --disk-usage)"
systemctl is-active systemd-journald
REMOTE
    ) && printf '%s\n' "$out" | sed 's/^/      /' || { printf '%s\n' "$out" | sed 's/^/      /'; bad "apply failed on vm$n"; }
done

echo
case "$MODE" in
    --verify)  [ $FAILS -eq 0 ] && echo "${G}verify: clean${O}" || echo "${R}verify: $FAILS finding(s)${O}"; exit $((FAILS>0)) ;;
    --dry-run) echo "dry run: $CHANGES change(s) would be made, $FAILS problem(s) seen; nothing changed" ;;
    --apply)   echo "applied; now: $0 --verify" ;;
esac
