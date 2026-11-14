-- Post-cutover #79 (email reminders, the Share field) and #80 (proposals at
-- email arrival, the Suggestions list, the research-at-arrival entitlement).

-- One reminder per event at launch (several later): minutes before each
-- occurrence, by email. Reminded: the calendar's owner and everyone the
-- calendar or the event is shared with (Gardner, 2026-11-14).
CREATE TABLE IF NOT EXISTS calendar.reminders (
    id             BIGSERIAL   PRIMARY KEY,
    event_id       BIGINT      NOT NULL REFERENCES calendar.events(id) ON DELETE CASCADE,
    minutes_before INTEGER     NOT NULL DEFAULT 10 CHECK (minutes_before >= 0 AND minutes_before <= 20160),
    channel        TEXT        NOT NULL DEFAULT 'email' CHECK (channel IN ('email')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT reminders_one_per_event UNIQUE (event_id)
);

-- Where an account's reminders go: none listed = the account's own address.
CREATE TABLE IF NOT EXISTS calendar.reminder_addresses (
    user_email TEXT NOT NULL,
    address    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_email, address)
);

-- The send queue: one row per (reminder, occurrence, recipient), filled 48 h
-- ahead by the runner and claimed with FOR UPDATE SKIP LOCKED, so the three
-- pool nodes (two workers each) never send one twice.
CREATE TABLE IF NOT EXISTS calendar.reminder_queue (
    id            BIGSERIAL   PRIMARY KEY,
    reminder_id   BIGINT      NOT NULL REFERENCES calendar.reminders(id) ON DELETE CASCADE,
    event_id      BIGINT      NOT NULL REFERENCES calendar.events(id) ON DELETE CASCADE,
    recurrence_id TIMESTAMPTZ NOT NULL,          -- the occurrence's start instant
    recipient     TEXT        NOT NULL,
    due_at        TIMESTAMPTZ NOT NULL,
    state         TEXT        NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'running', 'sent', 'failed')),
    attempts      INTEGER     NOT NULL DEFAULT 0,
    claimed_at    TIMESTAMPTZ,
    last_error    TEXT,
    sent_at       TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT reminder_queue_once UNIQUE (reminder_id, recurrence_id, recipient)
);
CREATE INDEX IF NOT EXISTS reminder_queue_due_idx ON calendar.reminder_queue (due_at) WHERE state = 'pending';

-- #80: a proposal (and facts) computed at arrival, kept on the link's row and
-- expiring with it; the runner's claim state; dismissal from the list.
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS proposal       JSONB;
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS facts          JSONB;
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS proposed_at    TIMESTAMPTZ;
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS job_state      TEXT CHECK (job_state IN ('running', 'done', 'skipped', 'failed'));
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS job_started_at TIMESTAMPTZ;
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS job_attempts   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE calendar.mail_links ADD COLUMN IF NOT EXISTS dismissed_at   TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS mail_links_pending_idx ON calendar.mail_links (created_at) WHERE proposal IS NULL AND job_state IS NULL;

-- Consent #3 (propose before any click) and the research-at-arrival
-- entitlement (admin-set; #63's billing later) with the user's own switch.
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS auto_propose                 BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS auto_propose_consent_sha256  TEXT;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS auto_propose_consent_at      TIMESTAMPTZ;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS research_at_arrival_allowed  BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE calendar.account_settings ADD COLUMN IF NOT EXISTS research_at_arrival          BOOLEAN NOT NULL DEFAULT FALSE;
