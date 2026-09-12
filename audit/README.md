# homelab-audit

System-wide audit trail for the `homelab-*` ecosystem: "what did user X
do, when, from where, via which client" — self-service for your own
history, `audit.view`-capability-gated (or `site_admin`, which always
has it — see `api/migrations/008-role-permissions.sql`) for anyone
else's.

## Architecture: this service never sits on the write path

Every `homelab-*` service already holds a direct Postgres connection to
the one shared `homelab` database (via pgbouncer). Producing a
mutation's audit record is a plain, synchronous `INSERT INTO
audit.queue` on that *same* connection — `Homelab::Common::AuditClient::
enqueue($db, %fields)` — using a narrow, **INSERT-only** grant (no
SELECT/UPDATE/DELETE). If that insert fails, the mutating action fails
too, deliberately: this design puts audit durability on "is Postgres
up" (already a hard dependency for everything) rather than "is a
separate service up." There is no `eval`/best-effort wrapper around
`enqueue()` anywhere it's called — that's not an oversight.

This service's only job is the *consumer* side: a recurring timer
(same `FOR UPDATE SKIP LOCKED` claim idiom as `homelab-worker`'s job
claim and `homelab-domain-admin`'s DKIM/PowerDNS timers) drains
`audit.queue` in batches, normalizes each entry's free-text
`action`/`resource_type` into `action_type_id`/`resource_type_id`
(`audit.action_types`/`audit.resource_types`, both find-or-create), and
inserts into the real, partitioned `audit.entries` fact table. If this
service is down, queued rows simply accumulate untouched in
`audit.queue` until it's back — nothing is lost, nothing blocks.

## Schema

`audit.queue` is small and transient by design (rows live for at most
one consumer tick) — a raw JSONB payload, no normalization on the hot
path. `audit.entries` is partitioned by month on `occurred_at` — 24
months of partitions are pre-created by migration
(`migrations/002-more-partitions.sql`), not by the running service
itself: creating a partition is DDL, and this app's own runtime role
deliberately never holds DDL privileges (the split-role design's whole
point). Extending further into the future, when needed, is a new
migration file — the same bounded, occasional operational task this
project already accepts for retention/cleanup below. Partitioning
matters here because both real query shapes ("what did user X do",
"what happened in this window", or both) benefit from partition
pruning, and it's what makes a future retention/cleanup job
(a DBA decision, explicitly out of scope for this project) cheap —
`DROP` an old partition instead of a slow bulk `DELETE` + vacuum.

## What counts as an audit event

A mutating/state-changing action that flows through a `homelab-*`
service we actually control. Not included: reads (nobody needs a trail
of who *looked at* something), or anything that never touches our own
code at all — IMAP activity, inbound mail delivery, Roundcube's own
direct SMTP submission to Postfix. Auditing those would mean
instrumenting Dovecot/Postfix directly, a separate, much larger effort.

## Read API

`GET /internal/v1/audit/log?user=<email>&since=<ts>&until=<ts>&action=<name>`,
fronted by `homelab-api`'s `/api/v1/audit/*` gateway route. Self-scoped
by default (an ordinary caller can only ever see their own
`user_email`, regardless of `?user=`); `site_admin` or a role explicitly
granted the `audit.view` capability may query any user, or all users if
`?user=` is omitted.

## Adding a new producer

Any service that wants to emit audit events needs: (1) `Homelab::
Common::AuditClient::enqueue($db, ...)` called right alongside its
mutation (same transaction, when one is already open), and (2) a
`GRANT INSERT ON audit.queue TO "<its runtime role>"` added to *its
own* postinst/bootstrap — see `drive/debian/postinst`, `domain-
admin/debian/postinst`, `api/debian/postinst` for the pattern (a short
`homelab-audit-grant-queue-insert --role ... --db-host ...` call,
shipped by `homelab-common`, idempotent, fails loudly with a clear
message if `homelab-audit` isn't installed/migrated yet rather than
silently granting onto a table that doesn't exist).
