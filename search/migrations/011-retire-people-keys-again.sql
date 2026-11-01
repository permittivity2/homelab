-- Retire the flat people.* metadata keys. Again.
--
-- 009 deleted them when search.people / search.photo_faces replaced them,
-- and they came straight back: the key list in Homelab::Search::Extract
-- still named them, and the indexer interns a key the first time it sees
-- one. So the same fact lived in two places -- a normalized face row AND
-- a joined string -- which is precisely what 009 set out to end. 2,059
-- rows of each had reappeared by the time it was noticed.
--
-- THE LESSON, recorded because the next person will hit it: deleting rows
-- is not retiring a key. The CATALOGUE is what creates keys, so a
-- retirement has to land there first. Extract's catalogue no longer lists
-- them (EXTRACTOR_VERSION 7), which is what makes this delete stick.
SELECT set_config('homelab.indexer', 'on', true);

DELETE FROM search.drive_metadata
 WHERE key_id IN (SELECT key_id FROM search.metadata_keys
                   WHERE key_name IN ('people.names', 'people.count'));

DELETE FROM search.metadata_keys
 WHERE key_name IN ('people.names', 'people.count');
