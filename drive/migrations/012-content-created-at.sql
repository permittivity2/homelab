-- The file's OWN date, as distinct from when we received it.
--
-- drive.files.uploaded_at answers "when did this arrive here", which is not
-- the question a user asking for "files from January" means. The real date
-- can only be captured at upload time, from the client: the browser has it
-- in File.lastModified, and the CLI has it in stat()'s mtime.
--
-- NOT BACKFILLABLE, and worth being explicit about rather than leaving a
-- mysteriously-empty column. The stored blob's mtime on the NFS share IS
-- the upload time -- the original is not recorded anywhere, so for every
-- file uploaded before this migration there is nothing to recover. Those
-- rows keep NULL and every reader falls back to uploaded_at. A column that
-- is NULL for the existing corpus is still worth having: it only gets more
-- useful from here.
ALTER TABLE drive.files ADD COLUMN IF NOT EXISTS content_created_at TIMESTAMPTZ;

COMMENT ON COLUMN drive.files.content_created_at IS
    'The file''s own creation/modification date as reported by the client at upload. NULL means unknown (everything uploaded before migration 012) -- fall back to uploaded_at.';

CREATE INDEX IF NOT EXISTS idx_files_user_content_created
    ON drive.files (user_email, content_created_at DESC);
