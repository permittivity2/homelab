-- Per-user mail-quota override. NULL means "use the fleet default" (the
-- 1 TB storage_size in homelab-dovecot's `quota "User quota"` block); a
-- non-null value is a site_admin override (bytes). Dovecot's sql userdb
-- surfaces this as a `quota_rule` extra field (*:storage=<n>B) only when
-- set, so a NULL simply falls through to the default -- same "nullable,
-- default applies" pattern as recovery_email (013). Set via
-- POST /api/v1/admin/users/:id/mail-quota; read by the dovecot runtime
-- role's userdb query (its SELECT grant is widened to include this
-- column -- see dovecot/script/homelab-dovecot-bootstrap-role).
ALTER TABLE api.users ADD COLUMN IF NOT EXISTS mail_quota_bytes BIGINT;
