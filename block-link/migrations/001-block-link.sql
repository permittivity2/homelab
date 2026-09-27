-- Site_admin-only domain-wide default. No cross-schema FK into
-- domainadmin.domains(domain_name) -- this schema's role has no grant
-- there, same convention as every other cross-package reference in
-- this ecosystem (see invite.invites.sender_email for the precedent).
CREATE TABLE IF NOT EXISTS block_link.domain_settings (
    domain_name      TEXT PRIMARY KEY,
    enabled          BOOLEAN NOT NULL DEFAULT FALSE,
    mode             TEXT NOT NULL DEFAULT 'header' CHECK (mode IN ('header', 'body', 'both')),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by_email TEXT
);

-- Self-service, own account only. NULL enabled = inherit the domain
-- default for this account's own home domain (the domain part of the
-- account's own login email) -- resolved by the milter and by this
-- service's own account-settings handler identically.
CREATE TABLE IF NOT EXISTS block_link.account_settings (
    user_email TEXT PRIMARY KEY,
    enabled    BOOLEAN,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Written by homelab-postfix-block-link's milter (INSERT-only grant --
-- see that package's own bespoke bootstrap-role script), read/updated
-- by this service's own /l/:token routes. Long-lived, NOT one-time-use
-- (deliberate divergence from invite.invites' token design -- see
-- README.md's "Why long-lived tokens" section): the whole point is
-- ongoing light management via the same link embedded in the original
-- email, so it stays valid for a generous window rather than burning
-- on first visit.
CREATE TABLE IF NOT EXISTS block_link.pending_links (
    id         BIGSERIAL PRIMARY KEY,
    token      TEXT NOT NULL UNIQUE,
    candidates JSONB NOT NULL,
    message_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pending_links_expires ON block_link.pending_links(expires_at);
