"""Direct IMAP/SMTP email access, authenticated via XOAUTH2 using the
CLI's own stored homelab-api JWT as the bearer token — the exact same
mechanism homelab-roundcube's SSO login uses against homelab-dovecot
(see dovecot/README.md and sso/README.md), just without any OAuth
redirect dance: the CLI already holds a JWT from `homelab-cli login`, so
it authenticates directly, no browser involved.

No new server-side API needed for this — homelab-dovecot/homelab-postfix
already speak IMAP/SMTP; this just makes homelab-cli another XOAUTH2
client of them, matching the project's "same identity, every surface"
design (see the root CLAUDE.md).

Known gap, not fixed here: homelab-dovecot and homelab-postfix both
still serve their default self-signed snakeoil TLS certificate on the
real IMAP/SMTP ports (unlike the HTTPS domains, which do have real
Let's Encrypt certs via homelab-webproxy) — verifying against a real CA
would just make every command below fail against the only environment
that currently exists. TLS certificate verification is therefore
deliberately relaxed (connection is still encrypted, just not verified
against a CA) until homelab-dovecot/homelab-postfix are given real
certs as a tracked follow-up.
"""

import base64
import email as email_module
import imaplib
import smtplib
import ssl
from email.message import EmailMessage


def _xoauth2_string(user, token):
    return f"user={user}\x01auth=Bearer {token}\x01\x01"


def _relaxed_ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _imap_connect(host, port, email_address, token):
    conn = imaplib.IMAP4_SSL(host, port, ssl_context=_relaxed_ssl_context())
    conn.authenticate("XOAUTH2", lambda _challenge: _xoauth2_string(email_address, token).encode())
    return conn


def list_messages(host, port, email_address, token, mailbox="INBOX", limit=20):
    conn = _imap_connect(host, port, email_address, token)
    try:
        conn.select(mailbox)
        _typ, data = conn.search(None, "ALL")
        uids = data[0].split()
        messages = []
        for uid in uids[-limit:]:
            _typ, msg_data = conn.fetch(uid, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
            headers = email_module.message_from_bytes(msg_data[0][1])
            messages.append({
                "uid": uid.decode(),
                "from": headers.get("From", ""),
                "subject": headers.get("Subject", ""),
                "date": headers.get("Date", ""),
            })
        return messages
    finally:
        conn.logout()


def read_message(host, port, email_address, token, uid, mailbox="INBOX"):
    conn = _imap_connect(host, port, email_address, token)
    try:
        conn.select(mailbox)
        typ, msg_data = conn.fetch(uid.encode(), "(RFC822)")
        if typ != "OK" or not msg_data or msg_data[0] is None:
            return None
        msg = email_module.message_from_bytes(msg_data[0][1])

        body = ""
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/plain" and not part.get_filename():
                    payload = part.get_payload(decode=True)
                    if payload is not None:
                        body = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
                        break
        else:
            payload = msg.get_payload(decode=True)
            if payload is not None:
                body = payload.decode(msg.get_content_charset() or "utf-8", errors="replace")

        return {"from": msg.get("From", ""), "subject": msg.get("Subject", ""), "date": msg.get("Date", ""), "body": body}
    finally:
        conn.logout()


def send_message(host, port, email_address, token, to, subject, body):
    msg = EmailMessage()
    msg["From"] = email_address
    msg["To"] = to
    msg["Subject"] = subject
    # EmailMessage does NOT add these on its own (unlike higher-level
    # mail libraries) -- found by actually reading a sent message back
    # via `mail read`, not by inspection: the Date header came back
    # completely empty.
    msg["Date"] = email_module.utils.formatdate(localtime=True)
    msg["Message-ID"] = email_module.utils.make_msgid()
    msg.set_content(body)

    conn = smtplib.SMTP(host, port, timeout=15)
    try:
        conn.ehlo()
        conn.starttls(context=_relaxed_ssl_context())
        conn.ehlo()

        auth_string = base64.b64encode(_xoauth2_string(email_address, token).encode()).decode()
        code, response = conn.docmd("AUTH", f"XOAUTH2 {auth_string}")
        if code != 235:
            raise smtplib.SMTPAuthenticationError(code, response)

        conn.send_message(msg)
    finally:
        conn.quit()
