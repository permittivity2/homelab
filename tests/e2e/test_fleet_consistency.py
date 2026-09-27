"""Fleet-consistency regression suite: catches silent drift across a
declared multi-instance pool -- e.g. a package installed on only 1 of 3
members of an HA pool. This is a genuinely new test *category*, not a
rewrite of an existing test: nothing else in this suite (or anywhere in
this repo, per a real audit done before writing this file) checks
whether every member of a declared pool actually matches.

Direct regression test for a real bug found live, 2026-09-25:
homelab-roundcube-invite was installed on only ct14 of the 3-member
roundcube-nginx/roundcube-php-fpm pool, silently -- a real user's login
would get a different, broken feature set purely depending on which
pool member HAProxy happened to route them to. No existing test would
have caught this even in principle.

Entirely SSH-based (homelab-cli admin fleet status + dpkg -l + reading
one config file over SSH) -- no dependency on the public HTTPS path
test_sso_flow.py/test_roundcube_login.py need, so this suite stays
useful even when that path is degraded (see those files' own history
with this admin workstation's flaky egress, 2026-09-25).

Pool membership is read from the fleet's own live registry
(`homelab-cli admin fleet status -j`), not a hardcoded host list --
stays correct as the fleet grows/shrinks/gets rebuilt, the same reason
homelab-cli's own `admin fleet status` command exists in the first
place rather than a static inventory file.
"""

import json
import re
import subprocess
from collections import defaultdict

import pytest


def _run(args, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def _ssh_alias(fleet_hostname):
    """Normalizes a fleet-registry-reported hostname ("ct05" or
    "homelab-ct08" -- the registry is inconsistent about the prefix,
    confirmed live) into a real ~/.ssh/config alias. Every ct0x host
    uses the "homelab-ctNN" alias except ct00, which is
    "homelab-ct00-internet-facing" (see ~/.ssh/config.d/*.conf)."""
    bare = re.sub(r"^homelab-", "", fleet_hostname)
    if bare == "ct00":
        return "homelab-ct00-internet-facing"
    return f"homelab-{bare}"


@pytest.fixture(scope="session")
def fleet_status(ssh_host):
    result = _run(["ssh", ssh_host, "homelab-cli", "-j", "admin", "fleet", "status"])
    assert result.returncode == 0, f"homelab-cli admin fleet status failed: {result.stderr}"
    return json.loads(result.stdout)


@pytest.fixture(scope="session")
def pools(fleet_status):
    """{service_name: [ssh_alias, ...]} for every service the fleet
    registry reports on more than one host -- a "pool" by definition."""
    by_service = defaultdict(set)
    for svc in fleet_status["services"]:
        by_service[svc["service_name"]].add(_ssh_alias(svc["hostname"]))
    return {name: sorted(hosts) for name, hosts in by_service.items() if len(hosts) > 1}


@pytest.fixture(scope="session")
def singly_registered_packages(fleet_status):
    """package_names that the fleet registry itself already declares as
    belonging to a DIFFERENT, single-host-only service (e.g.
    homelab-domain-admin, its own "domain-admin" service, co-located on
    just one of the three postfix hosts by design). These are legitimate
    single-instance services sharing hardware with a pool member, not
    pool drift -- excluded from the pool-consistency check below using
    the registry's own data as the source of truth, not a guessed
    allowlist. A package that ISN'T independently registered as its own
    service this way (e.g. a stray homelab-cli install, or a genuinely
    pool-scoped companion package like homelab-roundcube-invite) is
    never excluded, and still gets checked for real."""
    by_service = defaultdict(set)
    for svc in fleet_status["services"]:
        by_service[svc["service_name"]].add(_ssh_alias(svc["hostname"]))
    single_host_services = {name for name, hosts in by_service.items() if len(hosts) == 1}
    return {
        svc["package_name"]
        for svc in fleet_status["services"]
        if svc["service_name"] in single_host_services and svc["package_name"]
    }


def _installed_homelab_packages(host):
    """{package_name: version} for every installed homelab-* package on
    host. Deliberately NOT dpkg-query's -f='${Package}=${Version}'
    format string: ssh joins the remote command into one string for the
    remote shell to run, and that shell would expand ${Package}/
    ${Version} as its OWN (unset, empty) variables before dpkg-query
    ever saw them -- confirmed to be a real trap, not a hypothetical,
    while writing this file. Plain `dpkg -l | awk` (the exact pattern
    already used successfully, repeatedly, elsewhere in this project's
    own live debugging) has no such $-expansion hazard."""
    result = _run(["ssh", host, "dpkg -l | awk '/^ii  homelab-/{print $2, $3}'"])
    assert result.returncode == 0, f"{host}: dpkg -l failed: {result.stderr}"
    pkgs = {}
    for line in result.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            pkgs[parts[0]] = parts[1]
    return pkgs


def test_every_pool_member_runs_the_same_package_versions(pools, singly_registered_packages):
    """The generalized regression test for the roundcube-invite bug:
    every homelab-* package installed on ANY member of a declared pool
    must be installed at the SAME version on EVERY member -- not just
    the package the pool is named after, so a companion package (like
    homelab-roundcube-invite riding alongside homelab-roundcube) drifting
    is caught too. Excludes packages the fleet registry itself already
    declares as a separate single-host service co-located on one pool
    member (see singly_registered_packages) -- that's a legitimate
    architecture choice (e.g. homelab-domain-admin living on one of the
    three postfix hosts), not drift."""
    failures = []
    for service_name, hosts in pools.items():
        versions_by_host = {host: _installed_homelab_packages(host) for host in hosts}
        all_pkg_names = set().union(*versions_by_host.values()) - singly_registered_packages
        for pkg in sorted(all_pkg_names):
            present_on = {h: v.get(pkg) for h, v in versions_by_host.items()}
            if len(set(present_on.values())) > 1:
                failures.append(f"pool '{service_name}' {hosts}: '{pkg}' is inconsistent: {present_on}")

    assert not failures, "fleet package-version drift found:\n" + "\n".join(failures)


def test_roundcube_pool_members_have_identical_plugin_lists(pools):
    """The literal, direct regression test for the exact bug found live
    2026-09-25: ct14 had 'invite_sender' in $config['plugins'] (via
    homelab-roundcube-invite) while ct15/ct16 only had
    'recipient_blocking' -- one-third of real logins silently got a
    different, broken feature set purely depending on which pool member
    HAProxy routed them to. test_every_pool_member_runs_the_same_
    package_versions above would already catch the PACKAGE half of this
    (homelab-roundcube-invite missing on 2 of 3 hosts); this checks the
    resulting CONFIG state directly, which is the thing a real user's
    browser actually experiences."""
    roundcube_hosts = pools.get("roundcube-php-fpm", [])
    if not roundcube_hosts:
        pytest.skip("no roundcube-php-fpm pool reported by the fleet registry")

    plugin_lists = {}
    for host in roundcube_hosts:
        result = _run(["ssh", host, "sudo grep \"config\\['plugins'\\]\" /etc/roundcube/config.inc.php"])
        assert result.returncode == 0, f"{host}: could not read config.inc.php's plugins line: {result.stderr}"
        m = re.search(r"\$config\['plugins'\]\s*=\s*(\[[^\]]*\])", result.stdout)
        assert m, f"{host}: no \\$config['plugins'] line found in config.inc.php: {result.stdout!r}"
        plugin_lists[host] = m.group(1)

    distinct = set(plugin_lists.values())
    assert len(distinct) == 1, f"Roundcube pool members have different plugin lists: {plugin_lists}"
