-- Secrets this service needs every node to AGREE on.
--
-- homelab-invite runs as a POOL (three nodes behind one webproxy vhost,
-- round-robined per request). The device-setup links are HMAC-signed, so
-- a secret generated per host would verify on roughly one request in
-- three and fail on the other two -- intermittently, which is the worst
-- way for it to fail. The database is the one thing all three already
-- share, so the secret lives here.
--
-- Deliberately a generic table rather than a single-purpose column: the
-- next shared secret this service needs (and there will be one) should
-- not need another migration.
--
-- The row is NOT inserted here. gen_random_bytes() is pgcrypto, which is
-- not guaranteed present, and the alternatives available in plain SQL
-- (md5(random())) are not a credible source of key material. The app
-- inserts it from /dev/urandom on first use, with ON CONFLICT DO NOTHING
-- so two nodes racing on a cold start cannot produce two secrets.
CREATE TABLE IF NOT EXISTS invite.app_secrets (
    name       TEXT PRIMARY KEY,
    secret     TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
