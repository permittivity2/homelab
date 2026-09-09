# homelab-roundcube

Roundcube webmail (Debian's own `roundcube-core`/`roundcube-pgsql`
packages, not vendored source), wired to the same shared identity every
other `homelab-*` feature uses — but differently from
`homelab-dovecot`/`homelab-postfix`:

- **No direct `api.users` grant at all.** Roundcube authenticates purely
  by attempting a real IMAP `LOGIN` against `homelab-dovecot` with
  whatever the user typed on its login form — exactly like any other
  IMAP client would. It proves the unified cross-feature identity design
  (see the root `CLAUDE.md`) from the browser's side: the same
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

## Testing

Package-local: none — like `homelab-dns`, `homelab-dovecot`, and
`homelab-postfix`, this package is almost entirely templating (a PHP
config file, an nginx vhost) plus one small bespoke script; there isn't
meaningful logic to unit test beyond what
`script/homelab-roundcube-apply-schema` already does defensively
(idempotency check, search_path redirect). Real, live coverage is
`tests/e2e/test_roundcube_login.py`.
