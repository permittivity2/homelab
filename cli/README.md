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
homelab-cli drive list
homelab-cli drive upload <path>
homelab-cli drive download <file-id> [--output <path>]
homelab-cli drive delete <file-id>
```

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
once came back with a completely empty one), and `test_config.py` uses
`tmp_path`/`monkeypatch` for the config/session files (including
verifying `session.yml` is actually written `0600`, not just intended to
be).
