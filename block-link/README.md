# homelab-block-link

Settings backend + public management page for the click-to-block-link
mechanism: lets a recipient block the address(es) an inbound message was
sent to, from a link the companion package
[homelab-postfix-block-link](../postfix-block-link/README.md) injects into
that mail — reachable from any mail client, not just Roundcube.

## Not a new blocking mechanism

This service never writes `domainadmin.recipient_access` directly.
`POST /l/:token` calls `homelab-domain-admin`'s own
`/internal/v1/domains/recipient-access/on-behalf` (system_agent-
authenticated; who may block what is decided here first, by
`Visibility.pm`, from the visitor's sign-in) — the same table
`recipient_blocking`/`homelab-cli mail block` already write to.
See `domain-admin/lib/Homelab/DomainAdmin/App/Controller/RecipientAccess.pm`'s
`on_behalf` handler.

## Settings model

Two-tier, resolved by `_effective_setting()`:
1. `block_link.account_settings.enabled` if set (self-service, own
   account only) — else
2. `block_link.domain_settings.enabled`/`.mode` for the account's own
   *home* domain (the domain part of the account's login email — not
   necessarily the domain a given message's envelope address belonged
   to, since accounts can receive mail via cross-domain aliases).

`mode` (header/body/both) is domain-wide only — no per-account
override. It's an operational/compliance choice the domain owner makes
once, consistently, not something that should vary by who happens to
receive a given message.

## Why GET never mutates `/l/:token`

Automated mail-security link-prescanners (Microsoft Safe Links, Proofpoint
URL Defense, Mimecast, etc.) fetch every link in an inbound email before a
human ever opens it, to scan for malware. If a bare `GET` performed the
block, every recipient's address would get auto-blocked within seconds of
the message arriving — completely defeating the feature, silently. `GET`
only ever renders (since 0.1.6, for a signed-out visitor, only a redirect
to sign in); the database is only touched on `POST`, and only by a
signed-in visitor. Same shape RFC 8058 mandates for one-click
unsubscribe, and the exact same GET-renders/POST-mutates pattern already
proven in `homelab-invite`'s `/invite/:token` + `/invite/:token/accept`.

## The link alone is no credential: sign-in required (0.1.6)

Until 0.1.6 a link covering **one** account kept a one-click block for
whoever held it ("the token in the email is the credential"), on the
reasoning that only the recipient ever opens their own mail. That stopped
being true: the footer line that carries the link is quoted into every
reply and forward, and since the mail pool rewrites replies to go out
from the alias the message came to (post-cutover #67), the original
sender routinely ends up holding a working link — and could block the
very alias they were writing to (#69, 2026-11-11). So:

- `GET /l/:token` with nobody signed in goes straight to `/login` (and
  back to the link afterwards) **before the link is looked up**: a
  stranger holding a forwarded link learns nothing here, not even whether
  the link is valid. Someone already signed in to webmail or myaccount
  passes through `homelab-sso` without seeing its form. A session whose
  token no longer introspects gets the page with a Sign in button instead
  of another redirect, so a sign-in that comes back unverifiable can never
  loop between the two sites.
- `POST /l/:token` (Add to Block List) takes the same guards as unblock,
  in the same order, before anything is looked up: the page's CSRF token
  (`X-CSRF-Token`, from the form's `data-csrf`), then a live sign-in, then
  the link, then that the visitor is one of its accounts.

## Who sees which addresses

A message that reaches several mailmasker accounts in one delivery (To,
Cc or Bcc) gets **one** link, and the same link is in every copy:
`homelab-postfix-block-link` collects every enabled recipient in its
`envrcpt` callback and writes one `pending_links` row at `eom`, and a
milter can't give each recipient a different header or body. Until
0.1.4 the page showed every address on the link to whoever opened it,
with every box checked, so each recipient saw the others' addresses
(even a Bcc'd one), and one person's Save blocked the other person's
address on the other person's account (#48).

The rule is in `lib/Homelab/BlockLink/Visibility.pm`, and the page (GET)
and Add to Block List (POST) both use it, so the page never offers
something the server would refuse:

| Visitor | What the link page shows | What it may block |
|---|---|---|
| signed in as one of the link's accounts (`owner`) | that account's addresses from the message, and its **whole block list** (four sorts, a regex filter, unblock) | that account's addresses |
| signed in as some other account (`guest`) | "This link is for another account"; no address | nothing |
| not signed in | nothing: sent to sign in (or, with no `sso:` block, a page that only points at Manage Account) | nothing |

An account's **main address** is never offered: blocking it would stop
all of that account's mail. `homelab-domain-admin`'s self-service
endpoint refuses that too; the on-behalf path this service uses never
checked it, so the check lives here.

**Signing in** goes through `homelab-sso`, like drive, search and
myaccount; this app keeps the resulting token in its own session cookie
(`homelab-block-link`) and reads the block list with it from the same
api call myaccount uses (`GET /api/v1/domains/recipient-access/mine`).
It needs an SSO client registration and an `sso:` + `session:` block in
the config, written by `install-orchestrators/block-link-sso-provision.sh`.
Without them nobody can sign in here, so the link page can only point at
Manage Account. The session secret must be the same on every pool node
(requests are not sticky).

## Unblocking from the list

Signed in, each row of the block list has an **×**. It asks first, in the
shared theme's modal ("Unblock this address?", Cancel / Unblock; the
browser's own confirm box if the theme's script didn't load), then
`POST /l/:token/unblock {address}`. That calls the same api endpoint as
myaccount's Unblock button, with the visitor's own token:
`DELETE /api/v1/domains/recipient-access/mine/:recipient`. domain-admin
scopes that delete to the caller's own rows in its WHERE clause.

The session cookie is the credential here, as it is for Add to Block List
since 0.1.6, so both take the same care:
- **A CSRF token.** The list (and the form) carry Mojolicious's
  `csrf_token` in `data-csrf`, and the request must send it back as
  `X-CSRF-Token`. It is checked first, before anything is looked up. The
  cookie is also `SameSite=Lax` (the Mojolicious default), and the JSON
  body forces a preflight cross-site.
- **The same rule as the page.** You must be signed in as one of the
  link's accounts (`owner` in `Visibility.pm`), and the address must be on
  that account's block list as just read. So an allow entry (`OK`) is never
  removed here. The list's own spelling is what gets deleted.
- **Already gone** (unblocked in myaccount meanwhile, say) answers 404 with
  `gone`. The page takes the row off and says so.

If the unblocked address is one of this message's own, its row in the add
section comes back, ticked. Every offered address has a row there; the
ones already blocked are hidden and left out of the form.

## Why long-lived tokens

Unlike `homelab-invite`'s one-time-use tokens, a `pending_links.token`
stays valid for a generous window (`link_ttl_days`, default 90) and is
never consumed. The whole point is ongoing light management — "block or
unblock each" — via the *same* link sitting in the original email,
possibly revisited weeks later.

## Deployment

Public vhost, same pattern as every other public-facing service in this
project:
```yaml
- domain: blockemail.test.mailmasker.org
  upstream: 127.0.0.1:2515
```
No new nftables rule needed (80/443 already open fleet-wide; only the
loopback upstream port is new).

**Install order matters**: this package must be installed (and its
`block_link` schema created) *before* `homelab-postfix-block-link` on any
postfix host — the milter's own bootstrap script needs
`block_link.pending_links` to already exist to grant itself `INSERT` on
it.
