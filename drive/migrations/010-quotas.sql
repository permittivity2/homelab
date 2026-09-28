-- Per-user drive storage quota. Every user has a default limit (1 TiB,
-- applied in code when no row exists here -- see $DEFAULT_QUOTA_BYTES in
-- App.pm); a row in this table is a per-user OVERRIDE an admin sets to
-- raise or lower one user's limit. Usage is the live (non-trashed)
-- SUM(size_bytes); uploads that would push usage over the limit are
-- refused. (Mail has its own 1 TB quota, enforced by Dovecot -- separate.)
CREATE TABLE IF NOT EXISTS drive.quotas (
    user_email  TEXT PRIMARY KEY,
    limit_bytes BIGINT NOT NULL CHECK (limit_bytes >= 0),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
