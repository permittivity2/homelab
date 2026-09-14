-- Two real gaps in the original registry (004-service-registry.sql),
-- both found live during a stress-testing session: (1) feature_name as
-- the sole primary key means a second real instance of the same
-- service (a second homelab-drive, a second dovecot -- exactly what
-- HAProxy/nginx sitting in front of things is FOR: rolling upgrades,
-- HA) would silently overwrite the first instance's row instead of
-- coexisting; (2) entries carry no human-readable description at all,
-- so `registry list` shows e.g. "homelab-mailbridge -> 10.50.1.207:2510"
-- with zero indication that it's an IMAP/SMTP relay fronting dovecot +
-- postfix, not a database-backed CRUD service like its neighbors.

-- Re-key on (feature_name, host, port) so multiple real instances of
-- one feature_name can coexist as separate rows -- a restart/keepalive
-- re-registering the SAME host:port still upserts in place (identical
-- behavior to before for the common single-instance case), but a
-- genuinely different instance now adds a row instead of clobbering
-- the existing one.
ALTER TABLE api.service_registry DROP CONSTRAINT service_registry_pkey;
ALTER TABLE api.service_registry ADD PRIMARY KEY (feature_name, host, port);
ALTER TABLE api.service_registry ADD COLUMN IF NOT EXISTS description TEXT;

-- Non-HTTP infrastructure (dovecot, postfix, haproxy frontends, webproxy
-- vhosts) deliberately does NOT go in api.service_registry above --
-- homelab-api's own gateway (_gateway in App.pm) treats every row there
-- as something it can forward a JSON/HTTP request to, and these speak
-- IMAP/SMTP/raw TCP, not HTTP. Keeping them in a separate table means
-- there is no way for a non-HTTP entry to ever be accidentally selected
-- by that forwarding path. `kind` is free text ('imap', 'smtp',
-- 'tcp-proxy-frontend', 'http-proxy-vhost', ...) rather than an enum --
-- this table exists for human-facing topology visibility
-- (`homelab-cli topology`), not for anything else to branch on
-- programmatically. `fronts` names the real backend(s) a proxy-type
-- entry (an HAProxy frontend, a webproxy vhost) routes traffic to, as
-- plain "name@host:port"-style strings -- deliberately not a foreign
-- key into this same table, since the thing on the other end might
-- itself have several instances (see PRIMARY KEY reasoning above) and
-- "which one(s)" is exactly the kind of detail this column exists to
-- state in plain language rather than model relationally.
CREATE TABLE IF NOT EXISTS api.infrastructure_registry (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    host        TEXT NOT NULL,
    port        INTEGER,
    description TEXT,
    fronts      TEXT[],
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (name, host, port)
);
