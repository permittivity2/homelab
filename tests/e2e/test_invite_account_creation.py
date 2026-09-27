"""Regression tests for the invite ACCOUNT-CREATION redesign (2026-09-27).

The bug this fixes: the old acceptance page jumped straight to a
password field for an account whose login was hard-wired to the invite's
own recipient_email -- which made no sense once invites to fleet-managed
recipients were (correctly) rejected, leaving a real external invitee
with no fleet identity at all. The redesign: the invitee CHOOSES a
username, their login becomes <username>@<account_domain> (the fleet's
own mail domain), they set a password (entered twice, matched), and may
supply a recovery email (pre-filled with the address the invite was sent
to) for future password resets.

These tests drive the real public acceptance endpoints
(/invite/:token/username and /invite/:token/accept) exactly as the
page's own JS does, against the live fleet:

  1. A username already in use comes back as available:false WITH
     suggestions -- and, per the explicit requirement, WITHOUT ever
     saying "that's taken"/"already exists" (no account-existence
     oracle). A free username comes back available:true.
  2. Mismatched passwords are rejected and the invite is NOT consumed
     (the token survives for a real retry).
  3. The full happy path creates a real, login-capable account under the
     chosen fleet-domain username -- verified by actually logging into
     it. (Recovery-email capture is proven end-to-end by
     test_password_reset.py, which can only work if it was stored.)

Recipients are on @example.com (a genuinely external, non-fleet-managed
domain) so acceptance is allowed -- the managed-recipient rejection is
test_invite_domain_restriction.py's job.
"""

import json
import re
import subprocess
import time
import urllib.error
import urllib.request

from conftest import retry_open, login_succeeds, SITE_ADMIN_EMAIL
from test_sso_flow import _new_opener

INVITE_BASE_URL = "https://invite.test.mailmasker.org"

# Local part of the well-known site_admin fixture account
# (test-admin@test.mailmasker.org) -- guaranteed to already exist, so a
# reliable "this username is taken" probe without first creating one.
KNOWN_TAKEN_LOCALPART = "test-admin"

# Substrings a taken-username response must NOT contain -- the explicit
# requirement is to offer suggestions, never to confirm a specific
# account exists.
FORBIDDEN_EXISTENCE_WORDS = ("taken", "already", "exists", "in use", "unavailable")


def _send_invite(ssh_host, recipient):
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "--as", SITE_ADMIN_EMAIL, "-j", "invite", "send", "--to", recipient],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"could not mint an invite to {recipient}: {result.stderr}"
    return json.loads(result.stdout)


def _post(path, payload):
    req = urllib.request.Request(
        f"{INVITE_BASE_URL}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    opener = _new_opener()
    try:
        resp = retry_open(opener.open, req, timeout=15)
        return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def _get_page(token):
    opener = _new_opener()
    resp = retry_open(opener.open, f"{INVITE_BASE_URL}/invite/{token}", timeout=15)
    return resp.read().decode(errors="replace")


def _script_body(html):
    """The contents of the page's inline <script> block."""
    m = re.search(r"<script>(.*?)</script>", html, re.DOTALL)
    return m.group(1) if m else ""


def test_taken_username_offers_suggestions_without_revealing_existence(ssh_host):
    recipient = f"e2e-acct-sugg-{int(time.time())}@example.com"
    invite = _send_invite(ssh_host, recipient)
    token = invite["token"]

    # A free username: available, no suggestions needed.
    free = f"freename{int(time.time())}"
    status, body = _post(f"/invite/{token}/username", {"username": free})
    assert status == 200 and body.get("available") is True, (
        f"a clearly-free username should be available: {status} {body}"
    )

    # A taken username: NOT available, WITH real alternatives, and
    # WITHOUT confirming the name is taken.
    status, body = _post(f"/invite/{token}/username", {"username": KNOWN_TAKEN_LOCALPART})
    assert status == 200, f"username check should be a normal 200 response: {status} {body}"
    assert body.get("available") is False, (
        f"a known-existing username should not be available: {body}"
    )
    suggestions = body.get("suggestions") or []
    assert len(suggestions) >= 1, f"a taken username must come back with suggestions: {body}"
    assert KNOWN_TAKEN_LOCALPART not in suggestions, (
        f"suggestions must not include the taken name itself: {body}"
    )
    blob = json.dumps(body).lower()
    leaked = [w for w in FORBIDDEN_EXISTENCE_WORDS if w in blob]
    assert not leaked, (
        f"the taken-username response must NOT reveal that the account exists "
        f"(found {leaked!r}) -- offer suggestions only: {body}"
    )

    # And every suggestion offered is itself actually free.
    for name in suggestions:
        s, b = _post(f"/invite/{token}/username", {"username": name})
        assert s == 200 and b.get("available") is True, (
            f"suggested username {name!r} was not actually available: {s} {b}"
        )


def test_password_mismatch_is_rejected_and_does_not_consume_the_invite(ssh_host):
    recipient = f"e2e-acct-mismatch-{int(time.time())}@example.com"
    invite = _send_invite(ssh_host, recipient)
    token = invite["token"]
    username = f"mismatch{int(time.time())}"

    status, body = _post(f"/invite/{token}/accept", {
        "username": username, "password": "GoodPassword1", "password_confirm": "OtherPassword2",
    })
    assert status == 400, f"mismatched passwords should be a 400: {status} {body}"
    assert "match" in body.get("error", "").lower(), (
        f"the error should explain the passwords don't match: {body}"
    )

    # The invite must survive a rejected attempt: a correct retry with
    # the SAME token still works (the token was not burned).
    status, body = _post(f"/invite/{token}/accept", {
        "username": username, "password": "GoodPassword1", "password_confirm": "GoodPassword1",
    })
    assert status == 200 and body.get("ok"), (
        f"a corrected retry on the same token should succeed -- the mismatch must not have "
        f"consumed the invite: {status} {body}"
    )


def test_full_acceptance_creates_a_login_capable_fleet_account(ssh_host):
    recipient = f"e2e-acct-happy-{int(time.time())}@example.com"
    invite = _send_invite(ssh_host, recipient)
    token = invite["token"]
    username = f"happyuser{int(time.time())}"
    password = "HappyPathPass1"

    status, body = _post(f"/invite/{token}/accept", {
        "username": username, "password": password, "password_confirm": password,
        "recovery_email": recipient,
    })
    assert status == 200 and body.get("ok"), f"acceptance should succeed: {status} {body}"
    account_email = body.get("email")
    assert account_email == f"{username}@test.mailmasker.org", (
        f"the new login should be the chosen username on the fleet domain: {body}"
    )

    assert login_succeeds(account_email, password), (
        f"the freshly created account {account_email} could not actually log in -- acceptance "
        "reported success but no usable account exists"
    )


def test_acceptance_page_javascript_is_not_perl_mangled(ssh_host):
    """The regression test for the real "click Create account, nothing
    happens" bug (2026-09-27). The page's whole interactive behaviour --
    the username availability check AND the Create-account button -- is
    an inline <script> interpolated server-side through Perl's qq{}. A
    literal '@' in that JS was silently eaten by Perl's @'-package-var
    interpolation, corrupting the script into a SYNTAX ERROR so NO
    handlers bound and the button did nothing. Every other test in this
    suite POSTs to the endpoints directly, bypassing the page JS
    entirely, so none of them could ever catch this -- only fetching the
    real rendered page and inspecting the script can.

    Without a JS engine on the runner we can't truly parse it, but we can
    assert the specific corruption is gone (the '@'+DOMAIN expressions
    survived intact), that the server-side interpolations that MUST
    happen did (the real token is embedded), and that the script's
    delimiters balance -- which gross qq{}-interpolation damage would
    break."""
    recipient = f"e2e-acct-js-{int(time.time())}@example.com"
    invite = _send_invite(ssh_host, recipient)
    token = invite["token"]

    script = _script_body(_get_page(token))
    assert script, "no inline <script> found on the acceptance page"

    # The exact thing that was corrupted: the '@' literal joining the
    # username to the domain. Must appear intact (Perl must NOT have
    # eaten the @). Present in both the availability message and the
    # success message.
    assert script.count("'@' + DOMAIN") == 2, (
        "the acceptance page JS is missing the intact \"'@' + DOMAIN\" expressions -- Perl's "
        "qq{} interpolation likely ate the '@' again (the 'button does nothing' bug). Script "
        f"head: {script[:400]!r}"
    )
    # The server-side interpolations that must succeed for the JS to work.
    assert f"var TOKEN = '{token}'" in script, (
        f"the invite token was not interpolated into the page JS: {script[:300]!r}"
    )
    assert "getElementById('go').onclick" in script, "the Create-account button handler is missing"

    # Gross interpolation damage would unbalance these -- a cheap
    # structural sanity check short of a real JS parser.
    for opener, closer in (("{", "}"), ("(", ")"), ("[", "]")):
        assert script.count(opener) == script.count(closer), (
            f"unbalanced {opener}{closer} in the page JS ({script.count(opener)} vs "
            f"{script.count(closer)}) -- likely server-side interpolation corruption"
        )


def test_acceptance_works_with_and_without_a_recovery_email(ssh_host):
    """Both a supplied recovery email and an omitted (empty) one must
    produce a working account -- the recovery field is optional, and a
    blank one must not break acceptance (it's stored NULL server-side).
    The 'recovery actually captured + usable' path is proven end to end
    by test_password_reset.py; here we just guard that neither variation
    errors and both yield a login-capable account."""
    for label, recovery in (("with-recovery", f"recovery-{int(time.time())}@example.net"),
                            ("no-recovery", "")):
        recipient = f"e2e-acct-{label}-{int(time.time())}@example.com"
        invite = _send_invite(ssh_host, recipient)
        username = f"rec{label.replace('-', '')}{int(time.time())}"
        password = "RecoveryVariantPass1"
        status, body = _post(f"/invite/{invite['token']}/accept", {
            "username": username, "password": password, "password_confirm": password,
            "recovery_email": recovery,
        })
        assert status == 200 and body.get("ok"), (
            f"acceptance ({label}) should succeed: {status} {body}"
        )
        assert login_succeeds(body["email"], password), (
            f"the account created ({label}) could not log in: {body}"
        )
