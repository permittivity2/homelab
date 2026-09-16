-- Fleet agent: a lightweight, non-blocking service on every host running
-- any homelab-* feature, reporting a declarative manifest
-- (/etc/homelab/services/*.yml) checked against reality. Replaces
-- api.infrastructure_registry/`homelab-cli topology` (a separate
-- migration removes that table once the new system is proven) --
-- deliberately NOT extending api.service_registry, which stays exactly
-- as-is for its own distinct, latency-sensitive job (_gateway's live
-- request-routing lookup).

INSERT INTO api.roles (name, description) VALUES
    ('system_agent', 'Non-human system identity: a fleet agent pushing its own '
        || 'heartbeat, or homelab-api''s own outbound identity for pulling live '
        || 'status from an agent. Never used for interactive login -- see '
        || '_login''s explicit guard against this role.')
ON CONFLICT (name) DO NOTHING;

-- One row per host running an agent. address/agent_port is where
-- homelab-api reaches back IN to that host's agent for a live pull
-- (GET /status) -- populated from the agent's own heartbeat, since it
-- knows its own reachable address the same way every other
-- self-registering service already does (an explicit advertise_host
-- debconf answer, this project's consistent convention over
-- auto-detection).
CREATE TABLE IF NOT EXISTS api.hosts (
    hostname       TEXT PRIMARY KEY,
    address        TEXT NOT NULL,
    agent_port     INTEGER NOT NULL,
    agent_version  TEXT,
    last_heartbeat TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One row per (hostname, service_name) -- NOT collapsed to one row per
-- service_name, so two real instances of the same service on two
-- different hosts (HAProxy load-balancing multiple dovecot instances,
-- say) each get their own row naturally, no special-casing needed.
-- expected = declared in that host's manifest; actual = verified live
-- by the agent (systemd_unit active / tcp_port listening, per the
-- manifest's own `check` block) at checked_at. A mismatch in EITHER
-- direction is the interesting signal: expected=true/actual=false is a
-- real outage; expected=false/actual=true is an undeclared surprise
-- (exactly what the loopback-only stock `postfix` on every ct0N
-- container would have been, had this existed sooner).
CREATE TABLE IF NOT EXISTS api.host_service_status (
    id           BIGSERIAL PRIMARY KEY,
    hostname     TEXT NOT NULL REFERENCES api.hosts(hostname) ON DELETE CASCADE,
    service_name TEXT NOT NULL,
    package_name TEXT,
    kind         TEXT,
    expected     BOOLEAN NOT NULL,
    actual       BOOLEAN NOT NULL,
    description  TEXT,
    checked_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (hostname, service_name)
);

-- Short-lived, single-use codes minted by a site_admin (POST
-- /api/v1/admin/agent/enroll) and redeemed once by a new agent's
-- first-boot setup (POST /api/v1/agent/enroll/redeem) to get its first
-- JWT + refresh_token -- the one genuinely new piece of this whole
-- design, everything downstream (rotating refresh tokens, session
-- revocation) reuses machinery that already exists for human logins.
-- Modeled deliberately on OAuth2 device-authorization-grant codes
-- (RFC 8628): short window, one redemption, tied to a specific
-- identity (hostname) chosen at mint time, not the redeemer's choice.
CREATE TABLE IF NOT EXISTS api.agent_enrollment_codes (
    code       TEXT PRIMARY KEY,
    hostname   TEXT NOT NULL,
    issued_by  TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at    TIMESTAMPTZ
);

-- homelab-api's own outbound identity for pulling live status from an
-- agent (the PUSH direction -- an agent's own heartbeat -- uses that
-- agent's own enrolled identity instead; this row is specifically for
-- the reverse direction). Seeded here, not via the enroll/redeem flow,
-- since it's not a remote thing that needs bootstrapping -- it's
-- homelab-api's own permanent identity. password_hash is a random,
-- never-disclosed value: this account is only ever reachable via
-- _login's own explicit system_agent guard rejecting it outright, the
-- same defense-in-depth belt this migration adds for every enrolled
-- agent identity too.
-- md5(random-ish text), not gen_random_bytes() -- no pgcrypto
-- dependency anywhere else in this project, not worth adding one for a
-- single disposable value nobody is ever meant to know or use as a
-- real password.
INSERT INTO api.users (email, password_hash, active)
    SELECT 'system@homelab-api.internal', md5(random()::text || clock_timestamp()::text), true
    WHERE NOT EXISTS (SELECT 1 FROM api.users WHERE email = 'system@homelab-api.internal');

INSERT INTO api.user_roles (user_id, role_id)
    SELECT u.id, r.id FROM api.users u, api.roles r
    WHERE u.email = 'system@homelab-api.internal' AND r.name = 'system_agent'
    ON CONFLICT DO NOTHING;
