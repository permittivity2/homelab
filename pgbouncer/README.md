# homelab-pgbouncer

Configures PgBouncer (`scram-sha-256` auth, a static `userlist.txt`)
fronting the shared `homelab` Postgres database. See the repo root
`README.md` and `CLAUDE.md` (local, unpublished) for the full
architecture.

## `homelab-bootstrap-pgbouncer-entry`

Registers one role's SCRAM secret (as printed by `homelab-database`'s
`homelab-bootstrap-app-role`) into `userlist.txt`:

```bash
homelab-bootstrap-pgbouncer-entry --role homelab_drive_runtime \
    --scram-secret 'SCRAM-SHA-256$4096:...' --pgbouncer-host pgbouncer01
```

**Only ever register a feature's `_runtime` role here — never its
`_migrate` role.** The migrate role connects directly to Postgres,
bypassing pgbouncer entirely, on purpose (see `CLAUDE.md`'s split-role
design) — it's a short-lived, infrequent connection with no pooling
benefit to gain, and this sidesteps pool-mode edge cases with DDL. This
script doesn't enforce that distinction itself; it's a convention every
caller must follow.

Idempotent: re-registering an existing role (e.g. after a credential
rotation) replaces its line in place rather than appending a duplicate.
Same local/SSH/manual-fallback tiering as the role bootstrap tool —
never a stored/network admin credential.

## Testing

```bash
prove -I lib t/
```

`t/bootstrap-entry.t` needs no root or live pgbouncer — the userlist
add-or-replace logic is pure file manipulation, exercised end-to-end
against a temp file. It specifically verifies real SCRAM secrets
(which always contain a literal `$` as a structural separator, e.g.
`SCRAM-SHA-256$4096:salt$storedkey:serverkey`) survive correctly —
an earlier version of this very test had a shell-quoting bug that
silently truncated a secret at its `$`, caught by the test itself
failing rather than by inspection.
