# homelab-roundcube-invite

Add-on package for an already-installed [homelab-roundcube](../roundcube/README.md):
adds a "Send Invite" Settings tab, backed by [homelab-invite](../invite/README.md)
through homelab-api's own gateway. Holds no database credential of its
own — see `invite/README.md`'s architecture note for why the invite
mechanism is split this way (this plugin forwards the logged-in user's
own JWT, homelab-invite is the only process holding Postgres access).

This is the first package in this ecosystem that mutates a SIBLING
package's already-written config file, rather than only ever its own —
see "Registering the plugin" below for exactly how, and why it's safe.

## Deployment

Hard `Depends: homelab-roundcube` — this package does nothing standalone.
`postinst` also checks that Roundcube was actually *configured*
(`config.inc.php.bootstrapped` exists), not just installed: a hard dpkg
Depends only proves homelab-roundcube's own postinst ran, not that its
bootstrap succeeded. If that marker is missing, this package's own
postinst refuses gracefully (prints a message, exits 0) rather than
half-configuring on top of a Roundcube that was never finished.

Install on every host running homelab-roundcube — including each
instance of an HA trio (this package needs no per-instance role the way
roundcube itself does for its own database access, since it has none;
each instance's own `config.inc.php` gets edited independently and
identically).

## Registering the plugin

Roundcube's `$config['plugins']` array is a fixed PHP literal, written
**exactly once** by homelab-roundcube's own postinst (a
`.bootstrapped` marker prevents `dpkg-reconfigure` from ever rewriting
it — confirmed live, not assumed). This package's own postinst has to
mutate that already-written array to add `'invite_sender'`.

**Why a PHP script, not sed**: PHP array syntax (arbitrary existing
entries, quote style, whitespace) is exactly the kind of thing a regex
mangles silently on some but not all real `config.inc.php` shapes, and
`php` is a guaranteed-present tool on any host running php-fpm/Roundcube
anyway. `plugins/apply-plugin.php`:
1. Finds `$config['plugins'] = [...]`.
2. If `'invite_sender'` is already present, no-ops (`ALREADY_PRESENT`) —
   safe to re-run on every `dpkg-reconfigure`/upgrade.
3. Otherwise appends it and rewrites the file (`EDITED`).
4. Refuses (exit 1, file untouched) if the array isn't found in the
   expected single-statement shape at all, rather than guessing.

Verified against a real copy of the actual deployed `config.inc.php`
during development (not just a synthetic test fixture): correctly
appended to an existing `['recipient_blocking']` array, and a second run
correctly no-op'd.

`postinst`'s own safety net around this: backs `config.inc.php` up once
(`config.inc.php.pre-invite-sender.bak`, never overwritten by a later
run) before the edit, validates the result with `php -l`, and restores
the backup if that fails — Roundcube is never left serving a broken
config. `postrm`'s `remove` action reverses this by restoring the same
backup, so uninstalling this package can't leave Roundcube's plugins
array pointing at a now-missing plugin (which would otherwise
fatal-error every page load).

## Plugin implementation

`plugins/invite_sender/invite_sender.php` is directly modeled on
`../roundcube/plugins/recipient_blocking/recipient_blocking.php` — same
Settings-tab shape (`settings_actions` hook, `register_handler(
'plugin.body', ...)`), same JWT-forwarding (`$_SESSION['oauth_token']
['access_token']`), same `api_request()` Guzzle-availability workaround
and bounded-retry logic (GuzzleHttp\Client is only conditionally
autoloaded by Roundcube's own OAuth code, and this php-fpm SAPI has no
curl extension loaded — both confirmed real in that plugin's own header
comment, not re-derived here).

Deliberately simpler than `recipient_blocking` in one way: Settings-tab
only, no taskbar/message-toolbar integration, no cross-iframe state
bridging — sending an invite has no per-message context the way
blocking a recipient does, so there's no reason to take on that
plugin's iframe complexity.

Sends the actual invite email itself (`channel=roundcube_plugin` in the
`POST /api/v1/invites` call — homelab-invite mints the token/link but
does NOT send anything for this channel) via Roundcube's own
`rcube::deliver_message()` — the same lower-level method
`program/actions/mail/sendmdn.php` uses for its own self-contained
(non-compose-form) send. Exact signature confirmed against the real
installed `roundcube-core` source
(`program/lib/Roundcube/rcube.php`), not guessed:
`deliver_message(&$message, $from, $mailto, &$error, &$body_file=null, $options=null, $disconnect=false)`.
`Mail_mime` itself needs no Guzzle-style availability workaround —
confirmed by checking `rcmail_sendmail.php` for any explicit require of
it: there is none, so a registered application-wide autoloader must
already cover it (unlike `GuzzleHttp\Client`, which only `rcmail_oauth.php`
conditionally loads).

## Config

One debconf field: `homelab-roundcube-invite/api_base` (→
`$config['invite_sender_api_base']`), plus a cosmetic
`ttl_days_hint` shown in the invite email's own body text (the REAL
expiry is enforced entirely server-side by homelab-invite; a mismatch
here only ever shows the wrong number in an email, never changes actual
behavior).
