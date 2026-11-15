-- Post-cutover #85: invitations. People asked to an event (attendees), their
-- answers, the iCalendar SEQUENCE a changed invitation carries, a queue for
-- the mail that goes out about it (so a slow mailer never blocks Save), and
-- the inbox the mail pool's milter drops an attendee's emailed answer into
-- (a METHOD:REPLY calendar part) for the runner to apply.

-- RFC 5546: the organizer bumps SEQUENCE when the time or place changes;
-- a client keeps the highest it has seen.
ALTER TABLE calendar.events ADD COLUMN IF NOT EXISTS sequence INTEGER NOT NULL DEFAULT 0;

-- One row per person invited to an event. The organizer is the calendar's
-- owner (never a row here). token is the RSVP capability (/i/<token>): the
-- link in the invitation needs no sign-in, as /c/ and /e/ links do not.
-- sequence_sent is the SEQUENCE of the last invitation mailed to this person
-- (NULL: none yet). Taking someone off the list deletes the row; the CANCEL
-- for them is queued with everything it needs in its payload.
CREATE TABLE IF NOT EXISTS calendar.event_attendees (
    id            BIGSERIAL   PRIMARY KEY,
    event_id      BIGINT      NOT NULL REFERENCES calendar.events(id) ON DELETE CASCADE,
    email         TEXT        NOT NULL,
    name          TEXT,
    status        TEXT        NOT NULL DEFAULT 'needs-action' CHECK (status IN ('needs-action', 'accepted', 'tentative', 'declined')),
    comment       TEXT,
    token         TEXT        NOT NULL UNIQUE,
    invited_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at  TIMESTAMPTZ,
    responded_via TEXT        CHECK (responded_via IN ('link', 'web', 'mail', 'cli')),
    sequence_sent INTEGER,
    CONSTRAINT event_attendees_one_per_event UNIQUE (event_id, email)
);
CREATE INDEX IF NOT EXISTS event_attendees_email_idx ON calendar.event_attendees (lower(email));

-- The mail about invitations, claimed by the runner as reminders are:
--   request  an invitation (new, or the event changed) to one attendee
--   cancel   the event is gone, or this person was taken off the list
--   reply    an attendee answered: a note to the organizer
-- A pending request to the same person is replaced when another is queued
-- (three quick edits send one mail); the mail is rendered from the event as
-- it is at send time.
CREATE TABLE IF NOT EXISTS calendar.notice_queue (
    id          BIGSERIAL   PRIMARY KEY,
    event_id    BIGINT      NOT NULL REFERENCES calendar.events(id) ON DELETE CASCADE,
    kind        TEXT        NOT NULL CHECK (kind IN ('request', 'cancel', 'reply')),
    recipient   TEXT        NOT NULL,
    payload     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    due_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    state       TEXT        NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'running', 'sent', 'failed')),
    attempts    INTEGER     NOT NULL DEFAULT 0,
    claimed_at  TIMESTAMPTZ,
    last_error  TEXT,
    sent_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS notice_queue_due_idx ON calendar.notice_queue (due_at) WHERE state = 'pending';

-- An answer that came by mail: the milter on the mail pool reads a
-- text/calendar part with METHOD:REPLY and drops the bare facts here (it
-- gets INSERT only, as it has on mail_links). The runner matches uid +
-- attendee to a row above and records the answer; processed_at and result
-- say what became of it.
CREATE TABLE IF NOT EXISTS calendar.itip_inbox (
    id             BIGSERIAL   PRIMARY KEY,
    uid            TEXT        NOT NULL,
    attendee_email TEXT        NOT NULL,
    partstat       TEXT        NOT NULL,
    sequence       INTEGER,
    comment        TEXT,
    message_id     TEXT,
    from_addr      TEXT,
    received_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at   TIMESTAMPTZ,
    result         TEXT
);
CREATE INDEX IF NOT EXISTS itip_inbox_pending_idx ON calendar.itip_inbox (received_at) WHERE processed_at IS NULL;
