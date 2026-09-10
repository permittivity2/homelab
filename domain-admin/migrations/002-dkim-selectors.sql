-- DKIM key/selector rotation state machine (see README.md's "DKIM
-- rotation" section, built out in a later phase). Deliberately NO
-- private key column -- OpenDKIM needs the raw, reversible key on disk
-- regardless of where else it might also be stored, so a second copy in
-- this shared database would only add risk without removing the
-- on-disk requirement. Only the PUBLIC half (needed to render the DNS
-- TXT record) and rotation-state/timestamps live here.
CREATE TABLE IF NOT EXISTS domainadmin.dkim_selectors (
    id             BIGSERIAL PRIMARY KEY,
    domain_id      BIGINT NOT NULL REFERENCES domainadmin.domains(id) ON DELETE CASCADE,
    selector       TEXT NOT NULL,
    state          TEXT NOT NULL DEFAULT 'pending'
                       CHECK (state IN ('pending', 'active', 'retiring', 'retired')),
    public_key     TEXT NOT NULL,
    key_bits       INTEGER NOT NULL DEFAULT 2048,
    created_by     TEXT,
    activated_by   TEXT,
    retired_by     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_at   TIMESTAMPTZ,
    retiring_at    TIMESTAMPTZ,
    retire_after   TIMESTAMPTZ,
    retired_at     TIMESTAMPTZ,
    next_action_at TIMESTAMPTZ,
    UNIQUE (domain_id, selector)
);

-- OpenDKIM's SigningTable signs with exactly one selector per domain --
-- this makes "at most one active selector per domain" a real database
-- constraint instead of something rotation code has to get right on its
-- own every time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_dkim_selectors_one_active_per_domain
    ON domainadmin.dkim_selectors(domain_id) WHERE state = 'active';

CREATE INDEX IF NOT EXISTS idx_dkim_selectors_due
    ON domainadmin.dkim_selectors(next_action_at) WHERE next_action_at IS NOT NULL;
