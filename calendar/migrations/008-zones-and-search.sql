-- 008: the calendar on the move (post-cutover #88, #89) and search by meaning (#87).
--
-- events.pinned: a pinned event shows its own zone's clock wherever the viewer
-- is ("1:30 PM CST" on a phone in Montana); an unpinned one is converted to
-- the viewer's zone. Display only: the instant stored never changes.
ALTER TABLE calendar.events ADD COLUMN IF NOT EXISTS pinned BOOLEAN NOT NULL DEFAULT FALSE;

-- user_prefs.timezone NULL now means "Local": the zone of the device the
-- person is looking from, as the browser reports it. device_zone is the last
-- one a browser reported, so mail sent while nobody is looking (reminders)
-- can be written in it.
ALTER TABLE calendar.user_prefs ADD COLUMN IF NOT EXISTS device_zone    TEXT;
ALTER TABLE calendar.user_prefs ADD COLUMN IF NOT EXISTS device_zone_at TIMESTAMPTZ;

-- Every account starts on Local. Until now the column was filled by the page
-- itself with the first browser's zone, so a value here never meant a choice
-- was made; the settings page offers a fixed zone to anyone who wants one.
UPDATE calendar.user_prefs SET timezone = NULL, updated_at = NOW() WHERE timezone IS NOT NULL;
