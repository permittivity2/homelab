-- Post-cutover #78: "Find out more" -- research on an email's event through
-- the AI service's web-search tool. Its own consent (a second notice, hashed
-- like the first) and the "research every proposal" switch.
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS research_enabled        BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS research_consent_sha256 TEXT;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS research_consent_at     TIMESTAMPTZ;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS research_auto           BOOLEAN NOT NULL DEFAULT FALSE;
