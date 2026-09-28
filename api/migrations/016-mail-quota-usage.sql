-- Mail-usage mirror written by Dovecot's quota_clone plugin (the "Option A"
-- least-privilege way to let an admin read ANY user's mail usage without an
-- IMAP session: only usage NUMBERS ever leave dovecot, no powerful key).
-- Every mailbox quota CHANGE (LMTP delivery / IMAP append / expunge) upserts
-- the current bytes+messages here through a Postgres dict -- see the
-- quota_clone + dict_server blocks in
-- dovecot/conf.d/91-homelab-dovecot.conf.template.
--
-- homelab-api only READS this (GET /api/v1/admin/mail-usage, site_admin);
-- the dovecot runtime roles get INSERT/UPDATE/DELETE via the dovecot
-- bootstrap-role grant (script/homelab-dovecot-bootstrap-role). Created here
-- by the migrate role so api's ALTER DEFAULT PRIVILEGES auto-grants SELECT to
-- homelab_api_runtime.
--
-- Populates LAZILY: quota_clone writes on the NEXT quota change per user
-- (`doveadm quota recalc` does NOT trigger it -- verified live), so an
-- existing fleet needs a one-time backfill (doveadm quota get -> upsert).
-- Fresh installs have no mailboxes to backfill: each populates on its first
-- delivery, and an empty mailbox reads ~0 anyway. A missing row => the
-- endpoint returns used_bytes=null ("usage not yet available").
CREATE TABLE IF NOT EXISTS api.mail_quota_usage (
    username TEXT PRIMARY KEY,
    bytes    BIGINT NOT NULL DEFAULT 0,
    messages BIGINT NOT NULL DEFAULT 0
);
