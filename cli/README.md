# homelab-cli

Command-line client for the `homelab-*` ecosystem. The one package in
this repo allowed to be Python (see `CLAUDE.md`'s Language section) —
everything else ships as Perl — specifically so it's easy for a Linux
user to read, edit, or take apart for their own purposes. It's meant to
cover nearly all the same activities as the web UIs, not just
account/session management: email, file storage, and (for site_admin
accounts) user administration — see the root `CLAUDE.md` on why the API
being genuinely usable by third-party clients, not just a browser, is a
deliberate design goal. Anyone is free to write their own tool against
the same APIs this one calls; nothing here is a special, privileged
client.

```bash
homelab-cli configure --api-base https://api.test.mailmasker.org
homelab-cli register you@test.mailmasker.org
homelab-cli login you@test.mailmasker.org
homelab-cli whoami
homelab-cli registry list
homelab-cli registry lookup homelab-drive
homelab-cli logout
```

**`--api-base` is the only thing this CLI ever needs to know about.**
It didn't used to be — earlier, `configure` also needed
`--drive-base`/`--imap-host`/`--imap-port`/`--smtp-host`/`--smtp-port`,
one address per feature, which only gets worse as more features
(chat, ...) show up. Fixed by making `homelab-api` itself the single
client-facing gateway (see `../api/README.md`): `/api/v1/drive/*` and
`/api/v1/mail/*` forward to homelab-drive and homelab-mailbridge
respectively, resolved server-side via the service registry, the same
"one API, like Shopify's or GitHub's SSH interface" reasoning
documented in the root `CLAUDE.md`'s registry design notes. Every
`drive`/`mail` command below already reflects this — there's nothing
extra to configure for them.

`configure` with no flags at all just prints the current configuration.

Session (`token`/`refresh_token`) is stored `0600` in
`~/.config/homelab-cli/session.yml`, separate from the non-secret
`api_base` in `config.yml` in the same directory — same "local CLI
config, same trust model as `gh`/`aws`/`kubectl`" reasoning as
`../api/README.md`'s "Two different clients, two different trust
models" section.

The JWT itself is short-lived (`jwt.expiry_seconds` in `homelab-api`'s
own config, 30 minutes by default) but this is invisible in normal use:
`Client` (`homelab_cli/client.py`) transparently catches a 401 on any
authenticated call, spends the `refresh_token` for a new one, retries
the same request once, and writes the refreshed pair back to
`session.yml` — a long-running session (or just a command run a while
after the last one) keeps working without ever needing an explicit
`homelab-cli login` again, up to the refresh token's own 30-day
lifetime. `/api/v1/auth/refresh` rotates the refresh token on every
use, so the one on disk is always the current one, never reused stale.
If the refresh token itself has expired or been revoked (e.g. via
`logout` elsewhere), that one retry fails closed with a clear "session
expired -- run `homelab-cli login` again" instead of a confusing raw
401.

## Email (`mail`)

```bash
homelab-cli mail list [--mailbox INBOX] [--limit 20]
homelab-cli mail read <uid> [--mailbox INBOX]
homelab-cli mail send --to you@example.com --subject "Hi" --body "..."
```

Plain HTTP calls to `homelab-api`'s `/api/v1/mail/*` gateway now — no
IMAP/SMTP client code lives here at all any more. That logic (XOAUTH2
against dovecot/postfix, using the same JWT this CLI already holds)
moved server-side into `homelab-mailbridge` when the gateway was
built; see `../mailbridge/README.md` for the protocol-level details
(and the still-relevant known gap: dovecot/postfix serve a self-signed
cert on the real IMAP/SMTP ports, so TLS verification is relaxed
there, same as before — just enforced in Perl now, not Python).

## File storage (`drive`)

```bash
homelab-cli drive list [--folder <folder-id>]
homelab-cli drive upload <path> [--folder <folder-id>]
homelab-cli drive download <file-id> [--output <path>]
homelab-cli drive delete <file-id>
homelab-cli drive mkdir <name> [--parent <folder-id>]
homelab-cli drive rmdir <folder-id>
```

`list`/`upload` default to the root when `--folder`/no folder is given.
`rmdir` deletes everything inside the folder too, recursively — same
cascade as the web UI's own folder delete (see `../drive/README.md`'s
Folders section).

Talks to homelab-drive's Bearer-token-authenticated JSON API (see
`../drive/README.md`'s "JSON API" section) through `homelab-api`'s
`/api/v1/drive/*` gateway — a CLI never goes through the browser-facing
SSO redirect flow at all; it already holds its own JWT directly, and
now never needs to know drive's own address either.

## DNS + mail-domain administration (`dns`)

```bash
homelab-cli dns domains list
homelab-cli dns domains add example.org
homelab-cli dns domains add mail-only.example.org --no-dns
homelab-cli dns domains show example.org
homelab-cli dns domains enable example.org
homelab-cli dns domains disable example.org

homelab-cli dns records list example.org
homelab-cli dns records add example.org --name example.org --type A --value 203.0.113.10
homelab-cli dns records delete example.org --name example.org --type A

homelab-cli dns spf set example.org
homelab-cli dns spf set example.org --all fail --include sendgrid.net
homelab-cli dns dmarc set example.org
homelab-cli dns dmarc set example.org --policy quarantine --rua postmaster@example.org
```

`site_admin` role required server-side (same "just attempt the call and
surface whatever the server decides" approach as `admin`, below).
Backed by `homelab-domain-admin` through `homelab-api`'s
`/api/v1/domains/*` gateway — see `../domain-admin/README.md`, which
also covers DKIM rotation, per-recipient mail allow/block, and
multi-domain send-as grants (`dns dkim`, `dns recipient-access`, `dns
mail-aliases` — all already landed, not documented in this file yet).

`dns spf set`/`dns dmarc set` are a thin, friendlier layer over `dns
records add` — they build the correct TXT record value from a couple
of flags (SPF's real `+`/`?`/`~`/`-` qualifiers behind `--all
pass/neutral/softfail/fail`, DMARC's `p=`/`rua=`/`pct=` tags behind
`--policy`/`--rua`/`--pct`) instead of expecting an admin to already
know that syntax — most people running a mail server don't, and
getting it wrong is easy to do silently. Defaults are the safe,
conservative choice in both cases: SPF's `--all` defaults to
`softfail` (`~all`, mark suspicious — never hard-reject by default),
DMARC's `--policy` defaults to `none` (monitor only). Neither record
has key material or a rotation lifecycle the way DKIM does, so there's
no separate state machine here — running `set` again just replaces
the existing record (same upsert semantics as `dns records add`
itself).

`dns domains add` (when it creates a DNS zone) and `dns mail-aliases
add` (which always does) each print a one-line nudge afterward for
whichever of SPF/DMARC isn't set up yet for that domain, pointing at
the commands above — a check, never a blocker; domain/alias creation
still succeeds either way, and the check itself fails silently if the
zone isn't queryable yet rather than making creation look like it
failed.

## Background jobs (`jobs`)

```bash
homelab-cli jobs list [--all] [--type zip] [--state pending|running|completed|failed]
homelab-cli jobs show <job-id>
homelab-cli jobs download <job-id> [--output <path>]
```

Not nested under `drive`, even though `drive`'s bulk "download as zip"
feature is the only thing that submits a job today — `homelab-worker`
(`../worker/README.md`) is a deliberately generic background-job engine,
and future job types won't be drive-specific either; this CLI's
`list`/`show`/`download` work the same regardless of job type.

`list` shows your own jobs by default; `--all` requests every user's
jobs, honored server-side only for a `site_admin` account (a clean
`403` otherwise, not a silently-scoped-down result — same "just attempt
the call and surface whatever the server decides" approach as `admin`,
below). `download` defaults its destination filename to the job's own
`output_name` when `--output` is omitted. Backed by `homelab-worker`
through `homelab-api`'s `/api/v1/jobs/*` gateway.

## Administration (`admin`)

```bash
homelab-cli admin users list
homelab-cli admin users grant-role <user-id> <role>
homelab-cli admin users revoke-role <user-id> <role>
```

Talks to homelab-api's `site_admin`-gated endpoints (see
`../api/README.md`'s "Admin endpoints" section). No client-side role
check here — these commands just attempt the call and print whatever
the server decides; a non-admin account gets a clean "site_admin role
required" error, not a confusing local guess about permissions it can't
actually verify.

## Tab completion

Works out of the box after installing the package — no `~/.bashrc` edit
needed. Try `homelab-cli dri<TAB>`, `homelab-cli drive <TAB>`, or
`homelab-cli admin users grant-role 5 <TAB>` (completes to `user`/
`site_admin`) in a new shell.

Built on [`argcomplete`](https://github.com/kislyuk/argcomplete), the
standard way to add shell completion to an `argparse`-based CLI —
`homelab_cli/cli.py`'s `main()` calls `argcomplete.autocomplete(parser)`
right before `parse_args()` (a documented no-op unless a shell is
actually asking for completions, so it doesn't touch ordinary command
execution at all). Completion candidates always come from the real,
live `argparse` structure — every command, subcommand (including
nested ones like `admin users grant-role`), and flag `argcomplete`
finds by walking the parser — so there's no separate, hand-maintained
completion list that could quietly fall out of sync with the actual
commands. The `grant-role`/`revoke-role` `role` argument additionally
uses `choices=KNOWN_ROLES` (see `cli.py`), which gets both completion
*and* client-side validation for free from `argparse` itself —
`KNOWN_ROLES` mirrors `../api/migrations/003-rbac.sql`'s seed data but
isn't the technical source of truth (`api.roles`), so a role added
later only via SQL would work fine, just without completion for it
until this list is updated too.

The package ships `completions/homelab-cli` to
`/usr/share/bash-completion/completions/homelab-cli` (see
`debian/homelab-cli.install`) — the standard `bash-completion` project's
directory, which its own dynamic loader sources automatically the
first time a new shell tab-completes `homelab-cli`, keyed purely by
that installed file's name matching the command name exactly. **A real
packaging bug caught by actually installing and testing this, not just
running the unit tests**: debhelper's two-column `.install` file syntax
treats its second field as a *destination directory* to copy the
source's basename into, not a destination filename to rename to — an
initial `completions/homelab-cli.bash → .../completions/homelab-cli`
mapping silently created a *directory* named `homelab-cli` containing
`homelab-cli.bash` inside it, instead of a file literally named
`homelab-cli`. bash-completion's loader only recognizes a file at that
exact path, so completion would have silently never activated despite
every unit test passing — fixed by naming the source file itself
`completions/homelab-cli` (no extension, the standard convention for
shipped bash-completion scripts) so the directory-copy behavior lands
it correctly.

`tests/test_completion.py` drives `argcomplete`'s own `CompletionFinder`
directly against `build_parser()` (simulating `COMP_LINE`/`COMP_POINT`
the way a real shell would, without needing an actual bash process) to
assert on real completion output — subcommand completion at multiple
nesting depths, prefix completion, and the role `choices=` list — but
the packaging bug above was only actually caught by installing the
built `.deb` and testing the real, shipped file end-to-end (`source
/usr/share/bash-completion/completions/homelab-cli` in a real `bash -c`
subshell, then calling the real registered `_python_argcomplete`
function with `COMP_WORDS`/`COMP_CWORD` set, checking the real
`$COMPREPLY`) — worth remembering if this ever needs re-verifying,
since the unit tests alone couldn't have caught it.

## Man page

`man homelab-cli` after installing the package covers the full command
tree, not just the top-level overview `--help` gives you — every
subcommand down to e.g. `dns mail-aliases enable-send` gets its own
usage/options section. Same "never falls out of sync" reasoning as tab
completion above, applied to the same underlying problem: generated at
**build time** (`debian/rules`' `execute_after_dh_auto_build`) by
[`argparse-manpage`](https://pypi.org/project/argparse-manpage/)
walking the real, live `build_parser()` — not hand-authored, not
committed (`debian/homelab-cli.1` is gitignored, regenerated fresh
every build), so a new command can never ship without its man page
entry, the way a hand-maintained doc could silently drift.

`--description`/`--epilog` on the top-level `ArgumentParser` (see
`_DESCRIPTION`/`_EPILOG` in `cli.py`) render in **both** places —
`homelab-cli --help` and the man page's DESCRIPTION/EXAMPLES
sections — so there's exactly one place to keep that prose in sync,
not two. `RawDescriptionHelpFormatter` is what makes `--help` respect
the epilog's own line breaks (the EXAMPLES block); the description
text is hand-wrapped for the same reason, since that formatter turns
off argparse's *own* re-wrapping for both fields at once. One cosmetic
wrinkle worked around in `debian/rules`: argparse-manpage hardcodes
the epilog's section title to `COMMENTS`, not configurable via any of
its own flags (confirmed by reading its source) — a build-time `sed`
retitles it to `EXAMPLES` before the file ships, since that's what the
section actually contains.

## Testing

```bash
pip install -e '.[dev]' pytest   # or just: pip install requests pyyaml pytest
python3 -m pytest tests/
```

No live infrastructure needed — `test_client.py` mocks the HTTP layer
for every `Client` method, including `drive_*`/`mail_*` (both now go
through `homelab-api`'s gateway, so there's only ever the one client
class to test; see "Only `--api-base`" above), `test_config.py` uses
`tmp_path`/`monkeypatch` for the config/session files (including
verifying `session.yml` is actually written `0600`, not just intended to
be), and `test_completion.py` covers tab completion (see its own
section above for why installing the real `.deb` and testing the
shipped file for real also matters here, not just this suite).
