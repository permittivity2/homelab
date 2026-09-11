-- Device/IP visibility for api.sessions (see 005-sessions.sql for the
-- revocation mechanism this builds on -- introspect() already rejects
-- a revoked session in real time, this migration only adds WHO/WHERE
-- so a session can actually be recognized and chosen for revocation
-- instead of acted on blind).
--
-- All three nullable: existing rows (minted before this migration)
-- have none of this and stay perfectly valid, just unlabeled in a
-- sessions list until they naturally expire/get replaced by a refresh.
--
-- first_seen_at is deliberately separate from created_at -- a session
-- surviving many silent token refreshes (see App.pm's _refresh, which
-- carries these three columns forward rather than recapturing them)
-- keeps the ORIGINAL login's first_seen_at while created_at marks only
-- when the CURRENT jti was minted -- without this, a long-lived CLI
-- session refreshed every ~30min would look like a brand-new login
-- every single time in a naive created_at-based "logged in since" view.
ALTER TABLE api.sessions ADD COLUMN IF NOT EXISTS user_agent TEXT;
ALTER TABLE api.sessions ADD COLUMN IF NOT EXISTS ip_address TEXT;
ALTER TABLE api.sessions ADD COLUMN IF NOT EXISTS first_seen_at TIMESTAMPTZ;
