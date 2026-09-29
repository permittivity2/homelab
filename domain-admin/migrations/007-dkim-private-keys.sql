-- HA for DKIM signing: distribute private keys to the whole
-- postfix/OpenDKIM pool (ct05/06/07) so any host can sign locally and
-- survive the others rebooting or dying.
--
-- This deliberately revisits 002-dkim-selectors.sql's "no private key in
-- Postgres" stance. That reasoning ("a second copy in this shared
-- database would only add risk without removing the on-disk
-- requirement") was correct for a SINGLE signer host. With MULTIPLE
-- signer hosts, the DB is the natural distribution channel -- the single
-- source of truth every host materializes its local /etc/opendkim/keys
-- from -- and the risk 002 worried about is mitigated by ENVELOPE
-- ENCRYPTION: the private key is stored AES-256-GCM-encrypted under a
-- key-encryption-key (KEK) that lives ONLY in each signer host's config
-- (dkim.key_encryption_key), never in this database. A dump/backup is
-- useless without that KEK, and the raw key is decrypted only in memory
-- on a signer host and written to its own local disk (where OpenDKIM has
-- to read it regardless) -- it never crosses the network in the clear.
-- See Homelab::DomainAdmin::KeyVault.
--
-- private_key_encrypted NULL = a legacy row whose key predates this
-- column and still lives only on the original signer's disk; the
-- one-time backfill (encrypt-and-store the on-disk key) populates it.

ALTER TABLE domainadmin.dkim_selectors
    ADD COLUMN IF NOT EXISTS private_key_encrypted TEXT,
    ADD COLUMN IF NOT EXISTS key_enc_version       SMALLINT;
