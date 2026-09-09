-- One-time OAuth authorization codes, in Postgres rather than an
-- in-process hash -- a code minted by one hypnotoad worker must be
-- visible when a different worker handles the /oauth/token exchange
-- (proven necessary the hard way once already in this ecosystem's
-- history; see the old production repo's sso-ui, whose in-process
-- %codes hash only ever worked with server.workers = 1).
CREATE TABLE IF NOT EXISTS sso.oauth_codes (
    code          TEXT PRIMARY KEY,
    client_id     TEXT NOT NULL,
    email         TEXT NOT NULL,
    redirect_uri  TEXT NOT NULL,
    scope         TEXT,
    jwt           TEXT NOT NULL,
    refresh_token TEXT NOT NULL,
    expires_in    INTEGER NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_oauth_codes_expires_at ON sso.oauth_codes(expires_at);
