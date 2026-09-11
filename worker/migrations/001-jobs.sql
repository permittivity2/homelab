-- One table shared across every job type -- `type` selects which
-- Homelab::Worker::JobType::* module's run() handles a row, and `input`
-- is opaque JSONB meaningful only to that module (see README.md's job-
-- type abstraction). Same state-machine shape as
-- domainadmin.dkim_selectors: a small, explicit set of states, never a
-- free-text status column.
CREATE TABLE IF NOT EXISTS worker.jobs (
    id                 BIGSERIAL PRIMARY KEY,
    user_email         TEXT NOT NULL,
    type               TEXT NOT NULL,   -- 'zip' for v1; future: 'sha1', 'image_resize', ...
    state              TEXT NOT NULL DEFAULT 'pending'
                           CHECK (state IN ('pending', 'running', 'completed', 'failed')),
    input              JSONB NOT NULL,   -- opaque to the engine, meaningful only to the type's module
    output_name        TEXT,
    output_uuid        UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    output_size_bytes  BIGINT,
    error_message      TEXT,
    attempt_count      INTEGER NOT NULL DEFAULT 0,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at         TIMESTAMPTZ,
    completed_at       TIMESTAMPTZ,
    expires_at         TIMESTAMPTZ
);

-- Hot path for GET /internal/v1/jobs (owner-scoped listing, the default
-- for every caller including site_admin -- see README.md).
CREATE INDEX IF NOT EXISTS idx_jobs_user_email ON worker.jobs(user_email);

-- Partial indexes matching exactly the three things the recurring timer
-- (App.pm) does every tick, in order: claim (oldest pending job), reclaim
-- (stale running jobs), expire (terminal jobs past retention).
CREATE INDEX IF NOT EXISTS idx_jobs_claim   ON worker.jobs(created_at) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS idx_jobs_reclaim ON worker.jobs(started_at) WHERE state = 'running';
CREATE INDEX IF NOT EXISTS idx_jobs_expiry  ON worker.jobs(expires_at) WHERE expires_at IS NOT NULL;
