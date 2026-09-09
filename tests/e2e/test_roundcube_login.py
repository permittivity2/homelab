"""Phase 6 (mail stack) regression test: a real browser-equivalent visit
to homelab-roundcube over real HTTPS. Unlike every other test in this
suite, this one needs no SSH tunnel for the HTTP calls themselves:
homelab-webproxy's real Let's Encrypt certificate for
mail.test.mailmasker.org means this hits the genuine public
internet-facing path directly, the same way a real user's browser would
(see webproxy/README.md for how that got confirmed working).

Also the regression test for a real upstream incompatibility: Ubuntu's
roundcube-core 1.6.11 unconditionally redeclares array_first(), which
PHP 8.5 now ships as a genuine builtin — a hard PHP fatal on every page
load. See roundcube/script/homelab-roundcube-patch-php85-compat and
roundcube/README.md for the full story. If that patch ever regresses
(e.g. a roundcube-core package upgrade resets the file), the redirect
test below would 500 instead of cleanly 302.

Historical note, why there's no "plain password login via the web UI"
test here any more: earlier versions of this file logged in with a real
account by scraping a CSRF token off Roundcube's own bare `/` login
page and POSTing credentials directly, bypassing SSO entirely. Once
oauth_login_redirect was flipped to true (see the test below — a real
user's bug report: a live Drive session wasn't carrying over to a bare
Mail visit), Roundcube's own `unauthenticated` hook fires unconditionally
whenever nobody's logged in, for EVERY task/action, before any
Roundcube-side page can render — there is no URL that reaches the native
login form as an anonymous visitor any more, so that path can no longer
be exercised over HTTP at all (confirmed by reading index.php's own
dispatch code, not just empirically). Plain-password auth itself is
still fully covered at the protocol level by test_dovecot_login.py's
direct IMAP tests (Roundcube's SQL passdb is completely untouched by
any of this) — what's gone is coverage of Roundcube's OWN web-login code
path specifically, which is a real, deliberately-accepted reduction in
what this file can verify, not an oversight.
"""

import subprocess
import time
import urllib.error
import urllib.request

from test_sso_flow import DRIVE_LOGIN_URL, SSO_URL, _new_opener, _submit_credentials

BASE_URL = "https://mail.test.mailmasker.org"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Installed on an opener that should inspect a redirect response
    itself rather than transparently follow it."""

    def redirect_request(self, *args, **kwargs):
        return None


def test_bare_visit_auto_redirects_to_sso():
    """The actual regression test for the real bug: a bare visit to
    mail.test.mailmasker.org must immediately redirect to homelab-sso,
    not show Roundcube's own login page and wait for a manual click.
    Before oauth_login_redirect was flipped to true, this is exactly
    where "login once, login everywhere" silently stopped being true in
    a real browser — a live Drive session existed, but visiting Mail
    fresh still showed a local login page instead of checking it.

    Also still catches the array_first PHP 8.5 regression this file
    originally existed for (see the module docstring) — a PHP fatal
    here would 500, not cleanly 302."""
    opener = urllib.request.build_opener(_NoRedirect())
    # A redirect_request() that returns None (i.e. "don't follow") makes
    # urllib raise the 302 as an HTTPError rather than just returning it
    # as a normal response — the HTTPError object itself is what carries
    # the real status/headers here, not a separate response object.
    try:
        resp = opener.open(f"{BASE_URL}/", timeout=15)
        status, headers = resp.status, resp.headers
    except urllib.error.HTTPError as e:
        status, headers = e.code, e.headers
    assert status == 302, f"expected an immediate redirect to homelab-sso, got {status}"
    location = headers["Location"]
    assert location.startswith(f"{SSO_URL}/oauth/authorize"), f"redirected somewhere unexpected: {location}"
    assert "client_id=roundcube" in location


def test_live_drive_session_reaches_inbox_on_a_bare_mail_visit(ssh_host):
    """The property a real user actually expects from "login once,
    login everywhere": after logging into Drive, a completely bare,
    unprompted visit to Mail — not clicking anything Roundcube-specific,
    just typing the URL — lands straight in the inbox with zero clicks.
    test_sso_flow.py's own login-once test proves the underlying
    mechanism using Roundcube's explicit SSO entry point; this is the
    narrower, more literal regression test for oauth_login_redirect
    specifically — without it, even a live IdP session wasn't enough on
    a bare visit (see test_bare_visit_auto_redirects_to_sso's own
    history for why)."""
    email = f"e2e-roundcube-bare-{int(time.time())}@test.mailmasker.org"
    password = "E2eRoundcubeBareTest1Aa"
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "register", email, "--password", password],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"test account registration failed: {result.stderr}"

    opener = _new_opener()
    _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)

    mail_html = opener.open(f"{BASE_URL}/", timeout=15).read().decode()
    assert "Inbox" in mail_html or "taskbar" in mail_html, (
        "a live Drive session did not carry over to a bare Mail visit — "
        "check oauth_login_redirect in roundcube's config.inc.php"
    )
