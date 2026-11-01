-- Find an account's indexed rows by the drive file ids a share names.
--
-- A share is expressed in drive.files ids, so the borrowed pass asks
-- "which of THIS owner's indexed items are these files" -- an
-- (account_id, drive_file_id) lookup. Every existing index on the table is
-- account-led but keyed on something else (deleted_at, mime, the best
-- date), and drive_file_id had no index at all, so that lookup was a scan
-- of the owner's whole drive on every search by anyone they share with.
--
-- Partial on deleted_at: a borrowed pass never wants trashed rows, and the
-- owner's trash is the larger part of what the predicate would otherwise
-- have to step over.
CREATE INDEX IF NOT EXISTS idx_drive_acct_fileid
    ON search.drive_items (account_id, drive_file_id)
 WHERE deleted_at IS NULL;
