# homelab-database

Installs/configures PostgreSQL itself and idempotently creates the one
shared `homelab` database every feature's own narrow schema lives
inside. See the repo root `README.md` and `CLAUDE.md` (local,
unpublished) for the full architecture.

## What it does on install

- Detects the newest local PostgreSQL cluster (`pg_lsclusters`).
- Writes an additive `conf.d`/`pg_hba.conf.d` drop-in (never edits the
  vendor's `postgresql.conf`/`pg_hba.conf` directly) — `listen_addresses`
  and allowed CIDR ranges are debconf-configurable
  (`dpkg-reconfigure homelab-database`).
- Idempotently activates `include_dir` in both files if not already
  active (Debian's `postgresql-common` usually does this by default —
  checked first, never duplicated).
- Reloads (never restarts) the cluster.
- Creates the shared `homelab` database if it doesn't already exist.
- Optionally installs a nightly `pg_dump`-based backup cron
  (debconf-gated, off by default).

## High availability (Patroni + etcd + keepalived VIP)

Optional. A single `homelab-database` host is a standalone primary (above).
For automatic failover across 3 nodes, the package also ships the HA tooling
(install-time reproducible, proven on `prod-homelab06/07/08`):

- `/usr/sbin/homelab-database-ha-bootstrap` — run on **each** member to stand
  up the node: a 3-node **etcd** v3 cluster (Patroni's DCS), **Patroni** (uses
  Debian's `pg_createcluster`/`pg_clonecluster` helpers so the cluster matches a
  normal Debian layout), and a **keepalived** VIP that follows the Patroni
  leader. It does **not** load data — a fresh HA cluster comes up empty; load it
  via the normal migration dump/restore against the leader or VIP afterwards.
- Templates in `/usr/share/homelab-database/ha/` (`etcd.env`, `patroni.yml`,
  `keepalived.conf`).

```
# on every member (same --members, each its own --this-node):
homelab-database-ha-bootstrap \
  --members "prod-homelab06:10.50.2.150,prod-homelab07:10.50.2.151,prod-homelab08:10.50.2.152" \
  --this-node "$(hostname -s)" \
  --replication-password '<same-on-all-3>' \
  --vip 10.50.2.130 --app-network 10.50.0.0/22 --yes
# then: patronictl -c /etc/patroni/config.yml list
```

Notes / gotchas learned standing it up:
- **etcd v3 only** — Patroni uses its `etcd3` config block; `vip-manager` 1.0.2
  (Debian) speaks only etcd **v2**, so keepalived (tracking Patroni's REST
  `/leader`, which is 200 only on the leader) does the VIP instead.
- Patroni needs **`python3-etcd`** for the etcd3 DCS — the base `patroni` package
  only depends on `python3-consul`, so etcd users must add it (in `Suggests`).
- The Patroni **scope must be `<version>-<cluster>`** (e.g. `18-main`) or the
  Debian create/clone helpers fail with `invalid version`.
- Apps connect through **pgbouncer → the VIP**, so leader failover is
  transparent. A graceful `patronictl switchover` is ~seconds; an ungraceful
  leader crash promotes a replica within the DCS TTL (~30s).

## Where's `homelab-bootstrap-app-role`?

Moved to **`homelab-common`** (not this package) partway through
building `homelab-api` — every feature needs the bootstrap *client
tool*, but shouldn't need to install (and configure!) an entire local
Postgres server just to get it. See `common/README.md` for its docs and
`common/t/bootstrap-role.t` for its tests; this package is now pure
Postgres provisioning with no Perl code of its own.
