-- system_agent can't be deleted (post-cutover item 53).
--
-- Every fleet node's homelab-agent signs in with the system_agent role, and
-- the services trust it for server-to-server calls (invite consume, block-link
-- on-behalf, certificate publishing, ...). DELETE /api/v1/admin/roles/:name
-- refused only 'user' and 'site_admin' (migration 008's `protected` flag), so
-- one admin click could have cut off every agent in the fleet at once.

UPDATE api.roles SET protected = TRUE WHERE name = 'system_agent';
