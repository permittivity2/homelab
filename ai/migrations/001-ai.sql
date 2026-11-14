-- homelab-ai: one row per request that went through the service, whether it
-- succeeded or not. This is the fleet's record of what it asks a third party
-- and what that costs. No prompt or answer text is ever stored here: the
-- callers hold the consent for the content; this table holds the accounting.

CREATE TABLE IF NOT EXISTS ai.requests (
    id                 BIGSERIAL PRIMARY KEY,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    client             TEXT        NOT NULL,          -- the caller, by its configured name (search, calendar, ...)
    consent            TEXT        NOT NULL,          -- the consent the caller says this was made under (its notice id/hash)
    account            TEXT,                          -- opaque per-account key from the caller, if it sends one
    model              TEXT,                          -- what was asked for
    model_used         TEXT,                          -- what answered (server-side fallback may differ)
    status             INTEGER     NOT NULL,          -- upstream HTTP status; 0 = never reached; 429 = our own budget
    error              TEXT,
    latency_ms         INTEGER,
    input_tokens       INTEGER,
    output_tokens      INTEGER,
    cache_read_tokens  INTEGER,
    cache_write_tokens INTEGER,
    max_tokens         INTEGER
);
CREATE INDEX IF NOT EXISTS ai_requests_client_day_idx ON ai.requests (client, created_at);
CREATE INDEX IF NOT EXISTS ai_requests_account_idx ON ai.requests (account, created_at) WHERE account IS NOT NULL;
