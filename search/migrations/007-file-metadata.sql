-- Per-type file metadata (plan §8b): EXIF, durations, document properties,
-- archive contents.
--
-- NORMALIZED, NOT A JSONB BLOB. The same shape as message_headers +
-- header_names, for the same reasons: a key is a row, so adding one is an
-- INSERT rather than a migration; the value is indexed, so "photos taken
-- before 2020" is an index range rather than a scan over JSON; and the
-- key -- not the row -- decides the value's type, which is a functional
-- dependency sitting where it belongs.
--
-- Three value columns and exactly one of them filled. `value_kind` on the
-- key says which. A text column holding '40.166' would make a numeric
-- range query a cast over every row.

CREATE TABLE IF NOT EXISTS search.metadata_keys (
    key_id      SMALLSERIAL PRIMARY KEY,
    key_name    TEXT NOT NULL UNIQUE CHECK (key_name = lower(key_name)),
    -- What a person calls it. In the lookup rather than the template, so
    -- the web page, homelab-cli and AI mode all say the same word.
    label       TEXT NOT NULL,
    value_kind  TEXT NOT NULL CHECK (value_kind IN ('text', 'num', 'at')),
    -- NOT a label. AI mode filters these out of everything it sends to a
    -- third party. A photo's coordinates are the most revealing field this
    -- schema holds -- the live corpus already contains a drone shot with
    -- the exact spot it was taken -- and "useful to the owner" and "fine to
    -- send to someone else" are different questions. The owner still sees
    -- them in the UI; they simply never leave the building.
    sensitive   BOOLEAN NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS search.drive_metadata (
    drive_item_id BIGINT   NOT NULL,
    account_id    BIGINT   NOT NULL,
    key_id        SMALLINT NOT NULL REFERENCES search.metadata_keys (key_id),
    value_text    TEXT,
    value_num     DOUBLE PRECISION,
    value_at      TIMESTAMPTZ,
    PRIMARY KEY (drive_item_id, key_id),
    -- The composite FK that makes a mismatch impossible rather than
    -- unlikely: a metadata row cannot belong to a different account than
    -- the file it describes, because Postgres refuses to attach it.
    FOREIGN KEY (drive_item_id, account_id)
        REFERENCES search.drive_items (drive_item_id, account_id) ON DELETE CASCADE,
    CONSTRAINT drive_metadata_one_value
        CHECK (num_nonnulls(value_text, value_num, value_at) = 1)
);

-- One index per value kind, each led by the account because every query is
-- scoped to one. "Which photos did the DJI take", "videos over a minute",
-- "anything taken in 2019" are the three shapes.
CREATE INDEX IF NOT EXISTS idx_drive_meta_text
    ON search.drive_metadata (account_id, key_id, value_text) WHERE value_text IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_drive_meta_num
    ON search.drive_metadata (account_id, key_id, value_num)  WHERE value_num IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_drive_meta_at
    ON search.drive_metadata (account_id, key_id, value_at)   WHERE value_at IS NOT NULL;

-- Which extractor last ran over this file.
--
-- This is what makes a re-index incremental instead of a rebuild. Adding a
-- tag or fixing a transform means bumping Extract::EXTRACTOR_VERSION; every
-- file below that number is then a cheap indexed query, and the existing
-- work queue drains them without a special migration. NULL means "never
-- extracted", which is every row today.
ALTER TABLE search.drive_items
    ADD COLUMN IF NOT EXISTS extractor_version SMALLINT;

CREATE INDEX IF NOT EXISTS idx_drive_extractor
    ON search.drive_items (account_id, extractor_version)
 WHERE deleted_at IS NULL;

-- ------------------------------------------------- row-level security
-- USING only, no WITH CHECK: the web app READS this and the indexer WRITES
-- it, exactly like the rest of the index. The indexer passes through the
-- indexer_all policy below, which is keyed on a GUC the request path never
-- sets because it always sets a numeric account id.
--
-- metadata_keys carries no account_id and is not secret -- it is a list of
-- field names -- so it gets no policy, like search.mime_types.
ALTER TABLE search.drive_metadata ENABLE ROW LEVEL SECURITY;
ALTER TABLE search.drive_metadata FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS acct_isolation ON search.drive_metadata;
CREATE POLICY acct_isolation ON search.drive_metadata
    USING (account_id = nullif(current_setting('homelab.account_id', true), '')::bigint);

DROP POLICY IF EXISTS indexer_all ON search.drive_metadata;
CREATE POLICY indexer_all ON search.drive_metadata
    USING      (current_setting('homelab.indexer', true) = 'on')
    WITH CHECK (current_setting('homelab.indexer', true) = 'on');
