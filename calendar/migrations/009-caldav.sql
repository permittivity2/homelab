-- homelab-calendar 0.5.0 (post-cutover #84): CalDAV, so phones and desktop
-- calendar apps sync both ways.

-- App passwords: the credential a phone's calendar app types (HTTP Basic on
-- /dav/*). Never the SSO password, never a Bearer token. The secret is random
-- (about 120 bits) and shown once; the row keeps a salted SHA-256 of it. See
-- Model::create_app_password for why that and not argon2.
CREATE TABLE IF NOT EXISTS calendar.app_passwords (
    id              BIGSERIAL PRIMARY KEY,
    user_email      TEXT        NOT NULL,
    label           TEXT        NOT NULL,
    salt            TEXT        NOT NULL,
    secret_hash     TEXT        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at    TIMESTAMPTZ,
    last_used_agent TEXT,
    revoked_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS app_passwords_user_idx ON calendar.app_passwords (lower(user_email)) WHERE revoked_at IS NULL;

-- The sync token (RFC 6578) and every object's ETag come from ONE counter:
-- change_seq, stamped on an event by a trigger whenever its row changes (made,
-- edited, moved to the trash, restored) and whenever one of its parts changes
-- (an occurrence moved or cancelled, an attendee answers). A calendar's token
-- is the largest change_seq among its events, deleted ones included: a
-- deletion is a change a phone must hear of.
CREATE SEQUENCE IF NOT EXISTS calendar.change_seq;
ALTER TABLE calendar.events ADD COLUMN IF NOT EXISTS change_seq BIGINT NOT NULL DEFAULT 0;
UPDATE calendar.events SET change_seq = nextval('calendar.change_seq') WHERE change_seq = 0;
CREATE INDEX IF NOT EXISTS events_change_seq_idx ON calendar.events (calendar_id, change_seq);

CREATE OR REPLACE FUNCTION calendar.events_stamp_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.change_seq := nextval('calendar.change_seq');
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS events_stamp_change ON calendar.events;
CREATE TRIGGER events_stamp_change BEFORE INSERT OR UPDATE ON calendar.events
    FOR EACH ROW EXECUTE FUNCTION calendar.events_stamp_change();

CREATE OR REPLACE FUNCTION calendar.event_parts_stamp_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE calendar.events SET change_seq = nextval('calendar.change_seq') WHERE id = COALESCE(NEW.event_id, OLD.event_id);
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS event_exceptions_stamp_change ON calendar.event_exceptions;
CREATE TRIGGER event_exceptions_stamp_change AFTER INSERT OR UPDATE OR DELETE ON calendar.event_exceptions
    FOR EACH ROW EXECUTE FUNCTION calendar.event_parts_stamp_change();
DROP TRIGGER IF EXISTS event_attendees_stamp_change ON calendar.event_attendees;
CREATE TRIGGER event_attendees_stamp_change AFTER INSERT OR UPDATE OR DELETE ON calendar.event_attendees
    FOR EACH ROW EXECUTE FUNCTION calendar.event_parts_stamp_change();

-- The path segment a CalDAV client made a calendar under (MKCALENDAR picks
-- its own, usually a UUID); a calendar without one is reached by its number.
ALTER TABLE calendar.calendars ADD COLUMN IF NOT EXISTS dav_name TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS calendars_dav_name_idx ON calendar.calendars (lower(owner_email), dav_name) WHERE dav_name IS NOT NULL;
