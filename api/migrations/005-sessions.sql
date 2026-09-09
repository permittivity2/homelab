-- Makes access tokens (JWTs) revocable, not just refresh tokens.
--
-- Before this: introspect() was pure signature+expiry verification, no
-- DB lookup at all -- fast, but meant a "logged out" JWT stayed
-- perfectly valid to every caller for up to its own ~30min expiry_seconds,
-- regardless of what /auth/logout did. Revoking the refresh_token alone
-- only blocks *future* token issuance; it does nothing to the JWT
-- already in a client's hand.
--
-- With this: every issued JWT carries a `jti` claim tied to one row
-- here. introspect() now does one indexed lookup and rejects a revoked
-- session immediately, however much of the JWT's own exp window is
-- left. This is the mechanism real SSO logout (homelab-sso) relies on --
-- see its README -- every relying party (homelab-drive's own
-- introspect-on-every-request, homelab-roundcube's native OAuth
-- refresh/keep-alive hooks) already calls this same endpoint, so
-- logging out centrally here is what makes "logout once, logout
-- everywhere" real without any per-app webhook/backchannel-logout-uri
-- fan-out -- one shared revocation check, not a cookie.
CREATE TABLE IF NOT EXISTS api.sessions (
    jti               TEXT PRIMARY KEY,
    user_id           BIGINT NOT NULL REFERENCES api.users(id) ON DELETE CASCADE,
    refresh_token_id  BIGINT REFERENCES api.refresh_tokens(id) ON DELETE SET NULL,
    revoked           BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at        TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_refresh_token_id ON api.sessions(refresh_token_id);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON api.sessions(user_id);
