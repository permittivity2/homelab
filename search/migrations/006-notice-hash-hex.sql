-- The notice hash is hex TEXT, not BYTEA.
--
-- 005 declared it BYTEA, which is correct in the abstract and wrong in
-- practice: binding 32 raw bytes through Mojo::Pg reliably is fiddly.
-- `{ bytea => $bytes }` is not a form it understands and dies with "Cannot
-- bind a reference"; a bare scalar is sent as text and arrives as 47 bytes
-- rather than 32, so the CHECK would have rejected it even if the insert
-- had gone through. The symptom was a 500 on the signed-in search page,
-- because the consent lookup runs on every render.
--
-- 64 hex characters are just as unique as 32 bytes, compare identically,
-- survive any driver without a type hint, and can be read in psql and
-- matched against `sha256sum` by hand. The column is small and the table
-- holds one row per distinct wording.
--
-- Converted rather than dropped, so this is safe whether or not 005 managed
-- to write anything on a given host.
ALTER TABLE search.ai_notices
    DROP CONSTRAINT IF EXISTS ai_notices_body_sha256_check;

ALTER TABLE search.ai_notices
    ALTER COLUMN body_sha256 TYPE TEXT USING encode(body_sha256, 'hex');

ALTER TABLE search.ai_notices
    ADD CONSTRAINT ai_notices_body_sha256_hex
    CHECK (body_sha256 ~ '^[0-9a-f]{64}$');
