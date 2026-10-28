#!/bin/bash
# edge-standby-provision.sh <target-mgmt-ip>
#
# Provision a standby internet-facing edge node (prod-homelab01/02) to mirror
# the active edge prod-homelab00, so it is ready to be powered on in 00's
# place. Idempotent; re-runnable.
#
# The edges are MANUAL one-at-a-time: exactly ONE of 00/01/02 is powered on,
# and it picks up the public .66/.68 by DHCP from the AT&T reservations keyed
# to its eth7/eth6 MACs. There is no auto-failover and no keepalived -- that
# was removed on purpose (it could not give flush-free failover for
# pfSense-routed clients). "Standby" here means "cloned and ready to boot".
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
# NO homelab-keepalived: the edges are deliberately MANUAL one-at-a-time now
# (exactly one of 00/01/02 powered on, both public addresses arriving by DHCP
# from the AT&T reservations), and keepalived was purged from all three. Putting
# it back on a new standby would quietly re-introduce the auto-failover that was
# removed on purpose.
ssh "$TGT" 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    homelab-webproxy homelab-haproxy homelab-dnsdist homelab-certsync 2>&1 | tail -8
  echo "installed:"; dpkg-query -W homelab-webproxy homelab-haproxy homelab-dnsdist homelab-certsync'

say "[2/5] pull configs + certs from $SRC (as root, preserving perms/symlinks)"
ssh "$SRC" "sudo tar -C / -cf - $CLONE_PATHS" > "$STAGE/edge.tar"
echo "  staged $(du -h "$STAGE/edge.tar" | cut -f1) from $SRC"

say "[3/5] push configs onto $TGT"
cat "$STAGE/edge.tar" | ssh "$TGT" 'sudo tar -C / -xf - && echo "  unpacked edge configs + certs"'

say "[4/5] edge firewall drop-in (mail in + plex egress) + ensure include + reload"
ssh "$TGT" 'set -e
  # base include present? (so drop-ins load at boot)
  grep -q "include \"/etc/nftables.d/\*\"" /etc/nftables.conf || \
    { echo "include \"/etc/nftables.d/*\"" | sudo tee -a /etc/nftables.conf >/dev/null; echo "  added nftables.d include"; }
  # ADDITIVE edge delta: open the mail ports on input (53/80/443 already open
  # on this node; keep its own :22). The cloned 60-plex-egress.nft handles the
  # plex output rule.
  sudo tee /etc/nftables.d/20-edge-public.nft >/dev/null <<'"'"'NFT'"'"'
# Managed by edge-standby-provision.sh -- edge deltas, ADDITIVE to the base
# chains (the node keeps its own :22 accept for mgmt SSH).
#  - input: open the mail ports (53/80/443 already open in the base)
#  - output: allow egress to the plex backend (10.10.0.106:32400 is on the
#    10.10 data plane, not covered by the base intra-fleet accepts)
add rule inet filter input tcp dport { 25, 143, 587, 993 } accept comment "homelab-edge-mail-in"
add rule inet filter output ip daddr 10.10.0.106 tcp dport 32400 accept comment "homelab-plex-egress"
NFT
  # atomic reload of base + all drop-ins (no live public traffic on a standby,
  # so a flush+reload here is safe and avoids duplicate appended rules)
  sudo nft -f /etc/nftables.conf
  echo "  firewall reloaded; public input now:"; sudo nft list chain inet filter input | grep -E "dport|plex" | head'

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
echo; echo "== done: $TGT provisioned as a standby edge (no public IP yet; keepalived next) =="
