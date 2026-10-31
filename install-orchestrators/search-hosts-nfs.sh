#!/bin/bash
# ============================================================================
# Give the search hosts (prod-homelabvm70/71/72) READ-ONLY access to the mail
# and drive stores, and mount them.
#
#   ./search-hosts-nfs.sh --dry-run   # show the exact zfs/fstab changes
#   ./search-hosts-nfs.sh             # apply, then verify
#   ./search-hosts-nfs.sh --verify    # change nothing, just check
#
# WHY READ-ONLY IS SET ON THE SERVER, NOT THE CLIENT. A client-side `-o ro` is
# a promise the client makes to itself; root on that client can remount rw. The
# NFS server's own `ro=` cannot be overridden from the client, so that is where
# the restriction belongs. The fstab entries below ALSO say `ro` -- belt and
# braces, with the server as the belt.
#
# WHY THIS TOUCHES A LIVE PRODUCTION EXPORT, AND HOW IT IS MADE SAFE.
# /vault/dovecot_vmail_mig is the live mail store for prod-homelabvm62/63/64 and
# /vault/nfsexports/mailmasker-drive_mig is live drive storage for 65/66/67.
# `zfs set sharenfs` re-exports the dataset, so this is not a no-op for them.
# Three guards:
#   1. The script refuses to run unless the CURRENT sharenfs value is exactly
#      what it expects. If someone has changed these exports since this was
#      written, it stops rather than overwriting their work.
#   2. The new value keeps every existing `rw=` host and every existing option
#      byte-identical; the only edit is an added `ro=` clause.
#   3. After applying, it proves the live clients still work -- a real write on
#      a dovecot node and on a drive node, not just a mount check.
#
# WHY NOT root_squash FOR THE NEW HOSTS. The plan asked for it, and ZFS's
# sharenfs syntax cannot express it: options in that comma-separated string are
# GLOBAL to the dataset, not per host-group, so the only way to add root_squash
# for .214-.216 would be to also impose it on the dovecot and drive nodes, which
# rely on no_root_squash. Switching these datasets to /etc/exports to get
# per-group options is a bigger change to how the NAS manages them than this
# task warrants. What that costs us: root on a search host can read every
# mailbox. It could anyway -- that is what indexing all mail requires -- so the
# meaningful restriction is `ro=`, which is in place. Written down because the
# difference between "decided against" and "forgotten" matters later.
# ============================================================================
set -uo pipefail

NAS=10.20.0.105
SEARCH_STORAGE="10.45.2.214 10.45.2.215 10.45.2.216"
SEARCH_MGMT="10.20.2.214 10.20.2.215 10.20.2.216"
RO_LIST="10.45.2.214:10.45.2.215:10.45.2.216"

MAIL_DS=vault/dovecot_vmail_mig
DRIVE_DS=vault/nfsexports/mailmasker-drive_mig

# Exact expected current values. A mismatch stops the run (guard 1).
MAIL_WAS="rw=10.45.2.206:10.45.2.207:10.45.2.208,no_subtree_check,no_root_squash"
DRIVE_WAS="rw=10.45.2.209:10.45.2.210:10.45.2.211,no_subtree_check,no_root_squash,async"
MAIL_NEW="rw=10.45.2.206:10.45.2.207:10.45.2.208,ro=${RO_LIST},no_subtree_check,no_root_squash"
DRIVE_NEW="rw=10.45.2.209:10.45.2.210:10.45.2.211,ro=${RO_LIST},no_subtree_check,no_root_squash,async"

# Mount points on the search hosts. Mail is NFSv3 and drive NFSv4 on the owning
# nodes; matched here so behaviour is the same store, same protocol.
MAIL_SRC="10.45.0.105:/vault/dovecot_vmail_mig"
DRIVE_SRC="10.45.0.105:/vault/nfsexports/mailmasker-drive_mig"
MAIL_MNT=/srv/mail-ro
DRIVE_MNT=/srv/drive-ro
MAIL_FSTAB="$MAIL_SRC  $MAIL_MNT  nfs  ro,hard,noatime,nodiratime,nosuid,nodev,vers=3,rsize=1048576,wsize=1048576,timeo=600,retrans=5,_netdev  0  0"
DRIVE_FSTAB="$DRIVE_SRC  $DRIVE_MNT  nfs4  ro,hard,noatime,nosuid,nodev,timeo=600,retrans=2,_netdev  0  0"

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: search-hosts-nfs.sh [--dry-run] [--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
die(){  echo; echo "${R}$*${O}"; exit 1; }
RC=0

# -n: an ssh inside a `while read`/`for` loop eats the loop's stdin otherwise.
nas(){ ssh -n -o ConnectTimeout=10 "$NAS" "$@"; }
on(){  ssh -n -o ConnectTimeout=10 "$1" "${@:2}"; }

# ------------------------------------------------------------------ live check
# Used before AND after the export change: these are live production stores and
# "still mounted" is not the same as "still writable".
live_clients_ok(){
    local when="$1" node probe
    for node in 10.20.2.206 10.20.2.209; do
        case "$node" in
            10.20.2.206) probe=/var/mail/vhosts/.rw-probe-$$ ;;
            *)           probe=/var/lib/homelab/drive-storage/.rw-probe-$$ ;;
        esac
        if on "$node" "sudo touch $probe && sudo rm -f $probe" >/dev/null 2>&1; then
            ok "$when: $node can still WRITE its store"
        else
            bad "$when: $node can no longer write its store"
        fi
    done
    for svc in dovecot; do
        local s; s=$(on 10.20.2.206 "systemctl is-active $svc" 2>/dev/null)
        [ "$s" = active ] && ok "$when: dovecot still active on vm62" || bad "$when: dovecot is '$s' on vm62"
    done
}

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ]; then
    step "exports on the NAS"
    for ds in "$MAIL_DS" "$DRIVE_DS"; do
        v=$(nas "sudo zfs get -H -o value sharenfs $ds" 2>/dev/null)
        printf '%s' "$v" | grep -q "ro=${RO_LIST}" \
            && ok "$ds has ro= for the search hosts" \
            || bad "$ds has no ro= for the search hosts: $v"
    done
    for ip in $SEARCH_STORAGE; do
        n=$(nas "sudo exportfs -v 2>/dev/null | grep -c '$ip'" 2>/dev/null)
        [ "${n:-0}" -ge 2 ] && ok "$ip appears in $n export entries" || bad "$ip appears in ${n:-0} export entries (want 2)"
    done

    step "mounts on the search hosts"
    for ip in $SEARCH_MGMT; do
        for m in "$MAIL_MNT" "$DRIVE_MNT"; do
            if on "$ip" "findmnt -rn -o TARGET,OPTIONS $m" >/dev/null 2>&1; then
                opts=$(on "$ip" "findmnt -rn -o OPTIONS $m" 2>/dev/null)
                case "$opts" in
                    ro,*|*,ro|*,ro,*) ok "$ip $m mounted ro" ;;
                    *) bad "$ip $m mounted but NOT ro: $opts" ;;
                esac
            else
                bad "$ip $m is not mounted"
            fi
        done
        # The point of the whole exercise: can it actually read the data?
        c=$(on "$ip" "sudo ls -1 $MAIL_MNT 2>/dev/null | wc -l" 2>/dev/null)
        [ "${c:-0}" -ge 1 ] && ok "$ip can read $MAIL_MNT ($c domain dir(s))" || bad "$ip cannot read $MAIL_MNT"
        c=$(on "$ip" "sudo ls -1 $DRIVE_MNT 2>/dev/null | wc -l" 2>/dev/null)
        [ "${c:-0}" -ge 1 ] && ok "$ip can read $DRIVE_MNT ($c entries)" || bad "$ip cannot read $DRIVE_MNT"
        # And is read-only actually ENFORCED, by the server?
        if on "$ip" "sudo touch $MAIL_MNT/.wr-probe-$$" >/dev/null 2>&1; then
            on "$ip" "sudo rm -f $MAIL_MNT/.wr-probe-$$" >/dev/null 2>&1
            bad "$ip WROTE to $MAIL_MNT -- read-only is not being enforced"
        else
            ok "$ip write to $MAIL_MNT refused"
        fi
    done

    step "the live stores are unaffected"
    live_clients_ok "now"

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}search hosts have read-only access to mail and drive; live stores unaffected.${O}" \
                  || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"
for ip in $SEARCH_MGMT; do
    timeout 5 bash -c "echo > /dev/tcp/${ip}/22" 2>/dev/null \
        && ok "$ip answers on :22" || die "$ip does not answer on :22 -- finish Phase 0a first"
done

MAIL_CUR=$(nas "sudo zfs get -H -o value sharenfs $MAIL_DS" 2>/dev/null)
DRIVE_CUR=$(nas "sudo zfs get -H -o value sharenfs $DRIVE_DS" 2>/dev/null)
[ -n "$MAIL_CUR" ] || die "could not read sharenfs from $NAS"

MAIL_TODO=1; DRIVE_TODO=1
if [ "$MAIL_CUR" = "$MAIL_NEW" ];  then MAIL_TODO=0;  ok "$MAIL_DS already granted (idempotent, nothing to do)";  fi
if [ "$DRIVE_CUR" = "$DRIVE_NEW" ]; then DRIVE_TODO=0; ok "$DRIVE_DS already granted (idempotent, nothing to do)"; fi

# Guard 1: refuse to overwrite an export that is not what this script expects.
if [ "$MAIL_TODO" = 1 ] && [ "$MAIL_CUR" != "$MAIL_WAS" ]; then
    die "$MAIL_DS sharenfs is not what this script expects.
  expected: $MAIL_WAS
  found:    $MAIL_CUR
Refusing to overwrite it. Someone changed this export; reconcile by hand."
fi
if [ "$DRIVE_TODO" = 1 ] && [ "$DRIVE_CUR" != "$DRIVE_WAS" ]; then
    die "$DRIVE_DS sharenfs is not what this script expects.
  expected: $DRIVE_WAS
  found:    $DRIVE_CUR
Refusing to overwrite it. Someone changed this export; reconcile by hand."
fi
[ "$MAIL_TODO$DRIVE_TODO" = "00" ] || ok "current export values are exactly as expected"

step "the live stores work BEFORE the change"
live_clients_ok "before"
[ "$RC" = 0 ] || die "a live store is already unhealthy -- not touching the exports"

# ------------------------------------------------------------------ dry run
if [ "$DRY" = 1 ]; then
    step "would change, on $NAS"
    echo "  $MAIL_DS"
    echo "    from: $MAIL_CUR"
    echo "    to:   $MAIL_NEW"
    echo "  $DRIVE_DS"
    echo "    from: $DRIVE_CUR"
    echo "    to:   $DRIVE_NEW"
    note "the only edit is the added ro= clause; every rw= host and option is unchanged"
    step "would add, on each of $SEARCH_MGMT"
    echo "    $MAIL_FSTAB"
    echo "    $DRIVE_FSTAB"
    echo
    note "dry run: nothing changed."
    exit 0
fi

# ------------------------------------------------------------------- apply
step "grant read-only access on the NAS"
if [ "$MAIL_TODO" = 1 ]; then
    nas "sudo zfs set sharenfs='$MAIL_NEW' $MAIL_DS" >/dev/null 2>&1 \
        && ok "$MAIL_DS granted" || bad "$MAIL_DS: zfs set failed"
fi
if [ "$DRIVE_TODO" = 1 ]; then
    nas "sudo zfs set sharenfs='$DRIVE_NEW' $DRIVE_DS" >/dev/null 2>&1 \
        && ok "$DRIVE_DS granted" || bad "$DRIVE_DS: zfs set failed"
fi
[ "$RC" = 0 ] || die "export change failed; live clients checked below anyway"

step "the live stores still work AFTER the change"
live_clients_ok "after"

step "mount them on the search hosts"
for ip in $SEARCH_MGMT; do
    out=$(on "$ip" "
        set -e
        sudo mkdir -p $MAIL_MNT $DRIVE_MNT
        # Idempotent: only append if this source is not already in fstab.
        grep -q '$MAIL_MNT'  /etc/fstab || echo '$MAIL_FSTAB'  | sudo tee -a /etc/fstab >/dev/null
        grep -q '$DRIVE_MNT' /etc/fstab || echo '$DRIVE_FSTAB' | sudo tee -a /etc/fstab >/dev/null
        sudo systemctl daemon-reload
        mountpoint -q $MAIL_MNT  || sudo mount $MAIL_MNT
        mountpoint -q $DRIVE_MNT || sudo mount $DRIVE_MNT
        echo mounted
    " 2>&1)
    case "$out" in
        *mounted*) ok "$ip: $MAIL_MNT and $DRIVE_MNT mounted" ;;
        *) bad "$ip: mount failed -- $out" ;;
    esac
done

step "verify"
exec "$0" --verify
