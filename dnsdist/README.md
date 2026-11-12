# homelab-dnsdist

DNS-aware load-balancing edge for the homelab-\* ecosystem, using
PowerDNS's own `dnsdist`.

## Why this exists (and why not raw nftables DNAT)

`homelab-edge-forward` (raw nftables DNAT+SNAT) can move a service off
the public-facing host too, and still exists in this repo as a
general-purpose tool for protocols that don't have a purpose-built
proxy. But for DNS specifically, `dnsdist` is the better fit:

- **Listens directly**, the same model as `homelab-haproxy`'s frontends
  and `homelab-webproxy`'s vhosts -- no kernel `net.ipv4.ip_forward`,
  no DNAT/SNAT, no conntrack/forward-chain rules to get right. All of
  that incidental complexity (and the real bugs it caused: a missing
  `ct state established,related accept`, `ip_forward=0`, overlapping
  nftables includes) simply doesn't exist with this approach.
- **Real active health-checking** with automatic failover across
  backends -- the one thing raw NAT structurally cannot do.
- **Real load-balancing** across multiple backend PowerDNS instances in
  a pool, for backend HA (same idea as the postfix/dovecot HA trios
  elsewhere in this fleet) -- not a substitute for genuine
  multi-nameserver redundancy behind a second public IP, which stays
  DNS's own native mechanism for that (independent NS records).

## Usage

1. `apt install homelab-common homelab-dnsdist`
2. Edit `/etc/homelab/dnsdist/backends.yml` (postinst seeds a starter
   copy from `config/backends.example.yml` on first install):
   ```yaml
   listen_addresses:        # one addLocal() each; "[::]:53" = answer over IPv6 too
     - 0.0.0.0:53
     - "[::]:53"
   servers:
     - 10.50.2.162:53
   check_interval: 10
   check_timeout: 2
   max_check_failures: 3
   rise: 2
   use_proxy_protocol: true
   ```
   Deliberately a flat server list, not multiple named pools: dnsdist
   only routes queries to a named pool if a rule says so, and this
   project has no query-based routing need. Every server here lands in
   dnsdist's real default pool (the one unmatched queries actually
   use) -- found live, the hard way, when an earlier version of this
   script assigned every server a named pool with no routing rule,
   leaving every real client query silently dropped (0 backend
   traffic) while health checks still reported everything "healthy" (a
   server's health check runs directly against it, independent of pool
   routing).
3. `homelab-dnsdist-apply-backends` -- validates with
   `dnsdist --check-config` before ever touching the live config, then
   restarts (dnsdist's own systemd unit ships no `ExecReload=`, so this
   is always a restart, never a reload -- same as PowerDNS's own
   `pdns.service`).

## Public exposure requires an explicit ACL

dnsdist's own built-in ACL only allows RFC1918/loopback/link-local by
default -- a real public-facing authoritative nameserver needs
`acl: ["0.0.0.0/0", "::/0"]` set explicitly in `backends.yml`, or every
external resolver gets silently dropped even though everything else
(backend health, proxy protocol, local queries) works fine. Found
live: a fully-working dnsdist + PowerDNS setup that answered every
internal test correctly still had every real external query
(1.1.1.1, 8.8.8.8, ...) time out until this was added -- the same
public exposure PowerDNS itself already had with no ACL at all before
this package existed, not a new risk.

## IPv6 (post-cutover #64)

`listen_addresses` is a list and gets one `addLocal()` per entry. The edges
carry `0.0.0.0:53` and `"[::]:53"`, so dnsdist answers over both families
on one port (dnsdist sets `IPV6_V6ONLY` on its IPv6 sockets, so the two
wildcards coexist). The wildcard is deliberate: the house IPv6 prefix is a
lease from AT&T, and an address written here would go stale the day the
prefix changes. The backends stay IPv4 on the service plane; an IPv6
client's address reaches PowerDNS inside the PROXY protocol v2 header like
any other, so the Lua steering records see it unchanged. How the edges get
their IPv6 addresses, and the AAAA/glue side, live in
`install-orchestrators/dns-ipv6-orchestrate.sh`.

## PROXY protocol

Every generated backend gets `useProxyProtocol=true` by default, so the
backend sees the real client IP rather than dnsdist's own -- the same
concern `homelab-haproxy`'s `send-proxy` already solves for
postfix/dovecot. The backend PowerDNS must be configured to expect it
(`proxy-protocol-from`, confirmed supported by this project's installed
PowerDNS 5.0.2) or every query gets rejected outright with an explicit
REFUSED (not silently ignored or accepted as a normal query). That
setting takes a real CIDR, not a bare IP -- `10.50.2.144/32`, not
`10.50.2.144` -- found live: a bare IP left the trusted-sender list
effectively empty, so PowerDNS treated dnsdist's own proxy-protocol
header as coming from nobody it trusted and refused every query.

## Fleet-status visibility

Regenerates `/etc/homelab/services/dnsdist.yml` on every run (same
pattern as `homelab-haproxy-apply-backends`): one entry per pool,
`kind: dns-proxy-frontend`, a local `tcp_port` check on dnsdist's own
listen port (same as haproxy's own frontend entries -- this proves
dnsdist itself is up, not that every backend behind it is currently
healthy; dnsdist's own health checks and failover handle that
invisibly to clients), and `fronts` listing the real backend(s)
descriptively.
