"""Phase 6 (mail stack) regression test: real IMAP login against
homelab-dovecot's SQL passdb, proving the unified cross-feature identity
design for real — a password registered through homelab-api (the same
path homelab-drive's HTTP login uses) authenticates over IMAP with no
separate mail-specific password store, via a narrow column-scoped grant
on api.users (see dovecot/README.md and
dovecot/script/homelab-dovecot-bootstrap-role).

Also stands as the regression test for real bugs caught building this
package (see dovecot/README.md's Gotchas section for the full writeup):
  - adduser --system's auto-allocated uid landed below Dovecot's
    first_valid_uid floor (500) — an otherwise fully correct passdb+userdb
    lookup was rejected outright with "Mail access for users with UID
    <n> not permitted". homelab-dovecot's postinst creates vmail with a
    fixed, explicit uid/gid (5000) specifically to avoid this.
  - mail_inbox_path defaults SEPARATELY from mail_path in Dovecot 2.4 (a
    config-language rewrite the vendor's own NEWS.Debian calls
    "incompatible" vs 2.3) and silently keeps pointing at the legacy
    /var/mail/%{user} shared spool. Config parses cleanly either way
    (doveconf -n gives no warning) and LOGIN itself succeeds — only a
    real SELECT INBOX exposes the "Permission denied" autocreate
    failure, which is exactly why this test does a real SELECT (and
    APPEND, and SEARCH), not just a login.
  - Debian's stock dovecot-core config scopes a default
    `auth_username_format = %{user | username | lower}` to `protocol
    lmtp { }`, silently stripping the domain off every LMTP recipient
    lookup. IMAP login keeps working fine (a totally different code path
    that doesn't apply this transform) while every LMTP delivery — the
    mechanism homelab-postfix's virtual_transport actually uses — fails
    with "550 User doesn't exist" for an account that logs in over IMAP
    seconds earlier. `test_lmtp_delivery` below is the regression test:
    it delivers over real LMTP, not IMAP, so it fails the same way a
    real inbound email would if this regresses.

External (raw-internet) reachability is NOT exercised here — this test
forwards the real IMAPS port through the existing SSH channel instead,
to the real HAProxy IMAPS VIP (see conftest.py's imaps_vip fixture), not
any one pool member's own loopback — that still exercises every real
line of the stack this suite can reach: HAProxy's own frontend, its
load-balancing across the live 3-node Dovecot pool, and every line of
homelab-dovecot's own config (TLS handshake, SASL PLAIN, the SQL passdb
round trip, Maildir storage) end to end. This file previously asserted
ports 143/993 were unreachable from outside the network "confirmed
2026-09-09" — that claim was never re-verified after this same kind of
"external timeout" turned out, on 2026-09-25, to be this admin
workstation's own restricted egress in an unrelated case (port 80 to
this same fleet), not a real fleet-side block. Treat "is the raw
internet path open" as genuinely unknown, not confirmed-closed, until
someone tests it directly from an actual external network the way that
port-80 case eventually was.
"""

import contextlib
import imaplib
import smtplib
import socket
import ssl
import subprocess
import time

import pytest

from conftest import register_account

LOCAL_FORWARD_PORT = 19993
LOCAL_LMTP_FORWARD_PORT = 19024


@contextlib.contextmanager
def _tunnel(ssh_host, local_port, remote_host_port):
    """Forwards local_port on the admin workstation to remote_host_port
    ("host:port") as reachable FROM ssh_host over the internal fleet
    network, via the existing SSH channel — avoids any remote
    shell-quoting entirely (see test_bootstrap_roles.py for why that
    matters) since the actual protocol conversation happens as plain
    local Python code against a forwarded socket, not via a remote python
    invocation threaded through ssh's own argv-joining.

    remote_host_port is deliberately NOT always ssh_host's own loopback:
    IMAPS goes to the real HAProxy VIP (a genuinely different host from
    ssh_host, load-balanced across the real 3-node Dovecot pool); LMTP
    goes to whichever single host Postfix's own virtual_transport
    actually points at (also not necessarily ssh_host). Tunneling
    through ssh_host's loopback instead of the real target was the
    original design here and meant this suite never actually exercised
    the pool or the real delivery path — see env.example.yml's own
    comments on imaps_vip/lmtp_target for the full story.
    """
    proc = subprocess.Popen(
        ["ssh", "-N", "-L", f"{local_port}:{remote_host_port}", ssh_host],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", local_port), timeout=1):
                    break
            except OSError:
                time.sleep(0.3)
        else:
            raise RuntimeError(f"SSH port-forward to {remote_host_port} never came up")
        yield local_port
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def _imaps_tunnel(haproxy_host, imaps_vip):
    # Jumps through haproxy_host (ct00, the HAProxy host itself), not the
    # general ssh_host -- confirmed live that ssh_host's own egress
    # firewall has no rule for port 993 at all (see env.example.yml's
    # own comment on haproxy_host for the full story).
    return _tunnel(haproxy_host, LOCAL_FORWARD_PORT, imaps_vip)


def _lmtp_tunnel(postfix_host, lmtp_target):
    # Jumps through postfix_host, a real Postfix host -- its own
    # virtual_transport is the actual, legitimate caller of lmtp_target
    # in this fleet (see env.example.yml's own comment on postfix_host).
    return _tunnel(postfix_host, LOCAL_LMTP_FORWARD_PORT, lmtp_target)


@pytest.fixture(scope="module")
def mail_account(ssh_host):
    """Registers a fresh, real homelab-api account for this test run —
    the SAME registration path homelab-drive's login proxies through
    (Homelab::Common::AuthClient), so a pass here genuinely proves
    unified identity rather than a mail-specific test fixture."""
    email = f"e2e-dovecot-{int(time.time())}@test.mailmasker.org"
    password = "E2eDovecotTest1Aa"
    register_account(ssh_host, email, password)
    return email, password


def _connect(port):
    ctx = ssl.create_default_context()
    # Self-signed cert (dovecot-core's default snakeoil) until the
    # upstream firewall opens 80/443 and homelab-webproxy's Let's
    # Encrypt flow can reach this host too — see webproxy/README.md.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return imaplib.IMAP4_SSL("127.0.0.1", port, ssl_context=ctx)


def test_imap_login_against_sql_passdb(haproxy_host, imaps_vip, mail_account):
    email, password = mail_account
    with _imaps_tunnel(haproxy_host, imaps_vip) as port:
        m = _connect(port)
        try:
            typ, _ = m.login(email, password)
            assert typ == "OK", "SQL passdb rejected a real, just-registered homelab-api account"

            typ, _ = m.select("INBOX")
            assert typ == "OK", (
                "SELECT INBOX failed -- check mail_inbox_path in "
                "conf.d/91-homelab-dovecot.conf (see README.md Gotchas)"
            )

            subject = f"Subject: e2e check {email}\r\n\r\nhomelab-dovecot e2e test message.\r\n"
            typ, _ = m.append("INBOX", None, None, subject.encode())
            assert typ == "OK"

            typ, data = m.search(None, "ALL")
            assert typ == "OK"
            assert len(data[0].split()) >= 1, "the message just appended was not found by SEARCH"
        finally:
            with contextlib.suppress(Exception):
                m.logout()


def test_wrong_password_rejected(haproxy_host, imaps_vip, mail_account):
    email, _ = mail_account
    with _imaps_tunnel(haproxy_host, imaps_vip) as port:
        m = _connect(port)
        with pytest.raises(imaplib.IMAP4.error):
            m.login(email, "definitely-wrong-password")
        with contextlib.suppress(Exception):
            m.logout()


def test_lmtp_delivery(haproxy_host, imaps_vip, postfix_host, lmtp_target, mail_account):
    """The actual regression test for the auth_username_format gotcha —
    goes over real LMTP (what homelab-postfix's virtual_transport uses),
    not IMAP, so it fails the same way a real inbound email would if
    the domain-stripping default ever comes back. Then confirms the
    message is genuinely visible over IMAP afterward, not just that the
    LMTP command exited 0."""
    email, password = mail_account
    marker = f"e2e-lmtp-{int(time.time())}"

    with _lmtp_tunnel(postfix_host, lmtp_target) as port:
        lmtp = smtplib.LMTP()
        lmtp.connect("127.0.0.1", port)
        lmtp.helo("e2e-test-client")
        try:
            result = lmtp.sendmail(
                "sender@example.com", [email],
                f"Subject: {marker}\r\n\r\nhomelab-dovecot LMTP e2e test.\r\n".encode(),
            )
            assert result == {}, f"LMTP delivery was not fully accepted: {result}"
        finally:
            with contextlib.suppress(Exception):
                lmtp.quit()

    with _imaps_tunnel(haproxy_host, imaps_vip) as port:
        m = _connect(port)
        try:
            typ, _ = m.login(email, password)
            assert typ == "OK"
            typ, _ = m.select("INBOX")
            assert typ == "OK"
            typ, data = m.search(None, "SUBJECT", marker)
            assert typ == "OK"
            assert len(data[0].split()) >= 1, "the LMTP-delivered message was not found via IMAP SEARCH"
        finally:
            with contextlib.suppress(Exception):
                m.logout()


def test_lmtp_rejects_unknown_recipient(postfix_host, lmtp_target):
    """A recipient that doesn't exist in api.users must be rejected at
    the protocol level (550), not silently accepted and dropped —
    matters once homelab-postfix relies on this to decide accept/reject
    at RCPT TO time for real inbound mail."""
    with _lmtp_tunnel(postfix_host, lmtp_target) as port:
        lmtp = smtplib.LMTP()
        lmtp.connect("127.0.0.1", port)
        lmtp.helo("e2e-test-client")
        try:
            with pytest.raises(smtplib.SMTPRecipientsRefused):
                lmtp.sendmail(
                    "sender@example.com", ["definitely-not-a-real-user@test.mailmasker.org"],
                    b"Subject: should be rejected\r\n\r\nbody\r\n",
                )
        finally:
            with contextlib.suppress(Exception):
                lmtp.quit()


def test_userdb_resolves_shared_vmail_uid(dovecot_host, mail_account):
    """Regression test for the first_valid_uid gotcha specifically —
    confirms the account resolves to the fixed vmail uid/gid (5000),
    not whatever adduser --system happened to auto-allocate. Runs
    directly on a real Dovecot pool member (doveadm isn't installed on
    ssh_host in general -- see conftest.py's dovecot_host fixture)."""
    email, _ = mail_account
    result = subprocess.run(
        ["ssh", dovecot_host, "sudo", "doveadm", "user", email],
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 0, f"doveadm user lookup failed: {result.stderr}"
    assert "uid\t5000" in result.stdout, f"expected uid 5000 (vmail), got:\n{result.stdout}"
    assert "gid\t5000" in result.stdout, f"expected gid 5000 (vmail), got:\n{result.stdout}"
