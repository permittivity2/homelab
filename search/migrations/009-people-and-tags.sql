-- People and the tag tree, properly normalized.
--
-- WHAT THIS REPLACES. 007 stored tagged people as one text value -- "Ada
-- Lovelace, Grace Hopper" in a single column. That is a repeating group in
-- a field, which 1NF forbids before 3NF gets a say, and it is inconsistent
-- with this schema's own treatment of the same idea: mail participants get
-- four normalized tables (addresses, display_names, address_names,
-- message_addresses) precisely so a person is a row and not a substring.
--
-- Concretely, the string version was wrong in ways that matter:
--   * "photos with Jeff" is a LIKE over a joined list, so it also matches
--     Jefferson;
--   * the same person tagged twice in one photo cannot be expressed;
--   * the BOUNDING BOX that comes with every tagged face was discarded,
--     because a string has nowhere to put it;
--   * renaming a person means rewriting the string on every photo;
--   * and there is no way to list "who is in my photos", which is the
--     first thing anyone wants.
--
-- TWO LEVELS, because they are genuinely different things: a PERSON is
-- somebody who appears in this account's photos; a FACE is one tagged
-- region in one photo, which may or may not be named.
CREATE TABLE IF NOT EXISTS search.people (
    person_id    BIGSERIAL PRIMARY KEY,
    account_id   BIGINT NOT NULL REFERENCES search.accounts (account_id) ON DELETE CASCADE,
    display_name TEXT   NOT NULL CHECK (length(display_name) > 0),
    -- Case-insensitively unique per account: photo managers are
    -- inconsistent about capitalisation and "jeff gardner" and "Jeff
    -- Gardner" are one person, not two.
    UNIQUE (account_id, person_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS people_acct_name_key
    ON search.people (account_id, lower(display_name));

-- One row per TAGGED REGION. The area is a fraction of the image (0..1)
-- with x,y at the CENTRE of the box, exactly as the Metadata Working Group
-- spec defines it -- stored as given rather than converted to pixels,
-- because pixels would bake in the dimensions at tag time and a resized
-- copy would move every box.
--
-- person_id is NULLABLE on purpose: photo managers write unnamed regions
-- for "there is a face here, I have not said whose". Dropping those would
-- lose the fact that the photo has a face in it at all.
CREATE TABLE IF NOT EXISTS search.photo_faces (
    face_id       BIGSERIAL PRIMARY KEY,
    drive_item_id BIGINT NOT NULL,
    account_id    BIGINT NOT NULL,
    person_id     BIGINT,
    region_type   TEXT   NOT NULL DEFAULT 'Face',
    area_x        DOUBLE PRECISION CHECK (area_x BETWEEN 0 AND 1),
    area_y        DOUBLE PRECISION CHECK (area_y BETWEEN 0 AND 1),
    area_w        DOUBLE PRECISION CHECK (area_w BETWEEN 0 AND 1),
    area_h        DOUBLE PRECISION CHECK (area_h BETWEEN 0 AND 1),
    FOREIGN KEY (drive_item_id, account_id)
        REFERENCES search.drive_items (drive_item_id, account_id) ON DELETE CASCADE,
    -- The composite FK again: a face cannot point at a person belonging to
    -- a different account, because Postgres refuses to attach it.
    FOREIGN KEY (person_id, account_id)
        REFERENCES search.people (person_id, account_id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_faces_person ON search.photo_faces (account_id, person_id);
CREATE INDEX IF NOT EXISTS idx_faces_item   ON search.photo_faces (drive_item_id);

-- THE TAG TREE, which is the thing a person built by hand in their photo
-- manager: Places|Earth|USA|Utah|Moab|Arches National Park.
--
-- The flat Keywords field holds only the LEAF, so "Moab" is findable and
-- "Utah" is not -- even though they filed it under Utah themselves. The
-- hierarchy is the value here.
--
-- parent_id is the real structure. `path` is a MATERIALIZED copy of the
-- ancestor chain, and that redundancy is deliberate: it makes "everything
-- under Utah" a prefix match on an indexed column instead of a recursive
-- CTE on every search. It is derived from the parent chain and written by
-- the indexer, never edited independently.
CREATE TABLE IF NOT EXISTS search.tags (
    tag_id     BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES search.accounts (account_id) ON DELETE CASCADE,
    parent_id  BIGINT,
    name       TEXT   NOT NULL CHECK (length(name) > 0),
    path       TEXT   NOT NULL CHECK (length(path) > 0),
    UNIQUE (account_id, path),
    UNIQUE (account_id, tag_id),
    FOREIGN KEY (parent_id, account_id)
        REFERENCES search.tags (tag_id, account_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tags_path   ON search.tags (account_id, path text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_tags_name   ON search.tags (account_id, lower(name));

CREATE TABLE IF NOT EXISTS search.photo_tags (
    drive_item_id BIGINT NOT NULL,
    account_id    BIGINT NOT NULL,
    tag_id        BIGINT NOT NULL,
    PRIMARY KEY (drive_item_id, tag_id),
    FOREIGN KEY (drive_item_id, account_id)
        REFERENCES search.drive_items (drive_item_id, account_id) ON DELETE CASCADE,
    FOREIGN KEY (tag_id, account_id)
        REFERENCES search.tags (tag_id, account_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_phototags_tag ON search.photo_tags (account_id, tag_id);

-- people.names in drive_metadata is now redundant and actively misleading
-- -- two places holding the same fact, one of them a joined string. The
-- key is retired rather than left to rot; the rows go with it.
--
-- The GUC below is not optional. drive_metadata has FORCE ROW LEVEL
-- SECURITY, which subjects the TABLE OWNER to its policies too -- so a
-- migration running as the migrate role with no account declared matches
-- zero rows, deletes nothing, and then fails on the foreign key when the
-- keys it was supposed to have freed are still referenced. The indexer
-- policy is the existing way to work across every account, and this is
-- exactly that case.
SELECT set_config('homelab.indexer', 'on', true);

DELETE FROM search.drive_metadata
 WHERE key_id IN (SELECT key_id FROM search.metadata_keys
                   WHERE key_name IN ('people.names', 'people.count'));
DELETE FROM search.metadata_keys WHERE key_name IN ('people.names', 'people.count');

-- ------------------------------------------------- row-level security
-- Same rule as every other table carrying an account_id: the web app
-- reads under its own account, the indexer writes across accounts through
-- the second policy.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['people', 'photo_faces', 'tags', 'photo_tags'] LOOP
        EXECUTE format('ALTER TABLE search.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE search.%I FORCE  ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS acct_isolation ON search.%I', t);
        EXECUTE format($q$CREATE POLICY acct_isolation ON search.%I
            USING (account_id = nullif(current_setting('homelab.account_id', true), '')::bigint)$q$, t);
        EXECUTE format('DROP POLICY IF EXISTS indexer_all ON search.%I', t);
        EXECUTE format($q$CREATE POLICY indexer_all ON search.%I
            USING      (current_setting('homelab.indexer', true) = 'on')
            WITH CHECK (current_setting('homelab.indexer', true) = 'on')$q$, t);
    END LOOP;
END $$;
