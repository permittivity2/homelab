"""End-to-end regression tests for the self-service password-reset flow
(2026-09-27), the failsafe the invite recovery-email exists to enable.

The flow spans three packages, all exercised here for real:
  - homelab-sso serves the browser-facing pages (a "Forgot password?"
    link on its login page -> GET/POST /forgot -> GET/POST /reset/:token)
    and sends the reset email.
  - homelab-api owns the token + the password write
    (system_agent-gated /auth/password-reset/{request,confirm}), minting
    a one-time, 1-hour token only when the account has a recovery email
    on file, and revoking every session on a successful reset.
  - the email itself travels the real mail stack (authenticated SMTP
    submission -> Postfix -> Dovecot LMTP) to the account's recovery
    address.

To make delivery observable, the account being reset is given a recovery
address that is itself a real, readable fleet mailbox (created via the
normal fixture path) -- so the test can pull the emailed token straight
out of that inbox over real IMAP, exactly as a human would read it. This
also proves, end to end, that the invite flow's recovery_email really
was captured and stored: the reset email only arrives if it was.

The account-to-reset is created through the real invite acceptance flow
(choosing a username + a recovery email), so this doubles as coverage
that recovery_email set at acceptance is honored by reset.
"""

import imaplib
import json
import re
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from conftest import register_account, retry_open, login_succeeds, SITE_ADMIN_EMAIL
from test_dovecot_login import _imaps_tunnel
from test_sso_flow import _new_opener

INVITE_BASE_URL = "https://invite.test.mailmasker.org"
SSO_BASE_URL = "https://login.test.mailmasker.org"


def _send_invite(ssh_host, recipient):
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "--as", SITE_ADMIN_EMAIL, "-j", "invite", "send", "--to", recipient],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"could not mint an invite to {recipient}: {result.stderr}"
    return json.loads(result.stdout)


def _accept_invite(token, username, password, recovery_email):
    req = urllib.request.Request(
        f"{INVITE_BASE_URL}/invite/{token}/accept",
        data=json.dumps({
            "username": username, "password": password,
            "password_confirm": password, "recovery_email": recovery_email,
        }).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    opener = _new_opener()
    try:
        resp = retry_open(opener.open, req, timeout=15)
        return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def _create_account_with_recovery(ssh_host, recovery_email):
    """Create a real, login-capable account (through the real invite
    acceptance flow) whose recovery address is `recovery_email`."""
    recipient = f"e2e-reset-owner-{int(time.time())}@example.com"
    invite = _send_invite(ssh_host, recipient)
    username = f"resetuser{int(time.time())}"
    password = "InitialResetPass1"
    status, body = _accept_invite(invite["token"], username, password, recovery_email)
    assert status == 200 and body.get("ok"), f"could not create the account to reset: {status} {body}"
    return body["email"], password


def _forgot(email):
    data = urllib.parse.urlencode({"email": email}).encode()
    req = urllib.request.Request(f"{SSO_BASE_URL}/forgot", data=data, method="POST")
    opener = _new_opener()
    resp = retry_open(opener.open, req, timeout=15)
    return resp.status, resp.read().decode(errors="replace")


def _reset(token, password, confirm):
    data = urllib.parse.urlencode({"password": password, "password_confirm": confirm}).encode()
    req = urllib.request.Request(f"{SSO_BASE_URL}/reset/{token}", data=data, method="POST")
    opener = _new_opener()
    try:
        resp = retry_open(opener.open, req, timeout=15)
        return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def _read_reset_token(haproxy_host, imaps_vip, mailbox, password):
    """Poll the mailbox over real IMAP for the reset email and return
    the token from its /reset/<token> link, or None if none arrives."""
    for _ in range(12):
        with _imaps_tunnel(haproxy_host, imaps_vip) as port:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            m = imaplib.IMAP4_SSL("127.0.0.1", port, ssl_context=ctx)
            m.login(mailbox, password)
            m.select("INBOX")
            typ, data = m.search(None, "ALL")
            ids = data[0].split() if data and data[0] else []
            for mid in reversed(ids):
                typ, msg = m.fetch(mid, "(BODY[])")
                raw = msg[0][1].decode(errors="replace") if msg and msg[0] else ""
                mm = re.search(r"/reset/([0-9a-f]+)", raw)
                if "Reset your Homelab password" in raw and mm:
                    m.logout()
                    return mm.group(1)
            m.logout()
        time.sleep(2)
    return None


def test_full_password_reset_round_trip(ssh_host, haproxy_host, imaps_vip):
    # A readable fleet mailbox to receive the reset email.
    recovery_mailbox = f"e2e-reset-inbox-{int(time.time())}@test.mailmasker.org"
    recovery_password = "RecoveryInboxPass1"
    register_account(ssh_host, recovery_mailbox, recovery_password)

    # The account we'll actually reset -- created through the real invite
    # flow with the readable mailbox as its recovery address.
    account_email, old_password = _create_account_with_recovery(ssh_host, recovery_mailbox)
    assert login_succeeds(account_email, old_password), "sanity: the new account should log in before reset"

    # Ask for a reset -- the public page must respond uniformly whatever
    # the outcome (no enumeration).
    status, page = _forgot(account_email)
    assert status == 200 and "Check your email" in page, (
        f"/forgot should render its uniform confirmation: {status} {page[:300]!r}"
    )

    token = _read_reset_token(haproxy_host, imaps_vip, recovery_mailbox, recovery_password)
    assert token, (
        f"no password-reset email with a /reset/<token> link ever arrived in {recovery_mailbox} -- "
        "the recovery address set at invite acceptance was not honored, or mail delivery failed"
    )

    new_password = "BrandNewResetPass9"
    status, page = _reset(token, new_password, new_password)
    assert status == 200 and "Password updated" in page, (
        f"the reset should succeed and confirm: {status} {page[:300]!r}"
    )

    assert login_succeeds(account_email, new_password), "the new password should work after reset"
    assert not login_succeeds(account_email, old_password), "the OLD password must no longer work after reset"

    # Single-use: the same token can't be replayed.
    status, page = _reset(token, "YetAnotherPass2", "YetAnotherPass2")
    assert "invalid or has expired" in page, (
        f"a used reset token must be rejected on reuse: {status} {page[:300]!r}"
    )


def test_forgot_is_uniform_for_an_unknown_account(ssh_host):
    """No account enumeration: /forgot for an address with no account
    renders the exact same confirmation as for a real one, and doesn't
    error."""
    status, page = _forgot(f"definitely-no-such-account-{int(time.time())}@test.mailmasker.org")
    assert status == 200 and "Check your email" in page, (
        f"/forgot for an unknown account must render the same uniform confirmation: "
        f"{status} {page[:300]!r}"
    )
