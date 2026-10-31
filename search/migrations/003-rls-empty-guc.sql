-- Row-level security must treat an EMPTY custom GUC as "not set".
--
-- The policies written in 001 cast directly:
--     account_id = current_setting('homelab.account_id', true)::bigint
--
-- current_setting(..., true) returns NULL for a GUC that has never been set
-- in the session, and NULL = anything is NULL, so an unscoped query correctly
-- returned nothing. That is what the Phase 1 isolation test measured -- on
-- FRESH connections.
--
-- But once set_config(..., is_local => true) has run in a transaction on a
-- backend, the setting does not go back to "never set" when that transaction
-- ends: it reverts to the EMPTY STRING. The next query on that same pooled
-- connection then evaluates ''::bigint and the statement dies with
--     invalid input syntax for type bigint: ""
--
-- Which is exactly what a connection pool guarantees will happen, so it broke
-- every signed-in request as soon as a connection was reused -- while every
-- test on a fresh connection kept passing.
--
-- nullif(..., '') maps both cases to NULL, so an unscoped query still returns
-- zero rows (fails closed) instead of raising. Re-created here rather than
-- edited in place because 001 has already run everywhere.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'accounts', 'mailboxes', 'threads', 'messages', 'message_files',
        'message_addresses', 'message_headers', 'message_bodies',
        'attachments', 'drive_items', 'drive_item_text',
        'index_queue', 'index_state'
    ] LOOP
        EXECUTE format('DROP POLICY IF EXISTS acct_isolation ON search.%I', t);
        EXECUTE format($q$CREATE POLICY acct_isolation ON search.%I
            USING (account_id
                   = nullif(current_setting('homelab.account_id', true), '')::bigint)$q$, t);
    END LOOP;
END $$;
