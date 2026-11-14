-- Post-cutover #83 (the review of 2026-11-14): the defaults that were
-- hard-coded become preferences; several reminders per event and a webhook
-- channel; a per-recipient switch for reminders of shared events; a
-- suggestion dismissed per account rather than per message. The trash needs
-- no schema: events are already soft-deleted (events.deleted_at).

ALTER TABLE calendar.user_prefs
    ADD COLUMN IF NOT EXISTS default_reminder_minutes INT      NOT NULL DEFAULT 10 CHECK (default_reminder_minutes BETWEEN 0 AND 20160),
    ADD COLUMN IF NOT EXISTS all_day_reminder_hour    SMALLINT NOT NULL DEFAULT 9  CHECK (all_day_reminder_hour BETWEEN 0 AND 23),
    ADD COLUMN IF NOT EXISTS default_duration_minutes INT      NOT NULL DEFAULT 60 CHECK (default_duration_minutes BETWEEN 5 AND 1440),
    ADD COLUMN IF NOT EXISTS date_format              TEXT     NOT NULL DEFAULT 'mdy' CHECK (date_format IN ('mdy', 'dmy', 'ymd')),
    ADD COLUMN IF NOT EXISTS remind_shared            BOOLEAN  NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS webhook_url              TEXT;

-- Several reminders per event (004 allowed one) and a second channel. The
-- unnamed constraints of 004 are found by what they are, not by name.
DO $$
DECLARE c TEXT;
BEGIN
    FOR c IN SELECT conname FROM pg_constraint WHERE conrelid = 'calendar.reminders'::regclass AND contype = 'u' LOOP
        EXECUTE format('ALTER TABLE calendar.reminders DROP CONSTRAINT %I', c);
    END LOOP;
    FOR c IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'calendar.reminders'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%channel%' LOOP
        EXECUTE format('ALTER TABLE calendar.reminders DROP CONSTRAINT %I', c);
    END LOOP;
END $$;
ALTER TABLE calendar.reminders ADD CONSTRAINT reminders_channel_check CHECK (channel IN ('email', 'webhook'));
CREATE UNIQUE INDEX IF NOT EXISTS reminders_event_minutes_channel_idx ON calendar.reminders (event_id, minutes_before, channel);

-- A suggestion dismissed by one recipient of a message stays for the others.
CREATE TABLE IF NOT EXISTS calendar.mail_link_dismissals (
    link_id      BIGINT      NOT NULL REFERENCES calendar.mail_links(id) ON DELETE CASCADE,
    user_email   TEXT        NOT NULL,
    dismissed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (link_id, user_email)
);
-- What 0.1.x recorded (one flag per message): credit it to every recipient.
INSERT INTO calendar.mail_link_dismissals (link_id, user_email, dismissed_at)
SELECT m.id, lower(a), m.dismissed_at
  FROM calendar.mail_links m, jsonb_array_elements_text(m.accounts) AS a
 WHERE m.dismissed_at IS NOT NULL
ON CONFLICT DO NOTHING;
