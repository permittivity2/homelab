-- Progress + status visibility for the two async "produce a new file"
-- jobs (concat/append, and zip delivery). Both queues already existed
-- for the SERVER's benefit (claim-once, survive restart); this adds the
-- columns needed to expose "what's going on" to the USER -- live byte
-- progress, and a link to the finished file -- via GET status endpoints
-- (see App.pm's get_append_job / get_zip_job).

-- append_jobs: the concat subprocess streams bytes into a deterministic
-- temp file whose size a heartbeat step (in _run_append_jobs) reads and
-- mirrors into received_bytes; total_bytes is the sum of the source blob
-- sizes, recorded when the job is claimed. received/total drives the
-- client's progress bar, and "received_bytes stopped growing" (rather
-- than "started_at is simply old") is what now decides a genuinely
-- stuck job -- so a legitimately long concat can no longer be re-pended
-- and double-run.
ALTER TABLE drive.append_jobs ADD COLUMN IF NOT EXISTS total_bytes    BIGINT;
ALTER TABLE drive.append_jobs ADD COLUMN IF NOT EXISTS received_bytes BIGINT NOT NULL DEFAULT 0;

-- zip_placements: remember which drive.files row the finished zip landed
-- in, so a "completed" status can hand the client a direct file id/link
-- instead of just "look in Archives".
ALTER TABLE drive.zip_placements ADD COLUMN IF NOT EXISTS result_file_id BIGINT;
