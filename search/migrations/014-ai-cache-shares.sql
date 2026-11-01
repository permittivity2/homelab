-- A cached AI answer must not outlive a share either.
--
-- 012 put the question-asking contract into the cache key, because the
-- watermarks only covered the DATA moving. Shares are a third thing that
-- can change the right answer, and the watermarks miss them just as badly:
-- `watermarks()` is max(drive_item_id) per account, and granting or
-- revoking a share does not create or remove an index row, so the number
-- does not move.
--
-- The consequence is the one the whole feature is supposed to prevent.
-- Revoke a share and the file stops matching a live search immediately --
-- but a question already asked would keep being answered from cache,
-- describing a file the asker can no longer open, for the rest of the TTL.
--
-- The fingerprint is count + max(id) + max(revoked_at or created_at) over
-- the asking account's named shares. A grant moves the first two; a revoke
-- or an expiry moves the third. It is read from drive.shares on the
-- request path rather than stored here, so like the rest of this feature
-- there is no copy to go stale.
ALTER TABLE search.ai_cache
    ADD COLUMN IF NOT EXISTS share_fp TEXT NOT NULL DEFAULT '0:0:0';

-- The unique constraint IS the cache key, so it has to carry the new
-- column or two share states collide on one row.
ALTER TABLE search.ai_cache DROP CONSTRAINT IF EXISTS ai_cache_key;
ALTER TABLE search.ai_cache
    ADD  CONSTRAINT ai_cache_key
    UNIQUE (account_id, query_norm, mail_watermark, drive_watermark,
            contract_version, share_fp);
