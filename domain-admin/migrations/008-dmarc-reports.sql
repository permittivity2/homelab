-- DMARC aggregate (rua) report storage.
--
-- WHY THIS EXISTS. As of 2026-10-27 all 17 zones publish
-- rua=mailto:dmarc-reports@mailmasker.org, so aggregate reports now land in
-- a real mailbox -- and nothing read them. They arrive as gzipped or zipped
-- XML, one per reporting receiver per domain per day, which is unreadable by
-- hand at any useful volume. Until they are queryable there is no evidence
-- base for the eventual move from p=quarantine to p=reject, which is the
-- whole point of collecting them.
--
-- WHY domainadmin. This package already owns DMARC: it writes the _dmarc TXT
-- records and the DKIM selectors the reports are grading. Reports are the
-- feedback loop on records this schema already manages, so they belong
-- beside them rather than in a new schema with a new role to bootstrap.
--
-- GRAIN. One row per report in dmarc_reports, one row per <record> in
-- dmarc_records. A <record> is "N messages from this source IP, evaluated
-- this way" -- it is already an aggregate, so there is no per-message data
-- here and never will be; that is what forensic (ruf) reports are for.

CREATE TABLE IF NOT EXISTS domainadmin.dmarc_reports (
    id            BIGSERIAL   PRIMARY KEY,
    -- report_metadata/*
    org_name      TEXT        NOT NULL,
    org_email     TEXT,
    report_id     TEXT        NOT NULL,
    date_begin    TIMESTAMPTZ NOT NULL,
    date_end      TIMESTAMPTZ NOT NULL,
    -- policy_published/* -- what the receiver SAW in DNS when it evaluated.
    -- Stored per report rather than read from our own zone: it is the only
    -- way to tell "the receiver acted on an old/incorrect record" apart from
    -- "our record is wrong now", and the two have very different fixes.
    policy_domain TEXT        NOT NULL,
    policy_p      TEXT,
    policy_sp     TEXT,
    policy_pct    SMALLINT,
    policy_adkim  TEXT,
    policy_aspf   TEXT,
    ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Idempotency. The ingest is a timer on every domain-admin host and the
    -- mailbox is shared, so the same report WILL be offered more than once
    -- (a retry, a second host, a re-delivered message). (org_name,report_id)
    -- is the receiver's own unique key for a report, so ON CONFLICT DO
    -- NOTHING against it makes re-ingest free instead of duplicating rows.
    CONSTRAINT dmarc_reports_org_report_key UNIQUE (org_name, report_id)
);

CREATE TABLE IF NOT EXISTS domainadmin.dmarc_records (
    id            BIGSERIAL PRIMARY KEY,
    report_id     BIGINT    NOT NULL
                  REFERENCES domainadmin.dmarc_reports(id) ON DELETE CASCADE,
    source_ip     INET      NOT NULL,
    message_count INTEGER   NOT NULL,

    -- CAREFUL -- these three are policy_evaluated/*, i.e. the ALIGNMENT
    -- outcome DMARC acted on, NOT raw authentication. A message can have
    -- auth_results/dkim = pass while policy_evaluated/dkim = fail, when the
    -- signature verifies but its d= domain does not align with the header
    -- From under the published adkim policy. Conflating the two is the
    -- classic way to misread these reports and "fix" a problem that is
    -- really an alignment mismatch. The raw per-identity results are kept
    -- separately in auth_results below.
    disposition   TEXT,
    dkim_result   TEXT,
    spf_result    TEXT,

    header_from   TEXT,

    -- auth_results/* verbatim: the dkim list (domain, result, selector) and
    -- spf list (domain, result). JSONB rather than two more tables because
    -- it is read whole for a single record when drilling into a failure and
    -- never aggregated across records -- and because the selector in here is
    -- what makes a DKIM failure actionable (it names which key to look at).
    auth_results  JSONB
);

-- The two access patterns: "what happened for this domain over this window"
-- (the summary view) and "who else is sending as us" (grouping by source).
CREATE INDEX IF NOT EXISTS dmarc_reports_domain_window_idx
    ON domainadmin.dmarc_reports (policy_domain, date_begin DESC);
CREATE INDEX IF NOT EXISTS dmarc_records_report_idx
    ON domainadmin.dmarc_records (report_id);
CREATE INDEX IF NOT EXISTS dmarc_records_source_idx
    ON domainadmin.dmarc_records (source_ip);

-- Single-runner coordination for the ingest. domain-admin runs on six hosts
-- (prod-homelab21/22/23 and 39/40/41) and every one of them will have the
-- timer, but they share one mailbox -- so without a gate they would race to
-- fetch, parse and move the same messages. One row, claimed with
-- FOR UPDATE SKIP LOCKED, the same idiom this package already uses for the
-- pdns restart debounce and the DKIM auto-retire claim.
CREATE TABLE IF NOT EXISTS domainadmin.dmarc_ingest_lock (
    id        BOOLEAN     PRIMARY KEY DEFAULT TRUE CHECK (id),
    last_run  TIMESTAMPTZ,
    last_host TEXT,
    last_note TEXT
);
INSERT INTO domainadmin.dmarc_ingest_lock (id) VALUES (TRUE)
    ON CONFLICT (id) DO NOTHING;
