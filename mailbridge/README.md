# homelab-mailbridge

Internal-only IMAP/SMTP relay. Exists for one reason: so that
`homelab-api`'s `/api/v1/mail/*` gateway routes (see `../api/README.md`)
have something to forward to that actually speaks IMAP/SMTP — meaning
no client (`homelab-cli`, or any third-party script) ever needs to know
dovecot's or postfix's address. Only `homelab-api`'s address matters to
a client; this app's own address only matters to `homelab-api`.

Moved here from `homelab-cli`'s own client-side `mail.py`
(`imaplib`/`smtplib`), which is now just a thin HTTP client of
`homelab-api`'s gateway. The actual protocol logic — connect, XOAUTH2
authenticate, list/fetch/send — is unchanged in spirit, just ported to
Perl (`Mail::IMAPClient`, `Net::SMTP`, `Email::MIME`) and moved
server-side.

No database, no public address, no `homelab-webproxy` vhost — this is
as close to stateless as a service gets. It registers itself in the
service registry (`Homelab::Common::Registry`) with an internal
host/port only, the same as `homelab-drive`/`homelab-sso` do for their
own internal addresses, but deliberately without a `public_base_url` —
nothing external is ever meant to reach this directly.

## Auth

Every route requires `Authorization: Bearer <jwt>`, re-verified here
via `Homelab::Common::AuthClient::introspect` against `homelab-api` —
this app never trusts that the gateway already validated the token,
matching the "verify at every hop" convention already used throughout
this codebase (see `../drive/README.md`'s own `_current_email`
reasoning). The *same* JWT then becomes the XOAUTH2 bearer token
presented to dovecot/postfix — the exact mechanism
`homelab-roundcube`'s SSO login already uses against `homelab-dovecot`
(see `../dovecot/README.md`, `../sso/README.md`); dovecot/postfix
independently validate it too when the real `AUTHENTICATE`/`AUTH`
exchange happens.

**Known gap, carried over unchanged from the old client-side
implementation:** dovecot/postfix still serve their default self-signed
certificate on the real IMAP/SMTP ports (unlike the HTTPS domains,
which have real Let's Encrypt certs via `homelab-webproxy`) — TLS
certificate verification is therefore deliberately relaxed here too
(the connection is still encrypted, just not verified against a CA)
until that's given real certs as a tracked follow-up.

## Routes

- `GET /api/v1/mail/messages?mailbox=INBOX&limit=20` — recent
  message headers (uid, from, subject, date). `uid` is a real, stable
  IMAP UID (`Mail::IMAPClient`'s `Uid(1)` mode) — a small correctness
  improvement over the old client-side version, which searched by
  session-scoped sequence number instead, meaning a message's "id"
  could theoretically point at the wrong message if the mailbox
  changed between two separate requests.
- `GET /api/v1/mail/messages/:uid?mailbox=INBOX` — one message in
  full (from/subject/date/body). Body is the first `text/plain` leaf
  part found (`Email::MIME`'s `walk_parts`), matching the old
  implementation's own multipart-walking logic. 404 if the uid doesn't
  exist in that mailbox.
- `POST /api/v1/mail/send` — JSON body `{to, subject, body}`.
  Builds and sends a plain-text RFC 5322 message by hand (`From` is
  always the authenticated user's own email). `Date` and `Message-ID`
  are set explicitly — the old client-side version found the hard way
  (by reading a sent message back, not by inspection) that
  `email.message.EmailMessage` doesn't add a `Date` header on its own.

All three respond `401` for a missing/invalid `Authorization` header,
and `502` (not a raw 500) if the IMAP/SMTP round trip itself fails —
that distinction matters to `homelab-api`'s gateway, which relays this
app's status code straight through to the original client.

## Testing

```bash
HOMELAB_MAILBRIDGE_CONFIG=/path/to/config.yml \
HOMELAB_MAILBRIDGE_TEST_EMAIL=you@test.mailmasker.org \
HOMELAB_MAILBRIDGE_TEST_PASSWORD=... \
  prove -I lib t/
```

Needs a real config and a real, **already-provisioned** mailbox
account — unlike `drive`/`sso`'s throwaway-account tests, a brand-new
`homelab-api` account has no real IMAP mailbox behind it yet, so this
needs an account that already does (same convention `homelab-cli`'s own
mail tests use). `t/basic.t` sends a real message to itself via SMTP,
polls the list endpoint until it shows up (IMAP delivery isn't
instant), then reads it back and confirms the subject/body round-trip
exactly — a genuine protocol-level integration test, not a mock.
