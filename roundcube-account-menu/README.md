# homelab-roundcube-account-menu

A "Gmail-style" account menu add-on for an already-installed
`homelab-roundcube`. Ships one pure PHP/JS/CSS Roundcube plugin
(`homelab_account_menu`) as its own package — it is nothing without
Roundcube already installed and configured, so it depends hard on
`homelab-roundcube` and its postinst refuses gracefully (not failing the
apt transaction) if Roundcube's own `config.inc.php.bootstrapped` marker
isn't present yet.

## What it adds

A circular avatar button (the signed-in address's initial) in Roundcube's
left task rail — relocated by the plugin's own JS down next to the
existing **Logout**, which is elastic's own "account area" at the bottom
of the rail. Clicking it opens a native dropdown with:

- **Signed in as** `<the mailbox address>` (read from Roundcube's own
  session — `$_SESSION['username']`, the IMAP login).
- **Manage your account** → `https://myaccount.<domain>/` (the
  `homelab-accountmanage` self-service app). Opens in a new tab and
  auto-logs-in through the shared SSO session (accountmanage is a
  registered SSO client), so there's no second password prompt.
- **Password & security** → `…/#security`, **Signed-in devices** →
  `…/#sessions` (the account app's own in-page deep links).
- **Sign out** → reuses Roundcube's own `logout` command, which already
  chains through `homelab-sso`'s single-logout (see `homelab-roundcube`'s
  `rcmail_oauth.php` patch) — so signing out of webmail signs out of the
  SSO session, not just the local Roundcube one.

**The brand logo above the rail is a second trigger for the same menu.**
One menu, two openers — duplicating the markup would duplicate its ids.
The logo also becomes the Silver Linings logo, served from the shared
asset host so a rebrand changes one file and every app (webmail
included) follows with no package rebuild.

It holds **no credential** and **no database role** of its own.

## How it attaches (elastic specifics)

Stock elastic has no top-right corner; its only app-wide chrome is the
left task rail (`skins/elastic/templates/includes/menu.html`). The plugin
attaches entirely through the supported plugin API — **no core skin or
template edits**:

- `add_button([... 'data-popup' => 'account-menu' ...], 'taskbar')` puts
  the trigger in elastic's `taskbar` container. The `data-popup`
  attribute survives `button()`'s attribute allow-list because
  `html::attrib_string` always passes `data-*`/`aria-*` through.
- `$rcmail->output->add_footer(...)` emits the `<div id="account-menu"
  class="popupmenu">…` markup (top-level window only — gated off the
  framed message-preview request so the id isn't duplicated).
- elastic's own `dropdowns_init()` → `popup_init()` wires the Bootstrap
  popover at DOM ready, by selecting `[data-popup]` wherever the node
  sits — so the JS relocation of the trigger is safe and the popover is
  never re-initialised (which would double-bind it).

- The **logo** lives in elastic's skin *template*, so `add_button()`
  cannot reach it from PHP. The plugin JS wraps it and calls
  `UI.popup_init()` — elastic's own public API (`ui.js` exports it so
  framed/mobile callers can re-init a popup) — which means the logo gets
  the identical popover, outside-click close, Esc handling and aria
  wiring as every other elastic dropdown, with no handler of our own.
  The wrapper is a `<button>`, **never an `<a>`**: elastic's
  `layout.less` hides anchors inside `.popover-header` on anything wider
  than a phone (`a { display: none !important; }`), so an anchor wrapper
  would make the logo vanish on every desktop.
- The logo itself is set via `$config['skin_logo']`, a supported core
  option (`rcmail_output_html::get_template_logo`) — again not a skin
  edit, so a Roundcube upgrade cannot undo it.

The avatar is a CSS circle and the dropdown icons are inline SVG
data-URIs, so nothing depends on elastic's icon webfont.

## Config

Two debconf values, written to `config.inc.php`:

- `homelab-roundcube-account-menu/myaccount_url` →
  `$config['account_menu_url']` (default
  `https://myaccount.mailmasker.org`). The public, browser-reachable
  vhost of the account app. Set it to the test host
  (`https://myaccount.test.mailmasker.org`) in the test environment.
- `homelab-roundcube-account-menu/logo_url` → `$config['skin_logo']`
  (default `https://static.mailmasker.org/theme/v1/logo.svg`, the same
  asset `homelab-webtheme` serves to drive and myaccount). Set it empty
  to leave Roundcube's own logo alone.

## Install / upgrade safety

Because Roundcube writes `config.inc.php` exactly once (a `.bootstrapped`
marker, never rewritten by `dpkg-reconfigure`), the postinst makes an
idempotent, structurally-anchored edit to the already-written
`$config['plugins']` array to register the plugin — the same technique
and safety net (`apply-plugin.php` + back up first + validate with
`php -l` + restore on failure) proven by `homelab-roundcube-invite`. It
symlinks the plugin into `/var/lib/roundcube/plugins/` (Roundcube's
loader only resolves there) and restarts php-fpm. Install it on **all**
Roundcube pool nodes in lockstep to keep the pool consistent.
