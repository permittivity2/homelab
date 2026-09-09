# homelab-roundcube

Roundcube webmail (Debian's own `roundcube-core`/`roundcube-pgsql`
packages, not vendored source), wired to the same shared identity every
other `homelab-*` feature uses — but differently from
`homelab-dovecot`/`homelab-postfix`:

- **No direct `api.users` grant at all.** Login is delegated to
  `homelab-sso` (Roundcube's own native OAuth2 support — no plugin
  needed, see the SSO section below), which authenticates IMAP via a
  real XOAUTH2 exchange rather than a password; a plain password form
  (real IMAP `LOGIN` against `homelab-dovecot` with whatever the user
  typed, exactly like any other IMAP client) remains as a visible
  fallback. Either way, it proves the unified cross-feature identity
  design (see the root `CLAUDE.md`) from the browser's side: the same
  Argon2id-hashed `api.users` row that already backs HTTP login
  (`homelab-drive`), IMAP (`homelab-dovecot`), and SMTP submission
  (`homelab-postfix`) also logs into webmail, with zero additional
  credential plumbing on this package's part.
- **Roundcube's own state — contacts, preferences, message cache, never
  mail itself** (mail stays entirely in Dovecot's Maildir storage) —
  lives in its own `roundcube` Postgres schema via the **standard**
  split runtime/migrate role pair, minted by the generic
  `homelab-bootstrap-app-role` (the same tool `homelab-api` and
  `homelab-drive` use). This is different from `homelab-dovecot`'s and
  `homelab-postfix`'s bespoke, single-role bootstrap scripts: those two
  own no schema/tables of their own, so a migrate role would have
  nothing to do. Roundcube genuinely owns tables, so it fits the
  standard two-role pattern cleanly.
- **A one-time `search_path` redirect works around Roundcube's own
  vendor code.** Roundcube's PHP issues entirely unqualified SQL
  (`SELECT * FROM users`, never `roundcube.users`) — not something this
  package can patch. `script/homelab-roundcube-apply-schema` points both
  roles' default `search_path` at the `roundcube` schema before applying
  Roundcube's own vendor-shipped schema SQL (referenced live from
  `/usr/share/dbconfig-common/data/roundcube/install/pgsql`, never
  vendored/duplicated here — same precedent as `homelab-dns` applying
  PowerDNS's own upstream schema). See that script's header comment for
  the full story, including why this was necessary: verified empirically
  that without it, Roundcube's vendor schema lands in `public` instead,
  breaking this project's "each feature owns its own narrow schema"
  isolation principle.

## Serving PHP without changing homelab-webproxy

`homelab-webproxy`'s existing `sites.yml` reverse-proxy model
(`upstream: 127.0.0.1:<port>`) is designed around backends that already
speak HTTP directly, like `homelab-drive`'s own `hypnotoad`. Roundcube is
PHP and needs PHP-FPM via FastCGI, not plain HTTP — rather than teach
`homelab-webproxy` a second, FastCGI-flavored upstream type, this
package's own `postinst` writes a **separate, internal-only** nginx
vhost (`config/nginx-internal.conf.template`) listening on loopback
(default port 8080, debconf-configurable via
`homelab-roundcube/internal_port`) that bridges PHP-FPM to plain HTTP.
`homelab-webproxy` just treats it like any other upstream — point
`sites.yml`'s `mail.test.mailmasker.org` entry at this same port and
nothing else needs to change.

## Gotcha: Ubuntu's roundcube-core 1.6.11 vs PHP 8.5

Real upstream incompatibility, not something this project got wrong:
Roundcube 1.6.11 (as shipped by this Ubuntu release's `roundcube-core`)
unconditionally declares its own `array_first($array)` helper in
`program/lib/Roundcube/bootstrap.php`, with no `function_exists()`
guard — but PHP 8.5 (as shipped by the very same Ubuntu release) added
`array_first()` as a genuine core builtin. Redeclaring an already-defined
function is a hard, uncatchable PHP fatal error, so **every single page
load 500s** ("Cannot redeclare function array_first()") until this is
fixed — confirmed no other function Roundcube declares in that file
collides the same way.

`script/homelab-roundcube-patch-php85-compat` wraps only that one
function in a `function_exists()` guard, in place, on the file
`roundcube-core` actually ships — never a vendored/forked copy of
Roundcube. `debian/postinst` runs it unconditionally on every install/
reconfigure (not gated behind the bootstrap-already-done marker), since
a **future `roundcube-core` package upgrade could reset the file to its
unpatched state** — if webmail suddenly 500s after a routine `apt
upgrade`, check `journalctl`/nginx's error log for "Cannot redeclare
function array_first" first, then re-run
`dpkg-reconfigure homelab-roundcube` (or just the script directly) to
reapply the patch.

One narrower, separate wrinkle found while diagnosing this: `apt-get
install --reinstall roundcube-core` (or any real *upgrade* of an
already-configured `roundcube-core`) invokes the package's own
`bin/update.sh` as part of its **own** postinst, which hits this exact
same fatal — meaning a `roundcube-core` version bump could fail to
configure entirely, independent of `homelab-roundcube`. A genuinely
**fresh** `apt install roundcube-core` does not hit this (confirmed
empirically — `update.sh` only runs on the upgrade path), so this
doesn't block a normal first install of this package. If a future
`roundcube-core` upgrade ever does fail this way, the recovery is the
same either way: apply the patch script directly to the now-unpacked
file, then `dpkg --configure -a`.

## Single sign-on via homelab-sso

Roundcube 1.6.11 already has full native OAuth2 authorization-code-flow
support built in (`program/include/rcmail_oauth.php`), including
automatic XOAUTH2 IMAP/SMTP login — no custom plugin needed, just
`oauth_*` config keys (see `config/config.inc.php.template`) pointing at
`homelab-sso`. Two small, upstream-gap patches are required to make it
actually work here, applied in-place to the file `roundcube-core` ships
(never a vendored/forked copy of Roundcube) by
`script/homelab-roundcube-patch-oauth-sso`, run unconditionally on every
install/reconfigure (same idempotent, re-apply-after-upgrade pattern as
the PHP 8.5 compat patch above — see that script's own header for the
full story on both):

1. **`get_redirect_uri()` builds a PATH_INFO-style URL**
   (`index.php/login/oauth`) that this package's own internal nginx vhost
   silently mangles (`try_files ... /index.php$is_args$args` drops the
   PATH_INFO suffix entirely, with no error logged anywhere — the OAuth
   callback just never arrives). Patched to build a plain query-string
   callback instead (`index.php?_task=login&_action=oauth`), which
   Roundcube's router already handles natively, on any web server.
2. **`logout_after()` is a stock no-op.** Patched to redirect through
   homelab-sso's own `/logout` (new `oauth_logout_uri` config key, not a
   stock Roundcube setting) instead — otherwise a Roundcube-initiated
   logout would only clear Roundcube's own local session, leaving the
   *shared* homelab-sso session (and every other relying party riding on
   it) alive. This is what makes "logout once, logout everywhere" work
   in **both** directions: logging out via another app already killed
   Roundcube's session for free (its next introspect/keep-alive check
   sees the centrally-revoked JWT), but the reverse direction needed this
   patch.

The IMAP side of this (Dovecot accepting a JWT as an XOAUTH2 bearer
token, via a new `oauth2` passdb that introspects it against
`homelab-api`) lives in `homelab-dovecot`, not here — see that package's
README.

`oauth_login_redirect` is `true` (flipped from a deliberately cautious
`false` first-rollout default, after a real user's bug report: a live
Drive session wasn't carrying over on a bare visit to Mail — only the
explicit "Login with Homelab SSO" link triggered it, which isn't what
"login once, login everywhere" is supposed to feel like). With it on,
Roundcube's own `unauthenticated` hook auto-redirects to homelab-sso on
**every** request where nobody's logged in, unconditionally, for every
task/action — confirmed by reading `index.php`'s own dispatch code, not
just empirically.

**Real, deliberately accepted tradeoff**: this means Roundcube's own
native password-login form is no longer reachable by an anonymous
visitor through any URL at all — there's no query-param combination
that skips the redirect (a plausible-looking `?_err=session` escape
hatch does NOT work: `unauthenticated`'s own `error` field only becomes
non-empty via a real `$RCMAIL->session_error()` check, not a spoofable
request param). Plain-password auth itself is untouched and still fully
functional at the protocol level — `homelab-cli mail`, or any real IMAP/
SMTP client, still authenticates with a password exactly as before —
what's gone specifically is a way to reach Roundcube's *own web UI* login
form without going through homelab-sso first. If homelab-sso is ever
down, Roundcube's web UI is unreachable until it's back up; email itself
is not (IMAP/SMTP keep working directly). See
`tests/e2e/test_roundcube_login.py`'s module docstring for the full
investigation.

`session_lifetime` (30 minutes) is set to match `homelab-api`'s
`jwt.expiry_seconds` (`config/api.example.yml`) — the two are **not**
linked automatically; if the JWT lifetime ever changes, this must be
updated by hand too, or Roundcube's own local session dies well before
the SSO session does (symptom: a raw "session invalid or expired" page
instead of a silent SSO bounce, since the OAuth plugin's auto-redirect
only fires when no local session error is already present).

## Testing

Package-local: none — like `homelab-dns`, `homelab-dovecot`, and
`homelab-postfix`, this package is almost entirely templating (a PHP
config file, an nginx vhost) plus one small bespoke script; there isn't
meaningful logic to unit test beyond what
`script/homelab-roundcube-apply-schema` already does defensively
(idempotency check, search_path redirect). Real, live coverage is
`tests/e2e/test_roundcube_login.py`.
