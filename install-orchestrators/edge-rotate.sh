#!/bin/bash
# ============================================================================
# Rotate the internet edge to ONE of prod-homelab00/01/02, bring that node up
# to date, and verify it.
#
#   ./edge-rotate.sh 01              # swap to 01, update it, verify it
#   ./edge-rotate.sh 01 --os-updates # ...and apply the OS updates too
#   ./edge-rotate.sh 00 --no-updates # swap back, verify only
#   ./edge-rotate.sh 01 --dry-run    # say what it would do
#   ./edge-rotate.sh 01 --os-updates --no-phased   # leave phased updates alone
#
# WHY THIS IS A SCRIPT AND NOT A SEQUENCE OF COMMANDS.
#
# Exactly ONE edge node may be powered on, ever. The public 23.116.91.66/.68
# arrive by DHCP from AT&T reservations keyed to the edge NIC MACs, and all
# three containers carry those MACs so that whichever one is running claims the
# addresses. Two up at once is an address conflict on the public L2 -- the
# failure mode that took myaccount/invite/blockemail down in the 2026-10-25
# proxy01 incident. So the shutdown must COMPLETE before the start begins, and
# that ordering is the main thing being automated here.
#
# What this costs while it runs: the edge terminates all 16 public web vhosts
# and, through haproxy, inbound SMTP :25, submission :587 and IMAP(S) :143/:993
# for the whole fleet. A swap is therefore a brief public outage for web AND
# mail -- about 10-20 seconds of container transition, plus however long the
# DHCP lease takes to land.
#
# WHAT "OUTSTANDING WORK" MEANS HERE. A parked edge node has missed every
# homelab-* release since it was last up. This upgrades the homelab-* packages
# it already has installed -- it does NOT install new ones (the three nodes are
# meant to be identical, so a missing package is drift worth a human looking at
# it, reported below but not silently fixed) and it does NOT apply OS updates
# (a kernel or libc upgrade on the live internet edge deserves its own decision,
# so the count is reported instead).
#
# Two things a parked node specifically needs:
#   * its agent credential may have passed the 30-day refresh-token life, which
#     no restart fixes -- so this re-enrols automatically when introspect fails;
#   * its certificates will be stale, so certsync is forced once the agent can
#     authenticate again. Without that, TLS on all 16 vhosts serves expired
#     certs.
# ============================================================================
set -uo pipefail

TARGET=""; DRY=0; UPDATES=1; OS_UPDATES=0; PHASED=1
for a in "$@"; do
    case "$a" in
        --dry-run)    DRY=1 ;;
        --no-updates) UPDATES=0 ;;
        --os-updates) OS_UPDATES=1 ;;
        --no-phased)  PHASED=0 ;;
        00|01|02|0|1|2) TARGET=$(printf '%02d' "$((10#$a))") ;;
        *) echo "unknown argument '$a' (usage: edge-rotate.sh <00|01|02> [--os-updates] [--no-phased] [--no-updates] [--dry-run])"; exit 1 ;;
    esac
done
[ -z "$TARGET" ] && { echo "which edge? (00, 01 or 02)"; exit 1; }

PVE=10.20.1.8
CTID=$((400 + 10#$TARGET))
MGMT=10.20.2.$((144 + 10#$TARGET))
HERE="$(cd "$(dirname "$0")" && pwd)"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){ echo "  ${G}ok${O}   $*"; }
bad(){ echo "  ${R}FAIL${O} $*"; }
warn(){ echo "  ${Y}warn${O} $*"; }
step(){ echo; echo "=== $* ==="; }
pve(){ ssh -o ConnectTimeout=10 "$PVE" "$@"; }
# Run a command INSIDE the container via the hypervisor. Needed because the OS
# upgrade restarts openssh-server, so anything that polls over ssh loses the
# connection at exactly the moment it matters and reports a false failure.
cexec(){ ssh -o ConnectTimeout=10 "$PVE" "sudo pct exec $CTID -- sh -c '$1'" 2>/dev/null; }

step "current edge state"
EDGES=$(pve "sudo pct list" 2>/dev/null | awk '$1 ~ /^(400|401|402)$/ {print $1" "$2}')
[ -z "$EDGES" ] && { bad "could not read container state from pve2 ($PVE)"; exit 1; }
echo "$EDGES" | sed 's/^/  /'
RUNNING=$(echo "$EDGES" | awk '$2 == "running" {print $1}')
RUN_COUNT=$(echo "$RUNNING" | grep -c '[0-9]' || true)

if [ "$RUN_COUNT" -gt 1 ]; then
    bad "MORE THAN ONE edge is running ($(echo "$RUNNING" | paste -sd, -))."
    bad "That is a public address conflict. Stop one by hand before using this."
    exit 1
fi

if [ "$RUNNING" = "$CTID" ]; then
    ok "prod-homelab$TARGET is already the active edge -- no swap needed"
    SWAP=0
else
    SWAP=1
fi

if [ "$DRY" = 1 ]; then
    echo
    [ "$SWAP" = 1 ] && echo "  would: shutdown ${RUNNING:-none}, start $CTID, update, verify" \
                    || echo "  would: update and verify $CTID in place"
    exit 0
fi

# --------------------------------------------------------------- the swap
if [ "$SWAP" = 1 ]; then
    step "bring the current edge down BEFORE starting the next one"
    echo "  Public web and mail ingress are down from here until the new node"
    echo "  has its address. This ordering is not negotiable -- see the header."
    if [ -n "$RUNNING" ]; then
        echo "  shutting down $RUNNING (graceful)..."
        pve "sudo pct shutdown $RUNNING --timeout 60" >/dev/null 2>&1 || true
        for i in $(seq 1 24); do
            st=$(pve "sudo pct status $RUNNING" 2>/dev/null | awk '{print $2}')
            [ "$st" = "stopped" ] && break
            sleep 5
        done
        st=$(pve "sudo pct status $RUNNING" 2>/dev/null | awk '{print $2}')
        if [ "$st" != "stopped" ]; then
            warn "graceful shutdown did not finish -- forcing stop"
            pve "sudo pct stop $RUNNING" >/dev/null 2>&1 || true
            sleep 5
            st=$(pve "sudo pct status $RUNNING" 2>/dev/null | awk '{print $2}')
        fi
        [ "$st" = "stopped" ] && ok "$RUNNING stopped" \
            || { bad "$RUNNING is '$st' and will not stop -- NOT starting $CTID (conflict risk)"; exit 1; }
    fi

    step "start prod-homelab$TARGET (pct $CTID)"
    pve "sudo pct start $CTID" >/dev/null 2>&1 || { bad "pct start $CTID failed"; exit 1; }
    for i in $(seq 1 36); do
        timeout 4 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null && break
        sleep 5
    done
    timeout 4 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null \
        && ok "answers on :22 ($MGMT)" \
        || { bad "$MGMT never came up on :22 -- recover with: ssh $PVE 'sudo pct start ${RUNNING:-400}'"; exit 1; }

    step "wait for the public DHCP lease to land"
    echo "  The AT&T reservation is keyed to this node's NIC MACs, so the address"
    echo "  is not instant and nothing public works until it arrives."
    for i in $(seq 1 24); do
        PUB=$(ssh -o ConnectTimeout=6 "$MGMT" 'ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1 | grep -E "^23\." | paste -sd, -' 2>/dev/null)
        [ -n "$PUB" ] && break
        sleep 5
    done
    [ -n "${PUB:-}" ] && ok "public address(es): $PUB" \
        || warn "no 23.x address yet -- external checks below will fail until it lands"
fi

# ------------------------------------------------------- outstanding work
if [ "$UPDATES" = 1 ]; then
    step "the agent must authenticate before anything else can be fetched"
    AG=$(ssh -o ConnectTimeout=8 "$MGMT" '
        T=$(sudo grep "^token:" /etc/homelab/agent/credential.yml 2>/dev/null | sed "s/^token:[[:space:]]*//")
        [ -z "$T" ] && { echo "no-credential"; exit 0; }
        curl -s --max-time 8 -H "Authorization: Bearer $T" \
            http://10.50.2.132:3000/api/v1/auth/introspect \
          | grep -oE "system_agent|\"error\":\"[^\"]*\"" | head -1' 2>/dev/null)
    if [ "$AG" = "system_agent" ]; then
        ok "agent already authenticates"
    else
        warn "agent state is '${AG:-unreachable}' -- re-enrolling (expected on a node parked past the 30-day refresh-token life)"
        "$HERE/agent-reenroll.sh" "$TARGET" --force 2>&1 | sed 's/^/    /'
    fi

    step "upgrade the homelab-* packages this node already has"
    BEFORE=$(ssh -o ConnectTimeout=8 "$MGMT" 'dpkg-query -W -f="\${Package} \${Version}\n" "homelab-*" 2>/dev/null | awk "\$2 != \"\"" | sort')
    ssh -o ConnectTimeout=10 "$MGMT" '
        set -e
        sudo apt-get update -qq
        PKGS=$(dpkg-query -W -f="\${Package} \${Status}\n" "homelab-*" 2>/dev/null \
                 | awk "/install ok installed/ {print \$1}" | paste -sd" " -)
        [ -n "$PKGS" ] || { echo "no homelab-* packages installed"; exit 0; }
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade $PKGS 2>&1 \
          | grep -viE "^$|^\(Reading database|^Preparing|^Unpacking|^Selecting|Running kernel|^No (services|containers|user sessions|VM guests)" || true
    ' 2>&1 | sed 's/^/    /'

    AFTER=$(ssh -o ConnectTimeout=8 "$MGMT" 'dpkg-query -W -f="\${Package} \${Version}\n" "homelab-*" 2>/dev/null | awk "\$2 != \"\"" | sort')
    echo "  changed:"
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -E '^>' | sed 's/^> /    now /' || echo "    (nothing -- already current)"

    step "drift against the live reference set"
    # The three edge nodes are meant to be identical. A package one has and
    # another does not is drift a human should see, not something to install
    # silently -- installing it here would hide how it came to differ.
    REF=/home/gardner/claude/general/github-repos/homelab/git/install-orchestrators/.edge-reference-packages
    if [ -f "$REF" ]; then
        MISSING=$(LC_ALL=C comm -23 <(awk '{print $1}' "$REF" | LC_ALL=C sort) <(printf '%s\n' "$AFTER" | awk '{print $1}' | LC_ALL=C sort))
        [ -z "$MISSING" ] && ok "same package set as the reference" \
            || warn "packages on the reference edge but NOT here:$(printf ' %s' $MISSING)"
        VERDIFF=$(join <(sort "$REF") <(printf '%s\n' "$AFTER" | sort) 2>/dev/null | awk '$2 != $3 {print "    "$1": reference "$2", here "$3}')
        [ -z "$VERDIFF" ] && ok "same versions as the reference" || { warn "version differences:"; echo "$VERDIFF"; }
    else
        warn "no reference package list at $REF -- skipping the drift check"
    fi

    step "config drift against the live reference node"
    # Package upgrades fix package-managed config. They do NOT fix a hand-edit
    # that only ever landed on the node that happened to be running at the
    # time -- which, with one edge up at a time, is the normal way these three
    # drift apart. The reference fingerprint is captured from whichever node is
    # live and verified, BEFORE it is shut down (it cannot be read afterwards).
    #
    # Some files are MEANT to differ: each node has its own management address
    # and its own agent identity. Those are listed, not alarmed about.
    CREF=/home/gardner/claude/general/github-repos/homelab/git/install-orchestrators/.edge-reference-config
    if [ ! -f "$CREF" ]; then
        warn "no reference config fingerprint at $CREF -- skipping"
    else
        ssh -o ConnectTimeout=10 "$MGMT" 'sudo sh -c "
          for d in /etc/nginx/sites-available /etc/nginx/conf.d /etc/haproxy /etc/dnsdist /etc/sysctl.d /etc/nftables.d /etc/homelab /etc/systemd/network /etc/systemd/system/systemd-networkd-wait-online.service.d; do
            [ -d \"\$d\" ] || continue
            find \"\$d\" -type f ! -name credential.yml ! -name \"*.key\" ! -name \"*.pem\" -print0 2>/dev/null | xargs -0 sha256sum 2>/dev/null
          done
        "' 2>/dev/null | awk '{print $2, $1}' | sort > /tmp/edge-config-$TARGET.$$

        # Expected to differ: anything carrying this node's own address or identity.
        EXPECTED='/etc/homelab/agent/config.yml|/etc/systemd/network/|/etc/homelab/services/'

        # LC_ALL=C on every side: comm and join both require the SAME collation
        # as each other, and a locale-sorted list made files show up as BOTH
        # missing and extra at once (seen on the first prod-homelab01 run).
        export LC_ALL=C
        MISS=$(comm -23 <(awk '{print $1}' "$CREF" | sort) <(awk '{print $1}' /tmp/edge-config-$TARGET.$$ | sort))
        EXTRA=$(comm -13 <(awk '{print $1}' "$CREF" | sort) <(awk '{print $1}' /tmp/edge-config-$TARGET.$$ | sort))
        DIFFER=$(join <(sort "$CREF") <(sort /tmp/edge-config-$TARGET.$$) 2>/dev/null | awk '$2 != $3 {print $1}')
        rm -f /tmp/edge-config-$TARGET.$$

        UNEXPECTED=$(printf '%s\n' "$DIFFER" | grep -vE "^($EXPECTED)" | grep -E '.' || true)
        HOSTSPEC=$(printf '%s\n' "$DIFFER" | grep -E "^($EXPECTED)" | grep -E '.' || true)

        if [ -z "$MISS" ]; then ok "no config file missing on this node"
        else warn "config files on the reference node but MISSING here:"; printf '%s\n' "$MISS" | sed 's/^/      /'; fi

        if [ -z "$UNEXPECTED" ]; then ok "no unexpected config differences"
        else
            warn "config differs here, and these are NOT host-specific -- look at them:"
            printf '%s\n' "$UNEXPECTED" | sed 's/^/      /'
        fi

        [ -n "$HOSTSPEC" ] && echo "  ${D}differs as expected (per-node address/identity):$(printf ' %s' $HOSTSPEC)${O}"
        [ -n "$EXTRA" ] && { echo "  ${D}present only here (informational):${O}"; printf '%s\n' "$EXTRA" | sed 's/^/      /'; }
    fi

    step "certificates (stale on a parked node -- forced, not left to the timer)"
    ssh -o ConnectTimeout=10 "$MGMT" 'sudo systemctl start homelab-certsync' >/dev/null 2>&1 || true
    sleep 5
    ssh -o ConnectTimeout=8 "$MGMT" 'sudo journalctl -u homelab-certsync -n 6 --no-pager 2>/dev/null | tail -5' | sed 's/^/    /'

    if [ "$OS_UPDATES" = 0 ]; then
        step "pending OS updates (reported, NOT applied)"
        echo "  Pass --os-updates to apply them. Left alone by default because a"
        echo "  systemd or libc upgrade on the live internet edge wants a decision."
        ssh -o ConnectTimeout=8 "$MGMT" 'apt list --upgradable 2>/dev/null | grep -c upgradable || true' \
          | sed 's/^/    other upgradable packages: /'
    else
        step "OS updates -- applying"
        PENDING=$(ssh -o ConnectTimeout=8 "$MGMT" 'apt list --upgradable 2>/dev/null | grep -c upgradable || true')
        echo "  $PENDING package(s) pending. Two things make this safe to run here:"
        echo "   * --force-confold keeps every existing config file. The edge's nginx,"
        echo "     haproxy and postfix configs are hand/tool-managed, and a conffile"
        echo "     prompt would otherwise either hang the run or overwrite them."
        echo "   * it runs DETACHED under systemd-run, not in this ssh session. The"
        echo "     set includes openssh-server, and a dropped connection part-way"
        echo "     through dpkg leaves broken packages behind."
        if [ "$PHASED" = 1 ]; then
            PHASE_OPT='-o APT::Get::Always-Include-Phased-Updates=true'
            echo "   * it INCLUDES phased updates. Ubuntu rolls an -updates package out"
            echo "     to a deterministic fraction of machines first, keyed to"
            echo "     /etc/machine-id -- so the same apt run on these three nodes"
            echo "     installs DIFFERENT versions. That is the opposite of what this"
            echo "     trio needs: they carry the same MACs and are swapped for one"
            echo "     another, so a rotation would silently change the version of"
            echo "     systemd/PID 1 under production. Pass --no-phased to leave them."
        else
            PHASE_OPT=''
            warn "phased updates EXCLUDED (--no-phased): this node may end up on"
            warn "different versions than the other two edge nodes."
        fi

        PAYLOAD=$(base64 -w0 <<'UPGRADE'
#!/bin/bash
# The shebang is load-bearing: systemd execs this file directly, so without it
# the unit dies instantly with "Exec format error" (203/EXEC) and the log it was
# told to write stays empty -- which looks exactly like a silent failure.
set -e
apt-get update -qq
# Download first: this part touches nothing, so the node keeps serving while it
# runs and the install window stays as short as it can be.
DEBIAN_FRONTEND=noninteractive apt-get -y -qq __PHASE_OPT__ -d full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y __PHASE_OPT__     -o Dpkg::Options::=--force-confdef     -o Dpkg::Options::=--force-confold     full-upgrade
UPGRADE
)
        # Substituted after the heredoc so the heredoc itself stays unexpanded:
        # everything else in it is literal on purpose.
        PAYLOAD=$(printf '%s' "$PAYLOAD" | base64 -d \
                  | sed "s|__PHASE_OPT__|$PHASE_OPT|" | base64 -w0)
        ssh -o ConnectTimeout=10 "$MGMT" "
            printf '%s' '$PAYLOAD' | base64 -d | sudo tee /run/edge-os-upgrade.sh >/dev/null
            sudo chmod +x /run/edge-os-upgrade.sh
            sudo rm -f /var/log/edge-os-upgrade.log
            sudo systemctl reset-failed edge-os-upgrade 2>/dev/null || true
            sudo systemd-run --unit=edge-os-upgrade --no-block --property=Type=oneshot \
                --property=StandardOutput=file:/var/log/edge-os-upgrade.log \
                --property=StandardError=append:/var/log/edge-os-upgrade.log \
                /run/edge-os-upgrade.sh" >/dev/null 2>&1 \
            || warn "the launch command returned non-zero -- checking whether the unit started anyway"
        sleep 5
        case "$(cexec 'systemctl is-active edge-os-upgrade')" in
            activating|active) ok "upgrade running, detached" ;;
            *) bad "the upgrade unit is not running -- see 'journalctl -u edge-os-upgrade' on the node" ;;
        esac

        echo -n "  upgrading (sshd will restart part-way through; polling via the hypervisor)"
        for i in $(seq 1 120); do   # up to 20 minutes
            st=$(cexec 'systemctl is-active edge-os-upgrade')
            [ "$st" = "activating" ] || [ "$st" = "active" ] || break
            echo -n "."
            sleep 10
        done
        echo
        RESULT=$(cexec 'systemctl show edge-os-upgrade -p Result --value')
        LEFT=$(cexec 'apt list --upgradable 2>/dev/null | grep -c upgradable')
        case "$RESULT" in
            success) if [ "${LEFT:-0}" -gt 0 ] 2>/dev/null; then
                         # The unit succeeding and the work being done are two
                         # different things: apt exits 0 having deliberately
                         # kept packages back. Saying "clean" with a non-zero
                         # remainder is how a shortfall goes unnoticed.
                         warn "unit succeeded but $LEFT package(s) are STILL pending (was $PENDING)"
                         cexec 'apt list --upgradable 2>/dev/null | grep upgradable' \
                           | sed 's/^/      /' | head -15
                         warn "if these are phased, re-run without --no-phased"
                     else
                         ok "upgrade finished cleanly (was $PENDING pending, now $LEFT)"
                     fi ;;
            "")      warn "could not read the unit result (was $PENDING pending, now $LEFT)" ;;
            *)       bad "upgrade result: $RESULT (was $PENDING pending, now $LEFT)" ;;
        esac
        echo "  tail of /var/log/edge-os-upgrade.log:"
        cexec 'tail -5 /var/log/edge-os-upgrade.log' | sed 's/^/    /'
        AUDIT=$(cexec 'dpkg --audit')
        if [ -z "$AUDIT" ]; then ok "dpkg --audit is clean -- no half-configured packages"
        else bad "dpkg --audit reports problems:"; printf '%s\n' "$AUDIT" | head -10 | sed 's/^/      /'; fi

        # Also wait for sshd to come back, since everything after this needs it.
        for i in $(seq 1 24); do
            timeout 4 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null && break
            sleep 5
        done
        timeout 4 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null \
            && ok "sshd is back after its own upgrade" || bad "sshd did not come back"

        FAILED=$(cexec 'systemctl --failed --no-legend --no-pager')
        if [ -n "$FAILED" ]; then
            warn "unit(s) in a failed state after the upgrade:"
            printf '%s\n' "$FAILED" | sed 's/^/      /'
            echo "      ${D}(netplan-configure is pre-existing on these nodes: udevadm cannot"
            echo "       reload in an unprivileged container and /etc/netplan is empty)${O}"
        else
            ok "no unit left in a failed state"
        fi

        if cexec 'test -f /var/run/reboot-required && echo yes' | grep -q yes; then
            step "reboot required -- taking it now, while this node is the one being worked on"
            echo "  A container reboot is quick, but public web and mail are down for it."
            pve "sudo pct reboot $CTID" >/dev/null 2>&1 || true
            sleep 10
            for i in $(seq 1 36); do
                timeout 4 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null && break
                sleep 5
            done
            timeout 4 bash -c "echo > /dev/tcp/$MGMT/22" 2>/dev/null \
                && ok "back on :22" || bad "did NOT come back on :22 after the reboot"
            for i in $(seq 1 24); do
                PUB=$(ssh -o ConnectTimeout=6 "$MGMT" 'ip -4 -o addr show scope global | awk "{print \$4}" | cut -d/ -f1 | grep -E "^23\." | paste -sd, -' 2>/dev/null)
                [ -n "$PUB" ] && break
                sleep 5
            done
            [ -n "${PUB:-}" ] && ok "public address(es) back: $PUB" || warn "no 23.x address yet"
        else
            ok "no reboot required"
        fi
    fi
fi

# ------------------------------------------------------------------ verify
step "verify prod-homelab$TARGET"
"$HERE/edge-verify.sh" "$TARGET"
RC=$?

echo
if [ "$RC" = 0 ]; then
    echo "${G}prod-homelab$TARGET is the active edge and is serving.${O}"
else
    echo "${R}prod-homelab$TARGET did NOT verify clean ($RC failure(s)).${O}"
    echo "If the public paths are the problem and the node otherwise looks right,"
    echo "pfSense may still be ARPing the previous node -- flush its ARP entry for"
    echo "23.116.91.66. To fall back immediately:"
    echo "  ssh $PVE 'sudo pct shutdown $CTID --timeout 60 && sudo pct start 400'"
fi
exit "$RC"
