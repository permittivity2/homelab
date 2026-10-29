# homelab-accountmanage

Account self-service + administration web UI for the homelab-* fleet,
served at `myaccount.<domain>` (e.g. myaccount.test.mailmasker.org).

## What it is

A **thin BFF** Mojolicious app, same shape as `homelab-drive`: the browser
talks only to this app; it delegates login to `homelab-sso` (OAuth2
authorization-code, `Homelab::Common::SSOClient`), holds the resulting
token in its own signed session cookie, and re-verifies it against
`homelab-api`'s `/introspect` on every request. It **owns no database** —
every panel is rendered from aggregated calls to existing services made
with the logged-in user's own token, so what a user can see/do is exactly
what their token is allowed to do. The same app is therefore self-service
for a regular user and administration for a `site_admin`.

## Panels (iteration 1)

- **Profile** — email, account-created date, recovery email, status, roles
  (from `GET /api/v1/account/summary`).
- **Storage usage** — drive usage (`GET /api/v1/drive/usage`); mail usage
  is pending a dovecot-side endpoint. No quota limits exist yet fleet-wide.
- **Security** — password reset by email (links to homelab-sso `/forgot`);
  an authenticated in-place change is a later iteration.
- **Active sessions** — list + revoke one + "sign out everywhere else"
  (`GET/DELETE /api/v1/auth/sessions`).
- **Administration** (site_admin) — placeholder; user suspend/re-enable,
  storage limits, domain mail routing and DNS land in a later iteration.

- **Mail setup** — every signed-in user. An Apple `.mobileconfig` download,
  a QR code for handing the setup to a phone, and the manual IMAP/SMTP
  table for everything that is not an Apple device. See below.

Every homelab web app gets a top-right **profile button** (Google-style
avatar + dropdown) whose "Account Management" link points here.

## Mail setup, and the one place this app is not session-authenticated

```
GET /devices/apple.mobileconfig   session OR signed token
GET /devices/setup?t=<token>      standalone page, token only
GET /devices/qr.svg               session ONLY
```

Adding a mailbox to a phone is inherently cross-device: the panel is open
on a laptop and the account has to end up on a handset that has never
signed in here and never will. So the QR code carries a signed, minutes-
long token (`Homelab::Common::SetupToken`) and the page it opens accepts
that token in place of a session.

`/devices/qr.svg` is deliberately **session-only**: it MINTS the
capability, so letting a token reach it would let a lapsed one be traded
for a fresh one indefinitely.

What the token is worth: it names a mailbox. The profile behind it holds
an email address and two public hostnames and **no password** (see
`Homelab::Common::AppleProfile` for why that is non-negotiable rather than
an omission). Secret: `device_setup.token_secret`, written by the
postinst. Absent, the panel still shows the download button and the manual
settings — only the cross-device QR code goes away.

Settings come from `Homelab::Common::MailSetup`, shared with
homelab-invite's own setup page, so the two cannot drift.

## Deploy

Built via `../build-package.sh accountmanage <version> -y`. Runs on its own
CT (data-plane address in `registry.host`), fronted by `homelab-webproxy`
(`myaccount.<domain>` -> this host:2503) with a DNS A record to the public
edge. Needs an SSO client registered in `homelab-sso` (`client_id:
accountmanage`, redirect_uri `https://myaccount.<domain>/oauth/callback`)
and `homelab-agent` enrolled on the host for registry auth. Config lives at
`/etc/homelab/accountmanage/config.yml` (seeded from the example on first
install; edit in place — no debconf, no DB bootstrap).
