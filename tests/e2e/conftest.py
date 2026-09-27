"""Shared fixtures for the end-to-end regression suite.

See tests/e2e/README.md before adding a new test file. Every fix to a
real bug gets a regression test here that stays in the suite permanently
— see CLAUDE.md's "Testing discipline" section.
"""

import json
import pathlib
import socket
import subprocess
import time
import urllib.error
import urllib.request

import pytest
import yaml

E2E_DIR = pathlib.Path(__file__).parent
ENV_FILE = E2E_DIR / "env.yml"
ENV_EXAMPLE_FILE = E2E_DIR / "env.example.yml"

# Well-known, already-documented test/dev-domain admin account (not a real
# secret -- test.mailmasker.org is a throwaway test fleet). Used ONLY to
# mint invites for register_account() below; never used to log into
# anything test bodies themselves assert against. See
# memory/homelab_test_accounts.md in this project's own operator notes for
# the same credential reused elsewhere.
#
# This account's own invite quota was raised (2026-09-25, `homelab-cli
# invite quota set --user test-admin@test.mailmasker.org --max-pending 200
# --max-per-day 200`) specifically because it's this suite's fixture
# account, not a real end user -- the default 8/day quota was hit and
# blocked every test needing a fresh account partway through a single
# real run. If it's ever exhausted again, raise it further rather than
# working around it in test code.
SITE_ADMIN_EMAIL = "test-admin@test.mailmasker.org"
SITE_ADMIN_PASSWORD = "TestAdmin2026!"


@pytest.fixture(scope="session")
def env_config():
    """The active target environment's config (hostnames, not secrets).

    Falls back to env.example.yml with a warning if env.yml hasn't been
    created yet, so `pytest --collect-only` and CI's collection-only lint
    job both work without requiring a real env.yml to exist.
    """
    path = ENV_FILE if ENV_FILE.exists() else ENV_EXAMPLE_FILE
    with open(path) as f:
        config = yaml.safe_load(f)
    active = config["active_target"]
    return config["targets"][active]


@pytest.fixture(scope="session")
def ssh_host(env_config):
    """The `ssh <host>` alias for the active target, for tests that need
    to shell out (e.g. `subprocess.run(["ssh", ssh_host, ...])`)."""
    return env_config["ssh_host"]


@pytest.fixture(scope="session")
def imaps_vip(env_config):
    """host:port of the real HAProxy IMAPS frontend, load-balanced across
    the live Dovecot pool -- see env.example.yml's own comment on why this
    is not ssh_host's own loopback."""
    return env_config["imaps_vip"]


@pytest.fixture(scope="session")
def haproxy_host(env_config):
    """SSH alias for the HAProxy host itself -- the tunnel jump host for
    IMAPS specifically (see env.example.yml's own comment on why this
    isn't ssh_host)."""
    return env_config["haproxy_host"]


@pytest.fixture(scope="session")
def lmtp_target(env_config):
    """host:port Postfix's own virtual_transport actually delivers LMTP
    to -- NOT load-balanced (see env.example.yml's own comment)."""
    return env_config["lmtp_target"]


@pytest.fixture(scope="session")
def postfix_host(env_config):
    """SSH alias for a real Postfix host -- the tunnel jump host for
    LMTP specifically (see env.example.yml's own comment on why this
    isn't ssh_host)."""
    return env_config["postfix_host"]


@pytest.fixture(scope="session")
def dovecot_host(env_config):
    """SSH alias for one real Dovecot pool member, for checks that need
    to run a command directly ON a Dovecot host (e.g. `doveadm`) rather
    than speak IMAP/LMTP to it."""
    return env_config["dovecot_host"]


@pytest.fixture(scope="session", autouse=True)
def _tunnel_egress(env_config):
    """Optional: when env_config sets 'tunnel_via' (an SSH alias), every
    outbound HTTPS connection this suite makes for the rest of the
    session is silently redirected, at the raw socket layer, through an
    SSH local port-forward to that host's OWN loopback:443 -- SNI and
    the Host header are completely untouched (both are set by the
    caller from the ORIGINAL requested hostname, independent of the
    literal TCP peer connected to), so this changes nothing about what
    a test actually exercises, only which physical network path the
    bytes travel over. It's the exact same "hit nginx over its own
    loopback" path already proven reliable, all session, via direct SSH
    -- just applied transparently to urllib instead of requiring every
    test file to shell out.

    Exists because this admin workstation's own outbound route to the
    fleet's public IP has repeatedly, independently proven unreliable in
    ways that have nothing to do with the fleet itself: confirmed via a
    real NetworkManager journal entry (a genuine DHCP4 lease renewal on
    this box's own egress VLAN, bond0.60) landing in the middle of a
    real, otherwise-passing test run, 2026-09-26 -- see this suite's own
    prior incident history for the fuller story. A fleet host's own
    loopback to its own nginx has never once failed this session.

    Deliberately opt-in (leave 'tunnel_via' unset in env.yml to disable
    entirely) -- a runner with genuinely healthy egress doesn't need
    this, and patching socket.create_connection globally is not
    something to do unconditionally.

    Implementation note: http.client.HTTPConnection captures
    `self._create_connection = socket.create_connection` fresh, from
    the socket MODULE's current attribute, inside its own __init__ --
    not once at import time -- so patching the module attribute here,
    before any connection object gets constructed, is sufficient to
    redirect every connection urllib/http.client make afterward.
    Confirmed directly against this Python's own installed source
    (/usr/lib/python3.14/http/client.py) before relying on it, not
    assumed from older-version knowledge.
    """
    tunnel_via = env_config.get("tunnel_via")
    if not tunnel_via:
        yield
        return

    local_port = 18443
    proc = subprocess.Popen(
        ["ssh", "-N", "-L", f"{local_port}:127.0.0.1:443", tunnel_via],
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
            raise RuntimeError(f"SSH tunnel to {tunnel_via} never came up")

        real_create_connection = socket.create_connection

        def _patched_create_connection(address, *args, **kwargs):
            host, port = address
            if port == 443:
                return real_create_connection(("127.0.0.1", local_port), *args, **kwargs)
            return real_create_connection(address, *args, **kwargs)

        socket.create_connection = _patched_create_connection
        try:
            yield
        finally:
            socket.create_connection = real_create_connection
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.fixture(scope="session", autouse=True)
def _site_admin_cli_session(ssh_host):
    """Logs `homelab-cli` in as the well-known site_admin test account on
    ssh_host, once per test session -- register_account() below needs this
    to mint real invites. Session-scoped and autouse rather than relying on
    whatever CLI session state happens to already exist there: a stale or
    missing login would otherwise fail every test that creates an account,
    for a reason unrelated to whatever that test is actually checking.
    homelab-cli's own refresh_token handles staying logged in beyond this
    one call (see cli/homelab_cli/client.py's 401-retry-with-refresh
    logic) -- this only needs to run once per pytest session, not per test.
    """
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "login", SITE_ADMIN_EMAIL, "--password", SITE_ADMIN_PASSWORD],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, (
        f"could not log homelab-cli into {ssh_host} as {SITE_ADMIN_EMAIL} -- "
        f"is homelab-cli installed there (see README Setup)? {result.stderr}"
    )


def register_account(ssh_host, email, password):
    """Creates a real, usable test account on the live fleet.

    Uses `homelab-cli admin users create-service-account` (site_admin,
    via _site_admin_cli_session above), NOT the public invite mint+
    accept flow this helper used before 2026-09-26 -- every disposable
    fixture account this suite creates lives on test.mailmasker.org
    (the only domain on this fleet with a real, working mailbox), which
    is now (correctly) REJECTED by the invite-accept flow itself: see
    api/lib/Homelab/API/App.pm's _invite_recipient_domain_check and
    test_invite_domain_restriction.py's own module docstring for the
    real bug this enforces. Using the invite path here would make every
    single test in this suite fail on setup, not exercise anything real
    about invites -- the admin bypass is the same "site_admin creating
    an account directly, no invite" path the check is deliberately
    scoped to leave open (it only gates _register's invite_token
    branch), not a workaround for the restriction.

    Still fails closed like the old invite-based version did: any
    non-zero exit is a real assertion failure, not silently swallowed.
    """
    # `--as SITE_ADMIN_EMAIL` runs this one command as the stored
    # site_admin profile WITHOUT changing which profile is active on the
    # shared remote homelab-cli -- so it's immune to any test that
    # switched the active profile by logging in as some other account
    # (homelab-cli's active profile is global per host). Without this,
    # one test doing `homelab-cli login <plain-user>` silently breaks
    # every later register_account with "site_admin role required".
    result = subprocess.run(
        ["ssh", ssh_host, "homelab-cli", "--as", SITE_ADMIN_EMAIL, "-j",
         "admin", "users", "create-service-account", "--email", email, "--password", password],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, f"test account creation failed for {email}: {result.stderr}"


def login_succeeds(email, password):
    """True iff (email, password) authenticates -- verified straight
    against homelab-api's public /auth/login vhost, NOT via `homelab-cli
    login`. Deliberately avoids the CLI: `homelab-cli login` switches the
    shared active profile on the remote host, which silently breaks any
    later fixture (register_account, invite send) that needs the
    site_admin profile active. A plain HTTP check has no such side
    effect. Goes through the same tunnel the rest of the suite's HTTPS
    does (see _tunnel_egress)."""
    data = json.dumps({"email": email, "password": password}).encode()
    req = urllib.request.Request(
        "https://api.test.mailmasker.org/api/v1/auth/login",
        data=data, headers={"Content-Type": "application/json"}, method="POST",
    )
    opener = urllib.request.build_opener()
    try:
        resp = retry_open(opener.open, req, timeout=15)
        return resp.status == 200
    except urllib.error.HTTPError:
        return False


def retry_open(opener_open, *args, attempts=4, **kwargs):
    """Runs opener.open(*args, **kwargs), retrying on a raw connection
    timeout/error only (never on a real HTTP error status -- those come
    back as a normal response or a urllib.error.HTTPError, neither of
    which reaches this except clause, so a genuine 4xx/5xx from the
    fleet still fails immediately and for real).

    This admin workstation's own outbound network has repeatedly proven
    flaky against this fleet's public IP in ways that have nothing to do
    with the fleet itself -- confirmed multiple times on 2026-09-25 (a
    plain port-80 request to the same IP failed from here while
    succeeding immediately from a real external client; running this
    same suite failed on a raw connection timeout, then hit a completely
    different, real error on the very next attempt seconds later). A
    single-shot urllib call from here is not a reliable way to tell "the
    fleet is broken" from "this workstation's egress hiccuped" apart --
    retrying a transport-level failure a few times, with backoff, is
    cheap and removes that ambiguity for every caller instead of each
    test file working around it separately.
    """
    delay = 1
    for attempt in range(1, attempts + 1):
        try:
            return opener_open(*args, **kwargs)
        except urllib.error.URLError as e:
            if attempt == attempts or isinstance(e, urllib.error.HTTPError):
                raise
            time.sleep(delay)
            delay *= 2
