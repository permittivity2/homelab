-- Refresh-token rotation: make a LOST RESPONSE recoverable.
--
-- WHY THIS EXISTS. /api/v1/auth/refresh rotates: it revokes the presented
-- refresh token (and its session) and mints a new pair. That is the right
-- security property -- a stolen, already-used refresh token is useless on the
-- legitimate client's next refresh -- but it has a hole that is not a race and
-- cannot be fixed on the client:
--
--   the server commits the rotation, and the client never learns the result.
--
-- A request timeout, a reset connection, or the client process being killed
-- between the server's COMMIT and the client writing the new token to disk all
-- land in the same place: the old token is revoked, the new one was never
-- received, and the client has nothing left to authenticate with. For a human
-- that is one re-login. For homelab-agent it is PERMANENT: it holds no
-- password, only the token, so it retries a consumed token every 60 seconds
-- forever, silently.
--
-- That is exactly what happened on 2026-10-28/29: 14 of 51 fleet nodes locked
-- themselves out, clustered around package rollouts (when the API is loudest
-- and services are restarting -- precisely when a response gets lost). One of
-- them was the certificate issuer, which meant certificate publishing had
-- stopped. Nobody noticed for up to 4.4 days, because an agent in this state
-- reports `active` and its access token's expires_at is still in the future.
-- See post-cutover items 36 and 37.
--
-- THE FIX. Remember what a rotation produced, so presenting the consumed token
-- again within a short window returns THE SAME successor pair instead of 401.
-- A client that lost the response simply retries and converges. This is the
-- standard refresh-token "reuse with grace" pattern and it is a deliberate,
-- bounded softening of single-use:
--
--   * bounded in TIME -- jwt.refresh_grace_seconds, default 300 (see the
--     handler); outside the window a consumed token is rejected exactly as
--     before;
--   * it mints NOTHING -- the grace path hands back the successor that already
--     exists and creates no new session, so a retry loop converges instead of
--     generating sessions;
--   * it is REVOCABLE -- the grace path refuses once the successor's own
--     session is revoked, so a logout still ends everything immediately; and
--   * the token was already presented over TLS by whoever legitimately held
--     it. The attack it gives up is "replay a token you stole in the last five
--     minutes AND whose rightful owner never completed the rotation"; what it
--     buys is that an interrupted rotation stops being a permanent lockout.
--     Permanent lockout was the bigger risk, and it had already fired 14 times.
--
-- Rotation is also made ATOMIC in the same change (the handler now wraps
-- revoke+insert in one transaction). Before, those were separate autocommitted
-- statements: a crash in between left the user with a revoked token and no
-- successor at all -- the one case this grace window could not repair.

ALTER TABLE api.refresh_tokens
    -- What this token rotated INTO. Null for a live token, or for one revoked
    -- by logout rather than by rotation -- which is what keeps those two cases
    -- distinguishable, and why logout stays final.
    ADD COLUMN IF NOT EXISTS successor_id BIGINT
        REFERENCES api.refresh_tokens(id) ON DELETE SET NULL,
    -- When the rotation committed. The grace window is measured from here, not
    -- from created_at: a token can be minted long before it is used.
    ADD COLUMN IF NOT EXISTS rotated_at TIMESTAMPTZ;

-- Partial: only rotated rows are ever looked up this way, and on a fleet that
-- has been rotating every 60s per agent for weeks that is a small fraction of
-- a large table.
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_rotated_at
    ON api.refresh_tokens (rotated_at) WHERE rotated_at IS NOT NULL;

COMMENT ON COLUMN api.refresh_tokens.successor_id IS
    'The token this one rotated into. Lets a client that lost the rotation response retry and get the same successor back instead of being locked out. See migration 020.';
COMMENT ON COLUMN api.refresh_tokens.rotated_at IS
    'When the rotation committed. The refresh grace window (jwt.refresh_grace_seconds) is measured from here.';
