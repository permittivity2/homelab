-- metrics.view: read the fleet metrics (Prometheus-backed) surfaced in
-- the accountmanage "Metrics" tab. Follows the audit.view precedent from
-- 008-role-permissions.sql: site_admin has it unconditionally (see
-- App.pm's _has_capability_p, which short-circuits on site_admin), so no
-- row is seeded for site_admin. This catalog row simply lets a LESSER
-- role be granted read access to the metrics view via the existing RBAC
-- UI, without full site_admin -- exactly the "roles that have access"
-- requirement for the metrics dashboard.
INSERT INTO api.permissions (name, description) VALUES
    ('metrics.view', 'View the fleet metrics dashboard (Prometheus-backed) in myaccount')
ON CONFLICT (name) DO NOTHING;
