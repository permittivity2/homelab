"""Regression test for a real, serious bug found live, 2026-09-25/26:
"Connection to storage server failed" / "Server Error: Empty password" in
a real user's Roundcube session.

Root cause (fully diagnosed, not guessed -- see homelab-dovecot/README.md's
own "Multi-instance HA: shared mail storage must be mounted with the SAME
identity on every instance" section for the complete writeup): of the
three Dovecot hosts sharing one NAS-backed mail store over SSHFS, one
mounted it authenticating as the NAS's own `root` account instead of the
restricted `vmail` account the other two correctly use. Root bypasses the
NAS's own permission checks entirely, so any NEW mailbox that instance's
LMTP delivery created got written to disk owned by `root` -- invisible to
the other two instances (which correctly authenticate as `vmail`, and
`vmail` has zero access to a `root`-owned, owner-only file) the moment
either of THEM served that same mailbox's next IMAP session. Confirmed
directly on the real NAS, bypassing every mount: files really were
root-owned on disk, not just an artifact of one mount's own cosmetic uid
display.

This file has two tests, deliberately different in kind:

1. test_fresh_mailbox_is_readable_from_every_dovecot_pool_member --
   DETERMINISTIC. Doesn't rely on HAProxy's own round-robin luck to route
   a real session across all three backends within one test run (it might
   not, and a test that only sometimes exercises the bug isn't a real
   regression test for it). Creates one fresh mailbox via a real LMTP
   delivery, then explicitly SSHes to EVERY live Dovecot pool member (not
   just whichever one HAProxy happened to pick) and confirms each one can
   read it -- the exact same manual reproduction technique that first
   found this bug, now automated.

2. test_real_session_never_shows_storage_or_password_errors -- the
   user-facing symptom itself, checked directly and literally: a real,
   multi-request Roundcube session (inbox, refresh, repeated enough times
   to naturally spread across the pool via the real public HAProxy VIP)
   must never show either literal error string in any response body,
   whatever the underlying cause. Independently corroborated afterward
   against real Dovecot journalctl output for the session's own account,
   confirming it genuinely touched more than one pool member -- a pass
   that only ever hit one backend wouldn't actually prove anything about
   the pool-wide bug this file exists for.
"""

import re
import smtplib
import subprocess
import time
import urllib.error

from conftest import register_account, retry_open
from test_dovecot_login import _lmtp_tunnel
from test_fleet_consistency import fleet_status, pools
from test_sso_flow import DRIVE_LOGIN_URL, _new_opener, _submit_credentials

BASE_URL = "https://mail.test.mailmasker.org"

STORAGE_ERROR_MARKERS = (
    "Connection to storage server failed",
    "Empty password",
)


def _run(args, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def _fetch(opener, url):
    try:
        resp = retry_open(opener.open, url, timeout=15)
        return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def test_fresh_mailbox_is_readable_from_every_dovecot_pool_member(
    ssh_host, dovecot_host, postfix_host, lmtp_target, pools
):
    """Deterministic regression test for the actual root cause -- see this
    module's own docstring. Registers a real account, then sends it a
    real message over real LMTP (the same mechanism a real inbound email
    uses -- see test_dovecot_login.py's own test_lmtp_delivery) so a
    genuine new mailbox gets created for real, then checks every live
    Dovecot pool member can read it -- not just whichever one happened
    to deliver it.

    A bare Roundcube page load does NOT reliably do this: confirmed live,
    2026-09-26, that a fresh account's first "/" page fetch produces an
    IMAP login immediately followed by logout with no SELECT/LIST in
    Dovecot's own log -- Roundcube's initial HTML shell doesn't
    necessarily trigger a synchronous folder open, so autocreate never
    fires and no Maildir gets created at all. An earlier version of this
    test relied on exactly that page load and failed 100% of the time for
    that reason, not because of any storage bug -- real LMTP delivery is
    the actual, unambiguous trigger a real inbound email also uses."""
    dovecot_hosts = pools.get("dovecot", [dovecot_host])
    assert len(dovecot_hosts) >= 1, "no Dovecot pool members reported by the fleet registry"

    email = f"e2e-storage-{int(time.time())}@test.mailmasker.org"
    password = "E2eStorageTest1Aa"
    register_account(ssh_host, email, password)

    with _lmtp_tunnel(postfix_host, lmtp_target) as port:
        lmtp = smtplib.LMTP()
        lmtp.connect("127.0.0.1", port)
        lmtp.helo("e2e-test-client")
        try:
            result = lmtp.sendmail(
                "sender@example.com", [email],
                f"Subject: e2e storage test\r\n\r\nhomelab storage-reliability e2e test.\r\n".encode(),
            )
            assert result == {}, f"LMTP delivery was not fully accepted: {result}"
        finally:
            try:
                lmtp.quit()
            except Exception:
                pass

    domain = email.split("@", 1)[1]
    local = email.split("@", 1)[0]
    mailbox_path = f"/var/mail/vhosts/{domain}/{local}"

    unreadable = []
    for host in dovecot_hosts:
        result = _run(["ssh", host, f"stat '{mailbox_path}/cur' '{mailbox_path}/new' '{mailbox_path}/tmp'"])
        if result.returncode != 0:
            unreadable.append(f"{host}: {result.stderr.strip()}")

    assert not unreadable, (
        f"mailbox for {email} is NOT readable from every Dovecot pool member -- "
        "this is exactly the root/vmail mount-identity mismatch bug (see "
        "dovecot/README.md's own HA storage section):\n" + "\n".join(unreadable)
    )


def test_real_session_never_shows_storage_or_password_errors(ssh_host, dovecot_host, pools):
    """The user-facing symptom itself, checked literally across a real,
    repeated Roundcube session -- whatever the underlying cause, these
    two exact strings must never appear. Repeats enough real requests
    through the actual public HAProxy IMAPS VIP to have a real chance of
    spreading across every pool member (matching what a real multi-minute
    user session naturally does), then independently confirms via real
    Dovecot journalctl output that this session's account genuinely was
    served by more than one pool member -- a run that only ever touched
    one backend hasn't actually exercised the pool-wide bug this test
    exists for, and should be treated as inconclusive, not a clean pass.
    """
    email = f"e2e-storage-session-{int(time.time())}@test.mailmasker.org"
    password = "E2eStorageSessionTest1Aa"
    register_account(ssh_host, email, password)

    opener = _new_opener()
    _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)

    failures = []
    for _ in range(9):
        status, body = _fetch(opener, f"{BASE_URL}/?_task=mail&_mbox=INBOX")
        for marker in STORAGE_ERROR_MARKERS:
            if marker in body:
                failures.append(f"GET inbox: response body contains {marker!r} (body[:300]={body[:300]!r})")
        status, body = _fetch(
            opener,
            f"{BASE_URL}/?_task=mail&_action=list&_refresh=1&_layout=widescreen&_mbox=INBOX"
            f"&_remote=1&_unlock=0&_={int(time.time() * 1000)}",
        )
        for marker in STORAGE_ERROR_MARKERS:
            if marker in body:
                failures.append(f"GET refresh: response body contains {marker!r} (body[:300]={body[:300]!r})")

    assert not failures, (
        "a real Roundcube session showed the exact user-reported storage/"
        "password error -- see this module's own docstring for the known "
        "root cause and where it was fixed:\n" + "\n".join(failures)
    )

    # Corroborate real multi-backend coverage -- don't just trust that 9
    # requests were "probably" enough to spread across the pool.
    touched = set()
    for host in pools.get("dovecot", [dovecot_host]):
        result = _run(["ssh", host, f"sudo journalctl -u dovecot --since '2 minutes ago' --no-pager"])
        if email in result.stdout:
            touched.add(host)

    assert len(touched) >= 2, (
        f"this session's real IMAP traffic only touched {touched or 'no'} Dovecot pool "
        "member(s) in the last 2 minutes -- inconclusive for the pool-wide storage bug "
        "this test exists to catch; re-run, or check HAProxy's own balancing algorithm "
        "if this keeps happening"
    )
