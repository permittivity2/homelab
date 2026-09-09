# homelab-webproxy

nginx + Let's Encrypt reverse proxy for the homelab-* ecosystem. See
the repo root `README.md` and `CLAUDE.md` (local, unpublished) for the
full architecture.

## Usage

Edit `/etc/homelab/webproxy/sites.yml` (seeded from
`config/sites.example.yml` on first install):

```yaml
letsencrypt_email: admin@test.mailmasker.org
sites:
  - domain: drive.test.mailmasker.org
    upstream: 127.0.0.1:2501
```

Then run `homelab-webproxy-apply-sites` — for each site without an
existing vhost, it writes an HTTP vhost, reloads nginx, and runs
`certbot --nginx` to obtain a cert and upgrade the vhost to
HTTPS-with-redirect (certbot also wires up renewal). **Idempotent**:
re-running after adding a new site to `sites.yml` only touches the new
site — existing vhosts (and whatever certbot has since done to them)
are left completely alone, so it never re-requests a cert for an
already-configured domain (Let's Encrypt's real-world rate limits make
that a genuine footgun to avoid, not just a style preference).

## Known blocker on `test-static-internet-ip` (2026-09-09, partially addressed)

Cert acquisition originally failed there: Let's Encrypt's HTTP-01
challenge timed out connecting to port 80
(`Timeout during connect (likely firewall problem)`), and a direct
`curl` to port 3000 from outside earlier had the same symptom.

**Correction to this section's original write-up**: it stated the VM's
own local firewall was "confirmed wide open" based on `ufw inactive` /
`iptables` all-ACCEPT — that check was incomplete. This host actually
runs `nftables` directly (`systemctl status nftables`, config at
`/etc/nftables.conf`), which `ufw`/`iptables` status checks don't see at
all when nft rules aren't installed through either of those front-ends.
The real ruleset had a default-drop `input` chain with a narrow
allowlist that did NOT include 80 or 443 (only DNS/DHCP/NTP/SSH/mDNS/
NetBIOS + established/related traffic) — this host's own firewall was
genuinely part of the blocker, not innocent.

With the user's explicit approval, narrow `nft` allow rules for
25/80/443/587/993/143 were added to `/etc/nftables.conf` and applied
live (2026-09-09) — see `postfix/README.md`'s Gotchas section for the
full change and its (partial) verification. **Not yet confirmed**:
whether an upstream layer (`pve2` host-level or the `pfsense02` VM, both
outside this project's 4-host authorization) still filters these ports
separately — port 53 and 22 were previously reported working from the
real internet, but ad hoc re-testing during this same session gave
inconsistent results for 22 specifically, so treat that prior claim as
unverified rather than re-confirmed. **Needs an independent, genuinely
external test** (the user's own connection, or a third-party port
checker) to know for certain whether 80/443 are now reachable end to
end. Vhost generation and the nginx side of this package are fully
verified working regardless — only the network path from the internet
was ever in question.

## Testing

```bash
prove -I lib t/
```

`t/apply-sites.t` needs no real nginx, certbot, or systemd — it stubs
all three on `PATH` and uses temp directories for
`sites-available`/`sites-enabled`, so it thoroughly exercises the
actual templating/symlinking/idempotency logic without touching the
real system or requesting a real certificate.
