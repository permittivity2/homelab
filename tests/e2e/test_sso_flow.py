"""Phase 4/6 regression test: the actual point of building homelab-sso --
real cross-app "login once, login everywhere" and "logout once, logout
everywhere" for one browser, proven over real HTTPS against the live
public domains with a real cookie jar (http.cookiejar), the same way an
actual browser would experience it. Not just homelab-sso's own in-process
t/basic.t (which only proves the IdP-session mechanism in isolation) and
not just homelab-drive's/homelab-roundcube's own package-local tests
(which each only prove their own OAuth client wiring) -- this is what
proves the two apps actually share one login through homelab-sso, over
the real network, which is the property the whole rebuild was for.

No shared cross-app cookie is involved anywhere in this file (deliberately
-- see sso/README.md for why the design doesn't use one): "login once"
here means visiting a SECOND app's own "start SSO login" entry point, with
the SAME cookie jar, silently completes the whole redirect chain with NO
credentials sent a second time -- that only works because homelab-sso's
own IdP session cookie recognizes the browser. "Logout once" means logging
out of ONE app makes a completely FRESH visit to the OTHER app's own entry
point show homelab-sso's login form again -- proving the underlying
homelab-api session was centrally revoked, not just the app you clicked
logout on.

Each app's own entry point is used deliberately (rather than hand-building
a request straight to homelab-sso's /oauth/authorize) because each app
mints and stores its OWN CSRF `state` nonce when it starts the redirect --
skipping that and inventing a state value here doesn't reproduce what a
real browser does, and both apps correctly reject a callback whose state
doesn't match what that same app itself stored (see homelab-drive's
oauth_callback() and Roundcube's request_access_token()). An earlier draft
of this file took that shortcut and got a false failure as a result.
"""

import html
import http.cookiejar
import re
import subprocess
import time
import urllib.parse
import urllib.request

import pytest

DRIVE_URL = "https://drive.test.mailmasker.org"
MAIL_URL = "https://mail.test.mailmasker.org"
SSO_URL = "https://login.test.mailmasker.org"

DRIVE_LOGIN_URL = f"{DRIVE_URL}/login"
ROUNDCUBE_LOGIN_URL = f"{MAIL_URL}/?_task=login&_action=oauth"


@pytest.fixture
def sso_account(ssh_host):
    """A fresh, real homelab-api account per test (not module-scoped --
    each test drives its own login/logout sequence and they'd otherwise
    interfere with each other's IdP session state)."""
    email = f"e2e-sso-flow-{int(time.time() * 1000)}@test.mailmasker.org"
    password = "E2eSsoFlowTest1Aa"
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "register", email, "--password", password],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"test account registration failed: {result.stderr}"
    return email, password


def _new_opener():
    cj = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))


def _start_login(opener, entry_url):
    """Hits an app's own "start SSO login" entry point. With a live
    homelab-sso IdP session already established, this silently completes
    the whole redirect chain (app -> homelab-sso -> back to the app) and
    returns (True, final_html). With no session, it stops at
    homelab-sso's own login form and returns (False, login_form_html)."""
    resp = opener.open(entry_url, timeout=15)
    page_html = resp.read().decode()
    return (not resp.geturl().startswith(SSO_URL)), page_html


def _submit_credentials(opener, sso_login_form_url, email, password):
    """POSTs credentials to homelab-sso's own login form (reusing the
    client_id/redirect_uri/state it rendered, scraped out of that page's
    own form action/hidden fields) and follows the resulting redirect
    chain to completion. Returns the final page's HTML."""
    # homelab-sso's login form posts back to /oauth/authorize with
    # client_id/redirect_uri/state carried as hidden fields.
    resp = opener.open(sso_login_form_url, timeout=15)
    page_html = resp.read().decode()
    # html.unescape() the scraped values: Mojolicious's <%= %> HTML-escapes
    # interpolated values (see sso/templates/oauth/login.html.ep), so a
    # redirect_uri containing "&" (Roundcube's does; Drive's plain-path
    # one doesn't, which is why this only bit one of the two apps) comes
    # back as "&amp;" in the raw HTML -- submitting that literally would
    # never match what's actually registered.
    hidden = {k: html.unescape(v) for k, v in re.findall(r'name="(client_id|redirect_uri|state|scope)"\s+value="([^"]*)"', page_html)}
    assert {"client_id", "redirect_uri", "state"} <= hidden.keys(), f"could not find expected hidden fields on homelab-sso's login form: {page_html[:500]}"

    data = urllib.parse.urlencode({**hidden, "email": email, "password": password}).encode()
    req = urllib.request.Request(f"{SSO_URL}/oauth/authorize", data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    resp = opener.open(req, timeout=15)
    return resp.read().decode()


def test_login_via_drive_reaches_file_listing(sso_account):
    email, password = sso_account
    opener = _new_opener()

    landed, sso_form_html = _start_login(opener, DRIVE_LOGIN_URL)
    assert not landed, "expected no prior session -- should have stopped at homelab-sso's login form"
    assert "Log in" in sso_form_html

    drive_html = _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)
    assert email in drive_html, "did not land on Drive's own file listing, showing the logged-in user's email"


def test_login_once_roundcube_reuses_drive_session(sso_account):
    """The core "login once, login everywhere" property: after logging
    into Drive, visiting ROUNDCUBE's own SSO entry point with the SAME
    cookie jar must silently complete -- no credentials sent a second
    time -- and land Roundcube straight in the inbox."""
    email, password = sso_account
    opener = _new_opener()

    _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)

    landed, roundcube_html = _start_login(opener, ROUNDCUBE_LOGIN_URL)
    assert landed, "a live Drive session did not carry over to homelab-sso's IdP session for a second app"
    assert "Inbox" in roundcube_html or "taskbar" in roundcube_html, f"expected Roundcube's inbox, got something else (first 300 chars): {roundcube_html[:300]}"


def test_logout_via_drive_kills_roundcube_session(sso_account):
    """Real, bidirectional single logout, direction 1: log into both
    apps (via the login-once mechanism above), log out via Drive only,
    then confirm a completely fresh visit to Roundcube's own SSO entry
    point shows homelab-sso's login form again -- proving the shared
    homelab-api session was centrally revoked, not just Drive's own
    local session cleared."""
    email, password = sso_account
    opener = _new_opener()

    _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)
    landed, _ = _start_login(opener, ROUNDCUBE_LOGIN_URL)
    assert landed, "setup failed: Roundcube should already be silently logged in before testing logout"

    req = urllib.request.Request(f"{DRIVE_URL}/logout", data=b"", method="POST")
    opener.open(req, timeout=15).read()

    landed, _ = _start_login(opener, ROUNDCUBE_LOGIN_URL)
    assert not landed, "logging out via Drive did not kill the shared session -- Roundcube could still silently re-authenticate"


def test_logout_via_roundcube_kills_drive_session(sso_account):
    """Direction 2, the one an earlier iteration of this same
    architecture (this project's prior private repo) initially got wrong
    in exactly one direction -- see roundcube/README.md's "Single sign-on
    via homelab-sso" section for the logout_after() patch this depends
    on. Logs in via Roundcube's own entry point this time, logs out via
    Roundcube, confirms Drive can no longer silently re-authenticate."""
    email, password = sso_account
    opener = _new_opener()

    _submit_credentials(opener, ROUNDCUBE_LOGIN_URL, email, password)
    landed, _ = _start_login(opener, DRIVE_LOGIN_URL)
    assert landed, "setup failed: Drive should already be silently logged in before testing logout"

    # Roundcube's own logout needs a real CSRF _token from a real
    # Roundcube-rendered page first -- core rejects a bare ?_task=logout
    # with no/wrong token rather than actually logging out.
    mail_html = opener.open(f"{MAIL_URL}/", timeout=15).read().decode()
    m = re.search(r'"request_token"\s*:\s*"([a-zA-Z0-9]+)"', mail_html)
    assert m, f"no request_token found on Roundcube's own page -- can't drive a real logout without it: {mail_html[:300]}"
    token = m.group(1)

    logout_html = opener.open(f"{MAIL_URL}/?_task=logout&_token={token}", timeout=15).read().decode()
    assert "rcmloginuser" in logout_html or "rcmloginoauth" in logout_html, (
        f"logout request did not land back on Roundcube's own login page -- did the CSRF token extraction fail? {logout_html[:300]}"
    )

    landed, _ = _start_login(opener, DRIVE_LOGIN_URL)
    assert not landed, "logging out via Roundcube did not kill the shared session -- Drive could still silently re-authenticate"
