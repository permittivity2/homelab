-- Post-cutover #78: requests that used Anthropic's web-search server tool
-- report how many searches ran (usage.server_tool_use.web_search_requests).
-- Each is billed separately from tokens, so it is counted and budgeted
-- separately too.
ALTER TABLE ai.requests ADD COLUMN IF NOT EXISTS web_searches INTEGER NOT NULL DEFAULT 0;
