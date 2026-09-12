-- System-wide audit trail. See /home/gardner/.claude/plans (this
-- session's plan doc) for the full design reasoning -- summarized here:
-- audit.queue is a small, transient staging table every producing
-- service INSERTs into directly (narrow INSERT-only grant, no HTTP
-- hop, no eval/best-effort wrapper -- a failed enqueue means the
-- action itself fails, by design), and homelab-audit's own recurring
-- timer drains it into the real, normalized, partitioned audit.entries
-- fact table. Reliability is tied to "is Postgres up" (already a hard
-- dependency for everything), not "is a separate service up."

-- Small and transient by design -- rows live here for at most one
-- consumer tick, never grows unbounded the way audit.entries does, so
-- it deliberately does NOT get 3NF/partitioning treatment itself. Raw
-- JSONB payload keeps every producer's INSERT maximally simple/fast
-- (no FK lookups on the hot path) -- normalization happens consumer-side.
CREATE TABLE IF NOT EXISTS audit.queue (
    id          BIGSERIAL PRIMARY KEY,
    enqueued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload     JSONB NOT NULL
    -- payload shape: {actor_email, affected_user, jti, action, resource_type,
    --                 resource_id, source_service, ip_address, user_agent,
    --                 detail, occurred_at}
);
CREATE INDEX IF NOT EXISTS idx_audit_queue_enqueued_at ON audit.queue (enqueued_at);

-- Small, rarely-changing lookups, normalized out of the fact table --
-- 3NF (no repeating free-text groups on every one of millions of rows)
-- and it keeps the hot table's rows narrow.
CREATE TABLE IF NOT EXISTS audit.action_types (
    id   SMALLSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS audit.resource_types (
    id   SMALLSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- Partitioned by month on occurred_at: both stated query patterns
-- ("what did user X do", "what happened in this window", or both)
-- benefit from partition pruning, and it's what makes a future DBA
-- retention/cleanup job (explicitly out of scope for this project)
-- cheap later -- DROP a whole old partition instead of a slow bulk
-- DELETE + vacuum on an ever-growing single table. homelab-audit's own
-- recurring timer creates each month's partition ahead of time (see
-- App.pm's _ensure_partitions) -- this migration only creates the
-- parent (partitioned) table plus the first partition, so a fresh
-- install has somewhere to write from minute one.
-- actor_email (who performed the action) and affected_user (whose
-- account this action is about) are deliberately separate columns, not
-- one overloaded field -- for the overwhelming majority of actions
-- they're the same value (a user acting on their own stuff), but they
-- genuinely differ for the small set of admin-on-behalf-of-someone-else
-- actions (granting user X a role, revoking user X's session, granting
-- a mail-alias that routes to user X). ?user= (goal 1: "what did I do")
-- filters on actor_email; ?affecting= (goal 2: "everything that touched
-- this account, including admin actions on it") filters on
-- affected_user. See README.md for the full reasoning.
CREATE TABLE IF NOT EXISTS audit.entries (
    id                BIGSERIAL,
    occurred_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor_email       TEXT NOT NULL,
    affected_user     TEXT NOT NULL,
    jti               TEXT,
    action_type_id    SMALLINT NOT NULL REFERENCES audit.action_types(id),
    resource_type_id  SMALLINT REFERENCES audit.resource_types(id),
    resource_id       TEXT,
    source_service    TEXT NOT NULL,
    ip_address        TEXT,
    user_agent        TEXT,
    detail            JSONB,
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

CREATE INDEX IF NOT EXISTS idx_audit_entries_actor_time    ON audit.entries (actor_email, occurred_at);
CREATE INDEX IF NOT EXISTS idx_audit_entries_affected_time ON audit.entries (affected_user, occurred_at);
CREATE INDEX IF NOT EXISTS idx_audit_entries_time          ON audit.entries (occurred_at);
CREATE INDEX IF NOT EXISTS idx_audit_entries_jti           ON audit.entries (jti) WHERE jti IS NOT NULL;

-- First partition (current month), idempotent, so a fresh install can
-- accept writes immediately -- the timer keeps this and the next
-- month's partition topped up from here on.
DO $$
DECLARE
    part_start date := date_trunc('month', now());
    part_end   date := date_trunc('month', now()) + interval '1 month';
    part_name  text := 'entries_' || to_char(part_start, 'YYYY_MM');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = part_name) THEN
        EXECUTE format(
            'CREATE TABLE audit.%I PARTITION OF audit.entries FOR VALUES FROM (%L) TO (%L)',
            part_name, part_start, part_end
        );
    END IF;
END $$;
