#!/bin/bash
# ============================================================================
# The NFS mounts of the storage tiers, and what binds to them -- RUN ON THE
# ADMIN WORKSTATION. Post-cutover #41 F, G, H.
#
#   ./nfs-mounts-orchestrate.sh --dry-run      # what each host has vs what it should
#   ./nfs-mounts-orchestrate.sh --apply        # bring every host to it, one at a time
#   ./nfs-mounts-orchestrate.sh --verify       # the invariants, nothing changed
#   NODES="64 67" ./nfs-mounts-orchestrate.sh --apply    # only these
#
# WHAT IT OWNS, per host (the table below is the fleet fact):
#   - the fstab line of each NFS store: `hard` (a mail store waits, never
#     errors) AND `nofail` (remote-fs.target stops waiting for it, so a late
#     NAS no longer blocks non-root SSH through systemd-user-sessions, and
#     the mount's own foreground retry bounds the job); the line is replaced
#     in place, keyed on the mountpoint, after a dated backup of fstab
#   - a drop-in beside each service that needs the store:
#     /etc/systemd/system/<svc>.d/50-homelab-nfs-bind.conf with
#     BindsTo=<mount unit> After=<mount unit>. The package's own unit already
#     carries RequiresMountsFor= (the universal half: wait for the mount,
#     refuse a bare directory); BindsTo is the host's half, because a BindsTo
#     on a mount unit that does not exist would break the service on any host
#     without the mount -- and it is what also STOPS the service when the
#     mount goes away (Requires= does not follow an unexpected stop)
#   - /etc/homelab/boot-mounts.d/<tier>.list for homelab-mount-retry
#     (homelab-common >= 0.1.38): `<mountpoint> <mount unit> <services>`
#   - on the search hosts, the two stale lines cloned from vm69
#     (/srv/metrics and the bind of its prometheus subdirectory) are removed
#   then `systemctl daemon-reload`. Nothing is unmounted or restarted: a
#   mounted store stays mounted; the new ordering is for the next boot and
#   the next start.
# ============================================================================
set -u
MODE="${1:---dry-run}"
case "$MODE" in --dry-run|--apply|--verify) ;; *) echo "usage: $0 --dry-run|--apply|--verify"; exit 1 ;; esac
NAS=10.45.0.105
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; O=$'\e[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; FAILS=$((FAILS+1)); }
chg(){ echo "  ${Y}>>${O}   $*"; CHANGES=$((CHANGES+1)); }
FAILS=0; CHANGES=0
ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rssh(){ ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" "${@:2}" 2>/dev/null; }

# tier name | nodes | mountpoint | mount unit | fstab line | services (space-separated) | stale mountpoints to drop
TIERS=(
"dovecot|62 63 64|/var/mail/vhosts|var-mail-vhosts.mount|$NAS:/vault/dovecot_vmail_mig  /var/mail/vhosts  nfs  rw,hard,noatime,nodiratime,vers=3,rsize=1048576,wsize=1048576,timeo=600,retrans=5,_netdev,nofail  0  0|dovecot.service|"
"drive|65 66 67|/var/lib/homelab/drive-storage|var-lib-homelab-drive\\x2dstorage.mount|$NAS:/vault/nfsexports/mailmasker-drive_mig /var/lib/homelab/drive-storage nfs4 rw,hard,timeo=600,retrans=2,_netdev,nofail 0 0|homelab-drive.service|"
"search-mail|70 71 72|/srv/mail-ro|srv-mail\\x2dro.mount|$NAS:/vault/dovecot_vmail_mig  /srv/mail-ro  nfs  ro,hard,noatime,nodiratime,nosuid,nodev,vers=3,rsize=1048576,wsize=1048576,timeo=600,retrans=5,_netdev,nofail  0  0|homelab-search.service homelab-search-indexer.service|/srv/metrics /var/lib/prometheus/metrics2"
"search-drive|70 71 72|/srv/drive-ro|srv-drive\\x2dro.mount|$NAS:/vault/nfsexports/mailmasker-drive_mig  /srv/drive-ro  nfs4  ro,hard,noatime,nosuid,nodev,timeo=600,retrans=2,_netdev,nofail  0  0|homelab-search.service homelab-search-indexer.service|"
)

# The hosts, each with every tier line that applies to it.
declare -A HOST_TIERS
for t in "${TIERS[@]}"; do IFS='|' read -r name nodes mp unit line svcs stale <<<"$t"; for n in $nodes; do HOST_TIERS[$n]="${HOST_TIERS[$n]:-}$name"$'\n'; done; done
HOSTS=$(printf '%s\n' "${!HOST_TIERS[@]}" | sort)
[ -n "${NODES:-}" ] && HOSTS="$NODES"

tier(){ for t in "${TIERS[@]}"; do case "$t" in "$1|"*) echo "$t"; return;; esac; done; }

for n in $HOSTS; do
    ip=$(ip_of "$n")
    echo "=== prod-homelabvm$n ($ip) ==="
    fstab=$(rssh "$ip" "cat /etc/fstab") || { bad "unreachable"; continue; }
    # every tier line on this host -> the plan for this host
    declare -A WANT_LINE=() WANT_UNIT=() WANT_SVCS=() ; STALE=""; MPS=""
    for name in ${HOST_TIERS[$n]}; do
        IFS='|' read -r _ _ mp unit line svcs stale <<<"$(tier "$name")"
        WANT_LINE[$mp]="$line"; WANT_UNIT[$mp]="$unit"; WANT_SVCS[$mp]="$svcs"; MPS="$MPS $mp"; STALE="$STALE $stale"
    done
    # --- the fstab ------------------------------------------------------------
    for mp in $MPS; do
        have=$(echo "$fstab" | awk -v m="$mp" '$1 !~ /^#/ && $2 == m {print; exit}')
        want="${WANT_LINE[$mp]}"
        if [ "$(echo "$have" | tr -s ' \t' ' ')" = "$(echo "$want" | tr -s ' \t' ' ')" ]; then ok "fstab: $mp line is current (hard, nofail)"
        else chg "fstab: $mp line: $(echo "$have" | tr -s ' \t' ' ' | cut -c1-60)… -> …,_netdev,nofail"; fi
    done
    for mp in $STALE; do
        if echo "$fstab" | awk -v m="$mp" '$1 !~ /^#/ && $2 == m {found=1} END {exit !found}'; then chg "fstab: stale line for $mp to remove"; else ok "fstab: no stale line for $mp"; fi
    done
    # --- the drop-ins and the lists ---------------------------------------
    declare -A WANT_DROPIN=()
    for mp in $MPS; do for svc in ${WANT_SVCS[$mp]}; do WANT_DROPIN[$svc]="${WANT_DROPIN[$svc]:-}${WANT_UNIT[$mp]} "; done; done
    for svc in "${!WANT_DROPIN[@]}"; do
        units="${WANT_DROPIN[$svc]% }"
        want=$(printf '# Written by nfs-mounts-orchestrate.sh (post-cutover #41 F): this host mounts the\n# store(s) below; the service follows them -- it waits for them, refuses a bare\n# directory, and stops when they go away. RequiresMountsFor= is in the package unit.\n[Unit]\nBindsTo=%s\nAfter=%s\n' "$units" "$units")
        have=$(rssh "$ip" "cat /etc/systemd/system/$svc.d/50-homelab-nfs-bind.conf 2>/dev/null")
        [ "$have" = "$want" ] && ok "$svc: BindsTo drop-in current ($units)" || chg "$svc: BindsTo drop-in to write ($units)"
    done
    listname="${HOST_TIERS[$n]%%$'\n'*}"; listname="${listname%%-*}"
    wantlist=""; for mp in $MPS; do wantlist="$wantlist$mp ${WANT_UNIT[$mp]} ${WANT_SVCS[$mp]}"$'\n'; done
    havelist=$(rssh "$ip" "cat /etc/homelab/boot-mounts.d/$listname.list 2>/dev/null")
    [ "$havelist" = "${wantlist%$'\n'}" ] && ok "boot-mounts.d/$listname.list current" || chg "boot-mounts.d/$listname.list to write"
    # --- apply ------------------------------------------------------------
    if [ "$MODE" = "--apply" ] && [ "$CHANGES" -gt 0 ]; then
        script="set -e; sudo cp -a /etc/fstab /etc/fstab.bak-\$(date +%Y%m%d-%H%M%S); sudo install -d /etc/homelab/boot-mounts.d;"
        # rewrite fstab: replace the line of each wanted mountpoint, drop the stale ones, keep everything else
        pl='my %want = ('; for mp in $MPS; do pl="$pl q{$mp} => q{${WANT_LINE[$mp]}},"; done; pl="$pl); my %drop = map { \$_ => 1 } qw($STALE); my %done;"
        pl="$pl while (<STDIN>) { my @f = split; if (@f > 1 && \$f[0] !~ /^#/) { next if \$drop{\$f[1]}; if (\$want{\$f[1]}) { print \$want{\$f[1]}, qq{\\n} unless \$done{\$f[1]}++; next } } print } for (sort keys %want) { print \$want{\$_}, qq{\\n} unless \$done{\$_} }"
        script="$script sudo perl -e '$pl' < /etc/fstab > /tmp/fstab.new && sudo install -m 644 /tmp/fstab.new /etc/fstab && rm -f /tmp/fstab.new;"
        for svc in "${!WANT_DROPIN[@]}"; do units="${WANT_DROPIN[$svc]% }"
            script="$script sudo install -d /etc/systemd/system/$svc.d; printf '# Written by nfs-mounts-orchestrate.sh (post-cutover #41 F): this host mounts the\\n# store(s) below; the service follows them -- it waits for them, refuses a bare\\n# directory, and stops when they go away. RequiresMountsFor= is in the package unit.\\n[Unit]\\nBindsTo=%s\\nAfter=%s\\n' '$units' '$units' | sudo tee /etc/systemd/system/$svc.d/50-homelab-nfs-bind.conf >/dev/null;"
        done
        script="$script printf '%s' '$wantlist' | sudo tee /etc/homelab/boot-mounts.d/$listname.list >/dev/null; sudo systemctl daemon-reload; echo applied"
        out=$(rssh "$ip" "$script"); case "$out" in *applied*) ok "applied, systemd reloaded" ;; *) bad "apply failed: $out" ;; esac
        CHANGES=0
    fi
    # --- verify (always) --------------------------------------------------
    for mp in $MPS; do
        st=$(rssh "$ip" "mountpoint -q '$mp' && echo mounted || echo NOT-mounted; findmnt -no OPTIONS '$mp' | tr ',' '\n' | grep -c -x hard")
        case "$st" in mounted*1) ok "$mp mounted, hard" ;; *) bad "$mp: $(echo $st)" ;; esac
    done
    for svc in "${!WANT_DROPIN[@]}"; do
        units="${WANT_DROPIN[$svc]% }"
        # systemctl quotes a unit name that holds a backslash and doubles the
        # backslash ("var-lib-homelab-drive\\x2dstorage.mount"): undo both.
        shown=$(rssh "$ip" "systemctl show -p BindsTo -p RequiresMountsFor -p ActiveState '$svc' | paste -sd' ' -" | sed 's/\\\\/\\/g; s/"//g')
        miss=""; for u in $units; do case "$shown" in *"BindsTo="*"$u"*) ;; *) miss="$miss $u";; esac; done
        [ -z "$miss" ] && ok "$svc: systemd binds it to $units" || bad "$svc: BindsTo missing$miss (daemon-reload? apply?)"
        # systemd folds WorkingDirectory into RequiresMountsFor, so look for the
        # store's own path, not for the property being non-empty.
        rmiss=""; for mp in $MPS; do case " ${WANT_SVCS[$mp]} " in *" $svc "*) case "$shown" in *"$mp"*) ;; *) rmiss="$rmiss $mp";; esac;; esac; done
        [ -z "$rmiss" ] && ok "$svc: RequiresMountsFor covers its store(s) (package unit)" || bad "$svc: RequiresMountsFor lacks$rmiss -- the package that ships it is not installed yet"
        case "$shown" in *"ActiveState=active"*) ok "$svc active" ;; *) bad "$svc: $(echo "$shown" | grep -o 'ActiveState=[a-z]*')" ;; esac
    done
    tm=$(rssh "$ip" "systemctl is-enabled homelab-mount-retry.timer 2>/dev/null; systemctl is-active homelab-mount-retry.timer 2>/dev/null" | paste -sd' ' -)
    [ "$tm" = "enabled active" ] && ok "homelab-mount-retry.timer enabled and active" || bad "homelab-mount-retry.timer: ${tm:-absent} (homelab-common >= 0.1.38?)"
    unset WANT_LINE WANT_UNIT WANT_SVCS WANT_DROPIN
done
echo "=== result ==="
if [ "$MODE" = "--dry-run" ]; then echo "  dry run: $CHANGES change(s) would be made; $FAILS invariant(s) currently failing."
else [ "$FAILS" = 0 ] && echo "  every store mounted hard+nofail, every service bound to its mounts, the retry timer armed." || echo "  $FAILS problem(s) -- see FAIL lines."; fi
exit $(( FAILS > 0 ))
