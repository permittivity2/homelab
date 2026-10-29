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
GET /devices/qr.svg               session MINTS a code; a token ECHOES one
GET /devices/setup-link           session only -> JSON { url }
```

Adding a mailbox to a phone is inherently cross-device: the panel is open
on a laptop and the account has to end up on a handset that has never
signed in here and never will. So the QR code carries a signed, minutes-
long token (`Homelab::Common::SetupToken`) and the page it opens accepts
that token in place of a session.

`/devices/qr.svg` behaves differently depending on how it is reached, and
the difference is the security property:

- **with a session** it issues a *fresh* minutes-long token and draws
  that. A signed-in user can always get a new code; that is the panel's
  whole job.
- **with only `?t=`** it draws a code for *the token that was
  presented* — re-encoding a capability the caller already holds, never
  granting a new one. So a lapsed link cannot buy itself a fresh lease,
  which it could if this minted unconditionally.

The echo case exists for the resent welcome email: that link gets opened
on a laptop as often as on a phone, and a setup page with no way across to
the handset describes a one-tap install for a device the reader is not
holding. `t/devices.t` asserts this on the bytes, comparing against
`qr_svg` of the presented token's own URL.

`/devices/setup-link` returns a fresh URL as JSON for the panel's "Copy
link" button — a separate endpoint rather than a value in the dashboard
HTML, because it mints a capability (minting one per dashboard render, for
every user, whether or not they look at the section, is waste) and because
a token embedded in the page would then live in the browser's history and
back-forward cache of the dashboard itself, far longer than its own few
minutes.

**The signing key defaults to `session.secret`**, which is not laziness:
myaccount is a three-node pool (`10.50.2.171/172/173`) and that is the one
key already guaranteed identical across it — a cookie signed by one node
has to validate on the next. A key generated per host would verify on
about one request in three. Sharing it is safe because every signature
commits to a `purpose` string, and cookie signing is a different algorithm
over a different message. `device_setup.token_secret` overrides it, set
identically on every node.

What the token is worth: it names a mailbox. The profile behind it holds
an email address and two public hostnames and **no password** (see
`Homelab::Common::AppleProfile` for why that is non-negotiable rather than
an omission). Secret: `device_setup.token_secret`, written by the
postinst. Absent, the panel still shows the download button and the manual
settings — only the cross-device QR code goes away.

**The profile is signed by the certificate issuer, not here** — see
`Homelab::Common::ProfileSigner`. Configured under `profile_signing:`;
blank, unreachable or failing means the profile is served **unsigned**,
which installs exactly as well and only costs a red "Unverified" on the
iOS install screen.

Settings come from `Homelab::Common::MailSetup`, shared with
homelab-invite's own setup page, so the two cannot drift.

## Resending the welcome email (site_admin)

```
POST /admin/welcome-email/resend   { user_email, also_to? }
```

Administration → Users → **Resend the welcome email**. The reason it
exists is mundane and constant: the originals are sent once, at signup, to
addresses that bounce, to spam folders, and to people who delete them —
and the device-setup link inside them is how someone adds their *next*
phone months later. Without this the only remedy was reading IMAP
settings down the phone.

Two messages, and they are not interchangeable:

- the **welcome** message goes into the mailbox itself, always. Nothing
  has to be known or typed: the address *is* the account.
- the **"your account is ready"** message goes to a contact address, which
  is optional and **typed by the admin** rather than looked up.
  Deliberately: `homelab-api` exposes a user's recovery address only to
  that user, and the situation this action is for is almost always "they
  say nothing arrived, here is the address they are giving me now" —
  a better input than whatever is on file.

The account must exist, checked through `homelab-api` with the admin's
*own* token, so authorization for the lookup is the same authorization as
for the action and a typo cannot quietly mail a catch-all. The setup link
is minted for **days** (`device_setup.link_ttl_days`, default 30), not the
QR code's minutes — it has to survive the recipient getting round to
reading their mail. Both sends are evalled independently and reported
**per destination**, because a partial send is the interesting case: "it
reached the mailbox but their Gmail bounced" is a different conversation
from "nothing sent".

Needs a `mailer:` block (the same service mailbox homelab-invite sends as
— the resent message is the same message, so it should come from the same
place). Without one, this single action reports itself unavailable; this
app sends no other mail.

## Deploy

Built via `../build-package.sh accountmanage <version> -y`. Runs on its own
CT (data-plane address in `registry.host`), fronted by `homelab-webproxy`
(`myaccount.<domain>` -> this host:2503) with a DNS A record to the public
edge. Needs an SSO client registered in `homelab-sso` (`client_id:
accountmanage`, redirect_uri `https://myaccount.<domain>/oauth/callback`)
and `homelab-agent` enrolled on the host for registry auth. Config lives at
`/etc/homelab/accountmanage/config.yml` (seeded from the example on first
install; edit in place — no debconf, no DB bootstrap).
