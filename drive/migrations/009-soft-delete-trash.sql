-- Soft delete + Trash (web deletes are recoverable). A deleted item gets
-- a deleted_at timestamp instead of being unlinked; it keeps its
-- folder_id/parent_folder_id so Restore returns it exactly where it was.
-- Normal listings filter `deleted_at IS NULL`; the Trash view shows
-- `deleted_at IS NOT NULL`. Permanent delete / Empty Trash / the
-- retention sweep do the real unlink+row-delete (the pre-soft-delete
-- behavior). API/homelab-cli deletes stay hard by default (a browser
-- delete is soft; the CLI opts in with --trash). See App.pm.
ALTER TABLE drive.files   ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE drive.folders ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Hot path: normal folder/file listings are all "this user's live items".
CREATE INDEX IF NOT EXISTS idx_files_live   ON drive.files(user_email, folder_id)        WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_folders_live ON drive.folders(user_email, parent_folder_id) WHERE deleted_at IS NULL;
-- Trash listing + the retention sweep both scan "this user's trashed items,
-- oldest first".
CREATE INDEX IF NOT EXISTS idx_files_trashed   ON drive.files(deleted_at)   WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_folders_trashed ON drive.folders(deleted_at) WHERE deleted_at IS NOT NULL;
