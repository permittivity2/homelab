"""Regression test for the invite domain-restriction feature, added
2026-09-26.

Real requirement: an invite may be SENT to any address -- creation is
deliberately unrestricted, see invite/README.md's own data model
section -- but ACCEPTING one whose recipient is on a domain this fleet
already manages mail for makes no sense (that address either already
has a real account here, or would collide with this fleet's own mail
infrastructure -- see homelab-invite's README, "Anti-abuse"/"Email
sending" sections, which already assumed invite recipients are external
by definition; this feature makes that assumption an actual enforced
check). "Managed" means precisely the same set homelab-postfix's own
virtual_mailbox_domains pgsql map resolves against: domainadmin.domains
rows with mail_enabled=TRUE AND active=TRUE (see domain-admin/
migrations/001-domains.sql).

Enforced (as of the 2026-09-27 account-creation redesign) in
homelab-invite's own Controller::Invites -- accept()/show()/check via
_recipient_domain_error, operating on the invite's recipient_email --
NOT in homelab-api's _register. It moved because the redesign made the
account being registered a freshly CHOSEN fleet-domain login
(<username>@<account_domain>), which is DELIBERATELY on a fleet-managed
domain: checking the registration email would now reject every
legitimate acceptance. The thing that must not be fleet-managed is the
invite's own recipient (contact) address, which only homelab-invite
knows. The check runs FIRST in accept() -- before any field validation
-- so a managed-recipient invite is refused whatever the payload, and
BEFORE homelab-api's _register/consume is ever called (so a rejection
neither burns the token nor writes any api.login_attempts row). The
tests below exercise the real public accept page (the same one a real
invitee's browser hits), so they also prove the rejection message
surfaces where the user asked for it.

test.forge.name was onboarded as a second real, mail-enabled domain on
this fleet specifically so this feature has more than one domain to
prove the check is genuinely dynamic (queries domainadmin.domains
live) rather than a single hardcoded string -- see domain-admin/
README.md and PowerDNS.pm's own fixes from the same session for the
zone-creation bugs found provisioning it.

Note (unlike this file's pre-2026-09-27 form): because the domain
rejection now happens entirely inside homelab-invite and never reaches
homelab-api's _register, it no longer writes api.login_attempts rows,
so repeatedly running this file no longer risks tripping _register's
shared per-IP rate limiter -- the old "re-run more than twice and the
still-works test 429s" gotcha is gone.
"""

import json
import subprocess
import time
import urllib.error
import urllib.request

from conftest import retry_open, SITE_ADMIN_EMAIL
from test_sso_flow import _new_opener

INVITE_BASE_URL = "https://invite.test.mailmasker.org"

MANAGED_DOMAINS = ("test.mailmasker.org", "test.forge.name")


def _send_invite(ssh_host, recipient):
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "--as", SITE_ADMIN_EMAIL, "-j", "invite", "send", "--to", recipient],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, (
        f"could not mint an invite to {recipient} -- invite CREATION should always succeed "
        f"regardless of recipient domain (only acceptance is restricted): {result.stderr}"
    )
    return json.loads(result.stdout)


def _accept(token, username, password, password_confirm=None, recovery_email=""):
    """POST the redesigned acceptance payload (username + dual password
    + optional recovery). Each call uses a fresh opener; returns
    (status, decoded_json)."""
    payload = {
        "username": username,
        "password": password,
        "password_confirm": password if password_confirm is None else password_confirm,
        "recovery_email": recovery_email,
    }
    req = urllib.request.Request(
        f"{INVITE_BASE_URL}/invite/{token}/accept",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    opener = _new_opener()
    try:
        resp = retry_open(opener.open, req, timeout=15)
        return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_invite_acceptance_rejected_for_every_fleet_managed_domain(ssh_host):
    """The direct regression test: an invite to an address on EACH of
    this fleet's real managed mail domains gets rejected at accept
    time, with a clear, specific, domain-naming error -- and the token
    is NOT burned by a rejected attempt (re-accepting gets the exact
    same rejection, not "invite already used"). As of 2026-09-27 this is
    enforced in homelab-invite's own accept()/show() on the invite's
    recipient_email (it moved out of homelab-api's _register, which now
    creates a deliberately-fleet-domain chosen login), and checked
    FIRST -- before any username/password validation -- so a
    managed-recipient invite is refused whatever the submitted payload."""
    for domain in MANAGED_DOMAINS:
        recipient = f"e2e-invite-domain-block-{int(time.time())}@{domain}"
        invite = _send_invite(ssh_host, recipient)

        status, body = _accept(invite["token"], "pickedname", "E2eInviteDomainBlockTest1Aa")
        assert status == 403, f"expected 403 rejecting an invite to {recipient}, got {status}: {body}"
        error = body.get("error", "")
        assert domain in error, (
            f"rejection message for {recipient} doesn't name the domain -- doesn't clearly "
            f"state WHY, as required: {error!r}"
        )
        assert "managed" in error.lower(), (
            f"rejection message for {recipient} doesn't explain that this domain is fleet-"
            f"managed: {error!r}"
        )

        # Not burned: the same token, accepted again, must fail the
        # SAME way -- not "invite already used or expired" (which would
        # mean the invite got consumed despite the domain rejection).
        status2, body2 = _accept(invite["token"], "pickedname", "E2eInviteDomainBlockTest1Aa")
        assert status2 == 403 and domain in body2.get("error", ""), (
            f"re-accepting a domain-rejected invite for {recipient} should fail the exact same "
            f"way, not consume the token: got {status2}: {body2}"
        )


def test_invite_acceptance_still_works_for_a_non_managed_domain(ssh_host):
    """No false positives: an invite to a genuinely external address is
    unaffected by the restriction and a real account gets created for a
    freshly chosen fleet-domain username."""
    recipient = f"e2e-invite-domain-ok-{int(time.time())}@example.com"
    invite = _send_invite(ssh_host, recipient)

    username = f"e2eok{int(time.time())}"
    status, body = _accept(invite["token"], username, "E2eInviteDomainOkTest1Aa")
    assert status == 200 and body.get("ok"), (
        f"a normal, non-managed-domain invite acceptance should still succeed: got {status}: {body}"
    )
    assert body.get("email", "").startswith(username + "@"), (
        f"acceptance should report the new fleet-domain login it created: {body}"
    )
