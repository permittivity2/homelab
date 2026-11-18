# homelab-notes

`notes.<domain>` (post-cutover #71): a small place to jot things down. Notebooks
are the tabs, folders sit inside them, notes are written in Markdown, HTML or
plain text in a plain box and shown rendered. Earlier bodies are kept; a note
can carry links to an email or a drive file; a note or a whole notebook can be
shared with another account (see, or see and edit) or by a link anyone can
open. Everything homelab-cli needs is behind homelab-api's `/api/v1/notes/*`.

## The model

- A **notebook** belongs to an account (`owner_email`). **Folders** belong to a
  notebook (they may nest). A **note** is in one notebook and, optionally, one
  folder; it carries its `format` (`markdown`, `html`, `text`), its `body` as
  typed, a `revision` that goes up with every content change, and who last
  edited it. Soft deletes throughout (the trash).
- **Versions**: every save that changes title, body or format first copies the
  old content into `note_versions`; the last `versions_kept` (20) stay. A
  restore writes the chosen version as a new save, so nothing is ever lost by
  restoring.
- **The conflict check**: the page saves with the `revision` it was editing.
  If the row has moved on (another tab, another person), the server writes
  nothing and answers 409 with the newer note; the page offers "Show theirs"
  and otherwise keeps your words for the next save.
- **Sharing** is drive's and the calendar's shape (`shares`): every share has
  a token; `shared_with_email` NULL means anyone with the link (read only);
  a named share is `read` or `edit`; a share is on one note or on a whole
  notebook; `expires_at` optional; revoke. Levels (`Access.pm`): owner >
  edit > read. An editor changes words and links; only the owner shares,
  moves or deletes.
- **Links** (`links`): kind `mail` (a search hit: subject, from, date, mailbox,
  the search id for the person who linked it), `drive` (file id, name, size,
  type) or `url`. The pickers ask homelab-api's gateway **as the viewer**
  (their own token in the Authorization header), so this app never sees more
  than the person could. A mail link opens as a search by subject in the
  search app; a drive link as the file's download; the card shows what was
  known when it was linked.
- **Search**: a generated `tsvector` (title weighted A, body B) with a GIN
  index, `websearch_to_tsquery`, `ts_headline` for the passage; a substring
  fallback when the words make no query. Scoped to what the viewer may see.

## Rendering: the one gate

`Homelab::Notes::Markdown` turns Markdown into HTML (a GitHub-flavoured
subset: headings, paragraphs with hard breaks, lists with nesting and task
boxes, quotes, fenced and indented code, rules, pipe tables, links, images,
bare URLs, emphasis, strong, strikethrough, code spans, backslash escapes;
HTML typed into the note passes through). Its output is **not safe by itself**.

`Homelab::Notes::Clean` is the gate: an allowlist on Mojo::DOM. Tags not
listed are stripped with their text kept; `script`, `style`, `iframe`,
`object`, `embed`, `form`, `svg`, `math` and the like go with everything
inside; attributes stay only when the tag may have that one and the value
passes (`href`: http, https, mailto, a fragment or a path on this site; `src`:
http(s) only; no `style`, `class` but the code language, `id`, `on*`, `data:`).
Web links get `rel="noopener noreferrer" target="_blank"`. Markdown and HTML
bodies both end in Clean (`Render::render_body`); text bodies are escaped.

Belt and braces: every response carries a Content-Security-Policy with no
inline script (`script-src 'self'` plus the theme host), so the page script is
`/notes.js` and the boot data is a JSON data block. `t/clean.t` holds the
list of things that must never come through.

## Routes

Pages: `/` and `/n/:id` (the app), `/login`, `/oauth/callback`, `POST /logout`,
`/s/:token` and `/s/:token/n/:id` (a share link: the note, or the notebook's
list and one of its notes; a share made for one account opens only for it).

JSON for the page (session + CSRF on writes) under `/api/*`, and the same
handlers behind a Bearer check under `/internal/v1/notes/*`, which homelab-api
fronts as `/api/v1/notes/*`:

| | |
|---|---|
| `GET/POST notebooks`, `PATCH/POST notebooks/:id[/delete]` | list (own then shared, with permission), make, rename/recolour/reorder, trash with its notes |
| `GET/POST notebooks/:id/folders`, `PATCH/POST folders/:id[/delete]` | folders of a notebook |
| `GET notes?notebook_id&folder_id&q&limit&offset`, `POST notes` | the list (no bodies; `folder_id=0` = the root; without `notebook_id` everything the viewer may see; `q` searches), a new note |
| `GET/PATCH notes/:id`, `POST notes/:id/delete|restore|move` | the note with `body`, `html` (rendered), `links`, `permission`; change (with `revision`; 409 on a newer copy); trash, restore, move |
| `GET notes/:id/versions`, `GET versions/:id`, `POST versions/:id/restore` | history |
| `GET/POST notes/:id/links`, `POST links/:id/remove`, `GET pick/mail?q`, `GET pick/drive?folder_id` | links and the pickers |
| `GET/POST notes/:id/shares`, `GET/POST notebooks/:id/shares`, `POST shares/:id/revoke` | sharing |
| `GET trash`, `POST trash/empty`, `GET search?q`, `POST preview`, `GET/PUT prefs` | the rest |
| `GET /metrics` | Prometheus: `homelab_notes_up`, notebooks, notes (by format), trashed, versions, links, shares (and public), saves in the last hour, accounts |

## The page

Three panes: notebooks and folders (a drawer on a phone), the list, the note.
The note is shown rendered; Edit opens a plain textarea beside a live preview
(the preview is the server's rendering, so what you see is what everyone
gets); saves happen on a pause and on Done, Ctrl+S saves now. Keys: n new
note, e edit, / search, Esc back. The menu on a note: pin, share, move,
history, copy link, delete (with undo). A notebook's menu: rename, share,
delete.

## Install

Pool on prod-homelab47/48/49 via `install-orchestrators/notes-orchestrate.sh`
(the tier-3 role runbook run from the workstation, one shared role, node 1's
config copied with `registry.host` rewritten) after
`install-orchestrators/web-name-provision.sh notes.mailmasker.org 2518 47 48 49`
has put the name, certificate, vhost (all three edges) and the SSO client in
place, and `agent-enroll-orchestrate.sh 47 48 49` has enrolled the agents.
Later upgrades: `pkg-upgrade.sh homelab-notes 47 48 49`.

## Tests

`prove -I lib t/`: `markdown.t` (the subset, case by case), `clean.t` (what
stays, what goes, what must never come through), `access.t` (who may do
what), `basic.t` (start-up checks, sign-in, CSRF, the headers, the script; no
database). `t/model.t` needs `TEST_PG_URL` with the migration applied (CI's
`notes-db-tests` job does both; locally the scratch PostgreSQL).
