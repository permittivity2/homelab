# homelab-drive

A file-storage web UI, built BFF-style: browsers only ever talk to this
app, never directly to `homelab-api` or `homelab-sso`. Login is
delegated entirely to `homelab-sso` (an OAuth2-style authorization-code
flow — `/login` redirects to homelab-sso's `/oauth/authorize`,
`/oauth/callback` exchanges the resulting code server-to-server via
`Homelab::Common::SSOClient::exchange_code`); this app never sees a
password, and a live homelab-sso IdP session lets a user land here
already logged in ("login once, login everywhere" — see
`../sso/README.md`). The resulting access token is held in this app's
own signed session cookie, re-verified against homelab-api's
`/api/v1/auth/introspect` on every request (a session cookie surviving
doesn't mean the underlying token is still valid). `/logout` redirects
to homelab-sso's own `/logout` rather than just clearing this app's
cookie — that's what makes it a real, single logout instead of only a
local one.

Files are stored on local disk under `/var/lib/homelab/drive-storage`,
named by a random UUID (never the user-supplied filename — that's kept
only as a DB column for display/download purposes), indexed in this
package's own `drive` Postgres schema. No foreign key to `api.users` —
drive's migrate role has no grant on the `api` schema at all; the
user's email (from the JWT) is the only cross-feature identifier used,
consistent with "cross-feature consistency goes through HTTP, not a
shared DB reference" (see `CLAUDE.md`).

Deliberately minimal for the first pass: flat file list per user, no
directories/sharing/trash/versioning — those are straightforward to
add later once the core upload/list/download/delete path is proven.
Same for the UI itself: a bare file list with no folders, drag/drop, or
progress indication — real UX work (a proper two-pane layout, upload
progress instead of a silent wait, etc.) is tracked as follow-up, not
done here yet.

## Upload size limit

`MOJO_MAX_MESSAGE_SIZE=104857600` (100MB) in `systemd/
homelab-drive.service` raises Mojolicious's own default 16MB request
ceiling. This has to stay in sync with `homelab-webproxy`'s
`client_max_body_size` (also 100MB, see `webproxy/README.md`'s own
Gotcha on this) — that's a SEPARATE, independent ceiling one layer
further out, and whichever of the two is lower silently wins. Found
both defaults were far too low from a real user hitting the *lower* of
the two (nginx's own 1MB) with an ordinary 1.1MB upload, which failed
with a slow, confusing timeout rather than an immediate clear error —
see `tests/e2e/test_cli_features.py`'s
`test_drive_upload_over_1mb_and_16mb_succeeds` for the permanent
regression coverage (this can only be caught through the real nginx
proxy — `t/api.t` dispatches in-process and never touches nginx, so it
proves the Mojolicious-side fix but not nginx's).

## JSON API (for homelab-cli and third-party scripts)

Alongside the browser routes above, `GET /api/v1/files`, `POST
/api/v1/files` (multipart, field name `file`), `GET /api/v1/files/:id`
(also backs the browser's own download link — same handler, no
duplicated logic), and `DELETE /api/v1/files/:id` are Bearer-token
authenticated, not session-cookie authenticated — `_current_email`
checks an `Authorization: Bearer <jwt>` header first, falling back to
the session cookie only if that's absent. This is what
`homelab-cli drive` talks to: a CLI already holds its own homelab-api
JWT directly (from `homelab-cli login`), so it never goes through the
SSO redirect dance at all — see the root `CLAUDE.md` on why the API
being genuinely usable by third-party clients, not just this browser
UI, is a deliberate design goal. A file's internal storage `uuid` is
never exposed over the API (only used server-side to name the on-disk
blob); ownership is enforced the same way as the browser routes — a
file id belonging to a different user 404s, not 403s (indistinguishable
from "doesn't exist" on purpose).

## Testing

```bash
HOMELAB_DRIVE_CONFIG=/path/to/config.yml \
HOMELAB_DRIVE_TEST_EMAIL=you@test.mailmasker.org \
HOMELAB_DRIVE_TEST_PASSWORD=... \
HOMELAB_DRIVE_HOME=. \
  prove -I lib t/
```

Needs a real config (real runtime DB credentials, migrations already
applied, a real `sso.*` section pointing at a real, already-running
homelab-sso with this deployment's actual "drive" client registered)
and a real, already-registered `homelab-api` account — `t/basic.t`
exercises the full browser/session-cookie flow for real: the OAuth
round trip through homelab-sso (wrong-password rejection, correct-
credential code issuance, state/CSRF round-tripping, code exchange),
upload, list, download (byte-for-byte round-trip check), delete
(including confirming the download link is genuinely gone afterward,
not just hidden from the list), and logout (redirects to homelab-sso's
own `/logout`). `t/api.t` covers the Bearer-token JSON API specifically
(no token/bogus token rejection, the same upload/list/download/delete
round trip, and that one user's token can't see or reach another
user's files — 404, not 403).
