-- No foreign key to api.users on purpose: drive's migrate role has no
-- grant on the api schema at all (see CLAUDE.md — cross-feature
-- consistency goes through HTTP, i.e. Homelab::Common::AuthClient's
-- introspect(), not a direct cross-schema DB reference). user_email is
-- the identifier every feature already shares via the JWT's email claim.
CREATE TABLE IF NOT EXISTS drive.files (
    id          BIGSERIAL PRIMARY KEY,
    user_email  TEXT NOT NULL,
    filename    TEXT NOT NULL,
    uuid        UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    size_bytes  BIGINT NOT NULL,
    mime_type   TEXT,
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_files_user_email ON drive.files(user_email);
