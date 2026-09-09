# homelab-pgbouncer

Configures PgBouncer (`scram-sha-256` auth, a static `userlist.txt`)
fronting the shared `homelab` Postgres database. See the repo root
`README.md` and `CLAUDE.md` (local, unpublished) for the full
architecture.

## Where's `homelab-bootstrap-pgbouncer-entry`?

Moved to **`homelab-common`** (not this package) partway through
building `homelab-api` — every feature needs the bootstrap *client
tool*, but shouldn't need to install (and configure!) an entire local
pgbouncer server just to get it. See `common/README.md` for its docs
and `common/t/bootstrap-entry.t` for its tests (including the real-SCRAM-
secret-with-a-literal-`$`-survives-correctly regression test); this
package is now pure PgBouncer provisioning with no Perl code of its own.
