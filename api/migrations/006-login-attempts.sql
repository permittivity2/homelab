-- Backs both rate limiting on /auth/login and /auth/register (per-IP,
-- see Homelab::API::App) and a structured, queryable record of auth
-- activity -- deliberately a real table, not just app log lines, so a
-- future abuse-detection tool (this project's own "bad-ips" system is
-- the obvious candidate, but that integration is explicitly out of
-- scope here -- this table is just the data it would need) can run a
-- normal SQL query against it instead of scraping journald. Every
-- attempt is logged, success or failure, since "which IPs are hammering
-- registration" matters even when individual attempts succeed.
CREATE TABLE IF NOT EXISTS api.login_attempts (
    id           BIGSERIAL PRIMARY KEY,
    ip           TEXT NOT NULL,
    email        TEXT,
    endpoint     TEXT NOT NULL,   -- 'login' or 'register'
    success      BOOLEAN NOT NULL,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_ip_time ON api.login_attempts(ip, attempted_at);
