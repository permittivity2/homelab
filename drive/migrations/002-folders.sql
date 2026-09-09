-- Real folder hierarchy, added after the flat-list first pass proved
-- the core upload/list/download/delete path (see README.md). Same "no
-- FK to api.users, user_email is the shared identifier" reasoning as
-- 001-files.sql.
--
-- parent_folder_id NULL means "at the root" — deliberately not a
-- self-referencing sentinel row, since Postgres's own NULL semantics
-- already give every user their own implicit root with zero extra
-- rows. ON DELETE CASCADE on the self-reference means deleting a
-- folder recursively deletes its entire subtree — matches
-- drive.files.folder_id's own ON DELETE CASCADE below, so deleting a
-- folder cleans out everything inside it, files and subfolders alike,
-- in one statement.
CREATE TABLE IF NOT EXISTS drive.folders (
    id                BIGSERIAL PRIMARY KEY,
    user_email        TEXT NOT NULL,
    name              TEXT NOT NULL,
    parent_folder_id  BIGINT REFERENCES drive.folders(id) ON DELETE CASCADE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_folders_user_parent ON drive.folders(user_email, parent_folder_id);

-- No UNIQUE(user_email, parent_folder_id, name) constraint: Postgres
-- treats NULL as distinct from NULL in unique checks, so it wouldn't
-- actually catch two root-level folders with the same name anyway --
-- same-name duplicate prevention is a deliberate application-level
-- check instead (see App.pm), not schema-enforced.

ALTER TABLE drive.files ADD COLUMN IF NOT EXISTS folder_id BIGINT REFERENCES drive.folders(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS idx_files_folder_id ON drive.files(folder_id);
