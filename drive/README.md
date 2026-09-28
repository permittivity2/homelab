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

### Timestamp timezone display

`uploaded_at_display` (browser-rendered `index()` view only, same
UI-only/API-keeps-full-precision split as before) is now built with
`to_char(uploaded_at, 'YYYY-MM-DD HH24:MI:SS TZ')` instead of a Perl
regex trim of the plain numeric-offset text. Postgres's `TZ` format
spec pulls a real zone ABBREVIATION (e.g. "CDT") from the session's
`timezone` GUC — confirmed live to already be a real IANA zone name,
`America/Chicago`, not a bare offset (`SHOW timezone;` on the DB host).
This is what makes the abbreviation DST-correct for free: `to_char`
picks CDT or CST per-row based on each file's actual `uploaded_at`
date, not a hardcoded label that would silently go wrong across a DST
transition. Dropping fractional seconds falls out of the explicit
format string for free too — no separate regex step needed any more.
`data-date` (what column sorting reads) is unaffected — still the
plain, full-precision `uploaded_at` value.

### Size unit toggle (Bytes / Human Readable)

A toggle switch in the page header (so it's present on every folder
view, not just the current one) flips every row's size cell between
raw bytes ("1108959 bytes") and human-readable ("1.1 MB"). Entirely
client-side: the byte count is already on the page (the `data-size`
attribute column sorting already relies on), so re-formatting on
toggle is just a DOM text update, no re-fetch. Human-readable uses
1024-based units (KB/MB/GB/TB/PB, one decimal place) — the common
`ls -lh`/Finder/Explorer convention, not the technically-distinct
KiB/MiB.

Defaults to Human Readable (the checkbox's `checked` attribute in the
markup matches this, so there's no flash-of-wrong-state before JS
runs). Preference is stored in `sessionStorage`, deliberately not
`localStorage` — the ask was specifically "for the duration of the
session": survives a page refresh or navigating between folders (same
tab), but doesn't linger forever past that the way `localStorage`
would. Only `'bytes'` is ever written/checked for; anything else
(unset, corrupted, a future third value) falls back to the Human
Readable default rather than needing its own explicit case.

This is inherently a client-side interaction (a checkbox click) —
verified here by confirming the toggle markup, its `id`, and the size
cell's `file-size` class hook all render correctly (`t/basic.t`), but
*not* by an actual click (no browser-automation tooling in this
project) — worth a quick real-browser check after touching this code.

## Image thumbnails and slideshow

Ported from the old, still-running-in-production `homelab-drive-web-ui`
(`github-repos/homelab-api`'s `drive-web-ui`/`processor` packages) at the
user's request, after asking to look at how that app handles images
first — same user-visible feature (thumbnails in the file list, a
lightbox with a timed slideshow), reimplemented to fit this app's much
simpler architecture rather than copied wholesale. Three deliberate
architectural differences from the old implementation, all consequences
of this being a single self-contained app instead of a BFF fronting a
separate API + queue-worker system:

- **Generation is synchronous, at upload time**, inside `_save_upload()`
  — not queued for a background worker. This repo has no job queue yet
  (the old app used a dedicated `homelab-api-backend-processor`); since
  ImageMagick thumbnailing an ordinary photo is fast, synchronous is the
  simpler choice for now. Revisit with a real queue (Minion, per
  `../../CLAUDE.md`'s plans) if large/frequent image uploads ever make
  upload latency a real problem — a best-effort `eval` around the
  ImageMagick calls means a generation failure logs a warning and skips
  the derivative, but never fails the upload itself.
- **Serving is a plain `$c->reply->file(...)`**, same as `download()`,
  not nginx `X-Accel-Redirect` — the old app's NFS-backed, multi-host
  storage benefited from offloading byte-serving to nginx; this app's
  local-disk storage doesn't need that indirection.
- **Storage isn't user/uuid-sharded** — just `.thumbnails/<uuid>.jpg`
  and `.slideshow/<uuid>.jpg` under `storage.path`, matching this app's
  existing flat (non-sharded) convention for original files. The old
  app's `.thumbnails/<user_id>/<h1>/<h2>/<uuid>.jpg` sharding exists to
  keep any one directory from holding millions of files on a large
  shared NFS mount — not a concern at this app's scale.

Both derivatives are always re-encoded to JPEG regardless of the
original format, using ImageMagick's `Thumbnail(geometry => ...)` (the
`>` suffix means shrink-only, never enlarge a small image) — a 200×200
thumbnail (quality 80) for the file-listing row, and a much larger
1280×1280 "slideshow" image (quality 82) for the lightbox viewer, so
opening the lightbox doesn't have to load the full original just to
display it at screen size. Both geometries/qualities are configurable
under `image:` in config.yml (see `config/drive.example.yml`) but
default to the same values the old app used. The full original is only
ever sent on explicit download.

**A real bug caught by this feature's own test** (`t/thumbnails.t`):
the first version generated derivatives off a *sniffed* mime type
(`File::LibMagic`, deliberately not the client-declared upload
Content-Type — see below) but the file-listing template's "does this
row get a thumbnail" check still read the *stored*, client-declared
mime_type column. A client that doesn't send a proper `image/*`
Content-Type (Test::Mojo's own multipart upload helper doesn't, it
turns out) got a real thumbnail generated on disk that the row never
displayed — two signals that could disagree. Fixed by sniffing once,
right after the file lands on disk in `_save_upload()`, and correcting
the stored `mime_type` column to the sniffed value before anything else
(generation, the file row, the Type column, sort-by-type) reads it —
one trustworthy answer instead of two. Sniffing rather than trusting
the client matters for a second reason too: feeding attacker-controlled
bytes into ImageMagick under a spoofed `image/*` Content-Type is exactly
the kind of format-confusion ImageMagick has a real CVE history around,
so the decision to even attempt decoding never rests on client input.

Deleting a file (or a folder full of them, via `_delete_folder()`'s
recursive cleanup) unlinks its derivatives from disk too, not just the
original — same "the DB cascade doesn't know about real files on disk"
reasoning as the rest of this app's delete paths.

The lightbox (click a thumbnail or an image file's name) shows the
current folder's images only — built fresh from whatever rows are
already in the file table (`#files-table tbody tr[data-type^="image/"]`
— the same `data-type` attribute column sorting already uses, so no new
per-row data was needed). Prev/next wrap around; Home/End jump to
first/last; a play/pause button runs a timed auto-advance slideshow
with quick-select 2s/4s/10s buttons, *and* any digit key 1-9 sets that
exact number of seconds (0 pauses) — changing speed while playing
restarts the timer immediately at the new interval. Neighboring images
(next 2, previous 1) are prefetched into an in-memory, session-scoped
LRU cache (max 15) as you browse, so forward/backward navigation feels
instant instead of re-fetching every time. Fullscreen toggle, direct
download, and full keyboard support (arrows, Home/End, Escape, F, D,
Space/P) round out parity with the old app's lightbox.

Not ported: the old app's separate video-play-button/modal handling
(`.video-modal`, `playVideo()`) — a related but distinct feature the
user didn't ask for this round; worth a look if video preview is wanted
later.

This is inherently a client-side, real-browser-interaction feature
(clicking thumbnails, using the slideshow controls) — verified here by
uploading a real generated image through the full app and asserting on
the actual bytes/status codes/disk state the backend produces
(`t/thumbnails.t`), and by careful review of the ported JS, but *not* by
an actual click/keypress (no browser-automation tooling in this
project) — worth a real browser check after touching this code.

## Bulk select: delete and zip download

Checkboxes on both the folder sidebar (`<li>` rows) and the file table
(`<tr>` rows) — kept as two separate widgets sharing one selection state
(a `Selection` JS module, same object-literal-API shape as `Lightbox`),
not merged into one list; merging risked breaking the mobile slide-in
drawer for no functional gain. A bulk toolbar appears once anything is
selected, offering **Delete all selected** (synchronous) and **Download
as zip** (async — see below).

**Delete** (`POST /bulk/delete`, + `/api/v1/bulk/delete`) is a plain
loop over `_delete_file`/`_delete_folder` — both already do the real
work correctly (DB row + on-disk blob + derivatives + ownership check)
and are fast enough for this without any background job. **Folders are
processed before files**: a file that lives inside a selected folder is
already gone by the time its own individual delete is attempted, and
reports `not_found` there — an accepted, expected outcome under this
app's existing indistinguishable-404 convention (see the JSON API
section above), not a bug, and it's what makes the deleted/not_found
split deterministic regardless of what order the request's two id
arrays happen to list things in.

**Zip download is different — it does NOT build the archive in this
process.** The first design draft did exactly that (`Mojo::IOLoop->subprocess`
forked inside this app) and was explicitly rejected during planning:
zip-building isn't really a `drive` concern, and any future "this could
take a while" need in this ecosystem (SHA1 hashing, image resizing,
video transcoding, a full-account export bundling chats/emails/files)
would have had to reinvent the same in-process mechanism again. Instead
there's a new, separate, centralized service, `homelab-worker`
(`../worker/README.md`), that may run on a completely different host
and knows nothing about `drive`'s schema at all — it just fetches N
URLs (each with its own forwarded auth header) and bundles them into a
zip.

### Resolving a selection into a manifest

Storage here is **flat** — every file's bytes live at
`storage_path/<uuid>`, with no on-disk mirroring of the logical folder
tree (see "Folders" above) — so a zip can't just archive real
directories. `_resolve_manifest()` turns a selection (`file_ids` +
`folder_ids`) into a flat list of `{id, uuid, zip_path}`, one per real
file, via a recursive CTE over `drive.folders`/`drive.files` that
concatenates folder names into a path as it walks down. Two real edge
cases, both handled:

- **A folder *and* a file already inside it both selected** — collapses
  to *one* entry. Folder-derived entries are resolved into `%by_id`
  first; the individually-selected-file pass then skips any id already
  present, so the nested path always wins over the flat one.
- **Duplicate filenames within one folder** — `drive.files` has no
  `UNIQUE(folder_id, filename)` constraint, so two files can legitimately
  share a name there. `_dedupe_zip_path()` renames on collision with a
  numbered suffix (`notes.txt` → `notes (01).txt`), applied across the
  *whole* resolved manifest (one shared "seen" set), not reset per
  folder.

A `file_ids`/`folder_ids` entry that isn't actually owned by the caller
simply doesn't match either query's `user_email = ?` filter and is
silently dropped from the manifest — same indistinguishable-404-style
convention as everywhere else in this file, not a separate error path.

### The auth hand-off to homelab-worker

This app is a cookie-session BFF that never exposes a raw JWT to its own
browser JS — but it already holds one server-side (`$c->session('token')`,
set at SSO login, re-verified via `introspect()` on every request via
`_current_email`/`_current_auth`). It's the *same kind* of token
`homelab-cli` sends as `Authorization: Bearer`, and it's already
accepted by this app's own `GET /api/v1/files/:id`. So `create_zip_job`
forwards that exact token as every manifest entry's `auth_header`, and
`homelab-worker` presents it back to `public_base_url . "/api/v1/files/$id"`
(a static config value — see `config/drive.example.yml` — deliberately
*not* derived from the incoming request's `Host` header, since whatever
built the manifest and whatever `homelab-worker` actually fetches from
must agree exactly) to fetch each file, which re-verifies it the normal
way. No new auth primitive needed anywhere in this hand-off.

**Explicit, acknowledged tradeoff** (see `../worker/README.md` for the
full writeup): this is the user's real, full-scope session JWT, not a
narrow "fetch this one file" credential — `homelab-api` has no
token-narrowing capability today. The token only ever lives in the
job's `input` JSONB on `homelab-worker`'s own side for as long as the
job is pending/running, bounded by the JWT's own ~30-minute expiry.
The *same* token is also stashed in this app's own `drive.zip_placements`
row (see below) for the same bounded window, for the same reason: the
background delivery timer has no live request to pull a fresh one from.

### Zip job route, and delivery into an "Archives" folder

`POST /zip-jobs` (+ `/api/v1/zip-jobs`) resolves the manifest, submits
it to `homelab-worker` (`Homelab::Common::Registry::lookup`, then a
direct HTTP `POST /internal/v1/jobs` — not `Homelab::Common::Proxy::forward`,
since this needs to *build* a new request with the resolved manifest
+forwarded JWT, not relay the incoming one unchanged), and returns
immediately with `{id, output_name, dest_path}` — **not** a status to
poll. Zip build time is unpredictable, so rather than a live "still
building…" UI, the response just names where the finished file will
land (`Archives/<output_name>.zip`), and the user checks back whenever.

Delivery is a second, independent step: `create_zip_job` also
find-or-creates this user's root-level **Archives** folder
(`_ensure_archives_folder`) and inserts a `drive.zip_placements` row
(`migrations/003-zip-placements.sql`). A recurring 5-second timer in
`Homelab::Drive::App` (`_claim_and_deliver_zip_placement` — this app's
first recurring timer, same `FOR UPDATE SKIP LOCKED` claim pattern as
`homelab-domain-admin`'s and `homelab-worker`'s own timers) claims one
pending placement at a time, checks the underlying job via
`homelab-worker`'s own `GET /internal/v1/jobs/:id`, and once it's
`completed`, downloads the artifact and inserts it as a normal
`drive.files` row — same INSERT shape as `_save_upload`, just fed from
an HTTP response body instead of a `Mojo::Upload`. From then on the zip
is a completely ordinary file: browsable, downloadable, deletable
exactly like anything the user uploaded themselves. A job that fails to
build fails the placement immediately; a delivery-side failure (worker
briefly unreachable, or the stored JWT finally outliving its ~30-minute
lifetime before a very slow job finishes) retries up to 5 times before
giving up, at which point `homelab-cli jobs show/download <job_id>`
against the still-intact job on `homelab-worker`'s own side (kept for
its own `retention_hours`, unaffected by delivery here failing) is the
manual fallback.

There is no longer a browser-facing per-job status/download route at
all — nothing needs one now that delivery happens server-side.

## Mobile layout

Built desktop-first, with no responsive handling at all until a user
actually tried it on a phone and it showed: no `<meta name="viewport">`
(mobile browsers render at a virtual desktop width and shrink the
result, making everything tiny until you pinch-zoom), a fixed-240px
sidebar permanently competing with the file list for a phone's width,
an unbounded multi-column table with nothing to keep it from forcing
the whole page wider than the screen, and several tap targets (the
folder delete `✕` in particular) sized for a mouse cursor.

Fixed with a single CSS-only breakpoint (`max-width: 720px`) rather
than the old `homelab-drive-web-ui`'s server-side User-Agent detection
(`mobile`/`tablet`/`desktop` body classes, documented in that repo's
`DEVELOPMENT.md`) — this app has no per-request device branching
anywhere else, and a plain media query gets the same visual result
without adding any:

- **Viewport meta tag**, the actual prerequisite for any of the rest of
  this to matter.
- **Folder sidebar becomes a slide-in drawer** below the breakpoint
  (`position: fixed`, off-screen by default, toggled by a `☰ Folders`
  button in the breadcrumb bar) instead of a permanent column — there
  simply isn't room for both a sidebar and a usable file list at phone
  width. A `#sidebar-backdrop` overlay closes it on tap-outside. Above
  the breakpoint both the toggle button and backdrop are `display:
  none` (removed from layout entirely, not just hidden) — inert on
  desktop by construction, not by relying on the media query alone.
- **The file table scrolls horizontally inside its own
  `.table-scroll` wrapper** rather than widening the page — deliberately
  *not* reshaped into a stacked-card layout: the table markup, its
  `data-*` attributes, and the column-sorting JS are completely
  untouched, so sorting works identically on mobile without a second,
  parallel sort control to build and keep in sync. A wider phone-native
  "card" redesign is a reasonable further step if a horizontal scroll
  ever feels insufficient, not something this pass committed to.
- **Touch targets** (folder delete, new-folder submit, upload submit,
  per-row delete, sidebar toggle, lightbox controls) bumped to roughly
  44px, the standard minimum — a `padding: 0.15rem` icon button that
  reads fine with a mouse cursor is a real miss target with a finger.
- **Header decluttering**: the size-unit toggle's "Bytes"/"Human
  Readable" text labels and the logged-in email address both hide below
  the breakpoint (the switch itself keeps its `title=` tooltip; Log out
  stays) — there isn't room for a title, a labeled toggle, an email
  address, and a logout button on one line at phone width, and neither
  omission loses real functionality.
- The drag-and-drop `.drop-tip` hint is hidden on mobile — it points at
  a gesture (HTML5 drag-and-drop) that doesn't exist on touch; the
  plain `<input type=file>` above it still works exactly as before
  (opens the OS file picker/camera on tap).

Not ported from the old app: real server-side device detection, or a
`tablet` tier distinct from `mobile` — out of scope for a single "make
it usable on a phone" pass; revisit if a genuinely different tablet
layout is ever wanted.

Same honest caveat as every other layout/interaction change in this
README: verified by fetching the rendered page and confirming every
new element/class/rule is actually present (and that the full test
suite still passes — the table wrapping and markup changes here don't
touch anything the existing tests assert on), but a real phone/narrow-
viewport check is the only way to confirm it actually *feels* right.

## Upload size limit (4GB) and where the body goes

The stack accepts uploads up to ~4GB out of the box. That takes several
ceilings raised IN SYNC (whichever is lowest silently wins) across two
different request paths:

- **Browser** (`drive.<domain>` → homelab-webproxy → this app):
  homelab-webproxy's per-site `max_body_size: 5g` (`webproxy/
  README.md`) AND this app's `MOJO_MAX_MESSAGE_SIZE=5368709120` (5GB,
  headroom over a 4GB file + multipart framing) in
  `systemd/homelab-drive.service`.
- **CLI/API** (`homelab-cli drive upload` → homelab-api's
  `/api/v1/drive/*` gateway → this app): ALSO homelab-api's own
  `MOJO_MAX_MESSAGE_SIZE` + the `api.<domain>` vhost's `max_body_size`,
  since a CLI upload streams through homelab-api's `Proxy::forward` on
  its way here. Easy to miss — the two paths don't share a hop.

**Where the bytes go matters as much as the limit.** Mojo spools any
body over `MOJO_MAX_MEMORY_SIZE` (256KB) to a temp file, and
`MOJO_TMPDIR=/var/lib/homelab/drive-storage/.uploads-tmp` points that at
a dir on the SAME filesystem as `storage.path` — deliberately NOT the
default `/tmp`, which on this fleet is a RAM-backed **tmpfs**. A 4GB
upload spooled to a tmpfs would be held entirely in RAM and OOM the box
(the drive container has only 512MB RAM — confirmed the hard way). On
the storage filesystem instead, the spool lands on real disk AND
`$upload->move_to` into storage is a cheap rename, not a 4GB copy.
homelab-api's gateway hop has the same `MOJO_TMPDIR` treatment.

**Host requirements for real 4GB use:** the storage volume must hold
4GB files with headroom (drive's own disk was expanded from 8GB to 24GB
for this), and the api-gateway host needs temp room for the spool of a
CLI upload. hypnotoad's `inactivity_timeout` is raised to 1200s so a
slow/large transfer isn't dropped mid-flight.

Regression history: the previous 100MB/1MB defaults were found far too
low by a real user hitting nginx's own 1MB default with an ordinary
1.1MB upload — see `tests/e2e/test_cli_features.py`'s
`test_drive_upload_over_1mb_and_16mb_succeeds`.

## Chunked / resumable uploads

The whole-file `POST /files` path above still exists, but a single 4GB
request is fragile: one dropped connection wastes the entire transfer.
So a file larger than 8MB (`CHUNK_UPLOAD_THRESHOLD` in both the CLI and
the web JS) instead goes up in ordered, offset-addressed chunks that can
resume from wherever the server last had complete bytes. See
`migrations/006-upload-sessions.sql` for the full rationale.

**Protocol** (all four dual-mounted: bare path for the browser,
`/api/v1/...` for homelab-cli):

| Request | Body / header | Response |
|---|---|---|
| `POST /uploads` | JSON `{filename, total_size, folder_id?}` | `{upload_id, offset:0, chunk_size}` (or `{done, file_id}` for a 0-byte file) |
| `GET /uploads/:id` | — | `{offset, total_size, state, file_id?}` |
| `PATCH /uploads/:id` | `Upload-Offset:` header + raw chunk bytes | `{offset, done, file_id?}`; **409** with the true `{offset}` on mismatch |
| `DELETE /uploads/:id` | — | aborts, drops the partial |

Design points that matter:

- **The on-disk size of the one `.partials/<uuid>` file per session is
  the authoritative resume offset**, not the `received_bytes` DB column
  (that's a mirror, for cheap status reads + the stale sweeper). A
  resuming or duplicate client that sends the wrong `Upload-Offset` gets
  a **409 carrying the real offset** and re-aligns to it — the same
  mechanism handles resume, retries, and accidental double-sends
  uniformly.
- **`flock(LOCK_EX)` on the partial** serializes concurrent PATCHes for
  one session across hypnotoad prefork workers; the size is read under
  that lock, and the state is re-checked under it too (a finalize/abort
  on another worker may have won while we waited). Finalize (the chunk
  that reaches `total_size`) runs **while still holding that lock**, and
  flips `state='completed'` **together with `result_file_id` in one
  UPDATE, only after the bytes are renamed into storage** — so no
  observer ever sees a `completed` session with a null `file_id`, and a
  duplicated final chunk is serialized behind the finalizer and then
  takes the "already completed" path instead of double-inserting. mime
  sniffing + image derivatives run *after* the lock is released, so a
  slow `Image::Magick` pass can't widen that window or block a chunk.
  The `sysopen` deliberately has **no `O_CREAT`**: a partial that's
  vanished (raced away by finalize/abort/sweep) yields a clean "session
  moved on" response, never a resurrected orphan blob.
- **Abuse bounds & cleanup:** a per-user cap (`$MAX_OPEN_SESSIONS_PER_USER`,
  100) on concurrent `open` sessions (429 over it); `folder_id` is
  normalized to a bounded integer so a malformed one can't 500 the
  bigint cast; and `_sweep_stale_uploads` additionally does a
  directory-reconciliation pass, unlinking any `.partials` file with no
  owning session row older than an hour — a backstop for anything a
  crash mid-finalize could strand.
- **`.partials` lives on the storage filesystem** (real disk, not the
  tmpfs `/tmp`), so a big upload spills to disk instead of OOMing and
  **finalizing is a same-fs rename** into `storage_path/<file uuid>`,
  not a byte copy. The insert-row-then-rename order (same as the concat
  job) means a failed move never orphans a blob.
- **Why offset/state travel in the JSON body, not response headers**
  (the tus.io way): homelab-api's gateway relays only the backend's
  response *body* + content-type, not arbitrary response headers (see
  `common/lib/Homelab/Common/Proxy.pm`). Request headers (`Upload-Offset`)
  do forward through. So each chunk PATCH through the gateway is bounded
  to one chunk — which also sidesteps the gateway's 30s request timeout
  and the ct02 spool that a single 4GB request would strain.
- **Resume across invocations**: `homelab-cli drive upload` writes a
  sidecar (`~/.config/homelab-cli/uploads/<hash>.json`) with the session
  id the instant it's created, so re-running the same command after an
  interruption resumes instead of restarting. The sidecar key includes
  the file's size + mtime, so editing the file starts fresh. The browser
  retries a dropped chunk within the page session (re-syncing via GET).
- **Abandoned sessions** (client vanished) are reaped by
  `_sweep_stale_uploads` (a 10-min timer) once a still-`open` session has
  been idle > 24h — both the row and its orphaned partial.

## Append / combine files (reassemble split uploads)

Select several files and combine them into one, concatenating their
bytes end-to-end — the reassemble half of "split a big file, upload the
pieces." Two entry points, differing only in how the ORDER is decided
(order is load-bearing for concatenation):

- **Web** (`bulk-toolbar` "Combine into one file" button): the selected
  files are concatenated in **alphabetical order of their filenames**.
  The order is shown in the confirm prompt so it can be eyeballed before
  committing.
- **`homelab-cli drive append <id1> <id2> ...`**: concatenated in the
  **exact order the ids are listed** — the user picks the order.

Both POST to `/append-jobs` (browser) / `/api/v1/append-jobs` (CLI),
handled by `create_append_job`, which honors the received order
verbatim (it does NOT reuse `_resolve_manifest`, which sorts by id).
Every requested file must be one the caller owns, or the whole request
is refused — unlike zip, a concat with a missing piece would be
silently wrong.

**This runs on-host, NOT on homelab-worker** — unlike zip. A zip builds
something new that isn't already on drive's disk, so offloading it (and
paying the network round-trip) makes sense. A concat's source files are
ALREADY local blobs under `storage_path`; the work is nearly all disk
I/O and almost no CPU, so shipping gigabytes to a separate host and back
would be pure waste. Instead `create_append_job` records a
`drive.append_jobs` row (migration 005) and a recurring timer
(`_run_append_jobs`) claims it (`FOR UPDATE SKIP LOCKED`, same pattern
as the zip timer) and does the byte-copy in a **forked subprocess**
(`Mojo::IOLoop::Subprocess`) — streaming the sources in 1MB chunks into
one new blob — so a multi-GB combine never blocks a hypnotoad worker's
event loop and never holds a file in RAM. The child does only file I/O;
the parent inserts the `drive.files` row, renames the built blob into
storage (same-fs, cheap), sniffs its MIME, and marks the job done. A job
whose subprocess dies mid-build (restart) is reclaimed from `processing`
back to `pending` after 15 minutes. The result lands in the source
files' own folder (or a caller-specified one) and appears in drive when
ready — same "check back for it" model as zip, but with no worker, no
network hop, and no second host to provision. ("Heavy work off the
request" is the real rule — see CLAUDE.md; *where* it runs is a
per-workload call, and for concat that's right here.)

## Job status & progress (concat and zip)

Both async "produce a new file" jobs expose status so the UI can show
progress and — critically — **surface a failure** instead of a file that
silently never appears:

- **`GET /append-jobs/:id`** (concat) → `{state, received_bytes,
  total_bytes, file_id, error}`. `state` is `pending | processing |
  finalizing | completed | failed`. Live byte-% comes from a **heartbeat**
  step in `_run_append_jobs`: each tick it stats the growing per-run temp
  and mirrors its size into `received_bytes`, bumping `started_at` on
  growth. That bump is load-bearing — "stuck" now means *no progress for
  15 min*, not *started 15 min ago*, so a legitimately long combine is
  never re-pended and double-run.
- **`GET /zip-jobs/:id`** (zip) collapses the two-system lifecycle
  (homelab-worker builds → drive delivers into Archives) into one phase:
  `queued | building | delivering | completed | failed`, with `N of M`
  entry progress from the worker (`progress_current/total`, written to a
  per-attempt progress file the worker's own heartbeat mirrors) and the
  finished `file_id`. Uses a short-timeout UA so a hung worker can't
  freeze the poll.

The web UI polls both after submit (progress bar + error surfacing);
`homelab-cli drive append` prints the job id (poll `append-jobs/:id`).

**Concurrency & correctness hardening** (from adversarial review): concat
completion is guarded on an `attempt` epoch (migration 008) + a
`finalizing` claim before any side effect + a per-attempt temp path, so a
reclaimed-but-still-alive subprocess can't double-run, clobber the re-run's
bytes, or leave a completed job pointing at a missing/partial blob; concat
forks are capped fleet-wide (`$MAX_CONCURRENT_APPEND`); the worker sweeps
orphaned `.work` build dirs / progress files after an ungraceful crash.

**Known deferred limits** (tracked, not yet fixed): the zip-**delivery**
timer still downloads the artifact with a blocking UA on the event loop
(pre-existing); large **downloads** through the homelab-api gateway slurp
the whole body into RAM (so a multi-GB `drive download` via the gateway
can 502 on the 512MB api host); and `Archive::Zip`'s final write is a
single tickless phase (a >50GB export's write could be false-reclaimed).

## Trash (soft delete)

A **web-interface** delete is a **soft delete**: the item gets a
`deleted_at` timestamp (migration 009) and keeps its `folder_id` /
`parent_folder_id`, so it vanishes from normal listings but can be
restored to exactly where it was. It is **not** a real folder — Trash is
a virtual view (`GET /trash`, a sidebar link) over `deleted_at IS NOT
NULL`. Every normal query (`index`, `api_list`, folder listings,
breadcrumb, `_owned_folder`, folder-name uniqueness, the zip manifest,
concat sources, the Archives lookup) filters `deleted_at IS NULL`, so a
trashed item can't be listed, zipped, combined, or collide on a name.

- **Delete → Trash** (soft) is the default for the browser: `delete_file`,
  `delete_folder`, and the browser `/bulk/delete` route (via a
  `soft_delete` route default). A folder delete soft-deletes its whole
  subtree (folders + files) recursively, so it restores as a unit.
- **Restore** (`POST /files/:id/restore`, `POST /folders/:id/restore`)
  clears `deleted_at`; restoring also un-deletes the item's **ancestor
  folder chain** so it lands somewhere reachable even if its parent was
  trashed too. Restoring a folder brings back its whole subtree.
- **Permanent delete** — `POST /files|folders/:id/purge` (per item) and
  `POST /trash/empty` (everything) — do the real unlink (blob +
  thumbnail/slideshow) + row delete. A background timer
  (`_purge_expired_trash`, hourly) auto-purges items older than
  `trash.retention_days` (config, default 30; `0` disables auto-purge).

**API / homelab-cli deletes stay HARD (immediate) by default**, matching
the "scripts don't want a Trash accumulating" expectation:
`DELETE /api/v1/files/:id` and `homelab-cli drive delete` remove
immediately. Both opt into Trash with `?soft=1` / `homelab-cli drive
delete --trash`. The CLI also has `drive trash` (list) and `drive restore
<id> [--folder]`. Restore/purge/empty endpoints are dual-mounted
(`/api/v1/...`) so the browser Trash view drives them by `fetch`, same as
bulk delete.

Tested by `t/trash.t` (soft/hard/restore/purge/exclusion/folder-recursion/
ownership; the time-based retention purge is a timer, not covered there).

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
the session cookie only if that's absent. `POST /api/v1/append-jobs` (JSON `{file_ids: [...ordered...],
output_name?, folder_id?}`) starts a combine (see "Append / combine
files" above). This is what
`homelab-cli drive` (`list`/`upload`/`download`/`delete`/`mkdir`/`rmdir`/
`append`, all folder-aware via `--folder`/`--parent`) talks to: a CLI already
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
`t/thumbnails.t` covers image thumbnail/slideshow-image generation: a
real (self-generated, no external fixture needed) JPEG gets both
derivatives on disk and served correctly, a non-image upload gets
neither (and isn't itself broken by the attempt), cross-user isolation
on the two new routes, and that deleting a file also unlinks its
derivatives, not just the original. `t/bulk.t` covers bulk select: mixed
files+folders delete (including the folder-containing-a-selected-file
`not_found` case), manifest resolution (nested folders, the
folder+nested-file dedup case, the duplicate-filename case), and a real
end-to-end zip job — submit, poll through `homelab-worker`'s real
claim/run cycle, download, and unzip to confirm the archive's actual
folder structure and file contents match the original selection exactly
— which additionally needs a real, already-registered, reachable
`homelab-worker` (see `../worker/README.md`).
