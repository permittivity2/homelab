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

Every homelab web app gets a top-right **profile button** (Google-style
avatar + dropdown) whose "Account Management" link points here.

## Deploy

Built via `../build-package.sh accountmanage <version> -y`. Runs on its own
CT (data-plane address in `registry.host`), fronted by `homelab-webproxy`
(`myaccount.<domain>` -> this host:2503) with a DNS A record to the public
edge. Needs an SSO client registered in `homelab-sso` (`client_id:
accountmanage`, redirect_uri `https://myaccount.<domain>/oauth/callback`)
and `homelab-agent` enrolled on the host for registry auth. Config lives at
`/etc/homelab/accountmanage/config.yml` (seeded from the example on first
install; edit in place — no debconf, no DB bootstrap).
