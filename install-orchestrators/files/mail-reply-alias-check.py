#!/usr/bin/env python3
"""Functional checks for post-cutover #67, "reply from the alias a message was
sent to" -- run on the admin workstation by mail-reply-alias-orchestrate.sh.

Test harness, not shipped code (hence Python). Standard library only.

Modes
  setting show|on|off     read / set the test account's switch through the
                          public api (login as the test account)
  roundtrip --node-ip IP  the whole thing against ONE mail-pool node, through
                          an ssh tunnel to its 587 (the node expects haproxy's
                          PROXY protocol header, so one is sent):
                            1. send a message to the four test aliases
                            2. the milter must record it, chosen = the first
                               alias on the To line (read on the DB leader)
                            3. how many copies Dovecot stored (1 vs 4)
                            4. send a "reply" (In-Reply-To) From the account
                            5. the delivered copy must be From the alias, with
                               Return-Path = the alias and a DKIM signature for
                               the alias domain
                            6. negatives: switch off -> untouched; a foreign
                               In-Reply-To -> untouched; From already an alias
                               -> untouched
                          Test messages are deleted from the inbox afterwards
                          (--keep to leave them).
  count --subject X       list/count inbox messages whose Subject contains X
                          (the external four-alias test: 1 copy or 4?)

The account password is read from --password-file inside this program; it is
never an argument and never printed.
"""

import argparse
import contextlib
import email
import email.message
import email.policy
import email.utils
import imaplib
import json
import os
import random
import smtplib
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULT_ALIASES = [
    "claude67a@forge.name",
    "claude67b@forge.name",
    "claude67a@giraffenow.org",
    "claude67b@giraffenow.org",
]

FAILURES = []


def report(ok, what, detail=""):
    tag = "PASS" if ok else "FAIL"
    line = f"  {tag}  {what}"
    if detail:
        line += f"  -- {detail}"
    print(line, flush=True)
    if not ok:
        FAILURES.append(what)
    return ok


# ----------------------------------------------------------------- api --

def api(base, method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"error": raw.decode(errors="replace")}


def login(base, account, password):
    status, body = api(base, "POST", "/api/v1/auth/login", body={"email": account, "password": password})
    if status != 200 or not body.get("token"):
        sys.exit(f"login as {account} failed: HTTP {status} {body.get('error', '')}")
    return body["token"]


def setting_get(base, token):
    status, body = api(base, "GET", "/api/v1/domains/mail-reply-identity/mine", token=token)
    if status != 200:
        sys.exit(f"GET mail-reply-identity/mine: HTTP {status} {body}")
    return bool(body.get("reply_from_alias")), body


def setting_set(base, token, on):
    status, body = api(base, "PUT", "/api/v1/domains/mail-reply-identity/mine", token=token,
                       body={"reply_from_alias": bool(on)})
    if status != 200:
        sys.exit(f"PUT mail-reply-identity/mine: HTTP {status} {body}")
    return bool(body.get("reply_from_alias"))


# ---------------------------------------------------------------- smtp --

class ProxySMTP(smtplib.SMTP):
    """smtplib.SMTP that writes a haproxy PROXY protocol v1 line before the
    greeting. The mail pool's smtpd has smtpd_upstream_proxy_protocol=haproxy
    on every listener (haproxy on the edges fronts them), so a direct
    connection must speak it too or Postfix never says 220."""

    def __init__(self, host, port, proxy_line, timeout=30):
        self._proxy_line = proxy_line
        super().__init__(host, port, timeout=timeout)

    def _get_socket(self, host, port, timeout):
        sock = super()._get_socket(host, port, timeout)
        sock.sendall(self._proxy_line)
        return sock


@contextlib.contextmanager
def tunnel(ssh_host, local_port, remote_port):
    proc = subprocess.Popen(
        ["ssh", "-N", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-L", f"{local_port}:127.0.0.1:{remote_port}", ssh_host],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", local_port), timeout=1):
                    break
            except OSError:
                time.sleep(0.3)
        else:
            raise RuntimeError(f"ssh port-forward to {ssh_host}:{remote_port} never came up")
        yield
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def noverify_context():
    # The node's certificate is for mail.mailmasker.org; through the tunnel we
    # connect to 127.0.0.1. Our own server, over our own ssh channel.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def build_message(from_hdr, to_hdr, subject, msgid, body, in_reply_to=None, reply_to=None):
    msg = email.message.EmailMessage(policy=email.policy.SMTP)
    msg["From"] = from_hdr
    msg["To"] = to_hdr
    msg["Subject"] = subject
    msg["Message-ID"] = msgid
    msg["Date"] = email.utils.formatdate(localtime=True)
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
        msg["References"] = in_reply_to
    if reply_to:
        msg["Reply-To"] = reply_to
    msg.set_content(body)
    return msg


def submit(args, password, envelope_from, rcpts, msg):
    proxy_line = f"PROXY TCP4 {args.src_ip} {args.node_ip} {random.randint(20000, 60000)} 587\r\n".encode()
    with tunnel(args.node_ip, args.local_port, 587):
        s = ProxySMTP("127.0.0.1", args.local_port, proxy_line)
        try:
            s.ehlo("reply67-check.homelab.invalid")
            s.starttls(context=noverify_context())
            s.ehlo("reply67-check.homelab.invalid")
            s.login(args.account, password)
            s.sendmail(envelope_from, rcpts, msg.as_bytes())
        finally:
            with contextlib.suppress(Exception):
                s.quit()


# ---------------------------------------------------------------- imap --

HEADERS = "From Return-Path DKIM-Signature Reply-To Sender To Delivered-To In-Reply-To Subject Message-ID"


def imap_connect(args, password):
    ctx = ssl.create_default_context()
    m = imaplib.IMAP4_SSL(args.imap_host, args.imap_port, ssl_context=ctx, timeout=30)
    m.login(args.account, password)
    m.select("INBOX")
    return m


def imap_find(m, criterion):
    typ, data = m.search(None, criterion)
    if typ != "OK":
        return []
    return [n for n in data[0].split() if n]


def imap_headers(m, num):
    typ, data = m.fetch(num, f"(BODY.PEEK[HEADER.FIELDS ({HEADERS})])")
    if typ != "OK":
        return None
    for part in data:
        if isinstance(part, tuple):
            return email.message_from_bytes(part[1], policy=email.policy.default)
    return None


def imap_text(m, num):
    """The decoded text/plain content of one stored message (every text/plain
    leaf joined) -- where the milter's footer lines end up."""
    typ, data = m.fetch(num, "(BODY.PEEK[])")
    if typ != "OK":
        return ""
    raw = b""
    for part in data:
        if isinstance(part, tuple):
            raw = part[1]
            break
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    texts = []
    for part in msg.walk():
        if part.get_content_type() == "text/plain":
            try:
                texts.append(part.get_content())
            except Exception:  # an undecodable part is not what we are testing
                pass
    return "\n".join(texts)


def reply_line(alias):
    """The footer line block-link 0.2.2 writes under a message that came to an alias."""
    return f"Reply from the alias: a reply to this message goes out from {alias}."


def wait_for(m, criterion, timeout=90, want=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        m.noop()
        nums = imap_find(m, criterion)
        if len(nums) >= want:
            # a moment for the second copy, if a second copy is coming
            time.sleep(2)
            m.noop()
            return imap_find(m, criterion)
        time.sleep(2)
    return imap_find(m, criterion)


def imap_delete(m, nums):
    for n in nums:
        m.store(n, "+FLAGS", "\\Deleted")
    if nums:
        m.expunge()


def addr_of(value):
    if not value:
        return ""
    return (email.utils.parseaddr(str(value))[1] or "").lower()


# ------------------------------------------------------------------ db --

def leader_sql(args, sql):
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", args.leader_ip,
         "sudo -u postgres psql -d homelab -X -q -tA -v ON_ERROR_STOP=1"],
        input=sql, capture_output=True, text=True, timeout=60,
    )
    if r.returncode != 0:
        raise RuntimeError(f"psql on the leader failed: {r.stderr.strip()}")
    return r.stdout.strip()


def wait_for_record(args, account, msgid_bare, timeout=45):
    deadline = time.time() + timeout
    sql = ("SELECT chosen || '|' || chosen_via FROM domainadmin.mail_received_via "
           f"WHERE account = '{account}' AND message_id = '{msgid_bare}'")
    while time.time() < deadline:
        out = leader_sql(args, sql)
        if out:
            return out
        time.sleep(2)
    return ""


# --------------------------------------------------------------- modes --

def mode_setting(args, password):
    token = login(args.api_base, args.account, password)
    if args.action in ("on", "off"):
        now = setting_set(args.api_base, token, args.action == "on")
        report(now == (args.action == "on"), f"setting switched {args.action}", f"api says {now}")
    on, body = setting_get(args.api_base, token)
    print(f"  reply_from_alias={on} updated_at={body.get('updated_at')}")


def mode_count(args, password):
    m = imap_connect(args, password)
    nums = imap_find(m, f'HEADER Subject "{args.subject}"')
    print(f"  {len(nums)} message(s) with Subject containing '{args.subject}'")
    for n in nums:
        h = imap_headers(m, n)
        if h is None:
            continue
        print(f"  - Message-ID {h.get('Message-ID')}")
        for k in ("From", "To", "Delivered-To", "Return-Path", "Reply-To"):
            if h.get(k):
                print(f"      {k}: {h.get(k)}")
    m.logout()


def mode_reply(args, password):
    """Send one reply From the account (as a phone would) to --to, answering
    --in-reply-to, through --node-ip's 587. The rewrite happens on the server;
    the receiving side (e.g. Gardner's Gmail) shows the result. If --to is the
    account itself the delivered copy's headers are printed."""
    token = login(args.api_base, args.account, password)
    setting_set(args.api_base, token, True)
    account = args.account.lower()
    msgid = f"<reply67-manual-{time.strftime('%Y%m%d-%H%M%S')}-{random.randint(1000, 9999)}@check.homelab.invalid>"
    msg = build_message(f"Test Account <{account}>", args.to, args.subject, msgid,
                        args.body + "\n", in_reply_to=args.in_reply_to)
    submit(args, password, account, [args.to], msg)
    print(f"  sent {msgid} In-Reply-To {args.in_reply_to} to {args.to} via {args.node_ip}")
    if args.to.lower() == account:
        m = imap_connect(args, password)
        nums = wait_for(m, f'HEADER Message-ID "{msgid}"')
        for n in nums:
            h = imap_headers(m, n)
            for k in ("From", "Return-Path", "Reply-To", "DKIM-Signature"):
                if h.get(k):
                    print(f"      {k}: {str(h.get(k))[:160]}")
        m.logout()


def mode_roundtrip(args, password):
    aliases = args.alias or DEFAULT_ALIASES
    first_alias = aliases[0].lower()
    alias_domain = first_alias.split("@", 1)[1]
    ts = time.strftime("%Y%m%d-%H%M%S")
    tag = f"{ts}-{random.randint(1000, 9999)}"
    account = args.account.lower()
    display = "Test Account"
    created_ids = []

    token = login(args.api_base, args.account, password)
    setting_set(args.api_base, token, True)
    on, _ = setting_get(args.api_base, token)
    report(on, "switch is ON for the test account")

    # 1. the "original", to all four aliases, first alias first on the To line
    msgid1 = f"<reply67-orig-{tag}@check.homelab.invalid>"
    created_ids.append(msgid1)
    original = build_message(f"Outside Sender <{account}>", ", ".join(aliases),
                             f"reply67 original {tag}", msgid1,
                             "Original message addressed to four aliases of one mailbox.\n")
    submit(args, password, account, aliases, original)
    print(f"  sent original {msgid1} to {len(aliases)} aliases via {args.node_ip}")

    # 2. the record
    rec = wait_for_record(args, account, msgid1.strip("<>"))
    report(bool(rec), "milter recorded the original", rec or "no row within 45 s")
    if rec:
        chosen, via = rec.split("|", 1)
        report(chosen == first_alias and via == "to",
               "chosen = first of our aliases on the To line", f"chosen={chosen} via={via}")

    # 3. copies stored
    m = imap_connect(args, password)
    nums1 = wait_for(m, f'HEADER Message-ID "{msgid1}"')
    report(len(nums1) >= 1, "original delivered to the test mailbox", f"{len(nums1)} stored cop{'y' if len(nums1) == 1 else 'ies'} for {len(aliases)} recipients")
    if nums1:
        h = imap_headers(m, nums1[0])
        print(f"      To: {h.get('To')}")
        print(f"      Delivered-To: {h.get('Delivered-To')}")
        # 3b. the footer line (block-link 0.2.2): switch on, one account, came to an alias
        text = imap_text(m, nums1[0])
        line = reply_line(first_alias)
        if report(line in text, "footer line names the chosen alias", line if line in text else f"text ends: ...{text[-160:]!r}"):
            block = text.find("Manage blocked addresses")
            if block >= 0:
                report(text.find(line) < block, "footer line sits above the blocked-addresses line")

    # 4./5. the reply, From the login address, must leave as the alias
    msgid2 = f"<reply67-reply-{tag}@check.homelab.invalid>"
    created_ids.append(msgid2)
    reply = build_message(f"{display} <{account}>", account, f"reply67 reply {tag}", msgid2,
                          "A reply, sent the way a phone sends it: From the account's primary address.\n",
                          in_reply_to=msgid1)
    submit(args, password, account, [account], reply)
    nums2 = wait_for(m, f'HEADER Message-ID "{msgid2}"')
    if report(len(nums2) >= 1, "reply delivered", f"{len(nums2)} copy"):
        h = imap_headers(m, nums2[0])
        from_hdr = str(h.get("From") or "")
        report(addr_of(from_hdr) == first_alias, "reply From is the alias", f"From: {from_hdr}")
        report(display in from_hdr, "display name kept", from_hdr)
        report(addr_of(h.get("Return-Path")) == first_alias, "Return-Path (envelope sender) is the alias",
               f"Return-Path: {h.get('Return-Path')}")
        dkim = str(h.get("DKIM-Signature") or "").replace("\n", " ")
        report(f"d={alias_domain}" in dkim.replace(" ", ""), "DKIM-signed for the alias domain",
               f"d= in: {dkim[:120]}..." if dkim else "no DKIM-Signature header")
        report(str(h.get("In-Reply-To") or "").strip() == msgid1, "threading header untouched", str(h.get("In-Reply-To")))
        # this reply was addressed to the REAL address: nothing changes for it, so no footer line
        report("Reply from the alias:" not in imap_text(m, nums2[0]), "a message to the real address gets no footer line")

    # 6a. switch off -> untouched
    setting_set(args.api_base, token, False)
    msgid3 = f"<reply67-off-{tag}@check.homelab.invalid>"
    created_ids.append(msgid3)
    submit(args, password, account, [account],
           build_message(f"{display} <{account}>", account, f"reply67 switch-off {tag}", msgid3,
                         "Reply with the switch OFF: must stay From the primary address.\n", in_reply_to=msgid1))
    nums3 = wait_for(m, f'HEADER Message-ID "{msgid3}"')
    if report(len(nums3) >= 1, "switch-off reply delivered"):
        h = imap_headers(m, nums3[0])
        report(addr_of(h.get("From")) == account, "switch OFF: From left alone", f"From: {h.get('From')}")
        report(addr_of(h.get("Return-Path")) == account, "switch OFF: Return-Path left alone", f"Return-Path: {h.get('Return-Path')}")
    # 6a'. switch still off: a new original to the aliases gets no footer line
    msgid6 = f"<reply67-off-orig-{tag}@check.homelab.invalid>"
    created_ids.append(msgid6)
    submit(args, password, account, aliases,
           build_message(f"Outside Sender <{account}>", ", ".join(aliases), f"reply67 switch-off original {tag}", msgid6,
                         "Original to the aliases with the switch OFF: must carry no footer line.\n"))
    nums6 = wait_for(m, f'HEADER Message-ID "{msgid6}"')
    if report(len(nums6) >= 1, "switch-off original delivered"):
        report("Reply from the alias:" not in imap_text(m, nums6[0]), "switch OFF: no footer line")
    setting_set(args.api_base, token, True)

    # 6b. a foreign In-Reply-To -> untouched
    msgid4 = f"<reply67-foreign-{tag}@check.homelab.invalid>"
    created_ids.append(msgid4)
    submit(args, password, account, [account],
           build_message(f"{display} <{account}>", account, f"reply67 foreign {tag}", msgid4,
                         "Reply to a message nobody recorded: must stay From the primary address.\n",
                         in_reply_to=f"<nobody-knows-this-{tag}@example.invalid>"))
    nums4 = wait_for(m, f'HEADER Message-ID "{msgid4}"')
    if report(len(nums4) >= 1, "foreign-In-Reply-To reply delivered"):
        h = imap_headers(m, nums4[0])
        report(addr_of(h.get("From")) == account, "unknown original: From left alone", f"From: {h.get('From')}")

    # 6c. From already an alias (a Roundcube identity would do this) -> untouched
    other_alias = aliases[1].lower() if len(aliases) > 1 else first_alias
    msgid5 = f"<reply67-identity-{tag}@check.homelab.invalid>"
    created_ids.append(msgid5)
    submit(args, password, other_alias, [account],
           build_message(f"{display} <{other_alias}>", account, f"reply67 identity {tag}", msgid5,
                         "Reply already From an alias (chosen by the user): must not be changed to another one.\n",
                         in_reply_to=msgid1))
    nums5 = wait_for(m, f'HEADER Message-ID "{msgid5}"')
    if report(len(nums5) >= 1, "already-From-alias reply delivered"):
        h = imap_headers(m, nums5[0])
        report(addr_of(h.get("From")) == other_alias, "From already an alias: left alone", f"From: {h.get('From')}")

    if not args.keep:
        todel = []
        for mid in created_ids:
            todel += imap_find(m, f'HEADER Message-ID "{mid}"')
        imap_delete(m, todel)
        print(f"  deleted {len(todel)} test message(s) from the inbox")
    m.logout()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--account", default="testaccountforclaude@mailmasker.org")
    p.add_argument("--password-file", required=True, help="file holding the account password (read here, never printed)")
    p.add_argument("--api-base", default="https://api.mailmasker.org")
    p.add_argument("--imap-host", default="mail.mailmasker.org")
    p.add_argument("--imap-port", type=int, default=993)
    sub = p.add_subparsers(dest="mode", required=True)

    s = sub.add_parser("setting")
    s.add_argument("action", choices=["show", "on", "off"])

    c = sub.add_parser("count")
    c.add_argument("--subject", required=True)

    r = sub.add_parser("roundtrip")
    r.add_argument("--node-ip", required=True, help="mail-pool node (management IP); its 587 is reached through an ssh tunnel")
    r.add_argument("--leader-ip", required=True, help="DB primary (management IP) to read the recorded row")
    r.add_argument("--src-ip", required=True, help="this workstation's IP, for the PROXY protocol line")
    r.add_argument("--local-port", type=int, default=19587)
    r.add_argument("--alias", action="append", help="test alias (repeatable; default: the four claude67 fixtures)")
    r.add_argument("--keep", action="store_true", help="leave the test messages in the inbox")

    y = sub.add_parser("reply", help="send one reply From the account, answering --in-reply-to, to --to (the server rewrites it)")
    y.add_argument("--node-ip", required=True)
    y.add_argument("--src-ip", required=True)
    y.add_argument("--local-port", type=int, default=19587)
    y.add_argument("--in-reply-to", required=True, help="Message-ID of the original, with angle brackets")
    y.add_argument("--to", required=True)
    y.add_argument("--subject", default="Re: reply67 external test")
    y.add_argument("--body", default="This reply was sent from the account's primary address; the server should have swapped it to the alias.")

    args = p.parse_args()
    with open(args.password_file) as fh:
        password = fh.read().strip()
    if not password:
        sys.exit(f"{args.password_file} is empty")

    if args.mode == "setting":
        mode_setting(args, password)
    elif args.mode == "count":
        mode_count(args, password)
    elif args.mode == "reply":
        mode_reply(args, password)
    else:
        mode_roundtrip(args, password)

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) FAILED: " + "; ".join(FAILURES))
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
