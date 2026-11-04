-- End the refresh tokens that outlived their sessions (security fix,
-- 2026-11-03).
--
-- Until now a password change, a password reset and suspending an account
-- revoked the user's SESSIONS but not the refresh tokens those sessions held.
-- /api/v1/auth/refresh checked only the refresh token, so every such client
-- could refresh straight back in -- after you changed your password because
-- someone else had it, and after an admin suspended an account. The handlers
-- now end both together (_end_sessions), and refresh refuses a suspended
-- account or an ended session. This removes what the old behaviour left
-- behind:
--
--   1. a live refresh token every one of whose sessions was revoked. Rotation,
--      sign-out and "sign out a session" always revoke the token with its
--      session, so only the three paths above leave this state. A token that
--      is still in use has been rotated into a live session since, and is not
--      touched; a token with no session row at all is not touched either.
--   2. everything a suspended account still holds.
--
-- Measured on production before writing this: 36 tokens, on two accounts,
-- none of them a fleet agent's; all from 2026-10-18..25 and unused since.

UPDATE api.refresh_tokens rt
   SET revoked = TRUE
 WHERE rt.revoked = FALSE
   AND EXISTS     (SELECT 1 FROM api.sessions s WHERE s.refresh_token_id = rt.id)
   AND NOT EXISTS (SELECT 1 FROM api.sessions s WHERE s.refresh_token_id = rt.id AND s.revoked = FALSE);

UPDATE api.refresh_tokens rt
   SET revoked = TRUE
  FROM api.users u
 WHERE u.id = rt.user_id AND u.active = FALSE AND rt.revoked = FALSE;

UPDATE api.sessions s
   SET revoked = TRUE
  FROM api.users u
 WHERE u.id = s.user_id AND u.active = FALSE AND s.revoked = FALSE;
