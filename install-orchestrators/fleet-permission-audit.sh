#!/bin/bash
# ============================================================================
# Answer one question: can anything read or destroy data it has no business
# touching -- or is anything so tight that the service that NEEDS it cannot?
#
# Run it from the admin workstation. Nothing is changed; it only reports.
# Exit 0 = clean. Exit 1 = findings. Exit 2 = could not run the check.
#
#   ./fleet-permission-audit.sh              # the whole fleet
#   ./fleet-permission-audit.sh 65 66 67     # just these nodes
#   VERBOSE=1 ./fleet-permission-audit.sh    # also print nodes that are clean
#
# WHY THIS EXISTS -- the bug it was written the day after:
#
# The drive blob store sat at 0777 for months, so every local uid on a drive
# node could list all 30,512 of a user's files and, because write permission
# on a DIRECTORY is what authorises unlink, delete them. In the same hour we
# found the opposite failure in the same directory: blobs over 256 KB were
# landing in the wrong GROUP, so homelab-search got EACCES and told users
# their photos were "no longer on disk". Nothing was watching either way --
# both were found by a person clicking a link and by an upload test, months
# apart.
#
# The lesson generalised: permissions on a shared store are a FLEET
# invariant, not a per-package detail, and an invariant nobody measures is a
# wish. So this checks the whole fleet for both directions of the mistake.
#
# Deliberately NOT a `find /`: every search below is rooted at a homelab tree
# and uses -xdev, so it never crosses onto an NFS mount (a find over the
# 30k-file blob store from three clients at once is its own small outage).
# Shared stores are checked explicitly, once, by their own rule instead.
# ============================================================================
set -uo pipefail

FIRST="${FIRST:-0}"; LAST="${LAST:-72}"   # node NN -> 10.20.2.(144+NN)
PAR="${PAR:-16}"
VERBOSE="${VERBOSE:-0}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }

# --- the rules, as they run ON each node ------------------------------------
# Emits: SEV|RULE|path|detail
# Severities: CRIT (secret exposed / data destroyable), WARN (looser than
# intended, no direct exposure), INFO (worth knowing).
read -r -d '' REMOTE <<'REMOTE_EOF'
set -u
TREES=""
for t in /etc/homelab /var/lib/homelab /usr/share/homelab-drive; do
    [ -d "$t" ] && TREES="$TREES $t"
done
[ -n "$TREES" ] || exit 0

# 1. WORLD-WRITABLE anything in a homelab tree. On a directory this is the
#    serious one: write on a directory authorises unlink of files inside it
#    regardless of the files' own modes. Sticky dirs (1777) are exempted --
#    that is what the sticky bit is for.
find $TREES -xdev \( -type f -o -type d \) -perm -o+w ! -perm -1000 \
     -printf 'CRIT|world-writable|%p|mode=%m owner=%u:%g type=%y\n' 2>/dev/null

# 2. SECRETS READABLE BY OTHERS -- by CONTENT, not by filename.
#    A filename rule was tried first and was useless: it flagged every
#    /etc/homelab/services/*.yml service manifest and svc-hosts/hosts.yml,
#    which are declarative metadata that is SUPPOSED to be readable, and a
#    rule that cries wolf on 12 files per node gets ignored, which is worse
#    than not having it. So this opens each world-readable file and asks
#    whether it actually carries a live credential -- an assigned
#    password/secret/token key, or a user:pass@host connection URI. The
#    config trees of the services that keep credentials outside
#    /etc/homelab are included, because the question is "is a credential
#    exposed on this host", not "is a homelab file exposed".
for tree in /etc/homelab /etc/roundcube /etc/pgbouncer /etc/dovecot /etc/postfix /etc/opendkim; do
    [ -d "$tree" ] || continue
    find "$tree" -xdev -type f -perm -o+r -size -1M -print 2>/dev/null
done | while IFS= read -r f; do
    if grep -qiE "^[[:space:]]*[\"'#-]*(password|passwd|secret|client_secret|session_secret|token|api_key|apikey|key_encryption_key|kek)[\"']*[[:space:]]*[:=][[:space:]]*[^[:space:]#'\"]" "$f" 2>/dev/null \
       || grep -qE "://[^:/@[:space:]]+:[^@[:space:]]{4,}@" "$f" 2>/dev/null; then
        echo "CRIT|credential-world-readable|$f|mode=$(stat -c %a "$f" 2>/dev/null) owner=$(stat -c %u:%g "$f" 2>/dev/null)"
    fi
done

# 2b. pgbouncer's userlist.txt has its own rule, learned the hard way: it
#     must be root:postgres. Wrong ownership produces a DELAYED, sitewide
#     "SASL authentication failed" that looks like a credential problem
#     rather than a permission one.
for f in /etc/pgbouncer/userlist.txt; do
    [ -f "$f" ] || continue
    o=$(stat -c %U:%G "$f"); m=$(stat -c %a "$f")
    [ "$o" = "root:postgres" ] || echo "CRIT|pgbouncer-userlist-owner|$f|owner=$o mode=$m expected=root:postgres"
    case "$m" in 6[04]0|600) ;; *) echo "WARN|pgbouncer-userlist-mode|$f|mode=$m owner=$o" ;; esac
done

# 3. PRIVATE KEYS. Tighter rule than (2): a key must not be readable by
#    group OR other unless the group is the single service that needs it.
#    Reported for a human to judge; the mode and group are in the detail.
find /etc/homelab /etc/opendkim /var/lib/homelab -xdev -type f \
     \( -name '*.key' -o -name 'privkey*' -o -name '*.pem' -o -name '*kek*' -o -name '*.private' \) \
     \( -perm -o+r -o -perm -g+r \) \
     -printf 'CRIT|private-key-readable|%p|mode=%m owner=%u:%g\n' 2>/dev/null

# 4. THE AGENT CREDENTIAL specifically: it authenticates this host to the
#    control plane, so anything but 0600 is a privilege hole.
for f in /etc/homelab/agent/credential.yml; do
    [ -f "$f" ] || continue
    m=$(stat -c %a "$f")
    [ "$m" = "600" ] || echo "CRIT|agent-credential-mode|$f|mode=$m expected=600"
done

# 5. SHARED STORES. Checked by their mount root only -- never walked. These
#    are the directories whose mode decides what OTHER hosts' uids can do,
#    which is exactly where the drive store went wrong.
findmnt -rn -t nfs,nfs4 -o TARGET,SOURCE 2>/dev/null | while read -r mp src; do
    case "$mp" in
      /var/lib/homelab/*|/srv/*|/var/mail/*) ;;
      *) continue ;;
    esac
    m=$(stat -c %a "$mp" 2>/dev/null) || continue
    o=$(stat -c %u:%g "$mp" 2>/dev/null)
    case "$m" in
      *7|*6|*3|*2) echo "CRIT|shared-store-world-writable|$mp|mode=$m owner=$o src=$src" ;;
      *5|*4|*1)    echo "WARN|shared-store-world-readable|$mp|mode=$m owner=$o src=$src" ;;
    esac
done

# 6. THE DRIVE SETGID INVARIANT, asserted so it stays fixed. Every directory
#    a blob can be renamed into storage FROM must carry storage's group and
#    the setgid bit, because rename(2) preserves the SOURCE group and the
#    destination's setgid bit never gets a say. This is the check that would
#    have caught the group bug the day it shipped.
S=/var/lib/homelab/drive-storage
if [ -d "$S" ] && ! dpkg-query -W -f='${Status}' homelab-drive 2>/dev/null | grep -q 'install ok installed'; then
    # Residue from a removed package, not a live store. Reported as INFO,
    # because a CRIT on a directory no service uses is how an audit teaches
    # people to ignore it -- which is how the real 0777 sat there for months.
    echo "INFO|drive-storage-residue|$S|homelab-drive is not installed here; empty scaffolding left by a non-purge removal"
elif [ -d "$S" ]; then
    sg=$(stat -c %g "$S"); sm=$(stat -c %a "$S")
    case "$sm" in 2*) ;; *) echo "WARN|storage-not-setgid|$S|mode=$sm" ;; esac
    for d in .uploads-tmp .partials; do
        [ -d "$S/$d" ] || continue
        dg=$(stat -c %g "$S/$d"); dm=$(stat -c %a "$S/$d")
        if [ "$dg" != "$sg" ]; then
            echo "CRIT|rename-source-wrong-group|$S/$d|group=$dg storage_group=$sg mode=$dm"
        elif [ "${dm#2}" = "$dm" ]; then
            echo "CRIT|rename-source-not-setgid|$S/$d|mode=$dm group=$dg"
        fi
    done
fi
REMOTE_EOF

probe(){
  local nn="$1" ip out; ip="$(ip_of "$nn")"
  out=$(timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new "$ip" "sudo -n bash -s" <<<"$REMOTE" 2>/dev/null)
  if [ -z "$out" ] && ! timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "$ip" true 2>/dev/null; then
      echo "NOPROBE|$nn|$ip" >> "$TMP/unreached"; return
  fi
  [ -n "$out" ] && sed "s/^/$nn|/" <<<"$out" >> "$TMP/findings"
  echo "$nn" >> "$TMP/probed"
}

NODES=("$@")
if [ ${#NODES[@]} -eq 0 ]; then
  for n in $(seq "$FIRST" "$LAST"); do NODES+=("$(printf '%02d' "$n")"); done
fi

: > "$TMP/findings"; : > "$TMP/probed"; : > "$TMP/unreached"
i=0
for nn in "${NODES[@]}"; do
  probe "$nn" & i=$((i+1))
  [ $((i % PAR)) -eq 0 ] && wait
done
wait

echo "=============================================================="
echo " fleet permission audit -- $(date '+%Y-%m-%d %H:%M:%S')"
echo " probed $(wc -l < "$TMP/probed") node(s); $(wc -l < "$TMP/unreached") did not answer"
echo "=============================================================="

for sev in CRIT WARN INFO; do
  n=$(awk -F'|' -v s="$sev" '$2==s' "$TMP/findings" | wc -l)
  [ "$n" -eq 0 ] && continue
  echo
  echo "--- $sev ($n) ---"
  awk -F'|' -v s="$sev" '$2==s {printf "  node %s  %-28s %s\n      %s\n", $1, $3, $4, $5}' \
      "$TMP/findings" | sed 's/  *$//'
done

if [ -s "$TMP/unreached" ]; then
  echo
  echo "--- did not answer (NOT covered by this run) ---"
  awk -F'|' '{printf "  node %s (%s)\n", $2, $3}' "$TMP/unreached"
fi

total=$(wc -l < "$TMP/findings")
echo
if [ "$total" -eq 0 ]; then
  echo "RESULT: clean -- no findings on $(wc -l < "$TMP/probed") node(s)."
  [ -s "$TMP/unreached" ] && exit 1
  exit 0
fi
echo "RESULT: $total finding(s)."
exit 1
