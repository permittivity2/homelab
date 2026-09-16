-- fronts was part of yesterday's api.infrastructure_registry (now being
-- retired in favor of the agent/manifest system, see
-- 010-fleet-agent.sql) but got dropped when host_service_status was
-- designed -- needed back for exactly the entries infrastructure_registry
-- used it for (HAProxy frontends, webproxy vhosts: what real backend(s)
-- does this one route to). Plain text array, same as
-- infrastructure_registry's own column -- descriptive metadata for
-- `homelab-cli fleet status` to display, not something any code
-- branches on.
ALTER TABLE api.host_service_status ADD COLUMN IF NOT EXISTS fronts TEXT[];
