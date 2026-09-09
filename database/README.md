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

## `homelab-bootstrap-app-role`

Creates a **pair** of Postgres roles + a schema for one homelab-*
feature — see `CLAUDE.md`'s split-role design:

```bash
homelab-bootstrap-app-role --feature homelab_drive --schema drive --db-host database01
```

Prints `RUNTIME_ROLE=`/`RUNTIME_PASSWORD=`/`RUNTIME_SCRAM_SECRET=` and
`MIGRATE_ROLE=`/`MIGRATE_PASSWORD=`/`MIGRATE_SCRAM_SECRET=` on success.
Never uses a stored or network admin Postgres credential — only
OS-level peer auth (`sudo -u postgres`), tried local first, then over
SSH (if trust already works), then a printed-SQL manual fallback.

The runtime role gets CRUD only (no DDL) on the schema; the migrate
role gets CRUD+DDL on the same schema only, meant to be used
transiently by a feature's `postinst` via
`Homelab::Common::Migrate::run_migrations` — never held by the running
service. **Critical detail verified by `t/bootstrap-role.t`**: the
default-privileges grant that lets the runtime role automatically see
tables the migrate role creates *after* bootstrap must say
`ALTER DEFAULT PRIVILEGES FOR ROLE "<migrate_role>" ...` — omitting
`FOR ROLE` silently scopes it to whatever role ran the bootstrap script
itself (`postgres`) instead, and the runtime role would never actually
get access to anything created later. This exact bug was caught by
testing against a real Postgres, not by inspection.

## Testing

```bash
prove -I lib t/
```

`t/bootstrap-role.t` needs `HOMELAB_DATABASE_TEST_LIVE_BOOTSTRAP=1` and
passwordless `sudo` to the `postgres` user on a real local cluster with
a `homelab` database already created — it bootstraps a throwaway
feature, verifies the exact grant behavior above, and cleans up after
itself.
