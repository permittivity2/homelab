# Homelab

A self-hosted "homelab" service ecosystem — mail, identity/SSO, file
storage, DNS, backups, and more — built as a family of independent
`homelab-*` Debian packages that share a common Perl foundation instead
of duplicating config/database/queue plumbing in each one.

This is a ground-up rebuild of an earlier, private package family,
applying lessons learned there (see `CLAUDE.md` in the local project
root for the full writeup — not published here). No feature is
half-migrated from that project; everything here is built fresh.

## How this repo is organized

Every top-level directory is its own Debian package / Perl (or, for
`cli`, Python) distribution:

- **`common/`** — `homelab-common`, the shared library every other
  feature depends on: config loading, database connections (runtime
  *and* migration roles), service-registry client, job-queue helper,
  schema-migration runner, health-check helper. Build and install this
  first.
- **`database/`**, **`pgbouncer/`**, **`dns/`** — foundation
  infrastructure (PostgreSQL, PgBouncer, PowerDNS provisioning).
- **`api/`**, **`sso/`** — identity, RBAC, and the service registry;
  OIDC.
- **`postfix/`**, **`dovecot/`**, **`roundcube/`** — mail.
- **`webproxy/`** (nginx), **`haproxy/`** — edge/routing.
- **`drive/`**, **`backup-client/`**, **`backup-server/`** —
  storage/ops.
- **`worker/`** — `homelab-worker`, a generic, host-independent
  background-job engine (long-running work like zip-building, submitted
  over HTTP by any other feature) — see its own README for the job-type
  extension model.
- **`dhcp/`**, **`chat/`**, **`call/`** — extensibility proof: minimal
  scaffolded stubs proving a brand-new feature type needs no core
  changes to join the ecosystem. Not fully built out — see each
  package's own README for current status.
- **`cli/`** — `homelab-cli`, a command-line client for `homelab-api`.

## Architecture, in short

- **Every feature is its own package/process/systemd unit.** There is
  no unified listener — fault isolation is deliberate.
- **Synchronous calls** between features go over plain HTTP, with the
  destination looked up from a small service-registry table (never
  hardcoded IPs).
- **Asynchronous/fan-out work** goes through a durable, Postgres-backed
  job mechanism (`SELECT ... FOR UPDATE SKIP LOCKED` + a
  `Mojo::IOLoop->recurring` timer, not a separate queue library) —
  needs no infrastructure beyond the Postgres you already have. Long-
  running work (e.g. building a zip archive) is submitted to
  `homelab-worker`, a small, generic, host-independent job-runner
  service rather than run in-process inside whatever feature needs it —
  see `worker/README.md`.
- **Each feature owns a narrow Postgres schema**, with two roles: a
  CRUD-only runtime role (what the running service holds) and a
  separate CRUD+DDL migration role (used only transiently at
  install/upgrade time, never held by the long-running process).

## Building

```bash
cd .. && ./build-package.sh common 0.1.0 -y   # build the shared library first
./build-package.sh database 0.1.0 -y
# ...
./build-package.sh all 0.1.0 -y               # or build everything, in dependency order
```

See `build-package.sh --help` for full usage.

## Testing

Each package has its own unit test suite (`t/` for Perl packages,
`tests/` for the Python `cli` package). The cross-feature regression
suite lives in `tests/e2e/` — see `tests/e2e/README.md`.
