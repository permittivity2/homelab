# homelab-edge-forward

DNAT+SNAT port-forwarding from a host's public IP to an internal
backend, for the homelab-\* ecosystem.

## Why this exists

`homelab-haproxy` already decouples "holds the public IP" from "runs
the actual service" for TCP -- but it's structurally unable to do the
same for UDP (see its own package description), which rules it out for
DNS, the first real user of this package. This package fills that gap
with real kernel-level DNAT+SNAT via nftables, not plain interface
forwarding: the backend host has no public IP of its own, so a naive
forward (no NAT) would leave it trying to reply directly to the
internet with no valid public source address. SNAT rewrites the source
back to this host's own address so replies route back through it
correctly.

## Usage

1. `apt install homelab-common homelab-edge-forward`
2. Edit `/etc/homelab/edge-forward/forwards.yml` (postinst seeds a
   starter copy from `config/forwards.example.yml` on first install):
   ```yaml
   public_interface: eth5
   snat_to: 10.50.2.144
   forwards:
     - name: dns
       protocols: [udp, tcp]
       public_port: 53
       backend_host: 10.50.2.162
       backend_port: 53
   ```
3. `homelab-edge-forward-apply` -- validates with `nft -c -f` before
   ever touching the live ruleset, then applies.

## What it does NOT do

- **No load-balancing across multiple backends behind one forward.**
  When real redundancy is needed (e.g. a second public IP), stand up
  an independent second host with its own public IP and its own DNS
  NS record -- that's DNS's own native redundancy mechanism, and it's
  simpler and more standard than hiding multiple backends behind one
  forwarded IP.
- **No automatic cleanup of a removed forward's accept rule** in the
  shared `/etc/nftables.conf` (only the self-contained
  `/etc/nftables.d/50-edge-forward.conf` fragment is truly
  wholesale-regenerated). The orphaned accept line is harmless dead
  code once its matching DNAT rule is gone from the fragment -- see
  the script's own header comment.

## Fleet-status visibility

Regenerates `/etc/homelab/services/edge-forward.yml` on every run
(same pattern as `homelab-haproxy-apply-backends`), so
`homelab-cli admin fleet status`/`fleet drift` shows one row per
forward: `kind: udp-nat-forward`, a description stating explicitly
that this is DNAT+SNAT with no load-balancing, and a real
`remote_tcp_port` health check against the actual backend host:port
(not a local-only check, which would prove nothing about whether the
forward path actually works).
