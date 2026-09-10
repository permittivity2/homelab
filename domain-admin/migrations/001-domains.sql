-- The anchor table: every domain this ecosystem manages DNS for and/or
-- accepts mail for. Deliberately does NOT duplicate DNS zone content --
-- PowerDNS's own domains/records tables, in its separate `powerdns`
-- database, stay the single source of truth for that. dns_managed only
-- records whether THIS ecosystem is responsible for the zone existing.
CREATE TABLE IF NOT EXISTS domainadmin.domains (
    id           BIGSERIAL PRIMARY KEY,
    domain_name  TEXT NOT NULL UNIQUE,
    mail_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    dns_managed  BOOLEAN NOT NULL DEFAULT TRUE,
    active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_by   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- What homelab-postfix's virtual_mailbox_domains pgsql: map queries
-- (see ../../postfix/config/pgsql-virtual-domains.cf.template) once
-- Phase 3 replaces its previous single hardcoded debconf value. Partial
-- index: this is the hot path Postfix hits on every RCPT TO.
CREATE INDEX IF NOT EXISTS idx_domains_mail_lookup
    ON domainadmin.domains(domain_name) WHERE mail_enabled = TRUE AND active = TRUE;
