-- 010: common holidays (post-cutover #92).
--
-- One built-in calendar (kind = 'holidays') owned by a system address nobody
-- signs in as, filled by the Runner with ordinary all-day events from the
-- rules in Homelab::Calendar::Holidays, one row per holiday per year, for
-- the years now-1 .. now+10. A person switches it on in Settings, which is a
-- read share of that calendar to them (calendar.shares, as any shared
-- calendar), so the web, CalDAV, search and the sidebar need nothing new.
--
-- holiday_runs remembers the last fill (its window and a digest of what the
-- rules gave) so the Runner skips the work while nothing would change; a
-- changed rule or a new year runs it again, touching only the rows that
-- differ (so phones never re-download unchanged holidays).
--
-- holiday_checks is the watchdog's record: once a year the Runner asks
-- Nager.Date for the national public holidays of the current and the next
-- year and keeps any name the rules do not know (shown in Settings, exported
-- as a metric, alerted on). The row is claimed first so only one of the six
-- processes asks; a failed fetch is retried the next day.

ALTER TABLE calendar.calendars ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'personal';
ALTER TABLE calendar.calendars DROP CONSTRAINT IF EXISTS calendars_kind_check;
ALTER TABLE calendar.calendars ADD CONSTRAINT calendars_kind_check CHECK (kind IN ('personal', 'holidays'));
-- One calendar of each built-in kind.
CREATE UNIQUE INDEX IF NOT EXISTS calendars_one_per_builtin_kind ON calendar.calendars (kind) WHERE kind <> 'personal';

CREATE TABLE IF NOT EXISTS calendar.holiday_runs (
    kind          TEXT        PRIMARY KEY,                 -- 'fill'
    ran_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    from_year     INTEGER,
    through_year  INTEGER,
    digest        TEXT,
    rows_written  INTEGER     NOT NULL DEFAULT 0,
    rows_removed  INTEGER     NOT NULL DEFAULT 0,
    note          TEXT
);

CREATE TABLE IF NOT EXISTS calendar.holiday_checks (
    year          INTEGER     PRIMARY KEY,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    checked_at    TIMESTAMPTZ,
    ok            BOOLEAN,
    unknown       TEXT[]      NOT NULL DEFAULT '{}',
    note          TEXT
);
