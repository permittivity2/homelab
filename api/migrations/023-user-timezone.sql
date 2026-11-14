-- Post-cutover #74 phase 2: the account's time zone (an IANA name such as
-- America/Chicago), set at account creation from what the invite page's
-- browser reported, editable in myaccount, returned by introspect and the
-- account summary so every app shows times the same way. NULL = not known:
-- apps fall back to their own default (America/Chicago on this fleet).
ALTER TABLE api.users ADD COLUMN IF NOT EXISTS timezone TEXT;
