# install-orchestrators

Operator scripts that install and wire up the `homelab-*` packages across the
fleet. Each one is run **from the admin workstation**, not on a fleet node, and
drives the target nodes over passwordless `ssh` + `sudo`.

They exist because the install order and the debconf answers for a multi-host
tier are not derivable from the packages alone — which node gets which role,
which VIP a tier advertises, what has to exist before the next step can
succeed. That sequencing is the part that is expensive to reconstruct, so it
lives here rather than in anyone's shell history.

## Conventions

- `h NN` expands to `prod-homelabNN`. Fleet addressing is
  `10.20.2.(144+NN)` for management/ssh and `10.50.2.(144+NN)` for service
  traffic.
- `*-orchestrate.sh` installs and configures a whole tier; `*-setup.sh` /
  `*-provision.sh` do one node or one piece of infrastructure.
- Scripts are re-runnable where practical, and log to a file they name on
  startup.

## Credentials

**No credential is stored in this directory.** Anything secret is read at
run time from the host that already owns it — SCRAM hashes out of
`pg_authid.rolpassword` on the database primary, the SSO client secret out of
`/etc/homelab/sso/config.yml`, the PowerDNS API key out of
`/etc/homelab/domain-admin/config.yml`. Nothing is echoed into a tracked file.

The PGP block in `svc-hosts-orchestrate.sh` is the apt repository's **public**
signing key (`Silver Linings, LLC <packages@thedude.vip>`); distributing it is
its purpose.

Two scripts take an environment variable rather than carrying a value:

| Variable | Used by | Without it |
|---|---|---|
| `SMOKETEST_PW` | `migration-readiness-test.sh` | the login keystone check skips |
| `EXT_TEST_ADDR` | `migration-readiness-test.sh` | printed mail round-trip instructions show a placeholder |

```sh
SMOKETEST_PW='...' EXT_TEST_ADDR='you@example.com' ./migration-readiness-test.sh
```

Both were previously literals edited into the script before a run — a password
placeholder and a personal address. Pass them per-run instead; this is a public
repository.

## A caution

These act on real hosts. `edge-standby-provision.sh` in particular clones a
live edge node's configuration onto another node, and the edge is deliberately
**manual one-at-a-time** (exactly one of `prod-homelab00/01/02` powered on,
public addresses arriving by DHCP from the AT&T reservations). It installs no
`keepalived` on purpose — putting it back would quietly re-introduce the
auto-failover that was removed deliberately.
