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

## Known blocker on `test-static-internet-ip` (2026-09-09)

Cert acquisition fails there right now: Let's Encrypt's HTTP-01
challenge times out connecting to port 80
(`Timeout during connect (likely firewall problem)`), and a direct
`curl` to port 3000 from outside earlier had the same symptom. The
VM's own local firewall is confirmed wide open (`ufw inactive`,
`iptables` all-ACCEPT) — port 53 (DNS) and 22 (SSH) both work fine from
the real internet, so this is a port-specific allowlist further
upstream (likely the `pfsense02` VM on `pve2`, or `pve2`'s own
host-level firewall for this VM), outside the four hosts this project
has standing authorization to modify. **Needs the user to open 80/443
inbound to this host's public IP** before real certificate issuance
(and public HTTPS access generally) can be verified end-to-end. Vhost
generation and the nginx side of this package are fully verified
working — only the network path from the internet is blocked.

## Testing

```bash
prove -I lib t/
```

`t/apply-sites.t` needs no real nginx, certbot, or systemd — it stubs
all three on `PATH` and uses temp directories for
`sites-available`/`sites-enabled`, so it thoroughly exercises the
actual templating/symlinking/idempotency logic without touching the
real system or requesting a real certificate.
