"""Regression test for a real coverage gap found live, 2026-09-26: no
existing test actually verified that an invite EMAIL arrives anywhere.

Every prior invite test (test_invite_domain_restriction.py included)
mints an invite via `homelab-cli invite send` (channel='cli') and then
accepts it using the TOKEN straight out of the API's own JSON response
-- never needing the actual email to arrive at all. That's exactly why
a real bug went undetected: a user sent a real invite through
Roundcube's "Send Invite" page (channel='roundcube_plugin' -- a
DIFFERENT code path, where Roundcube's own PHP sends the email itself
via deliver_message(), not homelab-invite's Mailer.pm) and it never
arrived. Root cause, fully traced (not guessed): Roundcube's own SMTP
submission succeeded and the fleet's own Postfix accepted and queued
the message, but the fleet's own outbound egress to arbitrary external
mail servers on port 25 is blocked at the network level (confirmed:
`echo > /dev/tcp/<production-ip>/25` times out from every fleet host
tried, including the internet-facing edge, while the SAME production
IP on port 443 is reachable fine, and the SAME port 25 is reachable
from a genuinely different network -- this is fleet-egress-specific,
not a generic block). This is an infrastructure/firewall fact, not a
homelab-* package bug -- nothing here can fix it, and it isn't
attempted. See this session's own findings for the pfsense follow-up.

What IS fixed here: this test suite now has real coverage for the
actual, missing case -- an invite sent through the SAME Roundcube UI
path the original bug used (not the CLI shortcut), verified by really
receiving the resulting email over real IMAP, not by trusting an API
response. Recipient is on test.mailmasker.org (a domain this fleet
delivers mail for directly, no egress involved) specifically so this
test exercises exactly what CAN and SHOULD work today; a real invite to
a genuinely external domain remains untestable until the egress
restriction above is resolved (or deliberately decided to stay in
place) -- that's a real, known, and reported limitation, not something
worked around here.
"""

import imaplib
import json
import re
import ssl
import time
import urllib.error
import urllib.parse

import pytest

from conftest import register_account, retry_open
from test_dovecot_login import _imaps_tunnel
from test_fleet_consistency import fleet_status, pools
from test_roundcube_plugins import _invite_sender_enabled_fleet_wide
from test_sso_flow import DRIVE_LOGIN_URL, _new_opener, _submit_credentials

BASE_URL = "https://mail.test.mailmasker.org"


def _fetch(opener, url, data=None):
    req_data = urllib.parse.urlencode(data).encode() if data else None
    try:
        resp = retry_open(opener.open, url, data=req_data, timeout=15)
        return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def test_real_invite_sent_via_roundcube_ui_actually_arrives(
    ssh_host, haproxy_host, imaps_vip, pools
):
    """The direct regression test: send a real invite through the exact
    UI path (plugin.send_invite) the original bug used, then connect
    over real IMAP as the recipient and confirm the resulting message
    genuinely landed -- not just that the HTTP call returned 200."""
    if not _invite_sender_enabled_fleet_wide(pools):
        pytest.skip("invite_sender not installed fleet-wide -- see _invite_sender_enabled_fleet_wide")

    sender_email = f"e2e-invite-sender-{int(time.time())}@test.mailmasker.org"
    sender_password = "E2eInviteSenderTest1Aa"
    register_account(ssh_host, sender_email, sender_password)

    recipient_email = f"e2e-invite-recipient-{int(time.time())}@test.mailmasker.org"
    register_account(ssh_host, recipient_email, "E2eInviteRecipientTest1Aa")

    opener = _new_opener()
    _submit_credentials(opener, DRIVE_LOGIN_URL, sender_email, sender_password)
    mail_html = _fetch(opener, f"{BASE_URL}/")[1]
    assert "Inbox" in mail_html or "taskbar" in mail_html, (
        f"could not establish a real Roundcube session for {sender_email} -- "
        "setup failed before this test could send a real invite"
    )

    # Roundcube's own CSRF protection (get_request_token(), checked
    # against $_SESSION on every POST -- see rcmail.php/
    # rcmail_output_html.php) rejects a POST with no _token field
    # outright (403), same requirement a real browser's JS satisfies
    # automatically via rcmail.env.request_token. Pulled from whatever
    # authenticated page was already fetched -- present on every page,
    # not just this plugin's own.
    token_match = re.search(r'"request_token":"([^"]+)"', mail_html)
    assert token_match, "could not find Roundcube's own request_token in an authenticated page"
    request_token = token_match.group(1)

    marker = f"e2e-real-delivery-check-{int(time.time())}"
    status, body = _fetch(
        opener,
        f"{BASE_URL}/?_task=settings&_action=plugin.send_invite&_remote=1&_unlock=0",
        data={"recipient": recipient_email, "message": marker, "_token": request_token},
    )
    assert status == 200, f"POST plugin.send_invite failed outright: HTTP {status}"
    # Every plugin AJAX response embeds Roundcube's FULL, static
    # gettext dictionary (every registered label, including
    # 'sentnomail's own definition text) regardless of which one
    # actually fired -- a blind substring search for "the email could
    # not be sent" always matches that dictionary entry and is a false
    # positive. The real outcome is the "exec" field's own
    # display_message(...) call -- parse the response as real JSON and
    # check that specifically, rather than pattern-matching a string
    # that itself contains escaped quotes.
    response = json.loads(body)
    exec_js = response.get("exec", "")
    assert "display_message" in exec_js, f"no display_message() call in the response at all: {response!r}"
    assert '"confirmation"' in exec_js, (
        f"invite_sender did not report success sending to {recipient_email}: {exec_js!r}"
    )

    # Real delivery, real Postfix, real Dovecot LMTP autocreate --
    # give it a few seconds and a few retries rather than assuming
    # instant delivery (this fleet's own real characteristic, not a
    # test artifact -- test_dovecot_login.py's own LMTP tests don't
    # need this because they deliver synchronously via raw LMTP;
    # Roundcube's own deliver_message() hands off to Postfix
    # asynchronously instead).
    found = False
    last_seen_count = None
    for _ in range(10):
        with _imaps_tunnel(haproxy_host, imaps_vip) as port:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            m = imaplib.IMAP4_SSL("127.0.0.1", port, ssl_context=ctx)
            m.login(recipient_email, "E2eInviteRecipientTest1Aa")
            m.select("INBOX")
            typ, data = m.search(None, "ALL")
            ids = data[0].split() if data and data[0] else []
            last_seen_count = len(ids)
            for msg_id in ids:
                typ, msg = m.fetch(msg_id, "(BODY[])")
                raw = msg[0][1] if msg and msg[0] else b""
                if b"You're invited" in raw or marker.encode() in raw or b"invite" in raw.lower():
                    found = True
            m.logout()
        if found:
            break
        time.sleep(2)

    assert found, (
        f"the invite email sent to {recipient_email} via the real Roundcube UI never arrived "
        f"in its real IMAP inbox (saw {last_seen_count} message(s) after retrying) -- this is "
        "exactly the real, live bug this test exists to catch. If this ever fails again for a "
        "test.mailmasker.org recipient specifically (in-fleet delivery, no egress involved), "
        "that is a real regression -- check Postfix/Dovecot logs on the mail hosts directly, "
        "the same way this test's own root-cause investigation did."
    )
