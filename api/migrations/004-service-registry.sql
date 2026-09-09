-- The service registry from CLAUDE.md's architecture: where is feature
-- X reachable. Lives in api's own schema, touched only by homelab_api's
-- own role — every OTHER feature reaches it over HTTP
-- (POST/GET /api/v1/registry/...), never via a direct cross-schema DB
-- grant. homelab-api's own address is never looked up this way — every
-- feature gets it from its own local bootstrap config instead.
CREATE TABLE IF NOT EXISTS api.service_registry (
    feature_name     TEXT PRIMARY KEY,
    host             TEXT NOT NULL,
    port             INTEGER NOT NULL,
    health_check_url TEXT,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
