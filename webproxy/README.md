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

## Former blocker on `test-static-internet-ip` — resolved 2026-09-09

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
full change. Ad hoc connectivity tests run from the admin workstation
itself immediately afterward gave inconsistent, inconclusive results
(not a reliable "real internet" vantage point either way — see
`postfix/README.md`), so this was left as unconfirmed.

**Confirmed resolved, definitively**, minutes later: re-running
`homelab-webproxy-apply-sites` succeeded in obtaining real Let's
Encrypt certificates for *both* `drive.test.mailmasker.org` and
`mail.test.mailmasker.org` via the real HTTP-01 challenge — Let's
Encrypt's own servers are about as authoritative an independent external
verifier as exists; there's no more reliable proof that port 80 is
genuinely reachable from the real internet. `curl
https://drive.test.mailmasker.org/` from the admin workstation
afterward got a real `302` (the expected not-logged-in redirect to
`/login` — homelab-drive answering for real, over real HTTPS, with a
real trusted certificate). `https://mail.test.mailmasker.org/` correctly
502s — nginx and the certificate are both fine; there's just no
`homelab-roundcube` backend listening on `127.0.0.1:8080` yet.

This also resolves the "is there a separate upstream blocker at `pve2`/
`pfsense02`" question the postfix Gotcha raised: evidently not, at least
not for port 80 — whatever was blocking it before, this host's own `nft`
ruleset was sufficient to explain the whole thing once corrected.

## Gotcha: nginx's own 1MB body-size default (found 2026-09-09)

A real user hit this live: an ordinary ~1.1MB `homelab-drive` upload
failed with a slow, confusing browser timeout instead of a clear error.
Root cause: `vhost.conf.template` never set `client_max_body_size`, so
every site fell back to nginx's own compiled-in 1MB default — and
because that's the OUTER proxy layer, in front of every backend, it was
also silently making `homelab-roundcube`'s own 25MB attachment limit
(set on its separate internal vhost) unreachable for anything over 1MB,
even though nobody had hit that yet. Fixed with one shared
`client_max_body_size 100m;` in the template, applying to every site
this package manages — nothing here currently needs a genuinely
different limit from any other.

**Existing, already-configured vhosts do NOT pick this up automatically**
— `homelab-webproxy-apply-sites` deliberately never re-touches a vhost
that already has HTTPS configured (see "Idempotent" above; the same
policy that protects against Let's Encrypt rate limits also means a
template improvement like this one doesn't retroactively apply). An
already-live site needs the directive added to its
`/etc/nginx/sites-available/<domain>` file by hand (`sudo nginx -t`
before reloading, always), or the vhost file removed and regenerated
from scratch (which re-requests a cert — mind the rate limits).

This was also a two-layer bug, not just this one: `homelab-drive`'s own
Mojolicious process has an independent, unrelated 16MB default
(`Mojo::Message`'s own `max_message_size`) that would have been hit
next for anything between 16MB and 100MB — see `drive/systemd/
homelab-drive.service`'s `MOJO_MAX_MESSAGE_SIZE` for that half of the
fix. Both ceilings have to be raised together, or whichever is lower
silently wins.

## Testing

```bash
prove -I lib t/
```

`t/apply-sites.t` needs no real nginx, certbot, or systemd — it stubs
all three on `PATH` and uses temp directories for
`sites-available`/`sites-enabled`, so it thoroughly exercises the
actual templating/symlinking/idempotency logic without touching the
real system or requesting a real certificate.
