"""Phase 6 (mail stack) regression test: real SMTP against homelab-postfix
— recipient validation, SASL delegation to Dovecot, the anti-open-relay
restrictions, and a full inbound send that lands in a real mailbox via
LMTP (see homelab-dovecot's own test_lmtp_delivery for the delivery
mechanism itself; this file is about what gets ACCEPTED at the SMTP
level before that handoff ever happens).

test_unauthenticated_relay_is_denied is the most important test in this
file, not the most interesting one: it's the regression test for
accidentally configuring an open relay, which is a real, easy-to-get-
wrong mistake (see postfix/README.md for how permit_mynetworks nearly
produced a false pass here during development — testing an "external"
recipient from the admin workstation's own SSH session to the target
host is worthless, since that connection originates from 127.0.0.1,
which legitimately matches mynetworks; this test connects through the
submission service with TLS and deliberately withholds AUTH instead, so
mynetworks can't accidentally mask a real relay-restriction bug).

Manually verified during development but NOT re-exercised by this
automated suite (both deliberately — see the reasoning in each case):
  - Real outbound delivery to the actual internet (tested once against
    Gmail's real mail servers — a message to a deliberately-nonexistent
    address bounced with a genuine 550 from gmail-smtp-in.l.google.com,
    proving outbound port 25 is not blocked by this host's firewall).
    Not automated: repeatedly hitting a real external mail provider from
    a CI-style suite risks spam-reputation consequences neither this
    project nor Gmail should have to deal with for a test assertion.
  - Real inbound delivery from the actual internet. Blocked by the same
    upstream firewall issue documented for ports 80/443/143/993 (see
    webproxy/README.md and dovecot/test_dovecot_login.py) — port 25
    inbound is unreachable from outside this network until that's
    resolved. The SMTP-level behavior this firewall gap would otherwise
    hide is still fully exercised here, over the SSH tunnel, exactly
    like the inbound path would see it once the firewall opens.
"""

import contextlib
import imaplib
import smtplib
import socket
import ssl
import subprocess
import time

import pytest

LOCAL_SMTP_PORT = 19025
LOCAL_SUBMISSION_PORT = 19587
LOCAL_IMAPS_PORT = 19994


@contextlib.contextmanager
def _tunnel(ssh_host, local_port, remote_port):
    """Same reasoning as homelab-dovecot's own _tunnel: the SMTP
    conversation happens as plain local Python against a forwarded
    socket, over the existing SSH channel, never through a remote
    python/openssl invocation threaded through ssh's own argv-joining."""
    proc = subprocess.Popen(
        ["ssh", "-N", "-L", f"{local_port}:127.0.0.1:{remote_port}", ssh_host],
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
            raise RuntimeError(f"SSH port-forward to {remote_port} never came up")
        yield local_port
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def _tls_context():
    # Self-signed cert (dovecot-core's default snakeoil, reused for
    # postfix's smtpd_tls_cert_file too) until the upstream firewall
    # opens 80/443 and homelab-webproxy's Let's Encrypt flow can reach
    # this host — see webproxy/README.md.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


@pytest.fixture(scope="module")
def mail_account(ssh_host):
    """A fresh, real homelab-api account — the same registration path
    homelab-drive's HTTP login and homelab-dovecot's IMAP login both
    already prove unified identity against."""
    email = f"e2e-postfix-{int(time.time())}@test.mailmasker.org"
    password = "E2ePostfixTest1Aa"
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "register", email, "--password", password],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"test account registration failed: {result.stderr}"
    return email, password


def test_valid_recipient_accepted(ssh_host, mail_account):
    email, _ = mail_account
    with _tunnel(ssh_host, LOCAL_SMTP_PORT, 25) as port:
        s = smtplib.SMTP("127.0.0.1", port, timeout=10)
        try:
            s.ehlo("e2e-test-client")
            s.mail("e2e-sender@example.com")
            code, msg = s.rcpt(email)
            assert code == 250, f"a real, active recipient was rejected: {code} {msg}"
        finally:
            with contextlib.suppress(Exception):
                s.quit()


def test_invalid_recipient_rejected(ssh_host):
    """The actual anti-backscatter check: an address that isn't a real
    account must be rejected at RCPT TO, before Postfix ever accepts
    the message body — see postfix/README.md on virtual_mailbox_maps'
    role here (existence-check only, never a delivery path).

    Asserts on the returned code directly rather than expecting an
    exception: smtplib.SMTP.rcpt() returns (code, message) for ANY
    response, success or failure — it never raises
    SMTPRecipientsRefused itself (only the higher-level sendmail() /
    sendmail-style helpers do). An earlier version of this test wrapped
    rcpt() in pytest.raises(SMTPRecipientsRefused) and passed for the
    wrong reason during development, while a real, unrelated PgBouncer
    connection-pool issue was independently producing exceptions of its
    own — see postfix/README.md's Gotchas section."""
    with _tunnel(ssh_host, LOCAL_SMTP_PORT, 25) as port:
        s = smtplib.SMTP("127.0.0.1", port, timeout=10)
        try:
            s.ehlo("e2e-test-client")
            s.mail("e2e-sender@example.com")
            code, msg = s.rcpt("definitely-not-a-real-account@test.mailmasker.org")
            assert code in (550, 554), f"an unknown recipient was not rejected: {code} {msg}"
        finally:
            with contextlib.suppress(Exception):
                s.quit()


def test_unauthenticated_relay_is_denied(ssh_host):
    """The open-relay regression test — see this file's module
    docstring for why it goes through the submission service with TLS
    and no AUTH, not port 25 from the admin workstation's own SSH
    session (which would falsely pass via permit_mynetworks). See
    test_invalid_recipient_rejected's docstring for why this asserts on
    the returned code rather than expecting rcpt() to raise."""
    with _tunnel(ssh_host, LOCAL_SUBMISSION_PORT, 587) as port:
        s = smtplib.SMTP("127.0.0.1", port, timeout=10)
        try:
            s.ehlo("e2e-test-client")
            s.starttls(context=_tls_context())
            s.ehlo("e2e-test-client")
            s.mail("e2e-sender@example.com")
            code, msg = s.rcpt("someone-external@example.com")
            assert code in (550, 554), f"an unauthenticated relay attempt was not denied: {code} {msg}"
        finally:
            with contextlib.suppress(Exception):
                s.quit()


def test_authenticated_relay_is_permitted(ssh_host, mail_account):
    """Confirms SASL delegation to Dovecot actually grants relay
    permission for an external recipient — deliberately stops at RCPT
    TO acceptance (no DATA phase) so this doesn't queue a real outbound
    message; see the module docstring for why real outbound delivery is
    verified manually, not by this automated suite."""
    email, password = mail_account
    with _tunnel(ssh_host, LOCAL_SUBMISSION_PORT, 587) as port:
        s = smtplib.SMTP("127.0.0.1", port, timeout=10)
        try:
            s.ehlo("e2e-test-client")
            s.starttls(context=_tls_context())
            s.ehlo("e2e-test-client")
            s.login(email, password)
            s.mail(email)
            code, msg = s.rcpt("someone-external@example.com")
            assert code == 250, f"an authenticated user was denied relay to an external address: {code} {msg}"
        finally:
            with contextlib.suppress(Exception):
                s.quit()


def test_inbound_smtp_delivers_to_real_mailbox(ssh_host, mail_account):
    """The actual end-to-end proof: a full SMTP conversation (not just
    RCPT TO validation) from an unauthenticated, inbound-style
    connection, verified to have actually landed in the recipient's
    mailbox via LMTP — not just that Postfix's queue accepted it."""
    email, password = mail_account
    marker = f"e2e-postfix-inbound-{int(time.time())}"

    with _tunnel(ssh_host, LOCAL_SMTP_PORT, 25) as port:
        s = smtplib.SMTP("127.0.0.1", port, timeout=10)
        try:
            result = s.sendmail(
                "e2e-sender@example.com", [email],
                f"Subject: {marker}\r\n\r\nhomelab-postfix inbound e2e test.\r\n".encode(),
            )
            assert result == {}, f"inbound delivery was not fully accepted: {result}"
        finally:
            with contextlib.suppress(Exception):
                s.quit()

    with _tunnel(ssh_host, LOCAL_IMAPS_PORT, 993) as port:
        ctx = _tls_context()
        m = imaplib.IMAP4_SSL("127.0.0.1", port, ssl_context=ctx)
        try:
            typ, _ = m.login(email, password)
            assert typ == "OK"
            typ, _ = m.select("INBOX")
            assert typ == "OK"
            typ, data = m.search(None, "SUBJECT", marker)
            assert typ == "OK"
            assert len(data[0].split()) >= 1, (
                "message was accepted by Postfix but never showed up in the mailbox — "
                "check the LMTP handoff (virtual_transport) and homelab-dovecot's own LMTP listener"
            )
        finally:
            with contextlib.suppress(Exception):
                m.logout()
