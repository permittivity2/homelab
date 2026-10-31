-- Indexer bookkeeping that is not per-account.
--
-- Added because drive discovery had no watermark: it queried every row of
-- drive.files on every pass and enqueued all ~153 batches again, so the queue
-- grew without bound (119 -> 408 units in ten minutes), the same 30k files
-- were re-upserted forever, and -- worse -- mail indexing starved behind them,
-- sitting at 13,812 messages for six minutes while drive batches cycled.
-- Drive reaching a complete 30,497 items hid it: the counts looked finished
-- while the work never stopped.
CREATE TABLE IF NOT EXISTS search.index_meta (
    key        TEXT PRIMARY KEY,
    value      TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Deliberately NOT account-scoped and therefore deliberately WITHOUT row-level
-- security: it holds watermarks and timestamps, no user data. Every other
-- table in this schema that has an account_id has RLS forced on it; this one
-- has no account_id to scope by.
COMMENT ON TABLE search.index_meta IS
    'Indexer watermarks and timing. No user data, no account_id, no RLS by design.';
