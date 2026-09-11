-- Cross-domain "send as" + inbound routing, one grant with two
-- independent effects. destination is a real api.users.email this
-- domain/address routes to; source_pattern is either an exact address
-- ('sales@forge.name') or a catch-all domain wildcard ('@forge.name').
-- No FK to api.users -- same "no direct cross-schema reference, HTTP
-- between features" convention as domainadmin.recipient_access.
--
-- active and send_enabled are DELIBERATELY separate flags, not one
-- flag reused for both directions:
--   - active        governs INBOUND routing (virtual_alias_maps) only
--   - send_enabled  governs OUTBOUND authorization (smtpd_sender_login_maps) only
-- This is what makes "let a user keep receiving mail at a domain but
-- suspend their ability to send as it" a simple UPDATE instead of a
-- delete-and-recreate that would also break inbound delivery.
CREATE TABLE IF NOT EXISTS domainadmin.mail_aliases (
    id             BIGSERIAL PRIMARY KEY,
    source_pattern TEXT NOT NULL UNIQUE,
    destination    TEXT NOT NULL,
    active         BOOLEAN NOT NULL DEFAULT TRUE,
    send_enabled   BOOLEAN NOT NULL DEFAULT TRUE,
    created_by     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mail_aliases_destination ON domainadmin.mail_aliases(destination) WHERE active = true;
