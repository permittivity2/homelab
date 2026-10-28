-- Sharing: a file or a folder, either to another account or publicly.
--
-- ONE table covers both kinds, because they differ by exactly one column:
-- shared_with_email IS NULL means PUBLIC. That is how the pre-cutover
-- implementation modelled it too (api.drive_shares), and it is still the
-- right shape -- a public share and a user share need the same token, the
-- same revocation, the same access accounting.
--
-- EVERY share gets a token, user shares included. That is deliberate: the
-- requirement is that the link can be copied again at any time, so the token
-- cannot be something only the public flavour has.

CREATE TABLE IF NOT EXISTS drive.shares (
    id                BIGSERIAL PRIMARY KEY,
    token             TEXT        NOT NULL UNIQUE,
    owner_email       TEXT        NOT NULL,
    -- Exactly one of these is set; see the CHECK below.
    file_id           BIGINT      REFERENCES drive.files(id)   ON DELETE CASCADE,
    folder_id         BIGINT      REFERENCES drive.folders(id) ON DELETE CASCADE,
    -- NULL = public link. Stored as an ADDRESS, not a user id: drive has no
    -- users table of its own (accounts live in api.users, a different schema
    -- owned by a different role), and every other drive table already keys
    -- ownership by user_email for the same reason.
    shared_with_email TEXT,
    permission        TEXT        NOT NULL DEFAULT 'read',
    expires_at        TIMESTAMPTZ,
    -- Soft revoke, matching the deleted_at idiom the rest of this schema
    -- uses, so a revoked share stays auditable (who shared what, when, how
    -- often it was fetched) instead of vanishing.
    revoked_at        TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accessed_at       TIMESTAMPTZ,
    access_count      BIGINT      NOT NULL DEFAULT 0,

    CONSTRAINT shares_one_target CHECK ((file_id IS NOT NULL) <> (folder_id IS NOT NULL))
);

-- The public landing page hits this on every request, so it is the one
-- lookup that must stay fast.
CREATE UNIQUE INDEX IF NOT EXISTS shares_token_idx ON drive.shares(token);
CREATE INDEX IF NOT EXISTS shares_owner_idx       ON drive.shares(owner_email);
CREATE INDEX IF NOT EXISTS shares_shared_with_idx ON drive.shares(shared_with_email)
    WHERE shared_with_email IS NOT NULL;
