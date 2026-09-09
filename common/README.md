# homelab-common

Shared foundation library for every `homelab-*` feature package. See the
repo root `README.md` and `CLAUDE.md` (local, unpublished) for the full
architecture this implements.

## Modules

- **`Homelab::Common::Config`** — `load_config($env_var, $default_path)`.
  The one config-loading pattern every package used to hand-roll
  separately.
- **`Homelab::Common::DB`** — `pg_url(%opts)` builds a
  `postgresql://` URL (percent-encoding user/password correctly);
  `runtime_pg(%opts)` returns a `Mojo::Pg` handle for the day-to-day,
  DDL-less `<feature>_runtime` role (through pgbouncer); `migrate_dbh(%opts)`
  returns a plain `DBI` handle for the `<feature>_migrate` role (direct
  to Postgres, bypassing pgbouncer — see `CLAUDE.md`'s split-role
  design).
- **`Homelab::Common::Registry`** — `register(%opts)` /
  `lookup($feature, %opts)`. The service registry itself lives inside
  `homelab-api`'s own schema; every other feature reaches it over HTTP
  (these two calls), never via a direct cross-schema DB grant.
  `homelab-api`'s own address is never looked up this way — every
  feature gets it from its own local bootstrap config, same as DB
  credentials.
- **`Homelab::Common::Queue`** — `new_minion(%opts)` returns a
  Postgres-backed `Minion` instance for async/fan-out work. Namespace
  task names by owning feature (`drive.thumbnail`, `backup.reconcile`).
- **`Homelab::Common::Migrate`** — `run_migrations(%opts)` applies a
  feature's `migrations/NNN-description.sql` files, each in its own
  transaction, tracked in a per-schema `schema_migrations` table. Must
  be called with a `migrate_dbh`, never a `runtime_pg` connection.
- **`Homelab::Common::Health`** — `mount_health_route($app, %opts)`
  mounts a standard `GET /health` on a Mojolicious app, with an
  optional deeper `check` coderef.

## Testing

```bash
prove -I lib t/
```

`t/db.t` and `t/migrate.t` skip their live-connection tests unless
`HOMELAB_COMMON_TEST_DB_HOST` (+ `_NAME`/`_USER`/`_PASSWORD`, and
optionally `_PORT`) are set, pointed at a scratch Postgres database —
`migrate.t` creates and drops its own throwaway schema, safe to run
against a real instance. `t/registry.t` and `t/health.t` need no live
infrastructure at all.
