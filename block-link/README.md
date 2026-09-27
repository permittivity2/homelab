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
authenticated, since the person clicking has no JWT of their own) — the
same table `recipient_blocking`/`homelab-cli mail block` already write to.
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
renders a form with every candidate address **pre-checked** (matching the
"block by default" UX the feature was designed around); the database is
only touched on `POST`. Same shape RFC 8058 mandates for one-click
unsubscribe, and the exact same GET-renders/POST-mutates pattern already
proven in `homelab-invite`'s `/invite/:token` + `/invite/:token/accept`.

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
