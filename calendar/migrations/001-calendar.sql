-- homelab-calendar: calendars, events, recurrence exceptions, sharing and
-- per-account preferences. See README.md for the model; the short version:
--
--   * A calendar belongs to an account (owner_email). Accounts live in
--     api.users, a different schema owned by a different role, so ownership is
--     keyed by address here as in every other app schema (drive, block_link).
--   * An event is stored ONCE: its first occurrence as wall-clock time in an
--     IANA zone, plus an RFC 5545 RRULE when it repeats. Occurrences are
--     computed, never stored; per-occurrence edits and cancellations are rows
--     in event_exceptions keyed by the occurrence's original start instant
--     (the iCalendar RECURRENCE-ID).
--   * Sharing is drive's shape (drive/migrations/011-shares.sql): every share
--     has a token; shared_with_email NULL means "anyone with the link".

CREATE TABLE IF NOT EXISTS calendar.calendars (
    id            BIGSERIAL PRIMARY KEY,
    owner_email   TEXT        NOT NULL,
    name          TEXT        NOT NULL,
    color         TEXT        NOT NULL DEFAULT '#6f94b8',
    description   TEXT,
    -- The zone new events on this calendar start in. An event carries its own
    -- zone too (below), so moving a calendar never rewrites history.
    timezone      TEXT        NOT NULL DEFAULT 'America/Chicago',
    -- The one calendar an account's quick-add goes to; created on first visit.
    is_default    BOOLEAN     NOT NULL DEFAULT FALSE,
    position      INTEGER     NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Soft delete, as drive does: the row stays for the audit trail and so a
    -- share token for it answers "gone" rather than "never existed".
    deleted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS calendars_owner_idx ON calendar.calendars (owner_email) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS calendar.events (
    id             BIGSERIAL PRIMARY KEY,
    calendar_id    BIGINT      NOT NULL REFERENCES calendar.calendars(id) ON DELETE CASCADE,
    -- iCalendar UID: what an .ics export and, later, meeting invitations
    -- identify the event by across systems. Assigned on creation, never changed.
    uid            TEXT        NOT NULL UNIQUE,
    title          TEXT        NOT NULL,
    description    TEXT,
    location       TEXT,
    all_day        BOOLEAN     NOT NULL DEFAULT FALSE,
    -- Timed events: instants. Also filled for all-day events (midnight in the
    -- event zone) so ONE pair of columns answers every window query.
    starts_at      TIMESTAMPTZ NOT NULL,
    ends_at        TIMESTAMPTZ NOT NULL,      -- exclusive
    -- All-day events: the dates, end exclusive (iCalendar's convention), so a
    -- one-day event has end_date = start_date + 1.
    start_date     DATE,
    end_date       DATE,
    -- The IANA zone the wall clock lives in. 09:00 here stays 09:00 across a
    -- DST change; the instant in starts_at is derived from it, not the other
    -- way round.
    timezone       TEXT        NOT NULL,
    -- RFC 5545 RRULE value (no "RRULE:" prefix), NULL for a single event.
    rrule          TEXT,
    -- The instant after which the rule produces nothing (UNTIL, or the last
    -- of COUNT occurrences), computed on write; NULL = open-ended. Lets the
    -- window query skip rules that ended long ago without expanding them.
    recurrence_end TIMESTAMPTZ,
    color          TEXT,
    created_by_email TEXT      NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at     TIMESTAMPTZ,

    CONSTRAINT events_end_after_start CHECK (ends_at > starts_at),
    CONSTRAINT events_all_day_dates   CHECK (NOT all_day OR (start_date IS NOT NULL AND end_date IS NOT NULL AND end_date > start_date))
);
-- The window query: every live event of a calendar that could have an
-- occurrence in [window_start, window_end).
CREATE INDEX IF NOT EXISTS events_window_idx ON calendar.events (calendar_id, starts_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS events_recurring_idx ON calendar.events (calendar_id, recurrence_end) WHERE deleted_at IS NULL AND rrule IS NOT NULL;

-- One occurrence of a repeating event that differs from the rule: moved,
-- retitled, or cancelled. recurrence_id is the occurrence's ORIGINAL start
-- instant as the rule produced it; the override columns are NULL where the
-- occurrence keeps the event's own value.
CREATE TABLE IF NOT EXISTS calendar.event_exceptions (
    id            BIGSERIAL PRIMARY KEY,
    event_id      BIGINT      NOT NULL REFERENCES calendar.events(id) ON DELETE CASCADE,
    recurrence_id TIMESTAMPTZ NOT NULL,
    cancelled     BOOLEAN     NOT NULL DEFAULT FALSE,
    title         TEXT,
    description   TEXT,
    location      TEXT,
    all_day       BOOLEAN,
    starts_at     TIMESTAMPTZ,
    ends_at       TIMESTAMPTZ,
    start_date    DATE,
    end_date      DATE,
    color         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT event_exceptions_one_per_occurrence UNIQUE (event_id, recurrence_id),
    CONSTRAINT event_exceptions_end_after_start CHECK (starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at)
);
-- A moved occurrence can land in a window its original date is not in.
CREATE INDEX IF NOT EXISTS event_exceptions_moved_idx ON calendar.event_exceptions (event_id, starts_at) WHERE starts_at IS NOT NULL;

-- Sharing: a whole calendar or one event, to a named account or to anyone
-- holding the link. EVERY share gets a token (the link can always be copied
-- again). permission is READ (see) or EDIT (change, add, remove events; never
-- the calendar's own settings or its shares). detail applies to link shares:
-- 'busy' shows when the owner is busy and nothing else.
CREATE TABLE IF NOT EXISTS calendar.shares (
    id                BIGSERIAL PRIMARY KEY,
    token             TEXT        NOT NULL UNIQUE,
    owner_email       TEXT        NOT NULL,
    calendar_id       BIGINT      REFERENCES calendar.calendars(id) ON DELETE CASCADE,
    event_id          BIGINT      REFERENCES calendar.events(id)    ON DELETE CASCADE,
    shared_with_email TEXT,
    permission        TEXT        NOT NULL DEFAULT 'read' CHECK (permission IN ('read', 'edit')),
    detail            TEXT        NOT NULL DEFAULT 'full' CHECK (detail IN ('full', 'busy')),
    expires_at        TIMESTAMPTZ,
    revoked_at        TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accessed_at       TIMESTAMPTZ,
    access_count      BIGINT      NOT NULL DEFAULT 0,

    CONSTRAINT shares_one_target CHECK ((calendar_id IS NOT NULL) <> (event_id IS NOT NULL)),
    -- A link share cannot be an edit share: nobody is accountable for it.
    CONSTRAINT shares_link_is_read_only CHECK (shared_with_email IS NOT NULL OR permission = 'read')
);
CREATE INDEX IF NOT EXISTS shares_owner_idx       ON calendar.shares (owner_email);
CREATE INDEX IF NOT EXISTS shares_shared_with_idx ON calendar.shares (lower(shared_with_email)) WHERE shared_with_email IS NOT NULL;
CREATE INDEX IF NOT EXISTS shares_calendar_idx    ON calendar.shares (calendar_id) WHERE calendar_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS shares_event_idx       ON calendar.shares (event_id)    WHERE event_id    IS NOT NULL;

-- Per-account display preferences. timezone here is the app's own copy; once
-- the account carries a zone (homelab-api, phase 2 of the plan) that one wins
-- and this column is only a fallback for an account that has none.
CREATE TABLE IF NOT EXISTS calendar.user_prefs (
    user_email    TEXT        PRIMARY KEY,
    timezone      TEXT,
    week_start    SMALLINT    NOT NULL DEFAULT 0 CHECK (week_start IN (0, 1, 6)),   -- Sunday, Monday, Saturday
    time_format   TEXT        NOT NULL DEFAULT '12h' CHECK (time_format IN ('12h', '24h')),
    default_view  TEXT        NOT NULL DEFAULT 'month' CHECK (default_view IN ('month', 'week', 'day', 'agenda')),
    show_shared_events BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Which calendars (own and shared) a person has UNticked in the sidebar. A
-- missing row means visible, so a new calendar or a new share shows up at
-- once.
CREATE TABLE IF NOT EXISTS calendar.calendar_visibility (
    user_email  TEXT   NOT NULL,
    calendar_id BIGINT NOT NULL REFERENCES calendar.calendars(id) ON DELETE CASCADE,
    visible     BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (user_email, calendar_id)
);
