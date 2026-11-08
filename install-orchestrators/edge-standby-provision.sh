#!/bin/bash
# edge-standby-provision.sh <target-mgmt-ip>
#
# Provision a standby internet-facing edge node (prod-homelab01/02) to mirror
# the active edge prod-homelab00, so it is ready to be powered on in 00's
# place. Idempotent; re-runnable.
#
# EDGE MODEL (item 44): since 2026-11-06 all three edges run at once, each
# with its own public address by DHCP from the AT&T reservation keyed to its
# MAC (00=.66, 01=.67, 02=.68) and the public names listing all three in DNS.
# There is no public-address failover. Only the internal 10.50.2.140 floats,
# via homelab-keepalived (edge-vip-orchestrate.sh). The name "standby" is
# historical: it now means "a freshly cloned edge, ready to be given its own
# MAC and public address and brought into service".
#
# What it does on the target:
#   1. installs the edge package stack (webproxy/haproxy/dnsdist/certsync)
#   2. clones node 00's web/haproxy/dnsdist configs + Let's Encrypt certs
#      (workstation-mediated tar stream -- NO guest-to-guest SSH)
#   3. adds the edge firewall deltas as a drop-in (mail ports in, plex egress
#      out) -- ADDITIVE, so the target keeps its own :22 mgmt-SSH accept
#   4. (re)starts nginx/haproxy/dnsdist and verifies them addressed directly
#
# What it does NOT do: assign any public IP. The node gets .66/.68 by DHCP
# when it is the one powered on -- see the per-node networkd drop-ins in /etc.
#
# Certs are NOT a one-time copy any more: homelab-certsync pulls the
# current certificate for every configured lineage from the central store at
# boot and hourly, so a standby that has been powered off for weeks catches up
# on its own. etc/letsencrypt is still cloned so the node can serve TLS on its
# very first boot, before certsync's first run.
set -euo pipefail

SRC=10.20.2.144                 # prod-homelab00 (reference active edge)
TGT="${1:?usage: edge-standby-provision.sh <target-mgmt-ip>}"
SVC_IP="${2:-}"                 # optional: target's 10.50 service IP, for verify
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# etc/homelab/certsync is LOAD-BEARING and was missing: without it a freshly
# cloned standby has the certs it was given and no mechanism to ever refresh
# them -- it would serve an expired chain the first time it was promoted after
# ~90 days, silently.
CLONE_PATHS="etc/letsencrypt etc/nginx/sites-available etc/nginx/sites-enabled etc/nginx/conf.d etc/haproxy etc/dnsdist etc/homelab/webproxy etc/homelab/haproxy etc/homelab/dnsdist etc/homelab/certsync"

say(){ echo; echo "== $* =="; }

say "[1/5] install edge stack on $TGT"
# NO homelab-keepalived here: it is installed and configured afterwards by
# edge-vip-orchestrate.sh, which owns the internal 10.50.2.140 address and its
# per-node priority. Public addresses never float.
ssh "$TGT" 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    homelab-webproxy homelab-haproxy homelab-dnsdist homelab-certsync homelab-nginx-exporter 2>&1 | tail -8
  echo "installed:"; dpkg-query -W homelab-webproxy homelab-haproxy homelab-dnsdist homelab-certsync homelab-nginx-exporter'

say "[2/5] pull configs + certs from $SRC (as root, preserving perms/symlinks)"
ssh "$SRC" "sudo tar -C / -cf - $CLONE_PATHS" > "$STAGE/edge.tar"
echo "  staged $(du -h "$STAGE/edge.tar" | cut -f1) from $SRC"

say "[3/5] push configs onto $TGT"
cat "$STAGE/edge.tar" | ssh "$TGT" 'sudo tar -C / -xf - && echo "  unpacked edge configs + certs"'

say "[4/5] edge firewall: the live edge's base file + the canonical plex drop-in, then reload"
# The three edges' firewall files must be IDENTICAL (edge-firewall-unify.sh
# checks that; edge-rotate.sh lists any difference as drift). The base file
# /etc/nftables.conf already opens the mail ports and keeps SSH closed on
# every edge since 2026-11-02, so it is cloned from the source as it is, and
# the only drop-in of the edge's own is 60-plex-egress.nft (one uncommented
# rule, files/edge-60-plex-egress.nft). Until 2026-11-08 this step wrote a
# 20-edge-public.nft with a mail-in accept and a commented plex rule instead,
# which is exactly the drift unify.sh removed.
ssh "$SRC" "sudo cat /etc/nftables.conf" > "$STAGE/nftables.conf"
[ -s "$STAGE/nftables.conf" ] || { echo "could not read /etc/nftables.conf from $SRC"; exit 1; }
grep -q 'include "/etc/nftables.d/\*"' "$STAGE/nftables.conf" || { echo "the source base file has no nftables.d include -- stopping"; exit 1; }
ssh "$TGT" 'sudo tee /etc/nftables.conf >/dev/null' < "$STAGE/nftables.conf"
ssh "$TGT" 'sudo tee /etc/nftables.d/60-plex-egress.nft >/dev/null && sudo chmod 644 /etc/nftables.d/60-plex-egress.nft' \
    < "$(dirname "$0")/files/edge-60-plex-egress.nft"
ssh "$TGT" 'set -e
  sudo rm -f /etc/nftables.d/20-edge-public.nft
  # atomic reload of base + all drop-ins (no live public traffic on a standby,
  # so a flush+reload here is safe and avoids duplicate appended rules)
  sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
  echo "  firewall reloaded; public input now:"; sudo nft list chain inet filter input | grep -E "dport" | head
  echo "  plex egress:"; sudo nft list chain inet filter output | grep -F 10.10.0.106'

say "[5/5] free :53 for dnsdist + (re)start & verify edge services on $TGT"
ssh "$TGT" 'set -e
  sudo nginx -t
  # dnsdist binds 0.0.0.0:53 -> must free systemd-resolved stub listener.
  # Safe: the node resolves via /etc/resolv.conf (nameserver 10.20.0.140),
  # not the 127.0.0.53 stub, so disabling it does not break the nodes own DNS.
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf "[Resolve]\nDNSStubListener=no\n" | sudo tee /etc/systemd/resolved.conf.d/10-no-stub.conf >/dev/null
  sudo systemctl restart systemd-resolved
  sudo systemctl enable --now nginx haproxy dnsdist >/dev/null 2>&1 || true
  sudo systemctl restart nginx haproxy dnsdist
  for s in nginx haproxy dnsdist; do printf "  %s: %s\n" "$s" "$(systemctl is-active $s)"; done'

if [ -n "$SVC_IP" ]; then
  say "verify serving (addressed directly at $SVC_IP, no VIP needed)"
  ssh "$TGT" "
    echo -n '  nginx mail vhost : '; curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: mail.mailmasker.org' https://127.0.0.1/ --max-time 8
    echo -n '  haproxy :993     : '; (echo 'a LOGOUT' | timeout 8 openssl s_client -connect 127.0.0.1:993 -quiet 2>/dev/null | head -1)
    echo -n '  dnsdist :53      : '; dig +short +time=5 +tries=1 @127.0.0.1 mailmasker.org SOA 2>&1 | head -1
  "
fi
echo; echo "== done: $TGT provisioned as a standby edge (no public IP yet; give it a MAC, then run edge-vip-orchestrate.sh) =="
