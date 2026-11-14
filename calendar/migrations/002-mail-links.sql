-- Mail -> calendar links (#74 phase 3) and the AI proposal consent (phase 4).
--
-- account_settings: per-account switches, set from myaccount (through the
-- api gateway) or from this app's /settings page. The block-link milter on the
-- mail nodes READS mail_links_enabled for each recipient of an inbound
-- message; nothing else outside this app touches the table.
--
-- mail_links: one row per inbound message for a consenting recipient, written
-- by the milter (INSERT only), read here when the person opens the link in
-- the email. It holds what pre-filling an event needs and nothing more: the
-- subject, the sender, the Date header and a BOUNDED plain-text excerpt. Rows
-- expire after 30 days (expires_at) and are deleted by the app's own sweep.

CREATE TABLE IF NOT EXISTS calendar.account_settings (
    user_email            TEXT        PRIMARY KEY,
    mail_links_enabled    BOOLEAN     NOT NULL DEFAULT FALSE,
    mail_links_enabled_at TIMESTAMPTZ,
    -- The AI proposal: the person agreed to the notice whose words hash to
    -- ai_consent_sha256 (Homelab::Calendar::Consent). A change of wording
    -- invalidates the record, and they are asked again.
    ai_enabled            BOOLEAN     NOT NULL DEFAULT FALSE,
    ai_consent_sha256     TEXT,
    ai_consent_at         TIMESTAMPTZ,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS calendar.mail_links (
    id            BIGSERIAL   PRIMARY KEY,
    token         TEXT        NOT NULL UNIQUE,
    -- The consenting recipients of the message, lower-cased, as a JSON array:
    -- one message, one link, several accounts (To, Cc, Bcc), as block-link's
    -- pending_links does it. Opening the link signed in as any of them works.
    accounts      JSONB       NOT NULL,
    message_id    TEXT,
    subject       TEXT,
    from_addr     TEXT,
    date_header   TEXT,
    text_excerpt  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ NOT NULL,
    used_at       TIMESTAMPTZ,
    event_id      BIGINT      REFERENCES calendar.events(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS mail_links_expires_idx ON calendar.mail_links (expires_at);
