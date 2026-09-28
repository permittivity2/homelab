-- drive.zip_placements started life zip-only, but the background
-- delivery timer it feeds (Homelab::Drive::App::_claim_and_deliver_
-- placement) is generic: claim a pending row, poll the homelab-worker
-- job, download the finished artifact, drop it into drive.files at the
-- row's dest_folder_id. The 2026-09-27 "combine/append files" feature
-- reuses that exact machinery for a 'concat' worker job, so the one
-- thing that was still hard-coded -- the delivered file's MIME type
-- ('application/zip') -- becomes a per-row column instead.
--
--   NULL       -> the timer sniffs the downloaded bytes (File::LibMagic),
--                 falling back to application/octet-stream. Used by
--                 concat, whose output type isn't known until it exists.
--   non-NULL   -> used verbatim. Zip rows set 'application/zip'.
--
-- The table keeps its historical name (renaming a live table is more
-- churn/risk than it's worth); read "zip_placements" as "worker-output
-- placements" now.
ALTER TABLE drive.zip_placements ADD COLUMN IF NOT EXISTS mime_type TEXT;

-- dest_folder_id was NOT NULL because a zip always lands in the user's
-- "Archives" folder (a real row). A concat output instead lands next to
-- its source pieces, which may be at the root (folder_id IS NULL). Allow
-- that -- the delivery timer writes drive.files.folder_id = dest_folder_id
-- verbatim, and drive.files.folder_id is already nullable (NULL == root).
-- The FK/ON DELETE CASCADE is unaffected (a NULL FK simply doesn't
-- reference anything).
ALTER TABLE drive.zip_placements ALTER COLUMN dest_folder_id DROP NOT NULL;
