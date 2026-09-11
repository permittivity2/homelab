# homelab-worker

Centralized, host-independent background-job engine for the `homelab-*`
ecosystem. Executes long-running work submitted by any other feature
over HTTP, fronted by `homelab-api`'s `/api/v1/jobs/*` gateway route the
same way `homelab-mailbridge` backs `/api/v1/mail/*` (that gateway route,
plus `homelab-drive`'s own zip-job submission routes and
`homelab-cli`'s `jobs` command tree, are later phases of the same
approved plan -- **not** included in this package's own release, see
"What this release does and doesn't include" below).

## Why this exists

`homelab-drive`'s bulk-select "zip and download" feature needs to build
potentially large archives without blocking a web request. The first
design ran the zip build as a subprocess forked directly inside
`homelab-drive` itself -- rejected during planning as bad architecture:
zip-building is not really a `drive` concern, and any future "this could
take a while" need in this ecosystem (SHA1 hashing, image resizing,
video transcoding, bundling a user's entire account export) would have
had to reinvent the same in-process mechanism again. This package is the
generalization: one small, registry-registered service that knows how to
run *any* job type, may live on a completely separate host from whatever
feature submits work to it, and treats "add a new capability" as "add
one new Perl module," not a core-engine change.

## Deployment topology

No co-location requirement, unlike `homelab-domain-admin` (which must
share a host with OpenDKIM for private-key-material reasons). This
service's own storage (`storage_path`) is local to wherever it runs --
callers never assume a shared filesystem with it, only HTTP. On
`test-static-internet-ip` (currently single-host) this is automatic.

## Job-type abstraction

A job type is one Perl module with a single function:

```perl
package Homelab::Worker::JobType::Zip;
sub run {
    my ($input, $workdir) = @_;
    # ... returns the finished artifact's LOCAL path (inside $workdir), or dies
}
```

`$input` is whatever JSON payload the job was submitted with -- opaque
to the core engine, meaningful only to the type's own module.
`Homelab::Worker::App`'s `job_types` dispatch hash (`{ zip => \&Homelab::Worker::JobType::Zip::run, ... }`,
see `App.pm`'s `startup`) is the *only* place the engine needs to know a
type exists at all; neither the routes nor the claim/run timer ever
branch on job type.

### The `zip` job type (v1's only type)

Generic "fetch N URLs, each with its own auth header, bundle into one
zip" -- not drive-specific, reusable later by anything else that wants
the same shape:

```json
{
  "output_name": "drive-export-20260911.zip",
  "entries": [
    {"fetch_url": "https://drive.test.mailmasker.org/api/v1/files/12",
     "auth_header": "Bearer <jwt>", "zip_path": "Photos/2024/img.jpg"}
  ]
}
```

Each entry is fetched over plain HTTP (`Mojo::UserAgent`, inside the
forked child -- see below) with its own optional `Authorization` header,
then added to the archive at `zip_path` (`Archive::Zip`). `output_name`
is sanitized to its basename only before being used as a filename --
caller-supplied, never trusted as a path.

## The auth hand-off (why every entry carries its own `auth_header`)

This service is generic and has no identity of its own beyond "an
authenticated caller submitted this job" -- it cannot mint credentials
to fetch anything on a caller's behalf. Whatever submits a job (e.g.
`homelab-drive`, in a later phase) is expected to forward the *same*
real, homelab-api-signed JWT it already holds for its own use as each
entry's `auth_header`, and the fetch target (e.g. `drive`'s own existing
`GET /api/v1/files/:id`) is expected to verify it the normal way
(`introspect()`). This service itself introspects the JWT on its *own*
incoming `/internal/v1/jobs/*` request too (verify-at-every-hop, same
convention as `homelab-mailbridge`) -- that only proves who *submitted*
the job, not what the job is later allowed to *fetch*; each entry's
`auth_header` is independent and is exactly what the fetch target's own
auth check evaluates.

**Explicit, acknowledged tradeoff**: for a BFF-style caller like
`homelab-drive`, this is the user's real, full-scope session JWT, not a
narrow "fetch this one file" credential -- there is no token-narrowing/
minting capability anywhere in this ecosystem today. The token sits in
`worker.jobs.input` (JSONB) for as long as the job is pending/running,
bounded by the JWT's own natural session expiry (~30 min), and is never
included in any API response (`Controller::Jobs::_public_row` never
returns raw `input` -- see below). This matches the trust-level tradeoff
already accepted for `homelab-cli`'s own locally-stored token.

## Data model

New schema `worker` in the shared `homelab` database (own
`_runtime`/`_migrate` role pair via `homelab-bootstrap-app-role`, same
split-role pattern as every other feature -- see `../CLAUDE.md`). One
table, `worker.jobs`, shared across every job type -- see
`migrations/001-jobs.sql`. `input` (JSONB) is opaque to the schema
itself; `output_uuid` (not the row's own `id`) is the on-disk filename
under `storage_path`, so a job's artifact path is never guessable from
its sequential id.

## API

Internal routes are `/internal/v1/...`, same distinction
`homelab-domain-admin` already establishes between its own internal
namespace and the gateway's client-facing path:

```
POST   /internal/v1/jobs                 {type, input}   -> 201 {id, type, state, ...}
GET    /internal/v1/jobs[?all=1][&type=][&state=]         -> [ {...}, ... ]  (newest 50)
GET    /internal/v1/jobs/:id                               -> {id, type, state, error_message, output_name, output_size_bytes, user_email, ...}
GET    /internal/v1/jobs/:id/download                      -> streams the finished artifact
```

Auth: every route requires `Authorization: Bearer <jwt>`, verified via
`Homelab::Common::AuthClient::introspect()` -- copied directly from
`homelab-mailbridge`'s `_authenticated_email($c)` pattern (see
`App/Controller/Jobs.pm`'s `_authenticated`).

**Visibility rules** (reuses the `roles` field `introspect()` already
returns as of `homelab-domain-admin`'s Phase 5 work, same `site_admin`
check, copied verbatim):

- `GET /internal/v1/jobs` with no `all` param: always scoped to
  `WHERE user_email = <caller>`, for every caller including
  `site_admin` -- a predictable, least-surprise default even for admins.
- `GET /internal/v1/jobs?all=1`: every job, across every user -- only if
  the caller has `site_admin`; a non-admin passing `?all=1` gets a clean
  `403`, not a silently-scoped-down result.
- `GET /internal/v1/jobs/:id` and `.../download`: a user can act on
  their own job by id; a `site_admin` can act on *any* job by id, not
  just their own (matches `homelab-api`'s own `/api/v1/admin/users`
  precedent). Non-owner, non-admin gets the usual indistinguishable
  `404` either way -- a job existing at all is not leaked to someone who
  can't see it.
- List results are capped at the most recent 50 (`ORDER BY created_at
  DESC LIMIT 50`) -- no pagination UI in v1, just a sane cap so the
  query can't run away.

The response for every job never includes the raw `input` JSONB (see
`Controller::Jobs::_public_row`) -- for a zip job that holds each
manifest entry's forwarded `Authorization` header (see the auth section
above); an authenticated owner/admin gets to know a job ran and how it
went, not the literal credential it ran with.

Gateway route to add to `homelab-api` in a later phase:
`/api/v1/jobs/*` -> this service, same `strip_prefix`/`backend_prefix`
pattern as `/domains/*`. **Not added in this release** -- see below.

## Job runner: claim, run, reclaim, expire

Same proven pattern as `homelab-domain-admin`'s PowerDNS-restart-debounce
and DKIM-retirement timers (`Mojo::IOLoop->recurring` + `SELECT ... FOR
UPDATE SKIP LOCKED`), deliberately **not** `Homelab::Common::Queue`
(Minion) -- that module still has a broken bootstrap story and zero real
call sites anywhere in this codebase (reconfirmed while building this
package); every async need here has used the hand-rolled recurring-timer
pattern instead. `App.pm`'s single 5-second timer runs three
responsibilities in a fixed order every tick:

1. **Reclaim** (`_reclaim_stale_jobs`) -- any `running` row idle longer
   than `jobs.job_timeout_minutes` (worker crash, package upgrade, host
   reboot mid-job -- job state lives entirely in Postgres, never in this
   process's own memory, so recovery is identical regardless of cause)
   goes back to `pending` for another attempt, up to
   `jobs.max_attempts`, after which it's marked `failed` with a clear
   message instead of retrying forever.
2. **Expire** (`_expire_old_jobs`) -- deletes both the on-disk artifact
   and the row for every terminal (`completed`/`failed`) job past its
   `expires_at` (set at the moment a job reaches a terminal state, using
   `jobs.retention_hours`).
3. **Claim** (`_claim_and_run_job`) -- the actual scheduling policy, in
   one query: oldest pending job first, but never more than one running
   job per user (so a prolific user's backlog can never block a
   different, eligible user's job that arrived later) and never more
   than `jobs.max_concurrent_jobs` running at once:
   ```sql
   WITH running_count AS (SELECT count(*) AS n FROM worker.jobs WHERE state = 'running')
   SELECT j.* FROM worker.jobs j, running_count rc
   WHERE j.state = 'pending' AND rc.n < ?
     AND NOT EXISTS (SELECT 1 FROM worker.jobs r WHERE r.user_email = j.user_email AND r.state = 'running')
   ORDER BY j.created_at
   FOR UPDATE OF j SKIP LOCKED LIMIT 1
   ```
   `FOR UPDATE OF j` (not a bare `FOR UPDATE`) is required -- `j` is
   cross-joined against `running_count`, a CTE built from an aggregate
   (`count(*)`), and Postgres cannot lock that synthetic aggregate row,
   only real `worker.jobs` rows. The claimed row is flipped to `running`
   *inside* the claiming transaction, before commit -- not after -- so a
   job that runs for minutes can never be re-claimed by the next tick
   while genuinely still in flight.

Reclaim runs before expire before claim on purpose: a row reclaimed this
same tick is immediately eligible to be re-claimed rather than waiting a
full extra interval, and expiry never races a row the claim query might
still be examining.

The actual work executes via `Mojo::IOLoop::Subprocess->new->run($child, $parent)`
(not synchronously in the timer callback -- a job can run for minutes),
dispatched to the claimed row's `job_types->{$type}` handler. The child
never touches `$self->pg` or any other shared object -- only the plain
`input` data and a private `File::Temp` workdir -- so forking never risks
corrupting the parent's own Postgres connection. Every completion write
(both success and failure) is guarded by `WHERE id = ? AND attempt_count = ?`
(optimistic concurrency), so a reclaim sweep racing a still-alive child's
late completion can't corrupt state -- a reclaimed row's `attempt_count`
has already moved on by the time a stale write would try to land.

**Concurrency cap**: `jobs.max_concurrent_jobs` in config, either an
explicit integer or the literal `auto`, which resolves to
`floor(cpu_cores * 2 * 0.8)` via a plain `nproc` shellout (`Sys::CPU`
isn't packaged for this Debian release -- confirmed while building this
package -- and this value is only read once at startup, so a shellout
costs nothing worth avoiding it for). **Known, accepted minor race**:
with `hypnotoad` running `server.workers` prefork workers each running
this same timer independently, two workers' claims could both read
`running_count` before either commits, momentarily allowing one job over
the cap. This is a soft resource guideline, not a security boundary, so
this design accepts that rare, small overshoot rather than adding
cross-worker serialization for it.

## What this release does and doesn't include

This release is the standalone `homelab-worker` package only -- the
generic engine, the `zip` job type, and its own internal API. **Not**
included, per the approved plan's phasing (separate, later work):

- `homelab-api`'s `/api/v1/jobs/*` gateway route.
- `homelab-drive`'s bulk-select UI, manifest-resolution CTE, and
  zip-job/bulk-delete proxy routes.
- `homelab-cli`'s `jobs list/show/download` command tree.

Until those land, this service is fully functional and independently
testable (see `t/basic.t`) via its own `/internal/v1/jobs/*` API
directly, but nothing in the rest of the ecosystem calls it yet.

## Testing

`t/basic.t` (`Test::Mojo`, real Postgres + a real reachable
`homelab-api` -- set `HOMELAB_WORKER_CONFIG`) covers: auth required on
every route; job-type validation at submission time; a real end-to-end
`zip` job (two fetch entries, one public and one requiring its own
forwarded `auth_header`, fetched from `homelab-api`'s own reachable
endpoints so no other feature package is needed) through the *real*
recurring-timer-driven claim/run/complete cycle, not a mocked runner --
downloaded and unzipped with a real `Archive::Zip` read to confirm
actual contents, not just HTTP status codes; ownership isolation
(a different account gets a clean 404); the `?all=1` 403-for-non-admin /
200-with-cross-user-visibility-for-`site_admin` split, including by-id
and download for a job the admin doesn't own; a job whose fetch target
is genuinely unreachable ending up `failed` with a real `error_message`
rather than stuck, and a `409` (not `404`/broken `200`) downloading it.

Beyond the automated suite: built and installed as a real `.deb` on
`test-static-internet-ip` (registered itself in `homelab-api`'s service
registry, `systemctl status homelab-worker` active), with `t/basic.t`
run against that live deployment end-to-end -- not just unit-level
against an ephemeral test app.
