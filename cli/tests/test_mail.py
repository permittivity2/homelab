from unittest.mock import MagicMock, patch

import pytest
import smtplib

from homelab_cli import mail as mailmod


def test_xoauth2_string_format():
    s = mailmod._xoauth2_string("you@example.com", "the-jwt")
    assert s == "user=you@example.com\x01auth=Bearer the-jwt\x01\x01"


def test_list_messages_authenticates_with_xoauth2_and_parses_headers():
    fake_imap = MagicMock()
    fake_imap.search.return_value = ("OK", [b"1 2"])
    fake_imap.fetch.side_effect = [
        ("OK", [(b"1 (BODY[...])", b"From: a@x.com\r\nSubject: Hi\r\nDate: Mon\r\n\r\n")]),
        ("OK", [(b"2 (BODY[...])", b"From: b@x.com\r\nSubject: Yo\r\nDate: Tue\r\n\r\n")]),
    ]

    with patch("imaplib.IMAP4_SSL", return_value=fake_imap) as m:
        messages = mailmod.list_messages("imap.example.com", 993, "you@example.com", "the-jwt", limit=20)

    m.assert_called_once()
    assert m.call_args.args[0] == "imap.example.com"
    assert m.call_args.args[1] == 993

    # authenticate() was called with "XOAUTH2" and a callback that
    # produces the correct SASL response bytes when invoked (imaplib
    # calls it once per challenge; XOAUTH2 needs exactly one round trip).
    fake_imap.authenticate.assert_called_once()
    mechanism, callback = fake_imap.authenticate.call_args.args
    assert mechanism == "XOAUTH2"
    assert callback(b"") == b"user=you@example.com\x01auth=Bearer the-jwt\x01\x01"

    fake_imap.select.assert_called_once_with("INBOX")
    fake_imap.logout.assert_called_once()

    assert len(messages) == 2
    assert messages[0] == {"uid": "1", "from": "a@x.com", "subject": "Hi", "date": "Mon"}
    assert messages[1] == {"uid": "2", "from": "b@x.com", "subject": "Yo", "date": "Tue"}


def test_list_messages_logs_out_even_if_fetch_raises():
    fake_imap = MagicMock()
    fake_imap.search.return_value = ("OK", [b"1"])
    fake_imap.fetch.side_effect = RuntimeError("boom")

    with patch("imaplib.IMAP4_SSL", return_value=fake_imap):
        with pytest.raises(RuntimeError):
            mailmod.list_messages("imap.example.com", 993, "you@example.com", "the-jwt")

    fake_imap.logout.assert_called_once()


def test_read_message_extracts_plain_text_body():
    raw = b"From: a@x.com\r\nSubject: Hi\r\nDate: Mon\r\n\r\nHello there\r\n"
    fake_imap = MagicMock()
    fake_imap.fetch.return_value = ("OK", [(b"1 (RFC822 {n}", raw)])

    with patch("imaplib.IMAP4_SSL", return_value=fake_imap):
        message = mailmod.read_message("imap.example.com", 993, "you@example.com", "the-jwt", "1")

    assert message["from"] == "a@x.com"
    assert message["subject"] == "Hi"
    assert "Hello there" in message["body"]
    fake_imap.logout.assert_called_once()


def test_read_message_returns_none_for_missing_uid():
    fake_imap = MagicMock()
    fake_imap.fetch.return_value = ("NO", [None])

    with patch("imaplib.IMAP4_SSL", return_value=fake_imap):
        message = mailmod.read_message("imap.example.com", 993, "you@example.com", "the-jwt", "999")

    assert message is None


def test_send_message_authenticates_and_sends():
    fake_smtp = MagicMock()
    fake_smtp.docmd.return_value = (235, b"Authentication successful")

    with patch("smtplib.SMTP", return_value=fake_smtp) as m:
        mailmod.send_message("smtp.example.com", 587, "you@example.com", "the-jwt", "them@x.com", "Subject", "Body text")

    m.assert_called_once()
    assert m.call_args.args[0] == "smtp.example.com"
    assert m.call_args.args[1] == 587

    fake_smtp.starttls.assert_called_once()
    auth_call = fake_smtp.docmd.call_args
    assert auth_call.args[0] == "AUTH"
    assert auth_call.args[1].startswith("XOAUTH2 ")

    fake_smtp.send_message.assert_called_once()
    sent_msg = fake_smtp.send_message.call_args.args[0]
    assert sent_msg["To"] == "them@x.com"
    assert sent_msg["Subject"] == "Subject"
    assert sent_msg["From"] == "you@example.com"
    # Regression check: EmailMessage does NOT add these on its own —
    # a real sent-then-read-back message once came back with a
    # completely empty Date header because of exactly that.
    assert sent_msg["Date"], "Date header must be set explicitly"
    assert sent_msg["Message-ID"], "Message-ID header must be set explicitly"

    fake_smtp.quit.assert_called_once()


def test_send_message_raises_on_auth_failure():
    fake_smtp = MagicMock()
    fake_smtp.docmd.return_value = (535, b"Authentication failed")

    with patch("smtplib.SMTP", return_value=fake_smtp):
        with pytest.raises(smtplib.SMTPAuthenticationError):
            mailmod.send_message("smtp.example.com", 587, "you@example.com", "bad-jwt", "them@x.com", "Subject", "Body")

    # Even on failure, the connection must still be closed, not leaked.
    fake_smtp.quit.assert_called_once()
