-- Minimal RBAC for the litmus milestone: roles + user_roles only, no
-- per-endpoint role_permissions table yet (the old homelab-api repo has
-- one — a reasonable fast-follow once the core auth path is proven, not
-- worth the extra scope before that).
CREATE TABLE IF NOT EXISTS api.roles (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS api.user_roles (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES api.users(id) ON DELETE CASCADE,
    role_id    BIGINT NOT NULL REFERENCES api.roles(id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_user_id ON api.user_roles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role_id ON api.user_roles(role_id);

INSERT INTO api.roles (name, description) VALUES
    ('user', 'Default role — standard API access'),
    ('site_admin', 'Administrative capabilities (informational only; admin routes are hardcoded, not gated by a table, so a bad edit can''t lock every admin out)')
ON CONFLICT (name) DO NOTHING;
