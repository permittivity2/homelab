-- Tracks delivering a completed homelab-worker zip job's artifact into
-- this user's own drive.files, inside their root-level "Archives"
-- folder -- see ../README.md's "Bulk select: zip download" section.
-- homelab-worker is deliberately drive-agnostic and holds the finished
-- .zip on its OWN disk only (see ../../worker/README.md); nothing
-- copies it into drive.files unless something here does, and the
-- browser tab that submitted the job may not even still be open by the
-- time it's ready -- so this has to be a server-side background claim,
-- same FOR UPDATE SKIP LOCKED timer pattern as homelab-domain-admin's
-- and homelab-worker's own timers, not frontend polling.
CREATE TABLE IF NOT EXISTS drive.zip_placements (
    id                 BIGSERIAL PRIMARY KEY,
    job_id             BIGINT NOT NULL,   -- homelab-worker's own jobs.id; no FK, separate DB/schema
    user_email         TEXT NOT NULL,
    -- Same bounded-lifetime tradeoff already accepted for the job's own
    -- input.entries[].auth_header (see ../../worker/README.md's "auth
    -- hand-off" section) -- reused here so the delivery timer below can
    -- check job status / fetch the finished bytes without a live
    -- request context to pull a fresh token from.
    jwt                TEXT NOT NULL,
    dest_folder_id     BIGINT NOT NULL REFERENCES drive.folders(id) ON DELETE CASCADE,
    output_name        TEXT NOT NULL,
    -- 'processing' exists purely to make the claim step below atomic
    -- under hypnotoad's multiple prefork workers (config `server.workers`,
    -- default 2) each running this same timer independently -- a row is
    -- flipped to 'processing' in the same UPDATE that claims it, then
    -- flipped back to 'pending' (still building) or on to 'completed'/
    -- 'failed' once the underlying homelab-worker job is checked. Same
    -- concern homelab-worker's own claim query already handles by
    -- flipping to 'running' inside its claiming transaction before
    -- commit -- see worker/lib/Homelab/Worker/App.pm.
    state              TEXT NOT NULL DEFAULT 'pending'
                           CHECK (state IN ('pending', 'processing', 'completed', 'failed')),
    delivery_attempts  INTEGER NOT NULL DEFAULT 0,
    error_message      TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_zip_placements_pending ON drive.zip_placements(created_at) WHERE state = 'pending';
