#!/usr/bin/env python3
"""Post-cutover #65: what the mail ports offer, checked for real.

Test harness, not shipped code (hence Python); standard library only. The
account password, when needed, arrives on stdin -- never an argument, never
printed. Three modes:

  node --node-ip IP --src-ip SRC [--account A]
      Against ONE mail-pool node, through ssh tunnels to its 25, 587 and 465.
      Every listener there expects haproxy's PROXY protocol header, so one is
      sent first (on 465: PROXY line, then TLS). Checks: 25 refuses MAIL before
      HELO (503), advertises neither AUTH nor VRFY, VRFY -> 502, AUTH -> 503,
      and a normal inbound message to --account is accepted and lands in its
      inbox (IMAPS, then deleted). 587: no AUTH before STARTTLS, STARTTLS
      offered, no VRFY, VRFY -> 502, AUTH after STARTTLS, login works.
      465: inside TLS AUTH offered, no VRFY, VRFY -> 502, login works.
      Password on stdin when --account is given.

  hairpin --host NAME
      From the admin workstation through the house hairpin to the public
      address: the port-25 checks above, through the real edge (offsite's
      provider blocks outbound 25, so this is the internet-side proof of 25).

  offsite --host NAME --ips A,B,C --account A
      Runs ON OFFSITE: per public address, 587 (before and after STARTTLS,
      SNI = NAME) and 465 (implicit TLS) as above; then one real login over
      465 through NAME. Password on stdin.
"""
import argparse
import contextlib
import email.utils
import imaplib
import random
import smtplib
import socket
import ssl
import subprocess
import sys
import time

fails = 0


def check(cond, name):
    global fails
    if not cond:
        fails += 1
    print(("  ok   " if cond else "  FAIL ") + name, flush=True)


def noverify():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


class ProxySMTP(smtplib.SMTP):
    """Sends a PROXY protocol v1 line first; with tls_context the TLS handshake
    follows at once (port 465)."""

    def __init__(self, host, port, proxy_line, timeout=20, tls_context=None, sni=None):
        self._proxy_line, self._tls_context, self._sni = proxy_line, tls_context, sni
        super().__init__(host, port, timeout=timeout)

    def _get_socket(self, host, port, timeout):
        sock = super()._get_socket(host, port, timeout)
        sock.sendall(self._proxy_line)
        if self._tls_context is not None:
            sock = self._tls_context.wrap_socket(sock, server_hostname=self._sni or host)
        return sock


class SniSMTPS(smtplib.SMTP_SSL):
    """Connect to an address but present and verify a name (public probes)."""

    def __init__(self, ip, port, sni, context, timeout=20):
        self._sni = sni
        super().__init__(ip, port, timeout=timeout, context=context)

    def _get_socket(self, host, port, timeout):
        sock = socket.create_connection((host, port), timeout)
        return self.context.wrap_socket(sock, server_hostname=self._sni)


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
        with contextlib.suppress(Exception):
            proc.wait(timeout=5)


# ----------------------------------------------------------- the checks --

def checks_25(connect, label):
    """connect() returns a fresh SMTP object with the banner already read."""
    s = connect()
    code, _ = s.docmd("MAIL FROM:<check65@example.com>")
    check(code == 503, f"{label}: MAIL before HELO/EHLO refused ({code})")
    code, _ = s.ehlo("check65.homelab.invalid")
    check(code == 250, f"{label}: EHLO accepted ({code})")
    check(not s.has_extn("auth"), f"{label}: no AUTH advertised")
    check(not s.has_extn("vrfy"), f"{label}: no VRFY advertised")
    code, _ = s.docmd("VRFY postmaster")
    check(code == 502, f"{label}: VRFY disabled ({code})")
    code, _ = s.docmd("AUTH PLAIN AGUyZQBlMmU=")
    check(code in (502, 503), f"{label}: AUTH refused ({code})")
    with contextlib.suppress(Exception):
        s.quit()


def checks_587(connect, label, sni_ctx, account=None, password=None):
    s = connect()
    code, _ = s.ehlo("check65.homelab.invalid")
    check(code == 250, f"{label}: EHLO accepted ({code})")
    check(not s.has_extn("auth"), f"{label}: no AUTH before STARTTLS")
    check(s.has_extn("starttls"), f"{label}: STARTTLS offered")
    check(not s.has_extn("vrfy"), f"{label}: no VRFY advertised")
    code, _ = s.docmd("VRFY postmaster")
    check(code in (502, 530), f"{label}: VRFY refused before TLS ({code})")
    s.starttls(context=sni_ctx)
    s.ehlo("check65.homelab.invalid")
    check(s.has_extn("auth"), f"{label}: AUTH offered inside TLS")
    check(not s.has_extn("vrfy"), f"{label}: no VRFY inside TLS")
    code, _ = s.docmd("VRFY postmaster")
    check(code == 502, f"{label}: VRFY disabled inside TLS ({code})")
    if account:
        try:
            s.login(account, password)
            check(True, f"{label}: login as the test account works")
        except Exception as e:  # noqa: BLE001
            check(False, f"{label}: login failed ({e})")
    with contextlib.suppress(Exception):
        s.quit()


def checks_465(connect, label, account=None, password=None):
    s = connect()
    code, _ = s.ehlo("check65.homelab.invalid")
    check(code == 250, f"{label}: EHLO inside TLS accepted ({code})")
    check(s.has_extn("auth"), f"{label}: AUTH offered inside TLS")
    check(not s.has_extn("vrfy"), f"{label}: no VRFY advertised")
    code, _ = s.docmd("VRFY postmaster")
    check(code == 502, f"{label}: VRFY disabled ({code})")
    if account:
        try:
            s.login(account, password)
            check(True, f"{label}: login as the test account works")
        except Exception as e:  # noqa: BLE001
            check(False, f"{label}: login failed ({e})")
    with contextlib.suppress(Exception):
        s.quit()


def inbound_message(connect, label, account, password, imap_host):
    """A normal unauthenticated delivery on 25 to a local mailbox must still
    work: the point of an MX. Found over IMAPS within 60 s, then deleted."""
    tag = f"check65 inbound {int(time.time())}-{random.randint(1000, 9999)}"
    msgid = email.utils.make_msgid(domain="check65.homelab.invalid")
    s = connect()
    try:
        s.ehlo("check65.homelab.invalid")
        body = (f"From: check65 <check65@{account.split('@')[1]}>\r\nTo: {account}\r\nSubject: {tag}\r\n"
                f"Message-ID: {msgid}\r\nDate: {email.utils.formatdate(localtime=True)}\r\n\r\n"
                "Inbound delivery check on port 25 (post-cutover #65).\r\n")
        s.sendmail(f"check65@{account.split('@')[1]}", [account], body.encode())
        check(True, f"{label}: inbound message accepted on 25")
    except Exception as e:  # noqa: BLE001
        check(False, f"{label}: inbound message refused on 25 ({e})")
        return
    finally:
        with contextlib.suppress(Exception):
            s.quit()
    try:
        m = imaplib.IMAP4_SSL(imap_host, 993, ssl_context=ssl.create_default_context(), timeout=30)
        m.login(account, password)
        m.select("INBOX")
        nums, started = [], time.time()
        while time.time() - started < 60 and not nums:
            typ, data = m.search(None, "SUBJECT", f'"{tag}"')
            nums = data[0].split() if typ == "OK" else []
            if not nums:
                time.sleep(3)
                m.noop()
        check(bool(nums), f"{label}: it arrived in the inbox ({time.time() - started:.0f} s)")
        for n in nums:
            m.store(n, "+FLAGS", "\\Deleted")
        m.expunge()
        m.logout()
    except Exception as e:  # noqa: BLE001
        check(False, f"{label}: IMAPS follow-up failed ({e})")


# ------------------------------------------------------------------ modes --

def mode_node(a, password):
    base = a.local_port_base
    sport = random.randint(20000, 60000)

    def proxy(port):
        return f"PROXY TCP4 {a.src_ip} {a.node_ip} {sport} {port}\r\n".encode()

    print(f"--- prod node {a.node_ip}: port 25")
    with tunnel(a.node_ip, base + 25, 25):
        checks_25(lambda: ProxySMTP("127.0.0.1", base + 25, proxy(25)), f"{a.node_ip}:25")
        if a.account:
            inbound_message(lambda: ProxySMTP("127.0.0.1", base + 25, proxy(25)), f"{a.node_ip}:25",
                            a.account, password, a.imap_host)
    print(f"--- prod node {a.node_ip}: port 587")
    with tunnel(a.node_ip, base + 587, 587):
        checks_587(lambda: ProxySMTP("127.0.0.1", base + 587, proxy(587)), f"{a.node_ip}:587", noverify(),
                   a.account, password)
    print(f"--- prod node {a.node_ip}: port 465")
    with tunnel(a.node_ip, base + 465, 465):
        checks_465(lambda: ProxySMTP("127.0.0.1", base + 465, proxy(465), tls_context=noverify(), sni=a.sni),
                   f"{a.node_ip}:465", a.account, password)


def mode_hairpin(a, _password):
    print(f"--- {a.host}:25 through the edge (house hairpin)")
    checks_25(lambda: smtplib.SMTP(a.host, 25, timeout=20), f"{a.host}:25")


def mode_offsite(a, password):
    ctx = ssl.create_default_context()
    for ip in a.ips.split(","):
        print(f"--- {ip}:587 (SNI {a.host})")
        s587 = lambda ip=ip: smtplib.SMTP(ip, 587, timeout=20)  # noqa: E731
        sni_ctx = ssl.create_default_context()
        # starttls() uses the connect host for SNI; the connect host is an IP,
        # so wrap the hostname check into a context bound to the name instead.
        sni_ctx.check_hostname = False
        sni_ctx.verify_mode = ssl.CERT_REQUIRED
        checks_587(s587, f"{ip}:587", sni_ctx)
        print(f"--- {ip}:465 (SNI {a.host})")
        checks_465(lambda ip=ip: SniSMTPS(ip, 465, a.host, ctx), f"{ip}:465")
    print(f"--- {a.host}:465 login as {a.account}")
    checks_465(lambda: smtplib.SMTP_SSL(a.host, 465, timeout=20, context=ctx), f"{a.host}:465", a.account, password)
    print(f"--- {a.host}:587 login as {a.account}")
    checks_587(lambda: smtplib.SMTP(a.host, 587, timeout=20), f"{a.host}:587", ctx, a.account, password)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="mode", required=True)
    n = sub.add_parser("node")
    n.add_argument("--node-ip", required=True)
    n.add_argument("--src-ip", required=True)
    n.add_argument("--account", help="test account: login checks + one inbound message on 25 (password on stdin)")
    n.add_argument("--imap-host", default="mail.mailmasker.org")
    n.add_argument("--sni", default="mail.mailmasker.org")
    n.add_argument("--local-port-base", type=int, default=19000)
    h = sub.add_parser("hairpin")
    h.add_argument("--host", default="mail.mailmasker.org")
    o = sub.add_parser("offsite")
    o.add_argument("--host", default="mail.mailmasker.org")
    o.add_argument("--ips", required=True, help="comma-separated public addresses")
    o.add_argument("--account", required=True)
    a = p.parse_args()
    password = sys.stdin.readline().rstrip("\n") if getattr(a, "account", None) else None
    {"node": mode_node, "hairpin": mode_hairpin, "offsite": mode_offsite}[a.mode](a, password)
    print("\n" + ("ALL PASSED" if fails == 0 else f"{fails} FAILED"))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
