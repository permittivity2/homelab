-- Match the index to the query that actually runs.
--
-- 011 created shares_shared_with_idx ON drive.shares (shared_with_email)
-- WHERE shared_with_email IS NOT NULL -- which is right for drive's own
-- "Shared with me" list, where the address is compared as stored.
--
-- homelab-search resolves the same question differently, and has to:
-- photo managers, mail clients and people are inconsistent about case,
-- "Huuvola@" and "huuvola@" are one person, and drive itself matches
-- case-insensitively elsewhere. So search's predicate is
--
--     lower(shared_with_email) = lower($1)
--
-- and a btree on the BARE column cannot serve a call on lower() of it.
-- Measured on the live cluster: Seq Scan on shares, "Rows Removed by
-- Filter: 7". Free at seven rows. Not free at ten thousand, and this runs
-- on the render path of every authenticated search page -- the results,
-- the counts and the file-type facets -- so it degrades with the number
-- of shares in the WHOLE SYSTEM, not per user, which is the kind of slope
-- nobody notices until it is steep.
--
-- Same partial predicate as 011: a NULL shared_with_email is a public
-- link, search excludes those unconditionally, and they do not belong in
-- an index built for identity lookups.
CREATE INDEX IF NOT EXISTS shares_shared_with_lower_idx
    ON drive.shares (lower(shared_with_email))
 WHERE shared_with_email IS NOT NULL;
