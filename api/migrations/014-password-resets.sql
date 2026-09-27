-- One-time, short-TTL password-reset tokens. Same capability-token
-- shape as invite.invites (unguessable urandom hex, single-use via an
-- atomic UPDATE ... WHERE used=FALSE AND expires_at>NOW(), explicit
-- expiry) but for an EXISTING account rather than creating one.
--
-- Deliberately its own table, NOT reused sessions/refresh_tokens: a
-- reset token is PRE-authentication (the entire premise is that the
-- user cannot currently log in) and must never grant any API access --
-- only the one-time right to set a new password. Keeping it separate
-- from the session/JWT machinery makes that boundary structural rather
-- than a matter of remembering not to mint a session from it.
--
-- No email/ip columns here: the token is bound to a user_id (resolved
-- server-side from the requested login, never client-suppliable at
-- confirm time), and per-IP request throttling reuses the existing
-- api.login_attempts table (endpoint='password_reset') rather than
-- standing up a second rate-limit store.
CREATE TABLE IF NOT EXISTS api.password_resets (
    id          BIGSERIAL PRIMARY KEY,
    token       TEXT NOT NULL UNIQUE,
    user_id     BIGINT NOT NULL REFERENCES api.users(id) ON DELETE CASCADE,
    used        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_password_resets_user_id ON api.password_resets(user_id);
CREATE INDEX IF NOT EXISTS idx_password_resets_token ON api.password_resets(token);
