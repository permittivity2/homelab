#!/bin/bash
# ============================================================================
# Answer one question: is the fleet consistent?
#
# Run it from the admin workstation. It compares what every node has INSTALLED
# against what the apt repo PUBLISHES, and also reports the two things a
# version check alone misses: half-configured packages (dpkg left mid-install,
# which still reports the NEW version so a naive version diff calls it fine)
# and failed homelab-* units.
#
# Exit 0 = consistent. Exit 1 = something to look at. Nothing is changed.
#
# Why this exists: there are 40+ independently-versioned homelab-* packages
# across ~60 nodes. Nobody should be tracking that by hand, and "I think
# everything is current" is not a check.
#
#   ./fleet-version-audit.sh            # the whole fleet
#   ./fleet-version-audit.sh 06 07 08   # just these nodes
#   VERBOSE=1 ./fleet-version-audit.sh  # also list what IS current
# ============================================================================
set -uo pipefail

REPO="${REPO:-http://projects.thedude.vip/apt-homelab}"
DIST="${DIST:-unstable}"
FIRST="${FIRST:-0}"; LAST="${LAST:-67}"   # node NN -> 10.20.2.(144+NN)
PAR="${PAR:-20}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }

# --- what the repo publishes ------------------------------------------------
# Read the live index, not the local reprepro db: this is what the hosts
# themselves can actually see and install.
if ! curl -fsSL --max-time 30 "$REPO/dists/$DIST/main/binary-amd64/Packages" \
     | awk '/^Package: /{p=$2} /^Version: /{if(p)print p"|"$2; p=""}' \
     | sort -u > "$TMP/pub"; then
  echo "ERROR: could not read $REPO/dists/$DIST/... -- is the repo published?" >&2
  exit 2
fi
[ -s "$TMP/pub" ] || { echo "ERROR: published index is empty" >&2; exit 2; }

# --- what each node has -----------------------------------------------------
NODES=("$@")
if [ ${#NODES[@]} -eq 0 ]; then
  for n in $(seq "$FIRST" "$LAST"); do NODES+=("$(printf '%02d' "$n")"); done
fi

# A node that does not answer silently drops out of the comparison -- which is
# exactly how three nodes (the 62/63/64 mail VMs) sat two versions behind
# without showing up in an earlier hand-rolled sweep. Record non-responders
# explicitly so "consistent" always states what it actually covered.
probe(){ # probe NN -> lines: NN|pkg|installed|state
  local nn="$1" ip out; ip="$(ip_of "$nn")"
  out=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$ip" "dpkg-query -W -f='\${Package} \${Version} \${Status}\n' 'homelab-*' 2>/dev/null \
           | grep -v 'not-installed'
           echo '--failed--'
           systemctl list-units 'homelab-*' --state=failed --no-legend 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
  if [ -z "$out" ]; then echo "$nn" >> "$TMP/unreachable"; return 0; fi
  printf '%s\n' "$out" \
  | awk -v h="$nn" '
      /^--failed--$/ {f=1; next}
      f && NF        {print h"|"$1"|-|FAILED-UNIT"; next}
      # dpkg ${Status} is THREE words ("install ok installed"), so the state is
      # fields 3-5, not field 4 -- reading $4 gets the literal "ok" and calls
      # every healthy package half-configured. Collapse it to one token here.
      NF>=5          {print h"|"$1"|"$2"|"$3"_"$4"_"$5}'
}

i=0
for nn in "${NODES[@]}"; do
  probe "$nn" >> "$TMP/inst" &
  i=$((i+1)); [ $((i % PAR)) -eq 0 ] && wait
done
wait
touch "$TMP/inst"

touch "$TMP/unreachable"
REACHED=$(cut -d'|' -f1 "$TMP/inst" | sort -u | grep -c . || true)
NOREPLY=$(sort -u "$TMP/unreachable" | grep -c . || true)
echo "Checked $REACHED node(s) against $REPO ($DIST)"
if [ "$NOREPLY" -gt 0 ]; then
  echo "No reply from $NOREPLY node(s) -- NOT covered by the verdict below:"
  echo "  $(sort -u "$TMP/unreachable" | sed 's/^/prod-homelab/' | tr '\n' ' ')"
  echo "  (powered off, or no homelab-* packages installed)"
fi
echo

# --- compare ----------------------------------------------------------------
awk -F'|' -v verbose="${VERBOSE:-0}" '
  NR==FNR { pub[$1]=$2; next }
  {
    host=$1; pkg=$2; got=$3; state=$4
    if (state=="FAILED-UNIT")        { bad++; printf "  FAILED UNIT      prod-homelab%-4s %s\n", host, pkg; next }
    # `apt remove` (without purge) leaves deinstall/ok/config-files behind.
    # That is a deliberate, benign end state -- the package is gone and only
    # its config remains -- so it is NOT drift and NOT half-configured.
    if (state ~ /^deinstall_ok_/)       { removed++; if (verbose=="1") printf "  removed (cfg kept) prod-homelab%-4s %s\n", host, pkg; next }
    if (state!="install_ok_installed") { bad++; printf "  HALF-CONFIGURED  prod-homelab%-4s %-30s (%s)\n", host, pkg, state; next }
    if (!(pkg in pub))               { unknown++; if (verbose=="1") printf "  NOT IN REPO      prod-homelab%-4s %-30s %s\n", host, pkg, got; next }
    if (got != pub[pkg])             { bad++; printf "  BEHIND           prod-homelab%-4s %-30s %-12s -> %s\n", host, pkg, got, pub[pkg]; next }
    ok++
    if (verbose=="1") printf "  current          prod-homelab%-4s %-30s %s\n", host, pkg, got
  }
  END {
    printf "\n%d package-instance(s) current", ok+0
    if (unknown) printf ", %d installed but not in the repo", unknown
    if (removed) printf ", %d removed with config retained", removed
    printf "\n"
    if (bad) { printf "%d need attention (see above)\n", bad; exit 1 }
    print "FLEET CONSISTENT -- every installed homelab-* package matches the published version."
  }
' "$TMP/pub" "$TMP/inst"
