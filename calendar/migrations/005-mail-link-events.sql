-- Post-cutover #81: a link in an email reused after it already became an
-- event. Which events EACH ACCOUNT made from a link: one link row serves every
-- recipient of the message (accounts is a JSON array), so "already added" has
-- to be judged per account, and "Add another event" means one link can become
-- several events. mail_links.event_id / used_at stay as "the latest event
-- anyone made from this link": the runner's cheap gate against proposing a
-- link that already became an event.
--
-- Events are soft-deleted (events.deleted_at), so readers that need a LIVE
-- event join events and filter deleted_at IS NULL; the cascade below only
-- matters for the rare hard delete.
CREATE TABLE IF NOT EXISTS calendar.mail_link_events (
    link_id     BIGINT      NOT NULL REFERENCES calendar.mail_links(id) ON DELETE CASCADE,
    user_email  TEXT        NOT NULL,
    event_id    BIGINT      NOT NULL REFERENCES calendar.events(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (link_id, event_id)
);
CREATE INDEX IF NOT EXISTS mail_link_events_account_idx ON calendar.mail_link_events (link_id, user_email);

-- What 0.1.4-0.1.9 recorded (one event per link, no account): the event's
-- creator is the account that made it. Deleted events are kept here on
-- purpose: a suggestion an account once saved stays consumed for it.
INSERT INTO calendar.mail_link_events (link_id, user_email, event_id, created_at)
SELECT m.id, lower(e.created_by_email), m.event_id, COALESCE(m.used_at, e.created_at)
  FROM calendar.mail_links m
  JOIN calendar.events e ON e.id = m.event_id
 WHERE m.event_id IS NOT NULL
ON CONFLICT DO NOTHING;
