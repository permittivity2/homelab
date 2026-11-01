-- AI mode (plan §7): consent, accounting, the topic gate's record, and the
-- response cache.
--
-- NOTHING HERE STORES A MODEL'S OUTPUT AS AUTHORITY. The cache stores a
-- rendered answer so an identical question does not pay twice; every id in
-- it is re-resolved under the account's own RLS scope before anything is
-- shown. See lib/Homelab/Search/AI.pm.
--
-- SHAPE. Six tables, three of which are the same small-lookup pattern the
-- rest of this schema already uses (mime_types, address_roles,
-- header_names, maildir_subs): a repeated string becomes a row and an id.
--
--   ai_models      the model names we call            (lookup)
--   ai_outcomes    how an attempt ended               (lookup)
--   ai_notices     the consent texts, by content hash
--   ai_consent     append-only grant/revoke log
--   ai_requests    EVERY attempt: usage, cost, outcome, and the gate's log
--   ai_cache       the response cache
--
-- ai_requests is deliberately ONE table doing three jobs, because they are
-- the same fact viewed three ways: the monthly budget is a sum over it, the
-- rate limit is a count over it, and "is the topic gate too tight" is a
-- filter on it. Three tables would have stored one event three times.
--
-- MONEY IS AN INTEGER. cost_micros is millionths of a US dollar. A float
-- dollar amount summed over a month does not add up to what was billed.
-- The PRICE LIST is config, not data: prices change, and a historical row
-- must keep the cost computed when the call was made rather than silently
-- re-pricing itself later.

-- ----------------------------------------------------------------- lookups
CREATE TABLE IF NOT EXISTS search.ai_models (
    model_id    SMALLSERIAL PRIMARY KEY,
    model       TEXT NOT NULL UNIQUE CHECK (model = lower(model))
);

CREATE TABLE IF NOT EXISTS search.ai_outcomes (
    outcome_id  SMALLSERIAL PRIMARY KEY,
    outcome     TEXT NOT NULL UNIQUE CHECK (outcome = lower(outcome))
);

-- The closed set of ways an attempt can end. Seeded here so a new value is
-- a deliberate migration rather than whatever string a caller passed.
INSERT INTO search.ai_outcomes (outcome) VALUES
    ('answered'),          -- the model answered and we rendered it
    ('cached'),            -- served from ai_cache, no API call
    ('off_topic'),         -- the gate declined before the expensive call
    ('not_consented'),     -- reached the endpoint without a current consent
    ('rate_limited'),
    ('budget_exhausted'),
    ('refusal'),           -- stop_reason = refusal, from a safety classifier
    ('no_tool_call'),      -- tool_choice is auto; the model answered without searching
    ('timeout'),
    ('api_error'),
    ('disabled')           -- kill switch, or no API key configured
ON CONFLICT (outcome) DO NOTHING;

-- ---------------------------------------------------------- consent texts
-- The notice is stored ONCE and referenced, not copied onto every consent
-- row: the body depends on the hash, not on the account. Keeping the text
-- (rather than only its hash) is the point -- a consent record you cannot
-- read back is not a record of what anyone agreed to.
CREATE TABLE IF NOT EXISTS search.ai_notices (
    notice_id      BIGSERIAL PRIMARY KEY,
    body_sha256    BYTEA NOT NULL UNIQUE CHECK (length(body_sha256) = 32),
    body           TEXT  NOT NULL,
    first_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------- consent
-- APPEND-ONLY. The current state is the latest row for an account, and
-- there is no second copy of it to fall out of step. Revoking writes a row
-- rather than deleting one, because "they turned it off on the 3rd" is
-- exactly the fact a privacy record exists to keep.
--
-- Consent is per NOTICE: the current state only counts if it refers to the
-- notice text being shown today. Reword the notice materially and every
-- account is asked again instead of being carried onto new terms.
CREATE TABLE IF NOT EXISTS search.ai_consent (
    consent_id  BIGSERIAL PRIMARY KEY,
    account_id  BIGINT NOT NULL REFERENCES search.accounts (account_id) ON DELETE CASCADE,
    notice_id   BIGINT NOT NULL REFERENCES search.ai_notices (notice_id),
    granted     BOOLEAN NOT NULL,
    at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_agent  TEXT,
    UNIQUE (consent_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_ai_consent_current
    ON search.ai_consent (account_id, notice_id, at DESC);

-- ------------------------------------------------------------- attempts
-- One row per attempt, whatever happened to it. `query` is the user's own
-- text, visible only to them under RLS; it is here because the gate cannot
-- be tuned without seeing what it turned away.
CREATE TABLE IF NOT EXISTS search.ai_requests (
    request_id        BIGSERIAL PRIMARY KEY,
    account_id        BIGINT NOT NULL REFERENCES search.accounts (account_id) ON DELETE CASCADE,
    outcome_id        SMALLINT NOT NULL REFERENCES search.ai_outcomes (outcome_id),
    -- NULL when nothing was called: the kill switch, a missing consent, or
    -- an exhausted budget all end an attempt before any model sees it.
    model_id          SMALLINT REFERENCES search.ai_models (model_id),
    query             TEXT NOT NULL,
    at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    input_tokens      INTEGER NOT NULL DEFAULT 0 CHECK (input_tokens      >= 0),
    output_tokens     INTEGER NOT NULL DEFAULT 0 CHECK (output_tokens     >= 0),
    cache_read_tokens INTEGER NOT NULL DEFAULT 0 CHECK (cache_read_tokens >= 0),
    cache_write_tokens INTEGER NOT NULL DEFAULT 0 CHECK (cache_write_tokens >= 0),
    cost_micros       BIGINT  NOT NULL DEFAULT 0 CHECK (cost_micros >= 0),
    tool_calls        SMALLINT NOT NULL DEFAULT 0 CHECK (tool_calls >= 0),
    latency_ms        INTEGER,
    error             TEXT,
    UNIQUE (request_id, account_id)
);
-- The budget is a sum over a month and the rate limit a count over minutes;
-- both are (account_id, at) range scans, so one index serves both.
CREATE INDEX IF NOT EXISTS idx_ai_requests_acct_at
    ON search.ai_requests (account_id, at DESC);
-- "Is the gate too tight" reads one outcome across time.
CREATE INDEX IF NOT EXISTS idx_ai_requests_outcome
    ON search.ai_requests (outcome_id, at DESC);

-- ---------------------------------------------------------------- cache
-- Keyed on the account AND on how much of that account was indexed when the
-- answer was written. New mail or a new upload moves a watermark, which
-- changes the key, so a cached answer can never outlive the data it
-- described -- there are no invalidation hooks to forget.
--
-- The TTL is only a backstop for an account whose watermarks never move.
CREATE TABLE IF NOT EXISTS search.ai_cache (
    cache_id        BIGSERIAL PRIMARY KEY,
    account_id      BIGINT NOT NULL REFERENCES search.accounts (account_id) ON DELETE CASCADE,
    query_norm      TEXT   NOT NULL,
    mail_watermark  BIGINT NOT NULL,
    drive_watermark BIGINT NOT NULL,
    answer          JSONB  NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    hits            INTEGER NOT NULL DEFAULT 0 CHECK (hits >= 0),
    UNIQUE (account_id, query_norm, mail_watermark, drive_watermark),
    UNIQUE (cache_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_ai_cache_expiry ON search.ai_cache (expires_at);

-- ------------------------------------------------- row-level security
-- Same rule as the rest of the schema, with ONE deliberate difference:
-- these policies carry a WITH CHECK clause.
--
-- The index tables are read-only to the web app -- 001 gives them USING and
-- no WITH CHECK precisely so a request path cannot write. These four are
-- the app's own records: it has to write a consent row, an attempt row and
-- a cache entry. WITH CHECK on the same predicate means it can only ever
-- write rows belonging to the account it has already declared, so a bug in
-- the request path becomes a policy violation rather than a row filed
-- against someone else.
--
-- nullif(..., '') for the reason 003 exists: after set_config(..., true)
-- ends, the GUC reverts to the empty string on that pooled connection, and
-- ''::bigint raises instead of returning nothing.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['ai_consent', 'ai_requests', 'ai_cache'] LOOP
        EXECUTE format('ALTER TABLE search.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE search.%I FORCE  ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS acct_isolation ON search.%I', t);
        EXECUTE format($q$CREATE POLICY acct_isolation ON search.%I
            USING      (account_id = nullif(current_setting('homelab.account_id', true), '')::bigint)
            WITH CHECK (account_id = nullif(current_setting('homelab.account_id', true), '')::bigint)$q$, t);
    END LOOP;
END $$;

-- ai_models, ai_outcomes and ai_notices carry no account_id and are not
-- secret: a model name, an outcome name, and the notice every user is shown.
-- They are lookups, like search.mime_types, and get no policy for the same
-- reason that one does not.
