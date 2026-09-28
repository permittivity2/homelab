-- Harden the drive-local concat job against a reclaim racing a
-- still-alive-but-stalled subprocess (found by review). Two additions:
--
-- 1. `attempt` -- an epoch bumped every time the job is claimed. The
--    subprocess parent callback guards its completion/failure UPDATEs on
--    "WHERE id = ? AND attempt = ?", so a stale original run whose row
--    has since been re-pended and re-claimed (new attempt) can no longer
--    overwrite job state or insert a junk drive.files row. Same
--    optimistic-concurrency pattern homelab-worker already uses
--    (attempt_count). The per-run temp path also folds in the attempt
--    (see _append_tmp_path) so two runs never write the same file.
--
-- 2. a 'finalizing' state -- claimed with a guarded flip out of
--    'processing' before the parent does any side effect (INSERT the
--    file, rename the blob into storage), so only the run that still
--    owns the attempt ever creates the output; a stale run finds nothing
--    to claim and just drops its own temp.
ALTER TABLE drive.append_jobs ADD COLUMN IF NOT EXISTS attempt INT NOT NULL DEFAULT 0;

ALTER TABLE drive.append_jobs DROP CONSTRAINT IF EXISTS append_jobs_state_check;
ALTER TABLE drive.append_jobs ADD CONSTRAINT append_jobs_state_check
    CHECK (state IN ('pending', 'processing', 'finalizing', 'completed', 'failed'));
