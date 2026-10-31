# homelab-search

A normalized full-text index over the fleet's mail and drive content, and the
continuous indexer that maintains it. Serves `search.mailmasker.org`.

Phase 1 of post-cutover item 40: the schema and the indexer. The web app and
the optional AI mode are Phases 2 and 3.

## Shape

```
/srv/mail-ro   (ro NFS, dovecot vmail)  ─┐
/srv/drive-ro  (ro NFS, drive blobs)    ─┴─► indexer ──► Postgres `search` schema
                                                              ▲
                                             request path ─────┘  (Phase 2)
```

The split that makes the scope guarantee checkable: **the indexer touches the
filesystem; the request path touches only Postgres.** Nothing in a search
request opens a file.

## The one invariant: no account ever sees another's data

Not left to every future `WHERE` clause being written correctly. Four layers,
strongest first.

**1. Composite foreign keys.** Every child row carries `account_id` and
references its parent by `(parent_id, account_id)`:

```sql
FOREIGN KEY (message_id, account_id)
    REFERENCES search.messages (message_id, account_id)
```

Carrying `account_id` on a child is formally redundant — `message → mailbox →
account` already determines it — and that redundancy is the point. Postgres
itself refuses to attach account A's body, file, header or attachment to
account B's message, so an indexer bug is a constraint violation rather than a
disclosure.

**2. Row-level security, with `FORCE`.** Every table with an `account_id`.
`FORCE` matters: without it the table owner bypasses RLS entirely, which would
make the whole mechanism decorative for the migrate role. The policy reads
`current_setting('homelab.account_id', true)`, which is NULL when unset — and
`account_id = NULL` is NULL, so an unset value yields **zero rows**. Nothing is
visible until the app says who is asking.

The app must use `SET LOCAL` inside an explicit transaction, never a bare
`SET`: the pgbouncer tier runs `pool_mode = session`, and a bare `SET` persists
on the pooled server connection where the next client would inherit it.

**3. The indexer's own door, not a master key.** Indexing legitimately crosses
accounts. Giving the runtime role `BYPASSRLS` would have been simpler and would
have handed the same power to the web app, which must never have it. Instead a
second policy keys on `homelab.indexer = 'on'`, which the indexer sets (as `SET
LOCAL`, so it cannot leak onto a pooled connection) and the request path never
sets — it always sets a numeric account id.

**4. Paths derive from the account, never from input.** The two stores are not
symmetric and the rules differ:

- **Mail is path-scoped.** dovecot's `mail_path` is
  `/var/mail/vhosts/%{user|domain}/%{user|username}`, so an account's mail is
  exactly one directory. `Homelab::Search::Paths` is the only place a path is
  built, it takes `(domain, local_part)` from `search.accounts` and nothing
  else, and it asserts `realpath()` containment before any read — which defeats
  both `..` in a local part and a symlink planted inside a maildir. A prefix
  test on the unresolved string catches neither.
- **Drive is not path-scoped.** Blobs are flat by uuid
  (`/var/lib/homelab/drive-storage/<uuid>`), so the filesystem cannot tell you
  who owns a file; only `drive.files.user_email` can. A blob is therefore only
  opened for a uuid an account-scoped query just returned, and **the storage
  directory is never enumerated** — there is deliberately no function that
  lists it.

### The one thing the database cannot enforce

`domains`, `addresses`, `display_names` and `mime_types` are a *shared
vocabulary*: one row per distinct value, reused by every account, no account
association, so no RLS is possible on them. `search.addresses` therefore
contains every address anyone in the fleet has corresponded with.

> **Any query that resolves a person must reach them through
> `search.message_addresses`, never by reading `addresses`/`display_names`
> directly.** A participant typeahead built straight off `addresses` would leak
> one user's contacts to another. This is written in the migration too, in the
> file you have to open to add such a query.

## Normalization

Past 3NF, as asked. The parts that earn it:

| Relation | Why it is its own table |
|---|---|
| `mime_types (type, subtype)` | Split, so "any image" is `type = 'image'` on an indexed column instead of `LIKE 'image/%'` |
| `addresses` × `display_names` × `address_names` | One address appears under many display names and one name across many addresses — a genuine many-to-many. This is what lets a query find a **person** rather than string-matching a header |
| `address_roles` | from/sender/reply-to/to/cc/bcc as a lookup, with `message_addresses` carrying role + position |
| `header_names` + `message_headers` | An **allowlist** of headers, normalized so adding one is a row, not a migration. Storing every header is unbounded (spam headers are enormous) and almost none of it is queried |
| `message_files` | Each message's on-disk filename and location, keyed on the part of the maildir name that does **not** change |
| `threads` | `In-Reply-To` → parent's thread, else a new one |

## Two traps in the full-text columns

**The text-search config must be literal.** `to_tsvector('english', …)` is
IMMUTABLE and legal in a generated column; the one-argument form is only STABLE
because it reads `default_text_search_config`, and Postgres rejects it there.
(This cluster's default is already `pg_catalog.english`.)

**A tsvector is capped at ~1 MB**, so a large message or text file would error
the INSERT. `body_text` keeps the full text, `tsv_source` holds only the prefix
that was vectorized, and `truncated` records that it happened — which makes
"was this fully indexed?" answerable instead of invisible.

## Measured: full-text search under RLS cannot use the GIN index

Worth knowing before Phase 2's query layer is written. It is not a
configuration mistake and it is not obvious.

A full-text query run as the runtime role does a **sequential scan**, even
though `idx_bodies_tsv` exists and the planner uses it happily for the same
predicate without RLS:

```
Seq Scan on message_bodies  (cost=0.00..4245.84 rows=1525)
  Filter: ((RLS predicate) AND (tsv @@ '''invoic'''::tsquery))
```

The cause is Postgres's leakproof rule. `tsvector @@ tsquery` is not marked
leakproof, so it may not be evaluated before the row-security qual — and
using the GIN index would do exactly that. Three plausible explanations were
ruled out by measuring rather than reasoning:

- **not** the two OR'd policies: the identical predicate written as a plain
  `WHERE` clause uses `Bitmap Index Scan on idx_bodies_tsv`;
- **not** a missing explicit account filter: adding `account_id = 20`
  alongside the policy changes the plan not at all;
- **not** a missing composite index: a `GIN (account_id, tsv)` index built
  with `btree_gin` was not used either, so it was dropped rather than left to
  slow every insert for no benefit.

**Measured cost: ~109 ms for 1,601 hits over 27,194 messages**, scaling
linearly — so roughly 1.1 s at ten times this corpus. Fine now, worth fixing
before it is not.

The fix, when needed, is a `SECURITY DEFINER` search function taking the
account id as an argument and doing the filtering itself, so the planner sees
an ordinary query and can use the index; RLS stays on as the backstop for any
direct table access. That is a query-layer decision and belongs with Phase 2,
where the interface is actually written.

## pg_trgm is a prerequisite the package cannot install

`CREATE EXTENSION` is superuser-only and this schema's migrate role
deliberately is not. Once, on the Patroni primary:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS btree_gin;   -- see the RLS/leakproof note above
```

The migration tests for `pg_trgm` and builds GIN trigram indexes if present,
else btree fallbacks plus a warning — a missing extension must not fail the
install. **A rebuilt cluster silently loses these**, so it belongs in the HA
bootstrap notes as well; substring search degrades to sequential scans with no
error anywhere.

## The indexer

`homelab-search-indexer`, one per host, `Restart=always`.

```
homelab-search-indexer             # run forever (the systemd unit)
homelab-search-indexer --once      # one discovery + drain, then exit
homelab-search-indexer --discover  # enqueue only
homelab-search-indexer --status    # queue and index counts
```

**All three hosts index; none sits idle. Discovery is single-flight, execution
is shared.** One host takes a Postgres advisory lock, does the cheap scan,
enqueues, releases; every host then pulls units with `FOR UPDATE SKIP LOCKED`.

Per-user or per-directory sharding was considered and rejected **on the data**:
drive has two users, so a per-user split hands one host the entire drive corpus
and leaves two idle. `SKIP LOCKED` balances itself, needs no ownership map, and
returns a dead host's unit to the pool when its lease expires.

### Why not inotify

The mail and drive files are written by the *dovecot and drive* nodes, and NFS
does not deliver inotify events for changes made by another client. A watch on
`/srv/mail-ro` would sit silent forever while mail arrived. So:

- **Mail** is polled by maildir directory mtime — one `stat` per mailbox decides
  whether to list it, so a full sweep is a few hundred syscalls.
- **Drive** is polled from drive's own tables, which is exact (deletions and
  restores are visible) and keeps the never-enumerate rule intact.

### The maildir rename trap

A maildir file is **renamed when its flags change**: the name is
`<uniq>:2,<flags>`, so reading a message rewrites its filename and moves it
from `new/` to `cur/`. A naive "filename I have not seen = new message" check
re-indexes an entire mailbox every time someone opens their mail. The stable
identity is everything before the `:`, stored as `message_files.uniq_part`,
and a flag change is a one-column `UPDATE`.

### How much parallelism actually buys

Less than three hosts suggests. `tsv` is a `GENERATED` column, so
`to_tsvector` runs on the **Patroni primary** and there is no way around that —
it is a server-side function. Three indexers do not triple it; they send more
concurrent writes to one database. What genuinely parallelises is this side's
work: NFS reads, MIME parsing, HTML→text, normalisation.

So `indexer.busy_sleep_seconds` and the unit size are numbers to tune with
evidence, including downward. The queue makes that a setting rather than a
redesign. Where the parallelism earns its keep is the case that will come: a
re-index after an extractor or schema change.

A unit that fails `max_attempts` times is **parked** with its error rather than
retried forever — one malformed message must not sit at the head of the queue
blocking everything behind it.

## Everything the indexer reads is hostile input

Anyone on the internet can email these users, so every parsed field arrives
from a stranger. Subjects, bodies, address lists and part counts are all
capped; every decode is wrapped; a part that will not parse degrades the
message to metadata-only rather than aborting the mailbox. `Email::MIME` and
`Email::Address::XS` do the parsing rather than regexes, because an address
list is not comma-separated in any useful sense — `"Forge, Constance"
<c@x>` is **one** address, and a regex turns it into two fictional people.

## `content_created_at`

A file's own date, not when we received it. Captured at upload — the browser
sends `File.lastModified`, the CLI sends `stat()` mtime — into
`drive.files.content_created_at` (drive migration 012) and copied into the
index. Both are client-supplied and therefore validated: an implausible value
is dropped rather than stored, because a file claiming to be from 1899 would
sort ahead of everything real.

**Not backfillable.** Once the bytes are on the NFS share their mtime *is* the
upload time, so for every file uploaded before migration 012 there is nothing
to recover. Those rows stay NULL and every reader falls back to `uploaded_at`.

## Install notes

**The indexer runs as uid 5000 (`vmail`), not as `homelab`.** The postinst
creates that user and group with those exact fixed ids. Two independent
reasons, both of which produce a silent empty index if you get them wrong:

- **The store has two permission modes.** 21 account directories are `0770
  vmail:vmail` and 5 are `0700 vmail:vmail` — dovecot creates new maildirs
  `0700` by default. Group membership reads the older accounts and silently
  misses every newly created one, so the gap grows with each new mailbox.
  Presenting uid 5000 reads both.
- **The NAS has `manage-gids=y`**, so the NFS server resolves the caller's
  groups *locally by uid* and discards the supplementary group list the
  client sends. A supplementary gid of 5000 therefore buys nothing over NFS;
  only the uid and primary gid in the RPC credential count.

Running as the store's owner does **not** make it writable: for these hosts
the export is `ro=` on the *server*, so writes are refused whatever identity
is presented. That is why the read-only grant was put on the server rather
than left to a client mount option.

> **Running the indexer by hand needs the same identity.**
> `sudo -u vmail -g vmail homelab-search-indexer --once`
> `sudo -u homelab …` reads *nothing* and logs "cannot read the mail root".

`postrm purge` does **not** drop the `search` schema. It is rebuildable, but
dropping a schema during a routine apt operation is the shape of the
`homelab-database-ha` landmine. Dropping it is a deliberate act:
`DROP SCHEMA search CASCADE;`.

## Tests

`t/paths.t` is the one that matters most — it is the authorization boundary for
the filesystem half, so a regression there is a cross-account disclosure rather
than a cosmetic bug. It covers traversal, a symlink escaping the account tree,
the sibling-prefix case (`/x` must not "contain" `/x-evil`), and the legitimate
shapes that must not be refused (a mailbox sub-directory that does not exist
yet, a Maildir++ folder name with a space).
