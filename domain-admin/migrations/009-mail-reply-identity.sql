-- Post-cutover #67: "reply from the alias a message was sent to".
--
-- Two tables, owned by this package (mail routing/identity state lives in
-- domainadmin, next to mail_aliases), written and read mostly by SOMEBODY
-- ELSE: the homelab-postfix-block-link milter on the mail pool, through its
-- own narrow role (SELECT on mail_reply_identity, SELECT+INSERT on
-- mail_received_via -- see that package's bootstrap-role script). This
-- service only serves the per-user setting (GET/PUT
-- /internal/v1/domains/mail-reply-identity/mine) and prunes the log.
--
-- No cross-schema foreign keys (repo convention: user_email is a bare copy
-- of api.users.email, lowercase).

-- The per-user switch. No row = off. Gates only the REWRITE on 587; the
-- recording below happens for every account so switching this on later
-- works for mail already received.
CREATE TABLE IF NOT EXISTS domainadmin.mail_reply_identity (
    user_email       TEXT PRIMARY KEY,
    reply_from_alias BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One row per (destination account, inbound Message-ID) whenever the message
-- was addressed to one of the account's ALIASES (nothing is recorded when it
-- went to the real address -- there is nothing to rewrite to). `chosen` is
-- the address the reply will be sent from, picked by the rule in
-- Homelab::PostfixBlockLink::Milter::choose_reply_address: first of the
-- account's addresses on the To line, else Cc, else the first envelope
-- recipient. `candidates` lists every one of the account's own addresses
-- seen on the message, with where each was seen -- never the sender, the
-- subject or the body. message_id is stored normalised: no angle brackets,
-- no whitespace, case kept (RFC 5322 ids compare byte for byte).
CREATE TABLE IF NOT EXISTS domainadmin.mail_received_via (
    id          BIGSERIAL PRIMARY KEY,
    account     TEXT NOT NULL,
    message_id  TEXT NOT NULL,
    chosen      TEXT NOT NULL,
    chosen_via  TEXT NOT NULL CHECK (chosen_via IN ('to', 'cc', 'envelope')),
    candidates  JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- N copies of one message (four aliases in one transaction, a retry)
    -- must agree: the first record wins, later ones are ON CONFLICT DO NOTHING.
    CONSTRAINT mail_received_via_account_message_key UNIQUE (account, message_id)
);

-- The pruner (App.pm _prune_received_via, reply_identity.retention_days,
-- default 400) deletes by age in SKIP LOCKED batches.
CREATE INDEX IF NOT EXISTS idx_mail_received_via_received_at
    ON domainadmin.mail_received_via (received_at);
