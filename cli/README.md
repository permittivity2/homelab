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
homelab-cli configure --api-base https://api.test.mailmasker.org \
    --drive-base https://drive.test.mailmasker.org \
    --imap-host mail.test.mailmasker.org --imap-port 993 \
    --smtp-host mail.test.mailmasker.org --smtp-port 587
homelab-cli register you@test.mailmasker.org
homelab-cli login you@test.mailmasker.org
homelab-cli whoami
homelab-cli registry lookup homelab-drive
homelab-cli logout
```

`configure` with no flags at all just prints the current configuration.

Session (`token`/`refresh_token`) is stored `0600` in
`~/.config/homelab-cli/session.yml`, separate from the non-secret
config (API/drive base URLs, IMAP/SMTP host/port) in `config.yml` in the
same directory — same "local CLI config, same trust model as `gh`/`aws`/
`kubectl`" reasoning as `../api/README.md`'s "Two different clients, two
different trust models" section.

## Email (`mail`)

```bash
homelab-cli mail list [--mailbox INBOX] [--limit 20]
homelab-cli mail read <uid> [--mailbox INBOX]
homelab-cli mail send --to you@example.com --subject "Hi" --body "..."
```

No separate "mail login" step, and no new server-side API — this talks
directly to homelab-dovecot (IMAP) and homelab-postfix (SMTP submission)
using the already-saved homelab-api JWT as an XOAUTH2 bearer token, the
exact same mechanism homelab-roundcube's SSO login uses for real IMAP
auth (see `../dovecot/README.md` and `../sso/README.md`). See
`homelab_cli/mail.py`'s own module docstring for a known, tracked gap:
homelab-dovecot/homelab-postfix currently still serve their default
self-signed TLS certificate on the real IMAP/SMTP ports (unlike the
HTTPS domains), so certificate verification is deliberately relaxed for
now — the connection is still encrypted, just not verified against a
CA.

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
`../drive/README.md`'s "JSON API" section) — a CLI never goes through
the browser-facing SSO redirect flow at all; it already holds its own
JWT directly.

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

## Testing

```bash
pip install -e '.[dev]' pytest   # or just: pip install requests pyyaml pytest
python3 -m pytest tests/
```

No live infrastructure needed — `test_client.py` mocks the HTTP layer
(both homelab-api's `Client` and homelab-drive's `DriveClient`),
`test_mail.py` mocks `imaplib`/`smtplib` (including a regression check
for a real bug found while testing this live: `email.message.EmailMessage`
does not add a `Date` header on its own — a sent-then-read-back message
once came back with a completely empty one), `test_config.py` uses
`tmp_path`/`monkeypatch` for the config/session files (including
verifying `session.yml` is actually written `0600`, not just intended to
be), and `test_completion.py` covers tab completion (see its own
section above for why installing the real `.deb` and testing the
shipped file for real also matters here, not just this suite).
