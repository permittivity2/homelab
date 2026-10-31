-- =====================================================================
-- A normalized index over the fleet's mail and drive content, so
-- search.mailmasker.org can answer a query without walking NFS.
--
-- THE ONE INVARIANT THIS SCHEMA EXISTS TO ENFORCE: no account ever sees
-- another account's data. That is not left to every future WHERE clause
-- being written correctly. Two mechanisms, both in the database:
--
--  1. COMPOSITE FOREIGN KEYS. Every child table carries account_id and
--     references its parent by (parent_id, account_id), not parent_id
--     alone. Carrying account_id on a child is formally redundant --
--     message -> mailbox -> account already determines it -- and that
--     redundancy is the entire point: with it, Postgres itself refuses
--     to attach account A's body, file, header or attachment to account
--     B's message. An indexer bug becomes a constraint violation instead
--     of a disclosure. Where a column is denormalized in this file, it
--     is for this reason and it says so.
--
--  2. ROW-LEVEL SECURITY, applied at the end of this file to every table
--     that has an account_id, with FORCE so even the owning role is
--     subject to it. The app sets `homelab.account_id` per request, so a
--     query that forgets its filter returns zero rows rather than
--     everyone's.
--
-- RLS + pgbouncer: the pgbouncer tier runs pool_mode=session. The app
-- MUST use `SET LOCAL homelab.account_id = ...` inside an explicit
-- transaction, never a bare `SET` -- SET LOCAL is transaction-scoped and
-- therefore correct under every pool mode, while a bare SET persists on
-- the pooled server connection and would be inherited by whoever gets it
-- next if server_reset_query ever changed.
--
-- WHAT IS DELIBERATELY *NOT* ACCOUNT-SCOPED, AND THE RULE THAT FOLLOWS.
-- domains, addresses, display_names, mime_types and the small lookup
-- tables are a SHARED VOCABULARY: one row per distinct value, reused by
-- every account. They hold no account association and so cannot carry
-- RLS. The association lives in search.message_addresses, which is
-- account-scoped.
--
--   => Any query that resolves a person, an address or a name MUST reach
--      them through message_addresses (or drive_items), never by reading
--      addresses/display_names directly. search.addresses contains every
--      address anyone in the fleet has corresponded with; a participant
--      typeahead built straight off it would leak one user's contacts to
--      another. There is no way for the database to stop that, so it is
--      written here, in the file you have to read to add such a query.
-- =====================================================================

-- ------------------------------------------------------------ lookups
CREATE TABLE IF NOT EXISTS search.domains (
    domain_id  BIGSERIAL PRIMARY KEY,
    domain     TEXT NOT NULL UNIQUE CHECK (domain = lower(domain))
);

-- type/subtype split rather than one 'image/jpeg' string: it is the 3NF
-- form, and it makes "any image" an indexed equality (type = 'image')
-- instead of LIKE 'image/%'.
CREATE TABLE IF NOT EXISTS search.mime_types (
    mime_type_id BIGSERIAL PRIMARY KEY,
    type         TEXT NOT NULL CHECK (type    = lower(type)),
    subtype      TEXT NOT NULL CHECK (subtype = lower(subtype)),
    UNIQUE (type, subtype)
);

CREATE TABLE IF NOT EXISTS search.address_roles (
    role_id SMALLINT PRIMARY KEY,
    role    TEXT NOT NULL UNIQUE
);
INSERT INTO search.address_roles (role_id, role) VALUES
    (1, 'from'), (2, 'sender'), (3, 'reply_to'), (4, 'to'), (5, 'cc'), (6, 'bcc')
ON CONFLICT (role_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS search.maildir_subs (
    sub_id SMALLINT PRIMARY KEY,
    sub    TEXT NOT NULL UNIQUE
);
INSERT INTO search.maildir_subs (sub_id, sub) VALUES
    (1, 'cur'), (2, 'new'), (3, 'tmp')
ON CONFLICT (sub_id) DO NOTHING;

-- Only an allowlist of headers is stored (see message_headers). Keeping
-- the allowlist itself normalized means adding one is a row, not a
-- migration.
CREATE TABLE IF NOT EXISTS search.header_names (
    header_name_id BIGSERIAL PRIMARY KEY,
    name           TEXT NOT NULL UNIQUE CHECK (name = lower(name))
);

-- ----------------------------------------------------------- accounts
-- The spine. Every indexed row hangs off one of these.
--
-- No maildir_path column on purpose: it is fully derived from
-- (domain, local_part) plus the configured mount root, and storing a
-- derived absolute path invites it going stale the day the root changes.
-- Homelab::Search::Paths::maildir_for() is the single place that builds
-- it, and it asserts realpath containment before any read.
CREATE TABLE IF NOT EXISTS search.accounts (
    account_id        BIGSERIAL PRIMARY KEY,
    email             TEXT NOT NULL UNIQUE CHECK (email = lower(email)),
    domain_id         BIGINT NOT NULL REFERENCES search.domains(domain_id),
    local_part        TEXT NOT NULL,
    has_mail          BOOLEAN NOT NULL DEFAULT FALSE,
    has_drive         BOOLEAN NOT NULL DEFAULT FALSE,
    mail_indexed_at   TIMESTAMPTZ,
    drive_indexed_at  TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (domain_id, local_part)
);

-- ------------------------------------------------------------- people
-- The same address appears under many display names ("Constance Forge",
-- "constance", "C. Forge") and the same display name across many
-- addresses. That is a genuine many-to-many, so it gets its own tables --
-- which is what lets a query find a PERSON rather than string-matching a
-- header.
CREATE TABLE IF NOT EXISTS search.addresses (
    address_id BIGSERIAL PRIMARY KEY,
    local_part TEXT NOT NULL,
    domain_id  BIGINT NOT NULL REFERENCES search.domains(domain_id),
    -- Rendered 'local@domain', maintained by the trigger below, purely so
    -- a trigram index can exist over the whole address. A GENERATED
    -- column cannot be used: it may only reference columns of its own
    -- row, and the domain lives in another table.
    addr_text  TEXT NOT NULL,
    UNIQUE (local_part, domain_id)
);

CREATE OR REPLACE FUNCTION search.addresses_set_text() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    SELECT NEW.local_part || '@' || d.domain INTO NEW.addr_text
      FROM search.domains d WHERE d.domain_id = NEW.domain_id;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS addresses_set_text ON search.addresses;
CREATE TRIGGER addresses_set_text
    BEFORE INSERT OR UPDATE OF local_part, domain_id ON search.addresses
    FOR EACH ROW EXECUTE FUNCTION search.addresses_set_text();

CREATE TABLE IF NOT EXISTS search.display_names (
    display_name_id BIGSERIAL PRIMARY KEY,
    display_name    TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS search.address_names (
    address_id      BIGINT NOT NULL REFERENCES search.addresses(address_id)      ON DELETE CASCADE,
    display_name_id BIGINT NOT NULL REFERENCES search.display_names(display_name_id) ON DELETE CASCADE,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    msg_count       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (address_id, display_name_id)
);

-- --------------------------------------------------------------- mail
-- UNIQUE (account_id, mailbox_id) looks redundant next to the primary
-- key. It is what makes the composite foreign key from messages possible,
-- and so it is load-bearing, not decoration. Same for every other
-- (id, account_id) unique constraint in this file.
CREATE TABLE IF NOT EXISTS search.mailboxes (
    mailbox_id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES search.accounts(account_id) ON DELETE CASCADE,
    name       TEXT NOT NULL,          -- maildir folder, e.g. 'INBOX' or '.House Stuff'
    dir_mtime  TIMESTAMPTZ,            -- last seen mtime of cur/ + new/, the change detector
    UNIQUE (account_id, name),
    UNIQUE (mailbox_id, account_id)
);

CREATE TABLE IF NOT EXISTS search.threads (
    thread_id         BIGSERIAL PRIMARY KEY,
    account_id        BIGINT NOT NULL REFERENCES search.accounts(account_id) ON DELETE CASCADE,
    root_rfc822_msgid TEXT,
    subject_norm      TEXT,
    first_at          TIMESTAMPTZ,
    last_at           TIMESTAMPTZ,
    msg_count         INTEGER NOT NULL DEFAULT 0,
    UNIQUE (thread_id, account_id)
);

CREATE TABLE IF NOT EXISTS search.messages (
    message_id      BIGSERIAL PRIMARY KEY,
    account_id      BIGINT NOT NULL,
    mailbox_id      BIGINT NOT NULL,
    thread_id       BIGINT,
    -- Nullable: dovecot's IMAP UIDs live in dovecot-uidlist, not in the
    -- message file, and this indexer reads the maildir. Populated only if
    -- that file is parsed (not in this version); the real identity of a
    -- message here is message_files.uniq_part.
    imap_uid        BIGINT,
    rfc822_msgid    TEXT,
    in_reply_to     TEXT,
    subject         TEXT,
    sent_at         TIMESTAMPTZ,       -- the Date: header
    received_at     TIMESTAMPTZ,       -- first Received:, else the file's mtime
    size_bytes      BIGINT,
    has_attachments BOOLEAN NOT NULL DEFAULT FALSE,
    is_seen         BOOLEAN NOT NULL DEFAULT FALSE,
    is_flagged      BOOLEAN NOT NULL DEFAULT FALSE,
    is_draft        BOOLEAN NOT NULL DEFAULT FALSE,
    indexed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (message_id, account_id),
    -- A message cannot live in another account's mailbox or thread.
    FOREIGN KEY (account_id, mailbox_id)
        REFERENCES search.mailboxes (account_id, mailbox_id) ON DELETE CASCADE,
    FOREIGN KEY (thread_id, account_id)
        REFERENCES search.threads (thread_id, account_id) ON DELETE SET NULL
);

-- Each message's on-disk filename and location.
--
-- THE MAILDIR TRAP, which this table is shaped around: a maildir file is
-- RENAMED when its flags change -- the name is '<uniq>:2,<flags>', so
-- reading a message rewrites its filename and moves it from new/ to cur/.
-- A naive "filename I have not seen before = new message" check therefore
-- re-indexes an entire mailbox every time someone reads their mail. The
-- stable identity is everything before the ':', kept here as uniq_part,
-- and that is what UNIQUE is on.
--
-- The absolute path is reconstructed, never stored:
--   <configured root>/<domain>/<local_part>/<mailbox.name>/<sub>/<file_name>
CREATE TABLE IF NOT EXISTS search.message_files (
    message_id     BIGINT PRIMARY KEY,
    account_id     BIGINT NOT NULL,
    mailbox_id     BIGINT NOT NULL,
    sub_id         SMALLINT NOT NULL REFERENCES search.maildir_subs(sub_id),
    uniq_part      TEXT NOT NULL,      -- STABLE identity: before the ':'
    file_name      TEXT NOT NULL,      -- current name, flags included
    size_bytes     BIGINT,
    mtime          TIMESTAMPTZ,
    inode          BIGINT,
    UNIQUE (mailbox_id, uniq_part),
    FOREIGN KEY (message_id, account_id)
        REFERENCES search.messages (message_id, account_id) ON DELETE CASCADE,
    FOREIGN KEY (account_id, mailbox_id)
        REFERENCES search.mailboxes (account_id, mailbox_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS search.message_addresses (
    message_id      BIGINT NOT NULL,
    account_id      BIGINT NOT NULL,
    role_id         SMALLINT NOT NULL REFERENCES search.address_roles(role_id),
    position        SMALLINT NOT NULL,   -- order within the header
    address_id      BIGINT NOT NULL REFERENCES search.addresses(address_id),
    display_name_id BIGINT     REFERENCES search.display_names(display_name_id),
    PRIMARY KEY (message_id, role_id, position),
    FOREIGN KEY (message_id, account_id)
        REFERENCES search.messages (message_id, account_id) ON DELETE CASCADE
);

-- An ALLOWLIST, not every header. Storing all of them is unbounded (spam
-- headers are enormous) and almost none of it is ever queried. The
-- universally useful ones are columns on messages; participants are in
-- the junction above; this is for the handful worth filtering on.
CREATE TABLE IF NOT EXISTS search.message_headers (
    message_id     BIGINT NOT NULL,
    account_id     BIGINT NOT NULL,
    header_name_id BIGINT NOT NULL REFERENCES search.header_names(header_name_id),
    position       SMALLINT NOT NULL,
    value          TEXT,
    PRIMARY KEY (message_id, header_name_id, position),
    FOREIGN KEY (message_id, account_id)
        REFERENCES search.messages (message_id, account_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS search.attachments (
    attachment_id BIGSERIAL PRIMARY KEY,
    message_id    BIGINT NOT NULL,
    account_id    BIGINT NOT NULL,
    file_name     TEXT,
    mime_type_id  BIGINT REFERENCES search.mime_types(mime_type_id),
    size_bytes    BIGINT,
    FOREIGN KEY (message_id, account_id)
        REFERENCES search.messages (message_id, account_id) ON DELETE CASCADE
);

-- Body text, made searchable.
--
-- TWO TRAPS, both of which bite at CREATE TABLE or on a large message:
--
--  * The text-search config must be written LITERALLY. to_tsvector('english', …)
--    is IMMUTABLE and legal in a generated column; the one-argument
--    to_tsvector(…) is only STABLE because it reads
--    default_text_search_config, and Postgres rejects it here. (This
--    cluster's default is already pg_catalog.english, so the literal
--    matches live behaviour.)
--
--  * A tsvector is capped at about 1 MB. A big message or a big text file
--    errors the INSERT outright, so the indexer truncates what it feeds
--    the vector (body_text keeps the full text; tsv_source holds only the
--    prefix that was vectorized) and logs when it does. Storing the
--    truncated copy separately is what makes "was this message fully
--    indexed?" answerable later instead of invisible.
CREATE TABLE IF NOT EXISTS search.message_bodies (
    message_id  BIGINT PRIMARY KEY,
    account_id  BIGINT NOT NULL,
    body_text   TEXT,
    tsv_source  TEXT,
    truncated   BOOLEAN NOT NULL DEFAULT FALSE,
    tsv         tsvector GENERATED ALWAYS AS
                    (to_tsvector('english', coalesce(tsv_source, ''))) STORED,
    FOREIGN KEY (message_id, account_id)
        REFERENCES search.messages (message_id, account_id) ON DELETE CASCADE
);

-- -------------------------------------------------------------- drive
-- No foreign key to drive.files, by the same rule 001-files.sql states
-- for api.users: this schema's migrate role has no grant on the drive
-- schema at all. Reconciliation is the indexer's job, and a vanished
-- drive row is a sweep here, not a cascade.
CREATE TABLE IF NOT EXISTS search.drive_items (
    drive_item_id      BIGSERIAL PRIMARY KEY,
    account_id         BIGINT NOT NULL REFERENCES search.accounts(account_id) ON DELETE CASCADE,
    drive_file_id      BIGINT,
    file_uuid          UUID NOT NULL,
    file_name          TEXT NOT NULL,
    folder_path        TEXT,
    mime_type_id       BIGINT REFERENCES search.mime_types(mime_type_id),
    size_bytes         BIGINT,
    content_created_at TIMESTAMPTZ,
    uploaded_at        TIMESTAMPTZ,
    deleted_at         TIMESTAMPTZ,
    indexed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (account_id, file_uuid),
    UNIQUE (drive_item_id, account_id)
);

CREATE TABLE IF NOT EXISTS search.drive_item_text (
    drive_item_id BIGINT PRIMARY KEY,
    account_id    BIGINT NOT NULL,
    body_text     TEXT,
    tsv_source    TEXT,
    truncated     BOOLEAN NOT NULL DEFAULT FALSE,
    tsv           tsvector GENERATED ALWAYS AS
                      (to_tsvector('english', coalesce(tsv_source, ''))) STORED,
    FOREIGN KEY (drive_item_id, account_id)
        REFERENCES search.drive_items (drive_item_id, account_id) ON DELETE CASCADE
);

-- ------------------------------------------------- indexer work queue
-- All three search hosts consume this; nothing is statically partitioned.
-- Per-user or per-directory sharding was considered and rejected: drive
-- has two users, so a per-user split hands one host the entire drive
-- corpus and leaves two idle. FOR UPDATE SKIP LOCKED balances itself,
-- needs no ownership map, and returns a dead host's work to the pool when
-- its lease expires. Same job-table shape homelab-worker already uses.
CREATE TABLE IF NOT EXISTS search.index_queue (
    queue_id    BIGSERIAL PRIMARY KEY,
    kind        TEXT NOT NULL CHECK (kind IN ('mailbox', 'mail_uid_range', 'drive_batch')),
    account_id  BIGINT REFERENCES search.accounts(account_id) ON DELETE CASCADE,
    mailbox_id  BIGINT,
    file_ids    BIGINT[],
    payload     JSONB,
    priority    SMALLINT NOT NULL DEFAULT 5,
    claimed_by  TEXT,
    claimed_at  TIMESTAMPTZ,
    lease_until TIMESTAMPTZ,
    attempts    SMALLINT NOT NULL DEFAULT 0,
    last_error  TEXT,
    parked      BOOLEAN NOT NULL DEFAULT FALSE,
    enqueued_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS search.index_runs (
    run_id      BIGSERIAL PRIMARY KEY,
    host        TEXT NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ,
    units       INTEGER NOT NULL DEFAULT 0,
    items       INTEGER NOT NULL DEFAULT 0,
    errors      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS search.index_state (
    account_id BIGINT NOT NULL REFERENCES search.accounts(account_id) ON DELETE CASCADE,
    source     TEXT NOT NULL CHECK (source IN ('mail', 'drive')),
    cursor     TEXT,
    last_ok_at TIMESTAMPTZ,
    last_error TEXT,
    PRIMARY KEY (account_id, source)
);

-- ------------------------------------------------------------ indexes
CREATE INDEX IF NOT EXISTS idx_messages_acct_sent     ON search.messages (account_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_acct_mailbox  ON search.messages (account_id, mailbox_id);
CREATE INDEX IF NOT EXISTS idx_messages_msgid         ON search.messages (account_id, rfc822_msgid);
CREATE INDEX IF NOT EXISTS idx_msgaddr_addr           ON search.message_addresses (address_id, role_id);
CREATE INDEX IF NOT EXISTS idx_msgaddr_acct           ON search.message_addresses (account_id, address_id);
CREATE INDEX IF NOT EXISTS idx_bodies_tsv             ON search.message_bodies USING GIN (tsv);
CREATE INDEX IF NOT EXISTS idx_drivetext_tsv          ON search.drive_item_text USING GIN (tsv);
CREATE INDEX IF NOT EXISTS idx_drive_acct_live        ON search.drive_items (account_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_drive_acct_created     ON search.drive_items (account_id, content_created_at DESC);
CREATE INDEX IF NOT EXISTS idx_drive_acct_mime        ON search.drive_items (account_id, mime_type_id);
CREATE INDEX IF NOT EXISTS idx_attachments_acct       ON search.attachments (account_id, message_id);
-- Partial: the claim query only ever looks at unclaimed, unparked rows,
-- and the queue is mostly empty in steady state.
CREATE INDEX IF NOT EXISTS idx_queue_claimable        ON search.index_queue (priority, enqueued_at)
    WHERE parked = FALSE;

-- Trigram indexes for substring matching on names. pg_trgm is a contrib
-- extension and CREATE EXTENSION needs superuser, which this schema's
-- migrate role deliberately does not have -- so it is created once by
-- hand on the Patroni primary (see README.md) and this migration only
-- USES it. Missing extension must not fail the install: without it the
-- btree fallbacks below still serve prefix matches, substring matches
-- just become sequential scans, and a warning is logged. Note that a
-- rebuilt cluster silently loses the extension, which is why this is in
-- the HA bootstrap notes too.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE INDEX IF NOT EXISTS idx_addresses_trgm
            ON search.addresses USING GIN (addr_text gin_trgm_ops);
        CREATE INDEX IF NOT EXISTS idx_display_names_trgm
            ON search.display_names USING GIN (display_name gin_trgm_ops);
        CREATE INDEX IF NOT EXISTS idx_drive_name_trgm
            ON search.drive_items USING GIN (file_name gin_trgm_ops);
        CREATE INDEX IF NOT EXISTS idx_messages_subject_trgm
            ON search.messages USING GIN (subject gin_trgm_ops);
    ELSE
        RAISE WARNING 'pg_trgm is not installed: substring search will use sequential scans. Run CREATE EXTENSION pg_trgm on the primary (see homelab-search README).';
        CREATE INDEX IF NOT EXISTS idx_addresses_text     ON search.addresses (addr_text);
        CREATE INDEX IF NOT EXISTS idx_display_names_name ON search.display_names (display_name);
        CREATE INDEX IF NOT EXISTS idx_drive_name         ON search.drive_items (account_id, file_name);
    END IF;
END $$;

-- ------------------------------------------------- row-level security
-- Every table with an account_id. FORCE so the owning role is subject to
-- it too -- without FORCE the table owner bypasses RLS entirely, which
-- would make this whole section decorative for the migrate role.
--
-- current_setting(..., true) returns NULL when unset rather than raising,
-- and NULL = anything is NULL, so an unset account_id yields zero rows.
-- That is the intended default: nothing is visible until the app says who
-- is asking.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'accounts', 'mailboxes', 'threads', 'messages', 'message_files',
        'message_addresses', 'message_headers', 'message_bodies',
        'attachments', 'drive_items', 'drive_item_text',
        'index_queue', 'index_state'
    ] LOOP
        EXECUTE format('ALTER TABLE search.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE search.%I FORCE  ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS acct_isolation ON search.%I', t);
        -- USING only, deliberately no WITH CHECK: this policy governs what
        -- the web app can SEE. Without a WITH CHECK clause it grants no
        -- INSERT at all, which is correct -- the request path only ever
        -- reads. Writing is the indexer's job, under the policy below.
        EXECUTE format($q$CREATE POLICY acct_isolation ON search.%I
            USING (account_id = current_setting('homelab.account_id', true)::bigint)$q$, t);
    END LOOP;
END $$;

-- The indexer is the one process that legitimately works across accounts,
-- so it needs a way past the per-account policy -- but giving the runtime
-- role BYPASSRLS would also hand that to the web app, which must never
-- have it. Instead: a second policy keyed on the same GUC taking the
-- literal 'indexer', which only the indexer sets, and which the web app's
-- request path never sets because it always sets a numeric account id.
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'accounts', 'mailboxes', 'threads', 'messages', 'message_files',
        'message_addresses', 'message_headers', 'message_bodies',
        'attachments', 'drive_items', 'drive_item_text',
        'index_queue', 'index_state'
    ] LOOP
        EXECUTE format('DROP POLICY IF EXISTS indexer_all ON search.%I', t);
        EXECUTE format($q$CREATE POLICY indexer_all ON search.%I
            USING (current_setting('homelab.indexer', true) = 'on')
            WITH CHECK (current_setting('homelab.indexer', true) = 'on')$q$, t);
    END LOOP;
END $$;
