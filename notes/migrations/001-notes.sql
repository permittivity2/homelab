-- homelab-notes (post-cutover #71): notebooks, folders, notes, their earlier
-- bodies, links to mail and drive files, sharing, per-account preferences.
--
--   * A notebook belongs to an account (owner_email). Accounts live in
--     api.users, a different schema owned by a different role, so ownership
--     is keyed by address here as in every other app schema (drive, calendar).
--   * A note is in one notebook and, optionally, one folder of it. Its body is
--     stored as typed, with its format; rendering happens on read, so a better
--     renderer later improves every note.
--   * Sharing is drive's and the calendar's shape: every share has a token;
--     shared_with_email NULL means "anyone with the link" (read only); a named
--     share is read or edit; a share is on one note or on a whole notebook.
--   * Soft deletes throughout, as drive does: the row stays for the audit
--     trail and so a share link answers "gone" rather than "never existed".

CREATE TABLE IF NOT EXISTS notes.notebooks (
    id            BIGSERIAL PRIMARY KEY,
    owner_email   TEXT        NOT NULL,
    name          TEXT        NOT NULL,
    color         TEXT        NOT NULL DEFAULT '#6f94b8',
    position      INTEGER     NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS notebooks_owner_idx ON notes.notebooks (owner_email) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS notes.folders (
    id            BIGSERIAL PRIMARY KEY,
    notebook_id   BIGINT      NOT NULL REFERENCES notes.notebooks(id) ON DELETE CASCADE,
    parent_id     BIGINT      REFERENCES notes.folders(id) ON DELETE CASCADE,
    name          TEXT        NOT NULL,
    position      INTEGER     NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS folders_notebook_idx ON notes.folders (notebook_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS notes.notes (
    id            BIGSERIAL PRIMARY KEY,
    notebook_id   BIGINT      NOT NULL REFERENCES notes.notebooks(id) ON DELETE CASCADE,
    folder_id     BIGINT      REFERENCES notes.folders(id) ON DELETE SET NULL,
    owner_email   TEXT        NOT NULL,          -- the notebook's owner, copied for cheap scoping
    title         TEXT        NOT NULL DEFAULT '',
    format        TEXT        NOT NULL DEFAULT 'markdown' CHECK (format IN ('markdown', 'html', 'text')),
    body          TEXT        NOT NULL DEFAULT '',
    pinned        BOOLEAN     NOT NULL DEFAULT FALSE,
    -- Who last changed the body (an editor of a shared note is not the owner).
    edited_by     TEXT,
    -- Bumped on every change, so a page that saves on a pause can notice that
    -- someone else saved first (sent back as 409 with the newer body).
    revision      INTEGER     NOT NULL DEFAULT 1,
    search_tsv    TSVECTOR    GENERATED ALWAYS AS (
                      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
                      setweight(to_tsvector('english', left(coalesce(body, ''), 200000)), 'B')
                  ) STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS notes_notebook_idx ON notes.notes (notebook_id, folder_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS notes_owner_idx    ON notes.notes (owner_email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS notes_updated_idx  ON notes.notes (updated_at DESC);
CREATE INDEX IF NOT EXISTS notes_search_idx   ON notes.notes USING GIN (search_tsv);

-- The body before each save: the last N per note (N from the config; the
-- model trims on write). A restore writes the old body as a NEW version.
CREATE TABLE IF NOT EXISTS notes.note_versions (
    id            BIGSERIAL PRIMARY KEY,
    note_id       BIGINT      NOT NULL REFERENCES notes.notes(id) ON DELETE CASCADE,
    revision      INTEGER     NOT NULL,
    title         TEXT        NOT NULL DEFAULT '',
    format        TEXT        NOT NULL,
    body          TEXT        NOT NULL,
    saved_by      TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS note_versions_note_idx ON notes.note_versions (note_id, id DESC);

-- A link on a note: an email (what search knew of it when it was linked:
-- subject, from, date, mailbox, the search hit's id for the person who
-- linked it) or a drive file (id, name, size, type). The snapshot is what
-- a reader who does not have the message or file still sees.
CREATE TABLE IF NOT EXISTS notes.links (
    id            BIGSERIAL PRIMARY KEY,
    note_id       BIGINT      NOT NULL REFERENCES notes.notes(id) ON DELETE CASCADE,
    kind          TEXT        NOT NULL CHECK (kind IN ('mail', 'drive', 'url')),
    target        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    label         TEXT,
    added_by      TEXT,
    position      INTEGER     NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS links_note_idx ON notes.links (note_id);

CREATE TABLE IF NOT EXISTS notes.shares (
    id                BIGSERIAL PRIMARY KEY,
    token             TEXT        NOT NULL UNIQUE,
    owner_email       TEXT        NOT NULL,
    note_id           BIGINT      REFERENCES notes.notes(id) ON DELETE CASCADE,
    notebook_id       BIGINT      REFERENCES notes.notebooks(id) ON DELETE CASCADE,
    shared_with_email TEXT,                                 -- NULL = anyone with the link
    permission        TEXT        NOT NULL DEFAULT 'read' CHECK (permission IN ('read', 'edit')),
    expires_at        TIMESTAMPTZ,
    revoked_at        TIMESTAMPTZ,
    accessed_at       TIMESTAMPTZ,
    access_count      INTEGER     NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK ((note_id IS NULL) <> (notebook_id IS NULL))
);
CREATE INDEX IF NOT EXISTS shares_with_idx     ON notes.shares (shared_with_email) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS shares_note_idx     ON notes.shares (note_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS shares_notebook_idx ON notes.shares (notebook_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS notes.user_prefs (
    user_email        TEXT        PRIMARY KEY,
    last_notebook_id  BIGINT,
    last_note_id      BIGINT,
    default_format    TEXT        NOT NULL DEFAULT 'markdown' CHECK (default_format IN ('markdown', 'html', 'text')),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
