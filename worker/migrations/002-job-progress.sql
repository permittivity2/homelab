-- Live progress for a running job, so a caller (homelab-drive's zip
-- status endpoint, and through it the browser) can show "N of M" while a
-- long job builds instead of an opaque "running". A job type's run()
-- reports progress by writing to a small progress file (see App.pm's
-- progress-file convention); the recurring timer reads it each tick and
-- mirrors it here. progress_current advancing is ALSO what now marks a
-- job as alive: the stale-reclaim treats "current stopped moving" as
-- stuck, rather than "started_at is simply old" -- so a legitimately
-- long job (a multi-GB zip) is no longer re-pended and double-run.
ALTER TABLE worker.jobs ADD COLUMN IF NOT EXISTS progress_current BIGINT;
ALTER TABLE worker.jobs ADD COLUMN IF NOT EXISTS progress_total   BIGINT;
