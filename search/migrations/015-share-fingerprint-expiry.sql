-- The share fingerprint gained a fourth component.
--
-- 014 added share_fp to the AI answer cache key so a grant or a revoke
-- retires an answer built before it. It was three numbers -- count, max
-- id, max(revoked_at|created_at) -- and all three are written by somebody
-- doing something. An `expires_at` passing is not: no row changes, time
-- passes, and the fingerprint sat still while a share stopped being live.
-- The live search path has always got expiry right; only the cached
-- answer could lag, for up to the cache TTL.
--
-- So the fourth component is a count of the shares live AT READ TIME,
-- which drops by one the instant an expiry passes. The default moves with
-- it: a row stamped '0:0:0' can never again match a freshly computed
-- fingerprint, which retires the pre-existing cache exactly once. That is
-- the intended effect, not a side effect -- those answers were computed
-- under the three-number contract.
ALTER TABLE search.ai_cache
    ALTER COLUMN share_fp SET DEFAULT '0:0:0:0';
