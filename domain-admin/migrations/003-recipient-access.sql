-- Per-recipient allow/block, built out in a later phase. Adapted (not
-- copied verbatim -- this repo has no parallel dovecot.users table to
-- hang it off) from the old homelab-api repo's
-- dovecot.postfix_recipient_access. Backs homelab-postfix's
-- check_recipient_access pgsql: map. action is free text on purpose:
-- it passes straight through to Postfix's own check_recipient_access,
-- which accepts more than OK/REJECT (DISCARD, DEFER, a literal
-- "550 5.7.1 ..." response) -- no need to duplicate Postfix's own
-- vocabulary as a CHECK constraint.
CREATE TABLE IF NOT EXISTS domainadmin.recipient_access (
    id         BIGSERIAL PRIMARY KEY,
    recipient  TEXT NOT NULL UNIQUE,
    action     TEXT NOT NULL,
    reason     TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
