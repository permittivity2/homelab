-- GPS is no longer withheld from AI mode.
--
-- A product decision, recorded here because the reasoning matters more
-- than the flag: coordinates without a face carry little on their own, and
-- every request from this service already shares one Anthropic workspace,
-- so a request is not labelled with whose it is.
--
-- The counter-argument, noted and overruled rather than missed: phone GPS
-- plus timestamps is a home address without needing a face -- a cluster
-- recurring overnight across years is where somebody sleeps -- and within
-- a single request the model sees one library's photos together, so the
-- points are linkable to each other whatever the workspace holds.
--
-- `people.names` stays SENSITIVE. It was not part of this decision: a name
-- identifies a third party directly, and the people tagged in somebody's
-- photos never saw the consent notice because they are not users.
--
-- Done as a migration rather than by editing Extract's catalogue alone,
-- because the catalogue is only re-read when a key is next interned --
-- which happens on a fresh indexer process the next time a photo with
-- that key is indexed. That is a real update, but at an unpredictable
-- moment; a migration makes it happen at deploy.
UPDATE search.metadata_keys
   SET sensitive = false
 WHERE key_name IN ('gps.latitude', 'gps.longitude', 'gps.altitude_m');
