#!/usr/bin/env python3
"""Post-cutover #70: SMTPS (port 465, implicit TLS) checked from the internet.

Runs ON OFFSITE (smtps-orchestrate.sh copies it there), so every connection
crosses the real edge. Test harness, not shipped code (hence Python);
standard library only. One JSON argument:

  {"host": "mail.mailmasker.org", "account": "...", "ips": ["a.b.c.d", ...]}

The account's password arrives on stdin -- never an argument, never printed.

Per public address: the TLS handshake comes first and the certificate must
verify for HOST (chain and name), a 220 banner inside it, EHLO offers AUTH
and no STARTTLS, an unauthenticated relay attempt is refused; and 587 still
greets in clear and offers STARTTLS. Then once, through HOST: AUTH as the
account over 465, a message to itself, found over IMAPS within 90 s with
ESMTPSA in its Received line (authenticated, inside TLS), and deleted.
"""
import contextlib
import email.utils
import imaplib
import json
import smtplib
import socket
import ssl
import sys
import time

a = json.loads(sys.argv[1])
PW = sys.stdin.readline().rstrip("\n")
HOST, ME, IPS = a["host"], a["account"], a["ips"]
HELO = "smtps70-check.offsite.invalid"

fails = 0


def check(cond, name):
    global fails
    if not cond:
        fails += 1
    print(("ok   " if cond else "FAIL ") + name, flush=True)


ctx = ssl.create_default_context()  # the system CAs; verifies chain and name


class SniSMTPS(smtplib.SMTP_SSL):
    """Connect to ONE address but present and verify HOST (SNI + name check),
    so each edge is tested on its own while the certificate is judged
    against the name clients use."""

    def __init__(self, ip, sni, timeout=20):
        self._sni = sni
        super().__init__(ip, 465, timeout=timeout, context=ctx)

    def _get_socket(self, host, port, timeout):
        sock = socket.create_connection((host, port), timeout)
        return self.context.wrap_socket(sock, server_hostname=self._sni)


for ip in IPS:
    print(f"--- {ip}:465 (SNI {HOST})")
    try:
        s = SniSMTPS(ip, HOST)
    except Exception as e:  # noqa: BLE001 -- report, do not crash
        check(False, f"{ip}: TLS handshake, verified certificate, 220 banner ({e})")
        continue
    check(True, f"{ip}: TLS handshake first, certificate verified, 220 banner inside")
    cert = s.sock.getpeercert()
    names = [v for k, v in cert.get("subjectAltName", ()) if k == "DNS"]
    check(HOST in names, f"{ip}: the certificate names {HOST}")
    days = (ssl.cert_time_to_seconds(cert["notAfter"]) - time.time()) / 86400
    check(days > 7, f"{ip}: certificate valid for {days:.0f} more days")
    code, _ = s.ehlo(HELO)
    check(code == 250 and s.has_extn("auth"), f"{ip}: EHLO inside TLS offers AUTH ({code})")
    check(not s.has_extn("starttls"), f"{ip}: no STARTTLS offered (the session is already TLS)")
    s.mail("smtps70-nobody@example.com")
    code, _ = s.rcpt("someone-external@example.com")
    check(code in (550, 554), f"{ip}: relay without AUTH refused ({code})")
    with contextlib.suppress(Exception):
        s.quit()

    try:
        p = smtplib.SMTP(ip, 587, timeout=20)
        code, _ = p.ehlo(HELO)
        check(code == 250 and p.has_extn("starttls"), f"{ip}:587 still greets in clear and offers STARTTLS")
        with contextlib.suppress(Exception):
            p.quit()
    except Exception as e:  # noqa: BLE001
        check(False, f"{ip}:587 ({e})")

# ------------------------------------------------ the real thing, through HOST
print(f"--- {HOST}:465 as {ME}")
tag = f"smtps70 {int(time.time())}"
msgid = email.utils.make_msgid(domain=ME.split("@")[1])
try:
    s = smtplib.SMTP_SSL(HOST, 465, timeout=30, context=ctx)
    s.ehlo(HELO)
    s.login(ME, PW)
    check(True, "AUTH over 465 accepted")
    body = (f"From: {ME}\r\nTo: {ME}\r\nSubject: {tag}\r\nMessage-ID: {msgid}\r\n"
            f"Date: {email.utils.formatdate(localtime=True)}\r\n\r\n"
            "Sent over port 465 (implicit TLS) from offsite by smtps-check.py (post-cutover #70).\r\n")
    s.sendmail(ME, [ME], body.encode())
    check(True, "a message to myself accepted over 465")
    with contextlib.suppress(Exception):
        s.quit()
except Exception as e:  # noqa: BLE001
    check(False, f"AUTH + send over 465 ({e})")

try:
    m = imaplib.IMAP4_SSL(HOST, 993, ssl_context=ctx, timeout=30)
    m.login(ME, PW)
    m.select("INBOX")
    nums, started = [], time.time()
    while time.time() - started < 90 and not nums:
        typ, data = m.search(None, "SUBJECT", f'"{tag}"')
        nums = data[0].split() if typ == "OK" else []
        if not nums:
            time.sleep(3)
            m.noop()
    check(bool(nums), f"the message arrived in the inbox ({time.time() - started:.0f} s)")
    if nums:
        typ, data = m.fetch(nums[0], "(BODY.PEEK[HEADER.FIELDS (RECEIVED)])")
        received = b"".join(part[1] for part in data if isinstance(part, tuple)).decode("utf-8", "replace")
        check("ESMTPSA" in received, "the pool's Received line says ESMTPSA (authenticated, inside TLS)")
        m.store(nums[0], "+FLAGS", "\\Deleted")
        m.expunge()
        check(True, "test message deleted")
    m.logout()
except Exception as e:  # noqa: BLE001
    check(False, f"IMAPS follow-up ({e})")

print("\n" + ("ALL PASSED" if fails == 0 else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
