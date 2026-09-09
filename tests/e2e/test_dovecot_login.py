"""Phase 6 (mail stack) regression test: real IMAP login against
homelab-dovecot's SQL passdb, proving the unified cross-feature identity
design for real — a password registered through homelab-api (the same
path homelab-drive's HTTP login uses) authenticates over IMAP with no
separate mail-specific password store, via a narrow column-scoped grant
on api.users (see dovecot/README.md and
dovecot/script/homelab-dovecot-bootstrap-role).

Also stands as the regression test for two real bugs caught building
this package (see dovecot/README.md's Gotchas section for the full
writeup):
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

External connectivity is NOT exercised here — the same upstream firewall
blocker documented for ports 80/443 (see webproxy/README.md) also times
out ports 143/993 from outside the network, confirmed 2026-09-09; ss -tlnp
on the host itself confirms dovecot IS genuinely listening on 0.0.0.0.
This test forwards the real IMAPS port through the existing SSH channel
instead — that still exercises every line of homelab-dovecot's own
config (TLS handshake, SASL PLAIN, the SQL passdb round trip, Maildir
storage) end to end; only "is the host reachable from the raw internet"
is out of scope until that firewall opens.
"""

import contextlib
import imaplib
import socket
import ssl
import subprocess
import time

import pytest

LOCAL_FORWARD_PORT = 19993


@contextlib.contextmanager
def _imaps_tunnel(ssh_host):
    """Forwards LOCAL_FORWARD_PORT on the admin workstation to the
    target's real IMAPS listener (127.0.0.1:993 as seen FROM that host)
    over the existing SSH channel — avoids any remote shell-quoting
    entirely (see test_bootstrap_roles.py for why that matters) since
    the actual IMAP protocol conversation happens as plain local Python
    code against a forwarded socket, not via a remote python/imaplib
    invocation threaded through ssh's own argv-joining."""
    proc = subprocess.Popen(
        ["ssh", "-N", "-L", f"{LOCAL_FORWARD_PORT}:127.0.0.1:993", ssh_host],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", LOCAL_FORWARD_PORT), timeout=1):
                    break
            except OSError:
                time.sleep(0.3)
        else:
            raise RuntimeError("SSH port-forward to 993 never came up")
        yield LOCAL_FORWARD_PORT
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.fixture(scope="module")
def mail_account(ssh_host):
    """Registers a fresh, real homelab-api account for this test run —
    the SAME registration path homelab-drive's login proxies through
    (Homelab::Common::AuthClient), so a pass here genuinely proves
    unified identity rather than a mail-specific test fixture."""
    email = f"e2e-dovecot-{int(time.time())}@test.mailmasker.org"
    password = "E2eDovecotTest1Aa"
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "register", email, "--password", password],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"test account registration failed: {result.stderr}"
    return email, password


def _connect(port):
    ctx = ssl.create_default_context()
    # Self-signed cert (dovecot-core's default snakeoil) until the
    # upstream firewall opens 80/443 and homelab-webproxy's Let's
    # Encrypt flow can reach this host too — see webproxy/README.md.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return imaplib.IMAP4_SSL("127.0.0.1", port, ssl_context=ctx)


def test_imap_login_against_sql_passdb(ssh_host, mail_account):
    email, password = mail_account
    with _imaps_tunnel(ssh_host) as port:
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


def test_wrong_password_rejected(ssh_host, mail_account):
    email, _ = mail_account
    with _imaps_tunnel(ssh_host) as port:
        m = _connect(port)
        with pytest.raises(imaplib.IMAP4.error):
            m.login(email, "definitely-wrong-password")
        with contextlib.suppress(Exception):
            m.logout()


def test_userdb_resolves_shared_vmail_uid(ssh_host, mail_account):
    """Regression test for the first_valid_uid gotcha specifically —
    confirms the account resolves to the fixed vmail uid/gid (5000),
    not whatever adduser --system happened to auto-allocate."""
    email, _ = mail_account
    result = subprocess.run(
        ["ssh", ssh_host, "sudo", "doveadm", "user", email],
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 0, f"doveadm user lookup failed: {result.stderr}"
    assert "uid\t5000" in result.stdout, f"expected uid 5000 (vmail), got:\n{result.stdout}"
    assert "gid\t5000" in result.stdout, f"expected gid 5000 (vmail), got:\n{result.stdout}"
