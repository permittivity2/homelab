-- 002: the wiki format (post-cutover #93). A fourth body format, MediaWiki
-- markup, rendered by Homelab::Notes::Wikitext through the same cleaner as
-- Markdown. The two CHECK constraints learn it; nothing else changes shape.
ALTER TABLE notes.notes DROP CONSTRAINT IF EXISTS notes_format_check;
ALTER TABLE notes.notes ADD CONSTRAINT notes_format_check CHECK (format IN ('markdown', 'wiki', 'html', 'text'));
ALTER TABLE notes.user_prefs DROP CONSTRAINT IF EXISTS user_prefs_default_format_check;
ALTER TABLE notes.user_prefs ADD CONSTRAINT user_prefs_default_format_check CHECK (default_format IN ('markdown', 'wiki', 'html', 'text'));
