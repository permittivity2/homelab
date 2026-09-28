-- Drive-local file concatenation ("combine/append selected files").
--
-- Unlike the zip feature (offloaded to homelab-worker because it builds
-- something NEW that isn't sitting on drive's disk), a concat's source
-- files are ALREADY local blobs under storage_path -- so shipping them
-- to a separate worker host and back over the network is pure waste for
-- a workload that is nearly all local disk I/O and almost no CPU. This
-- table drives an on-host background job instead: a recurring timer in
-- Homelab::Drive::App claims a pending row (FOR UPDATE SKIP LOCKED, same
-- pattern as zip_placements) and runs the byte-copy in a forked
-- subprocess (so it never blocks a hypnotoad worker), then delivers the
-- result into drive.files. Survives a restart (a pending job is
-- re-claimed; a 'processing' row stale past 15min is re-pended).
--
-- source_uuids: the ordered list of source blob uuids to concatenate --
-- resolved from the caller's file_ids AND ownership-checked at create
-- time, then addressed by uuid so a later rename doesn't matter. Order
-- is load-bearing and preserved exactly as given.
CREATE TABLE IF NOT EXISTS drive.append_jobs (
    id             BIGSERIAL PRIMARY KEY,
    user_email     TEXT NOT NULL,
    source_uuids   JSONB NOT NULL,
    output_name    TEXT NOT NULL,
    dest_folder_id BIGINT REFERENCES drive.folders(id) ON DELETE CASCADE,   -- NULL == root
    state          TEXT NOT NULL DEFAULT 'pending'
                       CHECK (state IN ('pending', 'processing', 'completed', 'failed')),
    result_file_id BIGINT,
    error_message  TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at     TIMESTAMPTZ,
    completed_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_append_jobs_pending ON drive.append_jobs(created_at) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS idx_append_jobs_stale   ON drive.append_jobs(started_at) WHERE state = 'processing';
