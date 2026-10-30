#!/bin/bash
# ============================================================================
# Create (or reconcile) the pve2 backup jobs, split by failover-set position.
#
#   ./pve-backup-jobs.sh              # create/reconcile, then verify
#   ./pve-backup-jobs.sh --dry-run    # say what it would change
#   ./pve-backup-jobs.sh --verify     # change nothing, just check coverage
#
# WHY THE JOBS ARE SPLIT THIS WAY.
#
# The fleet is 17 failover sets of three, plus two singletons. One weekly job
# per POSITION means a backup window only ever touches one member of any set:
# position 1 on Monday, 2 on Tuesday, 3 on Wednesday. Back all three up at once
# and a slow night degrades every replica of a service simultaneously, which is
# the one thing having three of them was supposed to prevent.
#
# The positions are by VMID, deliberately, NOT by "whichever node is currently
# active". The edge trio is manual one-at-a-time, so 401 and 402 are normally
# stopped -- a stopped container still backs up fine, and keying on VMID means
# an edge rotation cannot shuffle a node between jobs.
#
# A FOURTH JOB exists for the bare spares (445, 447-461, 468): monthly, keeping
# two. They hold nothing today (zero homelab packages, zero service manifests),
# so weekly copies of empty machines would be ~12GB/week of nothing -- but
# leaving them out entirely means a spare that gets provisioned is backed up by
# nobody. Monthly is the compromise, and --verify below is what catches the
# handover.
#
# WHY "Thu *-*-01..07" AND NOT "*-*-01" for the monthly job. PVE parses its own
# calendar spec; "*-*-01 03:13" fires on the 1st whatever weekday that is, which
# drifts (Sun, Tue, Fri, Mon...) and periodically lands on a day one of the
# weekly jobs already owns. "Thu *-*-01..07" is the first Thursday: monthly, and
# never on a Mon/Tue/Wed. Both were checked against PVE::CalendarEvent before
# being written down here.
#
# WHAT WAS ALREADY THERE. pve2 already had two jobs, and neither touches a
# fleet guest, so these four neither duplicate them nor fight them over prune:
#   backup-32959789-1075  "Weekly backup of all VMs"      sun 01:00, enabled,
#                         keep-last=5, 11 LEGACY VMs (plex, administrator,
#                         aptcacher, ntp + 7 powered-off decommissioned hosts).
#   backup-f08f72f4-43f7  "Daily backup of Containers"    01:43, DISABLED,
#                         mode stop, keep-last=8, 5 legacy CTs incl. ns03.
# Because that second job is disabled, ns03 -- which CLAUDE.md calls permanent --
# currently has no working backup, and nor do forwarder01, vpn01 and mirrors.
# That is reported, not silently fixed: these four jobs are fleet-only by
# request.
#
# NOTIFICATIONS ALREADY WORK -- do not "fix" the relayhost. An empty postfix
# relayhost on pve2 looks like mail goes nowhere, and that is the wrong
# inference: postfix with no relayhost still delivers straight to MX. The MX for
# forge.name is mail.forge.name -> 23.116.91.66, the fleet's own edge, which pve2
# reaches on :25. Proven, not assumed:
#   pvesh create /cluster/notifications/targets/mail-to-root/test
#   -> postfix/smtp: to=<gardner@forge.name>, relay=mail.forge.name[23.116.91.66]:25,
#      dsn=2.0.0, status=sent (250 2.0.0 Ok)
# root@pam's address is set (gardner@forge.name) and datacenter email_from is
# pve2@forge.name, so a failed job does reach a real mailbox. Note there is no
# /var/log/mail.log on this host -- delivery is only in the journal, so use
# `journalctl -t postfix/smtp`, and an absent mail.log is not evidence of
# anything.
# ============================================================================
set -uo pipefail

PVE=10.20.1.8
STORAGE=nfs-backup
RET_SETS="keep-last=3,keep-weekly=4,keep-monthly=3"
RET_SPARES="keep-last=2"

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: pve-backup-jobs.sh [--dry-run] [--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
# -n is load-bearing: without it, an ssh inside a `while read` loop eats the
# loop's stdin and the loop quietly stops after the first iteration.
pve(){  ssh -n -o ConnectTimeout=10 "$PVE" "$@"; }
RC=0

# id | schedule | comment | prune-backups | vmid list
JOBS=(
"fleet-pos1|mon 03:13|Fleet position 1 - first of each failover set, plus singletons|$RET_SETS|400,403,406,409,412,415,418,421,424,427,430,433,436,439,442,446,462,465,469"
"fleet-pos2|tue 03:13|Fleet position 2 - second of each failover set|$RET_SETS|401,404,407,410,413,416,419,422,425,428,431,434,437,440,443,463,466"
"fleet-pos3|wed 03:13|Fleet position 3 - third of each failover set|$RET_SETS|402,405,408,411,414,417,420,423,426,429,432,435,438,441,444,464,467"
"fleet-spares|Thu *-*-01..07 03:13|Bare spares - monthly, first Thursday|$RET_SPARES|445,447,448,449,450,451,452,453,454,455,456,457,458,459,460,461,468"
)

# --------------------------------------------------------------- create/update
if [ "$VERIFY_ONLY" = 0 ]; then
    step "backup jobs on pve2"

    EXISTING=$(pve "sudo pvesh get /cluster/backup --output-format json" 2>/dev/null)
    if [ -z "$EXISTING" ]; then
        bad "could not read /cluster/backup from pve2 ($PVE)"
        exit 1
    fi

    for spec in "${JOBS[@]}"; do
        IFS='|' read -r id sched comment prune vmids <<<"$spec"

        # Present already? Reconcile rather than fail, so this is re-runnable.
        if printf '%s' "$EXISTING" | grep -q "\"id\":\"$id\""; then
            verb=set; path="/cluster/backup/$id"
        else
            verb=create; path="/cluster/backup"
        fi

        if [ "$DRY" = 1 ]; then
            echo "  would $verb $id  ($sched)  $(echo "$vmids" | tr ',' '\n' | grep -c .) guest(s)"
            continue
        fi

        args=(--schedule "$sched" --comment "$comment" --storage "$STORAGE"
              --mode snapshot --compress zstd --enabled 1 --fleecing 0
              --notification-mode notification-system
              --notes-template "{{guestname}}" --prune-backups "$prune"
              --vmid "$vmids")
        [ "$verb" = create ] && args+=(--id "$id")

        if out=$(pve "sudo pvesh $verb $path $(printf '%q ' "${args[@]}")" 2>&1); then
            ok "$verb $id -- $sched -- $(echo "$vmids" | tr ',' '\n' | grep -c .) guest(s)"
        else
            bad "$verb $id failed:"
            printf '%s\n' "$out" | sed 's/^/        /' | head -5
        fi
    done
fi

# --------------------------------------------------------------------- verify
step "what pve2 now has"
LIVE=$(pve "sudo pvesh get /cluster/backup --output-format json" 2>/dev/null)
[ -z "$LIVE" ] && { bad "could not read /cluster/backup back"; exit 1; }

# Pull (id, schedule, vmid) out of the API's own answer rather than trusting the
# table above -- the point of reading it back is to see what is really there.
parse(){ printf '%s' "$LIVE" | perl -MMojo::JSON=decode_json -e '
    local $/; my $j = decode_json(<STDIN>);
    for my $job (@{ref($j) eq "ARRAY" ? $j : []}) {
        printf("%s\t%s\t%s\t%s\n", $job->{id} // "?", $job->{schedule} // "?",
               (defined $job->{enabled} && !$job->{enabled}) ? "disabled" : "enabled",
               $job->{vmid} // "");
    }' 2>/dev/null; }

parse | while IFS=$'\t' read -r id sched en vmids; do
    printf "  %-22s %-22s %-9s %s guest(s)\n" "$id" "$sched" "$en" \
           "$(echo "$vmids" | tr ',' '\n' | grep -c .)"
done

step "no two jobs may share a guest, and none may share a day"
ALL_VMIDS=$(parse | cut -f4 | tr ',' '\n' | grep -E '^[0-9]+$' | sort)
DUPE=$(printf '%s\n' "$ALL_VMIDS" | uniq -d | paste -sd, -)
[ -z "$DUPE" ] && ok "every guest appears in exactly one job" \
               || bad "guest(s) in more than one job: $DUPE"

# Only enabled jobs can collide. A schedule whose first field is a time
# rather than a weekday has no day restriction at all -- it is DAILY, so it
# overlaps every other job, which a naive "same first field" test misses.
DAYS=$(parse | awk -F'\t' '$3 == "enabled" {print tolower($2)}' \
        | awk '{ print ($1 ~ /^[0-9]+:/) ? "EVERY-DAY" : $1 }' | sort)
DDUP=$(printf '%s\n' "$DAYS" | grep -v '^$' | uniq -d | paste -sd, -)
if [ -z "$DDUP" ]; then
    ok "no two enabled jobs fire on the same day"
elif [ "$DDUP" = "EVERY-DAY" ]; then
    warn "more than one enabled job runs daily -- they will overlap"
else
    warn "enabled jobs share a day ($DDUP) -- they will overlap"
fi
printf '%s\n' "$DAYS" | grep -q '^EVERY-DAY$' \
    && warn "an enabled job has no weekday (runs daily), so it can land on any other job's day"

step "next firing of each job, per PVE's own calendar parser"
parse | cut -f1,2 | while IFS=$'\t' read -r id sched; do
    nxt=$(pve "perl -MPVE::CalendarEvent -e '
        my \$e = PVE::CalendarEvent::parse_calendar_event(\"$sched\");
        my \$t = PVE::CalendarEvent::compute_next_event(\$e, time());
        print scalar(localtime(\$t));'" 2>/dev/null)
    printf "  %-14s %s\n" "$id" "${nxt:-UNPARSEABLE}"
    [ -z "$nxt" ] && bad "$id has a schedule PVE cannot parse: $sched"
done

step "coverage against the live fleet"
echo "  ${D}A node that declares a service manifest belongs in a position job; a${O}"
echo "  ${D}bare one belongs in fleet-spares. This is what catches a spare that${O}"
echo "  ${D}got provisioned but never moved out of the monthly job.${O}"

POS=$(parse | grep -E '^fleet-pos' | cut -f4 | tr ',' '\n' | grep -E '^[0-9]+$' | sort -u)
SPR=$(parse | grep -E '^fleet-spares' | cut -f4 | tr ',' '\n' | grep -E '^[0-9]+$' | sort -u)

MISPLACED=0; UNCHECKED=""
for n in $(seq 0 69); do
    ctid=$((400 + n)); ip=10.20.2.$((144 + n))
    printf '%s\n' "$POS $SPR" | grep -qw "$ctid" || continue

    svc=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$ip" \
            'ls /etc/homelab/services/ 2>/dev/null | grep -c .' 2>/dev/null)
    if [ -z "$svc" ]; then
        UNCHECKED="$UNCHECKED $ctid"
        continue
    fi

    if [ "$svc" -gt 0 ]; then
        printf '%s\n' "$POS" | grep -qw "$ctid" || {
            bad "$ctid declares $svc service manifest(s) but sits in the MONTHLY spares job"
            MISPLACED=1; }
    else
        printf '%s\n' "$SPR" | grep -qw "$ctid" || {
            warn "$ctid declares no service manifest but is in a weekly position job"
            MISPLACED=1; }
    fi
done

[ "$MISPLACED" = 0 ] && ok "every reachable guest is in the right job for what it runs"
[ -n "$UNCHECKED" ] && warn "not reachable, so not checked (normal for the parked edge standbys):$UNCHECKED"

step "result"
if [ "$RC" = 0 ]; then
    echo "  ${G}backup jobs are in place and consistent.${O}"
    echo
    echo "  ${D}Job mail reaches root@pam's address by direct MX delivery; verify${O}"
    echo "  ${D}with: pvesh create /cluster/notifications/targets/mail-to-root/test${O}"
else
    echo "  ${R}something is wrong -- see the failures above.${O}"
fi
exit $RC
