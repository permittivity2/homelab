-- The whole invite mechanism's state. sender_email/recipient_email/
-- accepted_user_email/revoked_by_email are bare TEXT, not a foreign
-- key into api.users(id) -- this schema is owned by a different,
-- narrowly-scoped role than api's own, and this ecosystem deliberately
-- never grants cross-schema REFERENCES (see domainadmin.recipient_
-- access.user_email/domainadmin.mail_aliases.destination for the same
-- convention already established).
CREATE TABLE IF NOT EXISTS invite.invites (
    id                   BIGSERIAL PRIMARY KEY,
    token                TEXT NOT NULL UNIQUE,
    sender_email         TEXT NOT NULL,
    recipient_email      TEXT NOT NULL,
    channel              TEXT NOT NULL DEFAULT 'cli',
    message              TEXT,
    status               TEXT NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at           TIMESTAMPTZ NOT NULL,
    accepted_at          TIMESTAMPTZ,
    accepted_user_email  TEXT,
    revoked_at           TIMESTAMPTZ,
    revoked_by_email     TEXT
);
CREATE INDEX IF NOT EXISTS idx_invites_recipient ON invite.invites(recipient_email);
CREATE INDEX IF NOT EXISTS idx_invites_sender    ON invite.invites(sender_email, created_at);

-- At most one live pending invite per (sender, recipient) pair -- the
-- actual dedup enforcement, not just an application-level check (a
-- concurrent double-send from two requests races safely against this).
CREATE UNIQUE INDEX IF NOT EXISTS idx_invites_sender_recipient_pending
    ON invite.invites(sender_email, recipient_email) WHERE status = 'pending';

-- Per-sender override; an absent row means the config-file defaults
-- (invite_quotas.default_max_pending/default_max_per_day) apply.
CREATE TABLE IF NOT EXISTS invite.invite_quotas (
    sender_email     TEXT PRIMARY KEY,
    max_pending      INTEGER NOT NULL,
    max_per_day      INTEGER NOT NULL,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by_email TEXT
);

-- Same shape/spirit as api.login_attempts -- a real queryable table,
-- not a counter that can silently drift from reality. `token` is kept
-- even when garbage (not a real 64-hex-char value) -- useful signal
-- for distinguishing "someone is guessing tokens" from "someone is
-- retrying an expired one."
CREATE TABLE IF NOT EXISTS invite.verification_attempts (
    id           BIGSERIAL PRIMARY KEY,
    ip           TEXT NOT NULL,
    token        TEXT,
    outcome      TEXT NOT NULL,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_verification_attempts_ip_time ON invite.verification_attempts(ip, attempted_at);
