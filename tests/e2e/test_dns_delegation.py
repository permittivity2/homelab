"""Phase 2 regression test: test.mailmasker.org actually resolves.

Covers the real integration proof from 2026-09-09 — homelab-database +
homelab-pgbouncer + homelab-dns installed fresh on test-static-internet-ip,
a real zone created, and verified resolving both directly against the
authoritative server and via a real external public resolver (proving the
parent-zone delegation + this host's answers are both correct, not just
locally self-consistent).

Also stands as the regression test for the PowerDNS "new zone not
servable until restart" gotcha documented in dns/README.md — if a future
change to the zone-creation tooling forgets to restart pdns, this test
catches it immediately rather than silently leaving a REFUSED zone.
"""

import subprocess

import pytest


def _dig(server, name, rtype):
    """Runs `dig +short @server name rtype`, returns stripped output lines."""
    result = subprocess.run(
        ["dig", f"@{server}", name, rtype, "+short"],
        capture_output=True, text=True, timeout=10,
    )
    return [line for line in result.stdout.strip().splitlines() if line]


@pytest.fixture(scope="module")
def target_ip(env_config):
    # test-static-internet-ip's public IP — the authoritative server for
    # this zone. Not in env.yml (that's hostnames, not IPs) since this
    # specific test needs to reach it as a DNS server, not SSH into it.
    return "23.116.91.67"


def test_authoritative_server_answers_directly(target_ip):
    answers = _dig(target_ip, "mail.test.mailmasker.org", "A")
    assert answers == [target_ip], (
        f"expected the authoritative server itself to answer mail.test.mailmasker.org "
        f"with {target_ip}, got {answers}"
    )


def test_drive_subdomain_resolves(target_ip):
    answers = _dig(target_ip, "drive.test.mailmasker.org", "A")
    assert answers == [target_ip]


def test_resolves_via_real_external_resolver():
    """The actual acceptance criterion: not just self-consistent against
    our own authoritative server, but genuinely resolvable from the
    outside internet via a resolver we don't control — proves the
    parent zone's delegation + glue are correct too, not just this
    host's own answers."""
    answers = _dig("8.8.8.8", "mail.test.mailmasker.org", "A")
    assert answers == ["23.116.91.67"]


def test_mx_record_resolves_via_real_external_resolver():
    answers = _dig("8.8.8.8", "test.mailmasker.org", "MX")
    assert answers == ["10 mail.test.mailmasker.org."]
