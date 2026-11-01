-- An individual file can be marked non-searchable, not just a folder.
--
-- 013 did folders. The same reasoning applies one level down: a single
-- document can be the private one without its whole folder being, and
-- making somebody move a file into a special folder to hide it from
-- search is a worse answer than letting them mark the file.
--
-- EFFECTIVE non-searchability is the OR of this flag and every folder
-- above the file -- see homelab-search's indexer, which computes it.
-- Clearing a file's own flag does not un-hide it if it sits in a folder
-- that is marked, which is the behaviour people expect from nesting.
ALTER TABLE drive.files
    ADD COLUMN IF NOT EXISTS exclude_from_search BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_files_excluded
    ON drive.files (user_email) WHERE exclude_from_search;
