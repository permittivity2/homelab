-- A folder whose contents never appear in search results.
--
-- THE FILES ARE STILL INDEXED. This is not "don't index it" -- the owner
-- can still open the folder, the blobs are still stored, and
-- homelab-search still holds their text and metadata. It is a filter on
-- what comes BACK from a search, so that a folder someone thinks of as
-- private does not surface a document by its contents when they are
-- searching for something else, or on a shared screen.
--
-- A FLAG PER FOLDER rather than one designated folder per account. Both
-- satisfy "make Private non-searchable", but a flag lets somebody mark a
-- second folder later without a schema change, and it is simpler to
-- enforce: the question at index time is "is this folder, or any folder
-- above it, excluded", which is one recursive walk either way.
--
-- IT APPLIES TO THE WHOLE SUBTREE. Folders nest, and a folder inside
-- Private is private -- anything else would be a trap.
ALTER TABLE drive.folders
    ADD COLUMN IF NOT EXISTS exclude_from_search BOOLEAN NOT NULL DEFAULT false;

-- The default the owner asked for: a folder already called "Private" is
-- excluded from the moment this lands, without anybody having to find a
-- setting. Case-insensitive because people type it both ways, and scoped
-- to top-level folders so a "Private" nested inside a shared folder is
-- not silently hidden on somebody's behalf.
UPDATE drive.folders
   SET exclude_from_search = true
 WHERE lower(name) = 'private'
   AND parent_folder_id IS NULL
   AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_folders_excluded
    ON drive.folders (user_email) WHERE exclude_from_search;
