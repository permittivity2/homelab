-- Fast-follow flagged (but deliberately deferred) by 003-rbac.sql's own
-- comment: "no per-endpoint role_permissions table yet ... a reasonable
-- fast-follow once the core auth path is proven." It has been.
--
-- `protected` is what makes 'user'/'site_admin' non-deletable -- a
-- plain boolean check in the DELETE route, not a hardcoded id/name
-- comparison that could silently stop matching after a re-seed.
ALTER TABLE api.roles ADD COLUMN IF NOT EXISTS protected BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE api.roles SET protected = TRUE WHERE name IN ('user', 'site_admin');

-- The catalog of capability strings any service can check for --
-- seeded/extended by code, not user-created free text (a permission
-- only means something if some route actually checks for it).
CREATE TABLE IF NOT EXISTS api.permissions (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE IF NOT EXISTS api.role_permissions (
    id            BIGSERIAL PRIMARY KEY,
    role_id       BIGINT NOT NULL REFERENCES api.roles(id) ON DELETE CASCADE,
    permission_id BIGINT NOT NULL REFERENCES api.permissions(id) ON DELETE CASCADE,
    UNIQUE (role_id, permission_id)
);

-- 'site_admin' does NOT get this row -- it doesn't need one. Its
-- capabilities are unconditional/hardcoded everywhere in this
-- ecosystem (see App.pm's _has_capability), on purpose: the same
-- "admin routes are hardcoded, not gated by a table, so a bad edit
-- can't lock every admin out" reasoning this migration's own
-- 003-rbac.sql predecessor already used to justify NOT gating admin
-- routes by a table in the first place. role_permissions is additive
-- infrastructure for defining NEW, LESSER roles with a named subset of
-- capabilities -- it never constrains what site_admin itself can do.
-- Seeded here as the first real capability (the motivating use case
-- for this whole table) so a role can be granted read access to the
-- audit trail without needing full site_admin.
INSERT INTO api.permissions (name, description) VALUES
    ('audit.view', 'View the system audit log (own entries always allowed; this grants viewing other users'' entries too)')
ON CONFLICT (name) DO NOTHING;
