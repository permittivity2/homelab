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
| `fleet-running-audit.sh` | is every node RUNNING what it should, and nothing else? (post-cutover #32) |
| `fleet-os-upgrade.sh` | the deliberate OS-package sweep: one node at a time, `apt-get upgrade` only, apps restarted so the new libc/perl run, the same checks as pkg-upgrade plus the running audit (post-cutover #97) |
| `fleet-reboot.sh` | reboot guests ONE AT A TIME through pve2 with prechecks (a patroni leader is switched over first), a graceful reboot, and after it: mounts, services, failed units, addresses and VIPs, the agent, patroni, an edge from offsite, the running audit (post-cutover #98) |
| `pve-storage-wave1.sh` | move the first member of every pool (and 445 446 453 469) from the spinning pool to the NVMe, one guest at a time: containers by shutdown → `pct move-volume` (source kept until the guest is back with every unit) → start → verify; VMs by an online `qm disk move`, the dead cloud-init CD detached; `--dry-run`, `--apply NN …`, `--verify` (post-cutover #41, waves plan step 2) |
| `pve-boot-order.sh` | the fleet's boot order on pve2 as Proxmox settings ONLY (`onboot` + `startup=order,up,down` per guest, nothing else on the hypervisor): `--dry-run` (the table, records today's values), `--apply`, `--undo FILE`, `--verify`, `--runbook` (the scheduled reboot's steps), `--after-boot` (every expected guest running, the startall task log, agents, patroni, VIPs, the NFS-bound services by name, the audits, alerts) (post-cutover #41) |
| `nfs-mounts-orchestrate.sh` | the NFS stores of dovecot (62-64), drive (65-67) and search (70-72): fstab lines `hard,nofail`, a `BindsTo` drop-in beside each service (the package unit carries `RequiresMountsFor`), the `boot-mounts.d` list for `homelab-mount-retry`, the stale vm69 metrics lines gone from the search hosts; `--dry-run`, `--apply`, `--verify` (post-cutover #41 F/G/H) |
| `db-unit-policy.sh` | the patroni/etcd override files on 06/07/08 (restart on failure after 5 s, patroni stops within 240 s and after etcd), written + daemon-reload, no restarts; `--verify` (post-cutover #41 I) |
| `journald-cap-orchestrate.sh` | the journal cap on the fleet VMs (62-67, 69-72): the drop-in sets every size (`SystemMaxUse=256M SystemMaxFileSize=32M SystemMaxFiles=8`, because the template's main `journald.conf` says `SystemMaxFileSize=1G` and journald raises the cap to twice that, so `SystemMaxUse=256M` alone capped nothing: 2 GB on vm69), journald restarted + rotated + vacuumed, the template's stale `/var/log/journal/<old machine-id>/` directories removed; `--dry-run`, `--apply`, `--verify` (post-cutover #104) |
| `unattended-upgrades-orchestrate.sh` | unattended SECURITY updates on the containers (never the DB tier or the edges): install where missing, `--verify` dry-runs the tool on every node (#97) |
| `fleet-permission-audit.sh` | can anything read or destroy data it has no business touching — or is anything so tight the service that needs it cannot? |

`fleet-running-audit.sh` is the half a version check cannot do. prod-homelab39
reported the right version of every homelab package the whole time it ran a
stray pgbouncer left over from before the cutover, and a VM's drive package sat
two versions behind until an upgrade swept it up. This one reads, on every
node, the installed packages with their dependencies, every systemd unit with
its state and owning package, every listening socket with the unit behind it,
and the agent's manifests, then judges them: a homelab package (or a stock
daemon one of them pulls in) whose enabled unit is not running, a manifest
whose unit is down or whose port has no listener, a failed unit = MISSING; a
daemon no installed homelab package needs (loopback-only or not), a homelab
unit running without its package, an exposed listener nothing explains, a
stray manifest = UNEXPECTED; masked or removed-not-purged leftovers = warnings;
a watched distro package at two versions = DRIFT. "Expected" is derived from
what is installed (plus Depends/Recommends, followed through); under #31 only
`expected_packages` changes. `--selftest` proves each rule on crafted
snapshots, `KEEP=DIR` keeps the per-node snapshot and `--from DIR` judges it
again without ssh, so every finding is reproducible from files. The header
lists the false positives it was built to avoid; add to those lists
deliberately, never silently.
A DRIFT line in the day after a security release is the containers' staggered
unattended-upgrades runs catching up; the edges and the DB tier never
auto-update, so when they are the lagging ones run `fleet-os-upgrade.sh` on
them.

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
| `TEST_ACCOUNT_PW_FILE` | `mail-reply-alias-orchestrate.sh` (via `files/mail-reply-alias-check.py`), `smtps-orchestrate.sh` (via `files/smtps-check.py`, which runs on offsite and reads the password from its stdin), `opendkim-keys-orchestrate.sh` (one signed message per node through the same checker) | a default path on the admin workstation is tried; the file holds the test account's password and is read by the checker itself, never passed as an argument |

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
