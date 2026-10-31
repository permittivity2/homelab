#!/bin/bash
# ============================================================================
# Finish a fleet VM that was cloned from prod-homelabvm69 (470/471/472).
#
#   ./vm-clone-finalize.sh 470              # do it
#   ./vm-clone-finalize.sh 470 --dry-run    # say what it would do
#   ./vm-clone-finalize.sh 470 --verify     # change nothing, check the result
#
# ONE HOST PER RUN, ON PURPOSE. Every clone currently carries 469's addresses
# AND 469's homelab-agent credential. 469 is the live Prometheus/Grafana server.
# Doing these in a batch means that if something goes wrong on the first one you
# find out with three machines half-converted; doing them one at a time means
# the run ends with a check that 469 is still serving before the next one starts.
#
# WHY THE ORDER IN HERE IS NOT NEGOTIABLE.
#
# 1. cloud-init is DISABLED on this lineage (/etc/cloud/cloud-init.disabled on
#    469, dated Oct 5). So `qm set -ipconfigN` changes NOTHING inside the guest
#    -- those lines are documentation. The guest's addresses come from a static
#    /etc/netplan/50-cloud-init.yaml which MATCHES EACH INTERFACE BY MAC:
#
#        eth1:
#          match: { macaddress: "bc:24:11:aa:90:69" }
#          addresses: ["10.20.2.213/22"]
#
#    Consequence: change the MACs on the hypervisor and the guest comes up with
#    NO NETWORK AT ALL, because no interface matches any more. That is not a
#    failure mode to avoid here -- it is the one we deliberately use (see 3).
#    Evidence this has bitten before: 469 still carries a
#    50-cloud-init.yaml.vm68-clone.bak from when IT was cloned off 468.
#
# 2. We therefore do everything through `qm guest exec`, not ssh. The guest
#    agent talks over virtio-serial, so it works with no network. qemu-guest-agent
#    is active on this lineage, so the clones have it.
#
# 3. THE CLONED AGENT CREDENTIAL IS THE DANGEROUS LEFTOVER, and the no-network
#    first boot is what makes removing it safe. /etc/homelab/agent/credential.yml
#    on the clone is byte-identical to the one live 469 is using, and the agent
#    rotates it atomically with a 300s grace window -- so a clone that reaches
#    the API and refreshes can lock 469 out of the fleet. Booting with a network
#    that cannot work means the cloned agent cannot reach anything, and we delete
#    the credential before netplan is fixed. First action in the guest, always.
#
# 4. MAC and address patterns are the fleet's, derived from VMs 462-469 rather
#    than invented. NN is the VMID's last two digits:
#      net0 vlan   10  BC:24:11:BB:90:NN  10.10.2.(144+NN)/22  link_down=1
#      net1 vlan   20  BC:24:11:AA:90:NN  10.20.2.(144+NN)/22  default gw .0.1
#      net2 vlan  450  BC:24:11:CC:90:NN  10.45.2.(144+NN)/22  NFS/storage
#      net3 vlan 3000  BC:24:11:30:90:NN  10.50.2.(144+NN)/22  service plane
#    470 -> :70/.214, 471 -> :71/.215, 472 -> :72/.216.
#
# 5. The netplan rewrite is two sed expressions and they cover all four
#    interfaces at once, because every MAC in that file ends ':90:69' and every
#    address ends '2.213/22'. That is a property of the pattern, not luck -- but
#    --verify re-reads the file afterwards rather than trusting it.
#
# WHAT IS DELIBERATELY KEPT: homelab-agent, homelab-common, homelab-node-exporter
# (every fleet host runs it), services/node-exporter.yml, the fleet-trust and
# metrics nftables drop-ins, homelab.list, thedude.list, and
# bad-ips.list.disabled -- left DISABLED, because a host must never carry both
# /apt and /apt-homelab.
# ============================================================================
set -uo pipefail

PVE=10.20.1.8
SRC_VMID=469                      # the clone source; must stay healthy
SRC_MGMT=10.20.2.213

VMID=""; DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        470|471|472) VMID="$a" ;;
        *) echo "unknown argument '$a' (usage: vm-clone-finalize.sh <470|471|472> [--dry-run] [--verify])"; exit 1 ;;
    esac
done
[ -n "$VMID" ] || { echo "which VM? usage: vm-clone-finalize.sh <470|471|472> [--dry-run] [--verify]"; exit 1; }

NN=$(( VMID - 400 ))              # 470 -> 70
OCT=$(( 144 + NN ))               # 470 -> 214
HOSTNAME="prod-homelabvm${NN}"
MGMT="10.20.2.${OCT}"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
die(){  echo; echo "${R}$*${O}"; exit 1; }
RC=0

# -n is load-bearing: an ssh inside a `while read` loop eats the loop's stdin
# and the loop quietly stops after one iteration.
pve(){  ssh -n -o ConnectTimeout=10 "$PVE" "$@"; }
guest(){ ssh -n -o ConnectTimeout=15 "$MGMT" "$@"; }
# TCP connect, never ping -- several fleet hosts filter ICMP, so ping reports a
# false "down" and would make this script lie.
tcp(){  timeout 5 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; }

echo
echo "prod-homelabvm${NN}  (VMID $VMID)  ->  mgmt $MGMT, service 10.50.2.${OCT}, storage 10.45.2.${OCT}"
echo "MACs: BB/AA/CC/30:90:${NN}"

# ----------------------------------------------------------------- verify only
if [ "$VERIFY_ONLY" = 1 ]; then
    step "verify prod-homelabvm${NN}"

    CONF=$(pve "sudo qm config $VMID" 2>/dev/null)
    for pair in "BB:90:${NN}" "AA:90:${NN}" "CC:90:${NN}" "30:90:${NN}"; do
        printf '%s' "$CONF" | grep -qi "$pair" \
            && ok "hypervisor MAC $pair present" \
            || bad "hypervisor MAC $pair MISSING"
    done

    if tcp "$MGMT" 22; then
        ok "answers on :22 ($MGMT)"
        H=$(guest 'hostname' 2>/dev/null)
        [ "$H" = "$HOSTNAME" ] && ok "hostname is $H" || bad "hostname is '${H:-?}', expected $HOSTNAME"

        # THREE addresses, not four. net0 (vlan 10, the legacy 10.10 plane) is
        # link_down=1 on every fleet VM, so eth0 is NO-CARRIER and never takes
        # its address -- confirmed identical on 469, 465 and 462. Expecting four
        # here reported a healthy host as broken, which is the wrong direction
        # for a check to fail in.
        ADDRS=$(guest "ip -4 -o addr show scope global | awk '{print \$4}' | sort | tr '\n' ' '" 2>/dev/null)
        EXPECT="10.20.2.${OCT}/22 10.45.2.${OCT}/22 10.50.2.${OCT}/22 "
        [ "$ADDRS" = "$EXPECT" ] && ok "mgmt/storage/service planes up: $ADDRS" \
                                 || bad "addresses are '$ADDRS', expected '$EXPECT'"
        # eth0 should still be CONFIGURED with the 10.10 address and merely
        # carrier-less; that distinguishes "down by design" from "netplan lost it".
        E0=$(guest "ip -o link show eth0 2>/dev/null | grep -c NO-CARRIER" 2>/dev/null)
        # sudo: this script chmod 600'd the netplan file, so an unprivileged
        # grep returns nothing and the check would warn about a healthy host.
        E0CFG=$(guest "sudo grep -c '10.10.2.${OCT}/22' /etc/netplan/50-cloud-init.yaml" 2>/dev/null)
        [ "${E0:-0}" = 1 ] && [ "${E0CFG:-0}" = 1 ] \
            && ok "eth0 carries 10.10.2.${OCT} in netplan and is down by design (link_down=1)" \
            || warn "eth0 state unexpected (NO-CARRIER=$E0, in netplan=$E0CFG)"

        MID=$(guest 'cat /etc/machine-id' 2>/dev/null)
        SRC_MID=$(ssh -n -o ConnectTimeout=10 "$SRC_MGMT" 'cat /etc/machine-id' 2>/dev/null)
        [ -n "$MID" ] && [ "$MID" != "$SRC_MID" ] \
            && ok "machine-id is its own (${MID:0:12}...)" \
            || bad "machine-id still matches 469 -- regenerate it"

        FP=$(guest 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk "{print \$2}"' 2>/dev/null)
        SRC_FP=$(ssh -n -o ConnectTimeout=10 "$SRC_MGMT" 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk "{print \$2}"' 2>/dev/null)
        [ -n "$FP" ] && [ "$FP" != "$SRC_FP" ] \
            && ok "ssh host key is its own" \
            || bad "ssh host key still matches 469 -- regenerate it"

        LEFT=$(guest 'dpkg-query -W -f="\${Package}\n" "homelab-*" 2>/dev/null | grep -E "prometheus|grafana" | grep -v node-exporter' 2>/dev/null)
        [ -z "$LEFT" ] && ok "no prometheus/grafana packages left" || bad "still installed: $(echo "$LEFT" | tr '\n' ' ')"

        MAN=$(guest 'ls -1 /etc/homelab/services/ 2>/dev/null | tr "\n" " "' 2>/dev/null)
        [ "$MAN" = "node-exporter.yml " ] \
            && ok "service manifests: $MAN" \
            || bad "service manifests are '$MAN', expected only node-exporter.yml"
        note "a stray manifest is what produces phantom fleet-drift entries"

        ID=$(guest 'sudo grep -E "^(hostname|advertise_host):" /etc/homelab/agent/config.yml | tr "\n" " "' 2>/dev/null)
        case "$ID" in
            *"$HOSTNAME"*10.50.2.${OCT}*) ok "agent config.yml identifies as this host ($ID)" ;;
            *) bad "agent config.yml still says '$ID' -- it would register as 469 in api.hosts" ;;
        esac

        # Same check agent-reenroll.sh uses: the credential's own token against
        # the API's introspect. "system_agent" is the only good answer.
        STATE=$(guest '
            T=$(sudo grep "^token:" /etc/homelab/agent/credential.yml 2>/dev/null | sed "s/^token:[[:space:]]*//")
            [ -z "$T" ] && { echo "no-credential"; exit 0; }
            curl -s --max-time 8 -H "Authorization: Bearer $T" \
                http://10.50.2.132:3000/api/v1/auth/introspect \
              | grep -oE "system_agent|\"error\":\"[^\"]*\"" | head -1' 2>/dev/null)
        case "${STATE:-unreachable}" in
            system_agent)   ok "agent introspects as system_agent" ;;
            no-credential)  warn "agent not enrolled yet -- run agent-reenroll.sh $NN" ;;
            *)              warn "agent state is '$STATE' -- run agent-reenroll.sh $NN" ;;
        esac
    else
        bad "no answer on :22 ($MGMT) -- if the MACs were changed, netplan inside the guest still matches the OLD ones"
    fi

    step "469 (the clone source) must be unharmed"
    if tcp "$SRC_MGMT" 22; then
        ok "469 answers on :22"
        for svc in prometheus grafana-server; do
            S=$(ssh -n -o ConnectTimeout=10 "$SRC_MGMT" "systemctl is-active $svc" 2>/dev/null)
            [ "$S" = active ] && ok "469 $svc active" || bad "469 $svc is '$S'"
        done
        A=$(ssh -n -o ConnectTimeout=10 "$SRC_MGMT" '
            T=$(sudo grep "^token:" /etc/homelab/agent/credential.yml 2>/dev/null | sed "s/^token:[[:space:]]*//")
            [ -z "$T" ] && { echo "no-credential"; exit 0; }
            curl -s --max-time 8 -H "Authorization: Bearer $T" \
                http://10.50.2.132:3000/api/v1/auth/introspect \
              | grep -oE "system_agent|\"error\":\"[^\"]*\"" | head -1' 2>/dev/null)
        [ "$A" = system_agent ] \
            && ok "469 agent still authenticates" \
            || bad "469 agent state is '$A' -- if a clone rotated its credential, repair with: agent-reenroll.sh --stale"
    else
        bad "469 does not answer on :22"
    fi

    step "result"
    [ "$RC" = 0 ] && echo "  ${G}prod-homelabvm${NN} is finished and 469 is unharmed.${O}" \
                  || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

# ------------------------------------------------------------------- preflight
step "preflight"

STATUS=$(pve "sudo qm status $VMID" 2>/dev/null | awk '{print $2}')
[ -n "$STATUS" ] || die "VMID $VMID not found on $PVE"
ok "VMID $VMID exists (status: $STATUS)"

if [ "$STATUS" != stopped ]; then
    die "VMID $VMID is '$STATUS', not stopped. This script configures a cold clone;
stop it first if that is really what you want:  ssh $PVE 'sudo qm stop $VMID'"
fi
ok "it is stopped, so the config change is safe"

# The single most important check in this script. If something already answers
# on the target address, writing this config and booting creates a duplicate --
# which is the 2026-10-25 proxy01 incident in a different costume.
if tcp "$MGMT" 22; then
    die "something ALREADY answers on $MGMT:22. Refusing to configure $VMID to
claim that address. Find out what it is before continuing."
fi
ok "nothing answers on $MGMT:22 yet -- the address is free"

if tcp "$SRC_MGMT" 22; then
    ok "469 is up (it must stay up; it is the live metrics server)"
else
    warn "469 does not answer on :22 -- continuing, but the final 469 check cannot run"
fi

# ----------------------------------------------------------------- hypervisor
step "set the fleet MACs and addresses on the hypervisor"
note "cloud-init is disabled on this lineage, so -ipconfigN is documentation;"
note "the guest's real addresses are fixed in netplan further down."

QMSET="sudo qm set $VMID \
  -net0 virtio=BC:24:11:BB:90:${NN},bridge=vmbr100,link_down=1,tag=10 \
  -net1 virtio=BC:24:11:AA:90:${NN},bridge=vmbr100,tag=20 \
  -net2 virtio=BC:24:11:CC:90:${NN},bridge=vmbr100,tag=450 \
  -net3 virtio=BC:24:11:30:90:${NN},bridge=vmbr100,tag=3000 \
  -ipconfig0 ip=10.10.2.${OCT}/22 \
  -ipconfig1 ip=10.20.2.${OCT}/22,gw=10.20.0.1 \
  -ipconfig2 ip=10.45.2.${OCT}/22 \
  -ipconfig3 ip=10.50.2.${OCT}/22"

if [ "$DRY" = 1 ]; then
    echo "  would run on $PVE:"
    echo "$QMSET" | sed 's/^/      /'
else
    if out=$(pve "$QMSET" 2>&1); then
        ok "MACs and ipconfig set"
    else
        bad "qm set failed: $out"
        die "stopping here; nothing has been started"
    fi
    # Clears the stale [special:cloudinit] section inherited from 469.
    pve "sudo qm cloudinit update $VMID" >/dev/null 2>&1 && ok "cloudinit drive refreshed" \
        || note "cloudinit update skipped (harmless: cloud-init is disabled in the guest)"
fi

# ---------------------------------------------------------------------- boot
step "start it -- expect NO network, and that is the point"
note "netplan inside still matches 469's MACs, so no interface comes up. The"
note "cloned homelab-agent therefore cannot reach the API and cannot rotate"
note "the credential it shares with live 469."

if [ "$DRY" = 1 ]; then
    echo "  would: qm start $VMID, wait for the guest agent, then run the cleanup"
else
    pve "sudo qm start $VMID" >/dev/null 2>&1 || die "qm start $VMID failed"
    ok "started"

    printf '  waiting for the guest agent'
    AGENT_UP=0
    for _ in $(seq 1 30); do
        if pve "sudo qm agent $VMID ping" >/dev/null 2>&1; then AGENT_UP=1; break; fi
        printf '.'; sleep 4
    done
    echo
    [ "$AGENT_UP" = 1 ] || die "the guest agent never answered. Without it there is no
no-network path into this VM; use the PVE console for $VMID."
    ok "guest agent responding (this is our no-network path in)"
fi

# -------------------------------------------------------------------- cleanup
step "remove what belongs to 469, inside the guest, before the network works"

# Built here, base64'd, and run through the guest agent. Base64 because the
# payload crosses ssh -> qm guest exec -> bash and nothing in it should have to
# survive three rounds of quoting.
read -r -d '' SCRIPT <<GUESTSCRIPT
set -u

# (a) THE DANGEROUS ONE FIRST. This credential is byte-identical to the one live
#     469 is using; the agent must never start with it on a working network.
systemctl disable --now homelab-agent 2>/dev/null || true
rm -f /etc/homelab/agent/credential.yml
# config.yml is NOT deleted (agent-reenroll.sh relies on it surviving) but on a
# CLONE it is not this host's own: it still says hostname: prod-homelabvm69 and
# advertise_host: 10.50.2.213. Left alone, this host would register itself into
# api.hosts AS 469 and overwrite the real one's row.
sed -i -e "s|^hostname:.*|hostname: ${HOSTNAME}|" \
       -e "s|^advertise_host:.*|advertise_host: 10.50.2.${OCT}|" \
       /etc/homelab/agent/config.yml
echo "a: homelab-agent disabled, cloned credential removed, config.yml re-identified"

# (b) the metrics stack this clone inherited and must not run
for u in prometheus grafana-server homelab-prometheus-pull.timer; do
    systemctl disable --now "\$u" 2>/dev/null || true
done
DEBIAN_FRONTEND=noninteractive apt-get -y purge \
    homelab-prometheus homelab-grafana prometheus grafana >/dev/null 2>&1 \
    && echo "b: purged prometheus/grafana packages" \
    || echo "b: WARN purge returned non-zero (checked again by --verify)"
rm -rf /var/lib/prometheus /var/lib/grafana /etc/prometheus /etc/grafana \
       /etc/homelab/prometheus /etc/homelab/grafana
# Explicit, because a known postrm bug has left these behind before and a stray
# manifest produces phantom fleet-drift entries.
rm -f /etc/homelab/services/prometheus.yml /etc/homelab/services/grafana.yml
rm -f /etc/nftables.d/10-homelab-prometheus-egress.nft
rm -f /etc/apt/sources.list.d/grafana.list
echo "b: metrics data, configs, manifests, egress rule and grafana apt source removed"

# (c) identity -- every one of these is currently IDENTICAL to 469's
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup >/dev/null 2>&1
rm -f /etc/ssh/ssh_host_*
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive openssh-server >/dev/null 2>&1
echo "$HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
sed -i "s/prod-homelabvm69/${HOSTNAME}/g" /etc/hosts
echo "c: machine-id, ssh host keys, hostname and /etc/hosts are now this host's own"

# (d) network LAST. Both substitutions cover all four interfaces, because every
#     MAC in this file ends ':90:69' and every address ends '2.213/22'.
NP=/etc/netplan/50-cloud-init.yaml
sed -i -e 's/:90:69"/:90:${NN}"/g' -e 's#2\.213/22#2.${OCT}/22#g' "\$NP"
rm -f /etc/netplan/50-cloud-init.yaml.vm68-clone.bak
chmod 600 "\$NP"
if netplan generate 2>&1 && netplan apply 2>&1; then
    echo "d: netplan rewritten and applied"
else
    echo "d: FAIL netplan did not apply -- the guest has no network"
fi
grep -cE ':90:69|2\.213/22' "\$NP" | sed 's/^/d: leftover 469 strings in netplan: /'
GUESTSCRIPT

if [ "$DRY" = 1 ]; then
    echo "  would run this in the guest via qm guest exec:"
    printf '%s\n' "$SCRIPT" | sed 's/^/      /'
    echo
    note "dry run: nothing changed, nothing started."
    exit 0
fi

B64=$(printf '%s' "$SCRIPT" | base64 -w0)
if out=$(pve "sudo qm guest exec $VMID --timeout 600 -- /bin/bash -c 'echo $B64 | base64 -d | bash'" 2>&1); then
    printf '%s\n' "$out" | sed 's/^/      /'
    ok "cleanup script ran"
else
    printf '%s\n' "$out" | sed 's/^/      /'
    bad "guest exec failed -- the VM is running but not converted; use the PVE console"
    exit 1
fi

step "wait for it on its own address"
printf '  waiting for %s:22' "$MGMT"
for _ in $(seq 1 20); do
    if tcp "$MGMT" 22; then echo; ok "answers on $MGMT:22"; break; fi
    printf '.'; sleep 3
done
echo
tcp "$MGMT" 22 || warn "no answer yet on $MGMT:22 -- check netplan via the console:
      ssh $PVE \"sudo qm guest exec $VMID -- /bin/bash -c 'cat /etc/netplan/50-cloud-init.yaml'\""

step "next steps, in this order"
cat <<NEXT
  1. Re-enroll the agent (it was deliberately left unenrolled):
       ./install-orchestrators/agent-reenroll.sh $NN
  2. Check this host and 469 together:
       ./install-orchestrators/vm-clone-finalize.sh $VMID --verify
  3. Only then move to the next clone.
NEXT
echo
echo "  ${D}Nothing here added the NFS mounts, the search package or the firewall${O}"
echo "  ${D}egress rule -- those are Phase 0b in the plan.${O}"
