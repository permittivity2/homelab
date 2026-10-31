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

## Audits (they change nothing)

Two scripts only look and report. Exit 0 means clean, 1 means findings.

| Script | Answers |
|---|---|
| `fleet-version-audit.sh` | is every node running what the apt repo publishes? |
| `fleet-permission-audit.sh` | can anything read or destroy data it has no business touching — or is anything so tight the service that needs it cannot? |

`fleet-permission-audit.sh` was written the day after the drive blob store was
found at **0777** — every local uid on a drive node could list all 30,512 of a
user's files and, because write permission on a *directory* is what authorises
unlink, delete them. In the same hour the opposite failure turned up in the
same directory: blobs over 256 KB were landing in the wrong group, so
`homelab-search` got `EACCES` and told users their photos were "no longer on
disk". Both had been true for months. Both were found by a person clicking a
link, not by a check.

The generalisation is the point: permissions on a shared store are a fleet
invariant, not a per-package detail, and an invariant nobody measures is a
wish. Its rules deliberately judge the *property* rather than the filename —
the first version flagged every service manifest as a leaked secret, and a
check that cries wolf twelve times per node is worse than no check, because it
teaches you to skip it.

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
