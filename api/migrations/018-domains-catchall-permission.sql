-- domains.catchall: manage domain catch-all routing in myaccount -- set a
-- domain's catch-all destination AND whether that catch-all may SEND AS
-- <anyone>@<domain> (send_enabled). Follows the audit.view / metrics.view
-- precedent (008/017): site_admin holds it unconditionally (App.pm's
-- _has_capability_p short-circuits on site_admin), so no row is seeded for
-- site_admin; this catalog row lets a LESSER role/group be granted the
-- ability to run the "Domain catch-all routing" admin area without full
-- site_admin. It is a powerful grant (a holder can route a whole domain's
-- mail and authorise sending as any address at it), so grant it narrowly.
INSERT INTO api.permissions (name, description) VALUES
    ('domains.catchall', 'Manage domain catch-all routing + domain send-as (the myaccount "Domain catch-all routing" area)')
ON CONFLICT (name) DO NOTHING;
