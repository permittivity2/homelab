-- Files that are indexed but never returned by a search.
--
-- The flag lives HERE, on the indexed row, rather than being looked up in
-- drive at query time: this schema deliberately holds no grant on
-- drive.*, and a search that had to join another app's tables to decide
-- what it may show would be both slow and a coupling the whole design
-- avoids. The indexer carries the fact across, which is its job.
--
-- Default TRUE, so a row that predates this -- or that the indexer has
-- not revisited yet -- behaves exactly as it did. The failure direction
-- matters: defaulting to false would silently empty everyone's search
-- results until a full re-index finished.
ALTER TABLE search.drive_items
    ADD COLUMN IF NOT EXISTS searchable BOOLEAN NOT NULL DEFAULT true;

-- Partial index: the excluded set is tiny and every query filters on the
-- common case, so this stays out of the way of the planner.
CREATE INDEX IF NOT EXISTS idx_drive_unsearchable
    ON search.drive_items (account_id) WHERE NOT searchable;

-- Immediate backfill by folder NAME, so the Private folder stops
-- appearing the moment this lands rather than whenever the indexer next
-- walks that file. folder_path here is the immediate folder's name, so
-- this catches the common case; the indexer computes the real answer --
-- which includes nested folders inside Private -- on its next pass over
-- each file, and corrects anything this missed.
SELECT set_config('homelab.indexer', 'on', true);

UPDATE search.drive_items
   SET searchable = false
 WHERE lower(coalesce(folder_path, '')) = 'private'
   AND searchable;
