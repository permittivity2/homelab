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

## Where's `homelab-bootstrap-app-role`?

Moved to **`homelab-common`** (not this package) partway through
building `homelab-api` — every feature needs the bootstrap *client
tool*, but shouldn't need to install (and configure!) an entire local
Postgres server just to get it. See `common/README.md` for its docs and
`common/t/bootstrap-role.t` for its tests; this package is now pure
Postgres provisioning with no Perl code of its own.
