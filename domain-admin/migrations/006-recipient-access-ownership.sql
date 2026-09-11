-- Adds self-service ownership to domainadmin.recipient_access (see
-- README.md's "Self-service address blocking" section). NULL means
-- admin-created/global (every existing row, and every row the
-- site_admin-only POST still creates) -- unaffected by this migration.
-- Non-NULL means a specific user created this entry for one of their
-- OWN addresses via POST .../recipient-access/mine, and scopes that
-- user's list/delete to just their own rows.
ALTER TABLE domainadmin.recipient_access ADD COLUMN IF NOT EXISTS user_email TEXT;

CREATE INDEX IF NOT EXISTS idx_recipient_access_user_email
    ON domainadmin.recipient_access(user_email) WHERE user_email IS NOT NULL;
