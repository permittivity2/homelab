-- A cached answer must not outlive the contract that produced it.
--
-- THE BUG THIS CLOSES, concretely. ai_cache is keyed on
-- (account_id, query_norm, mail_watermark, drive_watermark). The
-- watermarks mean "a cached answer can never outlive the data it
-- described", which was the whole design and is still right -- new mail or
-- a new upload moves the watermark and the key changes with it.
--
-- What the key did NOT cover is a change to the question-asking end: the
-- system prompt, the tool schemas, the shape of a tool result. "photos
-- with jeff" answered "I couldn't find any" because search_drive had no
-- `person` parameter and handed the model photos with an empty snippet and
-- no reason. Fixing that changed the prompt and the tools -- and the wrong
-- answer stayed cached, because the data had not moved. The person who
-- reported it would have retried and been told the same thing by a 25 ms
-- cache hit, with nothing in the logs to say why.
--
-- So the producer's version joins the key, exactly as
-- drive_items.extractor_version already does for the indexer: bump the
-- constant in the code and every answer built by the old contract stops
-- being found. The rows are left to expire on their own TTL rather than
-- deleted, so this is not a cache stampede.
ALTER TABLE search.ai_cache
    ADD COLUMN IF NOT EXISTS contract_version SMALLINT NOT NULL DEFAULT 0;

-- The unique constraint IS the cache key, so it has to carry the new
-- column or two contracts collide on one row.
ALTER TABLE search.ai_cache
    DROP CONSTRAINT IF EXISTS ai_cache_account_id_query_norm_mail_watermark_drive_waterma_key;

ALTER TABLE search.ai_cache
    DROP CONSTRAINT IF EXISTS ai_cache_key;
ALTER TABLE search.ai_cache
    ADD  CONSTRAINT ai_cache_key
    UNIQUE (account_id, query_norm, mail_watermark, drive_watermark, contract_version);
