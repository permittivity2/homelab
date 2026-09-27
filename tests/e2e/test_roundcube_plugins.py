"""Phase 4 regression test: a real Roundcube PLUGIN-INTERACTION bug, not
a per-plugin smoke test.

Actual bug, found and fixed live 2026-09-25: both recipient_blocking
(ships with homelab-roundcube) and invite_sender (ships with
homelab-roundcube-invite) called register_handler('plugin.body', ...) --
Elastic's shared, generic template-object name, confirmed real by reading
both plugins' own source, not assumed -- unconditionally for their
entire task=='settings' scope, rather than gating on their own specific
action. register_handler() throws "Cannot register template handler
plugin.body; already taken by another plugin" if a second plugin claims
an already-claimed handler name, so with both plugins active, ANY
settings page load -- not just either plugin's own page -- 500'd the
moment the second plugin's init() ran. Real, reproduced live symptom: a
plain "Preferences" page load 500'd once invite_sender started loading
successfully alongside the already-installed recipient_blocking.

The fix first applied (2026-09-25) only touched invite_sender's side:
its own registration was gated on
`$this->rc->action === 'plugin.sendinvite'` (see
roundcube-invite/plugins/invite_sender/invite_sender.php's init(), and
its own header comment for the full story). recipient_blocking's own
registration was left unconditional for the whole task=='settings'
branch -- fine as long as it was the only plugin doing so, but it left
a SECOND, quieter bug in the same collision that went uncaught until a
real user hit it live, 2026-09-26: since recipient_blocking loads
before invite_sender in $config['plugins'] (confirmed live:
`$config['plugins'] = ['recipient_blocking', 'invite_sender'];`),
recipient_blocking's unconditional registration always claims
'plugin.body' FIRST -- including on invite_sender's own Send Invite
page. register_handler() does NOT throw/500 on a second, colliding
claim by a DIFFERENT plugin the way this module's docstring above
first assumed -- confirmed by reading the real installed source
(rcube_plugin_api::register_handler(), program/lib/Roundcube/
rcube_plugin_api.php): it calls rcube::raise_error() with $terminate=
false, so the SECOND caller's registration is silently REJECTED (logged,
not fatal) and the FIRST owner keeps the handler. Net effect: clicking
"Send Invite" rendered successfully (no 500, no fatal marker -- the
original test below would have passed clean), correct page title, but
the actual `plugin.body` content was recipient_blocking's own
blockedaddresses_body -- a real user saw their blocked-addresses list
under the Send Invite page. Fixed the same way, on the other side of
the same collision: recipient_blocking's settings-task registration is
now ALSO gated on its own action (`$this->rc->action ===
'plugin.blockedaddresses'`), so each plugin only holds the name while
its own page is actually being rendered, regardless of load order.

This second bug is exactly why FATAL_MARKERS-only checking (the
original test below) is not sufficient on its own -- a wrong-plugin's-
content bug produces a clean 200 with no fatal string anywhere.
test_plugin_settings_pages_render_their_own_content below is the
direct regression test for THIS specific failure mode: it asserts each
plugin's own settings page contains THAT plugin's own markup and does
NOT contain the other plugin's markup, in both directions -- the
generic-page FATAL_MARKERS test above still exists to catch a return
to the ORIGINAL (throwing/500) failure mode as well, so both known
failure shapes of this same underlying collision stay covered.

That's exactly why the original test deliberately visits Roundcube's
GENERIC settings pages (Preferences, Identities) that belong to NEITHER
plugin -- a test that only ever hit invite_sender's own
?_action=plugin.sendinvite page would never have caught the original
bug (that page loaded fine; it was every OTHER settings page that
broke), and wouldn't catch a future recurrence either. Hitting the
generic pages is what makes it a real regression test for the
plugin-interaction itself rather than a per-plugin smoke test.

Login pattern (register a real account, SSO in via Drive, land in
Roundcube on a bare visit) is the exact one
test_roundcube_login.py's own test_live_drive_session_reaches_inbox_on_a_
bare_mail_visit already proved works -- reused verbatim rather than
reinvented here.
"""

import time
import urllib.error

import pytest

from conftest import register_account, retry_open
from test_fleet_consistency import _run, fleet_status, pools
from test_sso_flow import DRIVE_LOGIN_URL, _new_opener, _submit_credentials

BASE_URL = "https://mail.test.mailmasker.org"

# The literal error register_handler() throws on a second, colliding
# claim (see the module docstring) -- if this string is ever visible in
# a settings-page response body again, some plugin has repeated
# invite_sender's original mistake. "Fatal error" is the generic PHP
# fatal marker, in case a future collision surfaces through a different
# uncaught exception/error instead of this exact message.
FATAL_MARKERS = ("Fatal error", "already taken by another plugin")


def _invite_sender_enabled_fleet_wide(pools):
    """True only if EVERY member of the live roundcube-php-fpm pool has
    'invite_sender' in its own $config['plugins'] -- the same per-host
    config read test_fleet_consistency.py's own drift test already does.
    Deliberately not "enabled on at least one host": the HTTP requests
    below go through the real public HAProxy VIP, which load-balances
    across the whole pool, so testing invite_sender's own page is only a
    deterministic check if every pool member actually has it (the same
    reasoning test_fleet_consistency.py's header comment gives for why
    the 2026-09-25 partial-install bug mattered in the first place)."""
    roundcube_hosts = pools.get("roundcube-php-fpm", [])
    if not roundcube_hosts:
        return False
    for host in roundcube_hosts:
        result = _run(["ssh", host, "sudo grep \"config\\['plugins'\\]\" /etc/roundcube/config.inc.php"])
        if result.returncode != 0 or "invite_sender" not in result.stdout:
            return False
    return True


def _fetch(opener, url):
    """GETs url with the given (already-authenticated) opener, returning
    (status, body) whether the response is a plain 200 or a real HTTP
    error -- same try/except-HTTPError shape test_sso_flow.py's/
    test_roundcube_login.py's own tests already use, since the default
    opener here has no custom error handler and urllib raises a real 500
    as an HTTPError rather than just returning it."""
    try:
        resp = retry_open(opener.open, url, timeout=15)
        return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def test_settings_pages_survive_with_both_plugins_active(ssh_host, pools):
    """The actual regression test: log in for real, land in Roundcube's
    inbox via a bare visit (proving a real authenticated session, the
    same way test_roundcube_login.py's own bare-visit test does), then
    hit every settings-task page a real logged-in user would reach --
    the two plugin-owned entry points AND, crucially, the generic
    Preferences/Identities pages that own neither plugin. None of them
    may 500 or carry a PHP fatal-error / plugin-conflict marker in the
    body."""
    email = f"e2e-roundcube-plugins-{int(time.time())}@test.mailmasker.org"
    password = "E2eRoundcubePluginsTest1Aa"
    register_account(ssh_host, email, password)

    opener = _new_opener()
    _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)

    # Same bare-visit mechanism test_live_drive_session_reaches_inbox_on_
    # a_bare_mail_visit relies on (oauth_login_redirect's silent
    # IdP-session-carries-over redirect chain) -- establishes Roundcube's
    # own local PHP session before the settings pages below are hit with
    # the same cookie jar.
    mail_html = _fetch(opener, f"{BASE_URL}/")[1]
    assert "Inbox" in mail_html or "taskbar" in mail_html, (
        "a live Drive session did not carry over to a bare Mail visit -- "
        "check oauth_login_redirect in roundcube's config.inc.php "
        "(setup for this test failed before it could even exercise the "
        "plugin-interaction bug)"
    )

    # recipient_blocking ships with every homelab-roundcube install, so
    # its own settings action is always in scope. invite_sender only
    # gets exercised directly if it's actually installed fleet-wide --
    # see _invite_sender_enabled_fleet_wide's own docstring for why a
    # partial install isn't good enough to test deterministically over
    # the load-balanced HTTP path.
    actions = ["preferences", "identities", "plugin.blockedaddresses"]
    if _invite_sender_enabled_fleet_wide(pools):
        actions.append("plugin.sendinvite")

    failures = []
    for action in actions:
        url = f"{BASE_URL}/?_task=settings&_action={action}"
        status, body = _fetch(opener, url)
        if status == 500:
            failures.append(f"_action={action}: got HTTP 500 (body[:300]={body[:300]!r})")
            continue
        for marker in FATAL_MARKERS:
            if marker in body:
                failures.append(f"_action={action}: response body contains {marker!r} (body[:300]={body[:300]!r})")

    assert not failures, (
        "a Roundcube settings page carried a PHP fatal / plugin-conflict "
        "marker -- this is the recipient_blocking/invite_sender "
        "'plugin.body' collision (or a repeat of it by some other "
        "plugin); see this file's module docstring:\n" + "\n".join(failures)
    )


# Markers unconditionally present in each plugin's own *_body() output
# whenever a valid OAuth token exists (true for any real logged-in
# session this test creates) -- deliberately the FORM element ids, not
# anything inside the results table/list, since the table itself is
# swapped out for a "no results" box when a fresh test account has no
# invites/blocked addresses yet (see each plugin's own *_body() method).
SENDINVITE_OWN_MARKER = 'id="sendinviteform"'
BLOCKEDADDRESSES_OWN_MARKER = 'id="blockedaddressessearch"'


def test_plugin_settings_pages_render_their_own_content(ssh_host, pools):
    """Direct regression test for the real bug found live, 2026-09-26:
    see this module's own docstring for the full story. Unlike
    test_settings_pages_survive_with_both_plugins_active above (which
    only checks for a 500/fatal marker), this asserts each plugin's
    settings page contains THAT plugin's own form markup and does NOT
    contain the other plugin's -- the actual failure mode was a clean
    200 with the WRONG plugin's content silently rendered underneath,
    which a fatal-marker-only check can never catch."""
    if not _invite_sender_enabled_fleet_wide(pools):
        pytest.skip("invite_sender not installed fleet-wide -- see _invite_sender_enabled_fleet_wide")

    email = f"e2e-roundcube-plugin-content-{int(time.time())}@test.mailmasker.org"
    password = "E2eRoundcubePluginContentTest1Aa"
    register_account(ssh_host, email, password)

    opener = _new_opener()
    _submit_credentials(opener, DRIVE_LOGIN_URL, email, password)

    mail_html = _fetch(opener, f"{BASE_URL}/")[1]
    assert "Inbox" in mail_html or "taskbar" in mail_html, (
        "a live Drive session did not carry over to a bare Mail visit -- "
        "setup for this test failed before it could exercise either "
        "plugin's settings page"
    )

    _, sendinvite_body = _fetch(opener, f"{BASE_URL}/?_task=settings&_action=plugin.sendinvite")
    assert SENDINVITE_OWN_MARKER in sendinvite_body, (
        "the Send Invite settings page did not contain invite_sender's own "
        f"form ({SENDINVITE_OWN_MARKER!r}) -- got (body[:300]="
        f"{sendinvite_body[:300]!r})"
    )
    assert BLOCKEDADDRESSES_OWN_MARKER not in sendinvite_body, (
        "the Send Invite settings page rendered recipient_blocking's own "
        "Blocked Addresses form instead -- this is the exact 'plugin.body' "
        "ownership collision this module's docstring describes: "
        "recipient_blocking's settings-task registration must be gated on "
        "$this->rc->action === 'plugin.blockedaddresses' "
        f"(body[:300]={sendinvite_body[:300]!r})"
    )

    _, blockedaddresses_body = _fetch(opener, f"{BASE_URL}/?_task=settings&_action=plugin.blockedaddresses")
    assert BLOCKEDADDRESSES_OWN_MARKER in blockedaddresses_body, (
        "the Blocked Addresses settings page did not contain "
        f"recipient_blocking's own form ({BLOCKEDADDRESSES_OWN_MARKER!r}) -- "
        f"got (body[:300]={blockedaddresses_body[:300]!r})"
    )
    assert SENDINVITE_OWN_MARKER not in blockedaddresses_body, (
        "the Blocked Addresses settings page rendered invite_sender's own "
        "Send Invite form instead -- the reverse direction of the same "
        f"'plugin.body' ownership collision (body[:300]="
        f"{blockedaddresses_body[:300]!r})"
    )
