"""Phase 6 (mail stack) regression test: a real browser-equivalent login
to homelab-roundcube over real HTTPS — the last piece of the mail stack,
and the one that proves the unified cross-feature identity design from
the actual end-user's side. Unlike every other test in this suite, this
one needs no SSH tunnel: homelab-webproxy's real Let's Encrypt
certificate for mail.test.mailmasker.org means this hits the genuine
public internet-facing path directly, the same way a real user's browser
would (see webproxy/README.md for how that got confirmed working).

Also the regression test for a real upstream incompatibility: Ubuntu's
roundcube-core 1.6.11 unconditionally redeclares array_first(), which
PHP 8.5 now ships as a genuine builtin — a hard PHP fatal on every page
load. See roundcube/script/homelab-roundcube-patch-php85-compat and
roundcube/README.md for the full story. If that patch ever regresses
(e.g. a roundcube-core package upgrade resets the file), every request
here 500s instead of returning real HTML — this test would catch that
immediately as a non-200 status or a missing login form, not just an
IMAP-level auth failure.
"""

import http.cookiejar
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

BASE_URL = "https://mail.test.mailmasker.org"


@pytest.fixture(scope="module")
def mail_account(ssh_host):
    """A fresh, real homelab-api account — the same registration path
    every other mail-stack e2e test proves unified identity against."""
    email = f"e2e-roundcube-{int(time.time())}@test.mailmasker.org"
    password = "E2eRoundcubeTest1Aa"
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "register", email, "--password", password],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"test account registration failed: {result.stderr}"
    return email, password


def _new_session():
    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    return opener


def _fetch_login_token(opener):
    resp = opener.open(f"{BASE_URL}/", timeout=15)
    html = resp.read().decode()
    assert resp.status == 200, f"login page did not load: HTTP {resp.status}"
    m = re.search(r'name="_token"\s+value="([^"]+)"', html)
    assert m, "no CSRF token found on the login page — is homelab-roundcube actually serving real HTML (see the array_first PHP 8.5 Gotcha)?"
    return m.group(1)


def _attempt_login(opener, token, email, password):
    data = urllib.parse.urlencode({
        "_token": token,
        "_task": "login",
        "_action": "login",
        "_timezone": "UTC",
        "_url": "",
        "_user": email,
        "_pass": password,
    }).encode()
    req = urllib.request.Request(f"{BASE_URL}/?_task=login", data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Referer", f"{BASE_URL}/")
    resp = opener.open(req, timeout=15)
    return resp.read().decode()


def test_real_https_login_reaches_inbox(mail_account):
    email, password = mail_account
    opener = _new_session()
    token = _fetch_login_token(opener)
    html = _attempt_login(opener, token, email, password)
    assert "Inbox" in html or "taskbar" in html, (
        "login did not land on the Inbox — check homelab-dovecot's IMAP passdb "
        "and that this account is active"
    )


def test_wrong_password_does_not_reach_inbox(mail_account):
    """A wrong password must never reach the Inbox. Roundcube answers
    this particular rejection with a real HTTP 401 (not a 200 with a
    login-form-again page), which urllib raises as HTTPError by
    default — that exception IS the passing case here, not a test
    infrastructure failure; only a 2xx/3xx response showing the Inbox
    would mean the IMAP passdb rejection isn't being honored."""
    email, _ = mail_account
    opener = _new_session()
    token = _fetch_login_token(opener)
    try:
        html = _attempt_login(opener, token, email, "definitely-the-wrong-password")
    except urllib.error.HTTPError as e:
        assert e.code in (401, 403), f"expected a real auth-rejection status, got {e.code}"
        return
    assert "Inbox" not in html, "a WRONG password reached the Inbox — SASL/IMAP passdb rejection isn't being honored"
