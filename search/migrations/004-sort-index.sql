-- Make the default ordering index-friendly.
--
-- Both result lists are ordered by coalesce(date_a, date_b) DESC. The indexes
-- from 001 are on the bare columns -- (account_id, sent_at DESC) and
-- (account_id, content_created_at DESC) -- which an expression in ORDER BY
-- cannot use, so Postgres sorted every row of the account before applying
-- LIMIT 50. On the largest mailbox that is 25,798 rows and measured 5.2
-- SECONDS for an unfiltered listing.
--
-- The application no longer issues that unfiltered query at all (an empty
-- form is a landing page, not a search for everything), so this is no longer
-- on the hot path -- but every *filtered* search is ordered the same way, and
-- an index the planner can actually use is worth more than relying on the
-- filter being selective.
CREATE INDEX IF NOT EXISTS idx_messages_acct_bestdate
    ON search.messages (account_id, (coalesce(sent_at, received_at)) DESC);

CREATE INDEX IF NOT EXISTS idx_drive_acct_bestdate
    ON search.drive_items (account_id, (coalesce(content_created_at, uploaded_at)) DESC);
