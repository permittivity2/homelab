-- Certificate store: the fleet's single source of truth for issued TLS
-- certificates, so renewals reach every consumer automatically instead of
-- being hand-copied.
--
-- WHY THIS EXISTS: certbot issues on ONE host, but a cert is consumed by many
-- (mail.mailmasker.org alone is served by 3 dovecot + 3 postfix + the edge
-- nginx). Before this, distribution was a manual `cp` + reload, so every
-- renewal silently left 6+ backends stale. This table is the hand-off point:
-- the issuer publishes here, every consumer pulls from here.
--
-- SECURITY MODEL (mirrors domainadmin.dkim_selectors, migration 007): the
-- private key is stored ENVELOPE-ENCRYPTED under a key-encryption-key (KEK)
-- that lives only in each host's local config and never in this database, via
-- Homelab::Common::KeyVault (AES-256-GCM, "v1:" || base64(iv|tag|ct)). The GCM
-- additional-authenticated-data is "<lineage>/<serial>", so a blob is bound to
-- its own row and cannot be lifted into another one. Consequence worth
-- stating plainly: homelab-api serves CIPHERTEXT and never sees plaintext key
-- material -- only a consumer holding the KEK can decrypt. A dump of this DB
-- does not leak usable private keys.
--
-- The public halves (cert/chain/fullchain) are encrypted too. They are not
-- secret, but encrypting everything keeps ONE code path rather than two.

CREATE TABLE IF NOT EXISTS api.certificates (
    id               BIGSERIAL PRIMARY KEY,
    -- certbot's lineage name, i.e. the directory under /etc/letsencrypt/live/.
    lineage          TEXT        NOT NULL,
    -- the leaf certificate's serial, uppercase hex, no colons. Globally unique
    -- per CA; combined with the lineage it is the stable identity of ONE issued
    -- certificate. It is deliberately NOT a hash of the stored bytes: GCM uses a
    -- fresh nonce on every encryption, so ciphertext differs run-to-run and could
    -- never serve as a change signal.
    serial           TEXT        NOT NULL,
    not_before       TIMESTAMPTZ NOT NULL,
    not_after        TIMESTAMPTZ NOT NULL,
    -- the four PEMs as certbot writes them, each envelope-encrypted.
    cert_enc         TEXT        NOT NULL,
    chain_enc        TEXT        NOT NULL,
    fullchain_enc    TEXT        NOT NULL,
    privkey_enc      TEXT        NOT NULL,
    key_enc_version  SMALLINT    NOT NULL DEFAULT 1,
    -- sha256 of the DECRYPTED bytes. This is what a consumer compares against
    -- what is on its own disk to decide "has this actually changed?" -- cheap,
    -- and strictly more sensitive than comparing the serial, because it also
    -- catches a rotated intermediate in the chain and the fresh key minted on
    -- every renewal.
    sha256_fullchain TEXT        NOT NULL,
    sha256_privkey   TEXT        NOT NULL,
    -- the domains this certificate actually covers (leaf CN + SANs), so a
    -- consumer can sanity-check it got what it expected.
    domains          TEXT[]      NOT NULL DEFAULT '{}',
    published_by     TEXT,
    published_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- THE idempotency key. The publisher runs from a certbot deploy-hook AND
    -- from a reconcile timer, so the same (lineage, serial) is offered more than
    -- once by design; `ON CONFLICT DO NOTHING` makes a repeat publish a silent
    -- no-op rather than a duplicate or an error.
    CONSTRAINT uq_certificates_lineage_serial UNIQUE (lineage, serial)
);

CREATE INDEX IF NOT EXISTS idx_certificates_lineage    ON api.certificates (lineage);
CREATE INDEX IF NOT EXISTS idx_certificates_not_after  ON api.certificates (not_after);

-- Which version of each lineage consumers should install. Separate from the
-- versions table so promotion is its own explicit, monotonic step: a late retry
-- of an OLDER serial (a drained spool entry, say) inserts its row but must never
-- demote a newer live certificate. The writer therefore guards promotion with
-- "only if this one expires later than what is current".
CREATE TABLE IF NOT EXISTS api.certificate_current (
    lineage        TEXT        PRIMARY KEY,
    certificate_id BIGINT      NOT NULL REFERENCES api.certificates(id) ON DELETE RESTRICT,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Convenience view for the admin/visibility endpoint: what is live per lineage
-- and how long it has left. Keeps the ciphertext columns out of the read path
-- so a careless `SELECT *` on the view cannot spill encrypted key material.
CREATE OR REPLACE VIEW api.certificate_status AS
    SELECT c.lineage,
           c.serial,
           c.not_before,
           c.not_after,
           (c.not_after - NOW())                   AS expires_in,
           EXTRACT(DAY FROM (c.not_after - NOW()))::int AS days_remaining,
           c.domains,
           c.sha256_fullchain,
           c.published_by,
           c.published_at,
           cc.updated_at                           AS promoted_at
      FROM api.certificate_current cc
      JOIN api.certificates c ON c.id = cc.certificate_id;
