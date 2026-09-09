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

Deliberately minimal for the first pass: no sharing/trash/versioning —
those are straightforward to add later once the core upload/list/
download/delete path is proven. No drag/drop upload either — a plain
`<input type=file>` form, with a small (~10 lines of inline JS, the same
minimal-JS convention already used for delete confirmations) disable-
and-say-"Uploading…" touch so a large upload doesn't look like nothing
is happening.

## Folders

Real, nestable folder hierarchy (`migrations/002-folders.sql`,
`drive.folders` self-referencing via `parent_folder_id`; `drive.files`
gained a `folder_id`), added after a user's own hands-on feedback on the
original flat-list-only UI ("directories on the left, files in the main
part"). `GET /` (root) and `GET /folders/:id` share one handler
(`index()`) that shows the current folder's own direct subfolders (the
left sidebar) and files (the main pane) side by side, plus a clickable
breadcrumb built by walking `parent_folder_id` up to the root.

Deliberately NOT a full recursive tree view in the sidebar (only direct
children of the folder you're currently in) — keeps the query a plain
indexed lookup instead of a recursive CTE for the common case, and a
breadcrumb plus one level of children is enough to navigate; a full
tree is a reasonable future enhancement, not a v1 requirement. Also
deliberately no "move a file/folder to a different folder" yet — create,
navigate, upload-into, and (recursive) delete are the core primitives
this pass proves out.

Deleting a folder deletes everything inside it, recursively, via
`ON DELETE CASCADE` on both `drive.folders.parent_folder_id` and
`drive.files.folder_id` — but the DB cascade only removes rows, it has
no idea files also have real on-disk blobs, so `_delete_folder()` walks
the whole subtree first (a recursive CTE) to collect every `uuid` about
to be orphaned and unlinks them from disk after the DB delete succeeds.
Skipping that step would leak storage forever on every folder delete —
see `t/folders.t`'s disk-file-count assertion, which is what actually
catches a regression here (the DB-level cascade alone would still pass
every id-based "is it gone" check even if the on-disk unlink were
silently dropped).

No `UNIQUE(user_email, parent_folder_id, name)` constraint backs the
duplicate-folder-name check — Postgres treats `NULL` as distinct from
`NULL` in unique constraints, so it wouldn't actually catch two
root-level folders sharing a name anyway (`parent_folder_id IS NULL` for
both). The check is a deliberate application-level check-then-insert in
`_create_folder()` instead, with the same narrow, accepted TOCTOU race
under real concurrent requests as `homelab-api`'s own `register()` has
for email uniqueness.

### Drag-and-drop upload

Dropping files (or whole folders, dragged straight from the OS file
manager — this is upload, not a move-within-Drive feature; see
"deliberately no move" above) onto the main pane uploads into the
folder currently being viewed; dropping onto a folder row in the
sidebar uploads into *that* folder directly, regardless of which one is
open. Plain vanilla JS (`templates/index.html.ep`'s own `<script>`
block, no framework, no build step) — it just calls the same
`/api/v1/files`/`/api/v1/folders` JSON API `homelab-cli` uses, via
`fetch()` with `credentials: 'same-origin'` so this page's own session
cookie authenticates it.

Dragging a whole folder requires recursively walking it
(`webkitGetAsEntry()`/`FileSystemDirectoryReader` — non-standard in
name only, supported in every current browser; falls back to flat
per-file drops if it's ever unavailable) and creating matching Drive
folders as it goes, reusing a folder that already exists (a 409 from
`POST /api/v1/folders`) rather than failing the whole drop — this is
what makes dragging the same folder twice (e.g. after adding a file to
it locally) a no-op merge instead of an error. Uploads are processed
one at a time, not in parallel — simpler, and avoids two branches of
the same drop racing to create the same not-yet-existing folder.

**Real bug found by a user actually dragging a nested folder** (e.g.
"turkeys" containing "Downloads"): the subfolder came out as a *sibling*
of "turkeys" under the drop target instead of nested inside it, even
though the recursive walk itself correctly nests a directory's own
children under it once it's actually recursed into. Root cause was a
hypothesis when first fixed (some browser/OS/file-manager combination
hands back a dropped folder's own descendants as *separate* top-level
`DataTransferItem`s too, alongside the folder itself, bypassing the
recursion entirely for the redundant copy) — **confirmed correct**: the
same user re-tested the same real drag after the fix shipped and it
now nests properly. `dedupeNestedTopLevelEntries()` filters out any
top-level entry whose `fullPath` is nested under another top-level
entry's own `fullPath` before processing starts, and `console.warn`s when it
actually removes something, so real evidence exists to pin the cause
down precisely if this resurfaces.

This is inherently a client-side, real-browser-gesture feature —
verified here by directly replicating the exact API call sequence the
script makes (create → 409 → look-up-and-reuse → upload-with-folder_id)
over curl, and by careful manual review of the script itself, but *not*
by an actual automated drag gesture (no browser-automation tooling in
this project yet, and HTML5 drag-and-drop is notoriously hard to
simulate reliably even with one) — a real browser check is worth doing
after touching this code.

### Column sorting

Clicking a `<th>` in the file table (Name/Size/Type/Uploaded) sorts by
that column, client-side, no page reload — a repeat click on the same
column reverses direction (`▲`/`▼` shown on the active column). Plain
JS reordering the existing `<tr>` elements under `<tbody>`; nothing
server-side, since a folder's whole file list is already on the page at
once (no pagination to fight with). Name/type sort case-insensitively
(`data-name`/`data-type` are pre-lowercased by the template); size
sorts on the raw byte count (`data-size`), not the rendered "123 bytes"
text, which would sort lexicographically wrong; date sorts on the full-
precision `uploaded_at` (not the seconds-trimmed display text — see
below), so ordering among files uploaded within the same displayed
second stays correct even though the display can't show that
precision.

Upload timestamps display without fractional seconds (Postgres's own
`timestamptz` text output includes them, e.g.
`2026-09-09 10:24:45.492803-05` — real precision, but noise for a human
reading a file listing). This is a `uploaded_at_display` field computed
in `index()` (a regex strip, not a re-query) — deliberately only in the
browser-rendered view, not in the JSON API's own `uploaded_at`
(`api_list`), since a script consuming the API might actually want full
precision; presentation trimming belongs in the UI layer, not the API
contract.

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

Alongside the browser routes above, `GET /api/v1/files` (optional
`?folder_id=`, omitted means root — NOT "every file everywhere"), `POST
/api/v1/files` (multipart, field name `file`, optional field
`folder_id`), `GET /api/v1/files/:id` (also backs the browser's own
download link — same handler, no duplicated logic), `DELETE
/api/v1/files/:id`, and the folder equivalents `GET /api/v1/folders`
(optional `?parent_id=`), `POST /api/v1/folders` (JSON body `{name,
parent_folder_id}`), `DELETE /api/v1/folders/:id` are all Bearer-token
authenticated, not session-cookie authenticated — `_current_email`
checks an `Authorization: Bearer <jwt>` header first, falling back to
the session cookie only if that's absent. This is what
`homelab-cli drive` (`list`/`upload`/`download`/`delete`/`mkdir`/`rmdir`,
all folder-aware via `--folder`/`--parent`) talks to: a CLI already
holds its own homelab-api JWT directly (from `homelab-cli login`), so it
never goes through the SSO redirect dance at all — see the root
`CLAUDE.md` on why the API being genuinely usable by third-party
clients, not just this browser UI, is a deliberate design goal. A
file's internal storage `uuid` is never exposed over the API (only used
server-side to name the on-disk blob); ownership is enforced the same
way as the browser routes — a file or folder id belonging to a
different user 404s, not 403s (indistinguishable from "doesn't exist"
on purpose).

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
user's files — 404, not 403). `t/folders.t` covers the folder hierarchy:
create/nest/navigate, duplicate-name and bad-parent rejection,
cross-user isolation, and that a recursive folder delete actually
unlinks every contained file from disk (counts real files in
`storage.path` before/after, not just DB-row/API-visibility checks).
