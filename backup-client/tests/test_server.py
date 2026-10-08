"""Unit tests for the pure-logic functions in
server/homelab-borg-service-backup-server.

No real SSH/borg/filesystem-user calls -- these only exercise identifier
validation, authorized_keys line construction/parsing, and the
enroll/revoke list-manipulation logic.
"""
import pytest

import homelab_borg_service_backup_server as srv


# --- is_valid_identifier ----------------------------------------------------

@pytest.mark.parametrize("identifier, expected", [
    ("testserver-9c571a0ac61240dea1baf1a6d61001ba", True),
    ("api01", True),
    ("host.example", True),
    ("host_name", True),
    ("", False),
    ("-leading-dash", False),
    ("../escape", False),
    ("with space", False),
    ("with/slash", False),
    ("with;semicolon", False),
])
def test_is_valid_identifier(identifier, expected):
    assert srv.is_valid_identifier(identifier) is expected


# --- build_authorized_keys_line / identifier_from_line ----------------------

def test_build_and_parse_round_trip():
    pubkey = "ssh-ed25519 AAAAtest host-comment"
    line = srv.build_authorized_keys_line(pubkey, "/var/borgbackup/myhost")
    assert line == (
        'command="borg serve --restrict-to-repository /var/borgbackup/myhost"'
        ',restrict ssh-ed25519 AAAAtest host-comment'
    )
    assert srv.identifier_from_line(line) == "myhost"


def test_identifier_from_line_no_match():
    assert srv.identifier_from_line("ssh-ed25519 AAAAtest no-restriction-here") is None


# --- enroll_lines ------------------------------------------------------------

def test_enroll_lines_appends_new():
    existing = ["command=\"...\",restrict ssh-ed25519 AAAAother"]
    new_line = 'command="borg serve --restrict-to-repository /var/borgbackup/host2",restrict ssh-ed25519 AAAAnew'
    updated, already_present = srv.enroll_lines(existing, "ssh-ed25519 AAAAnew", new_line)
    assert already_present is False
    assert updated == existing + [new_line]


def test_enroll_lines_idempotent_on_existing_pubkey():
    pubkey = "ssh-ed25519 AAAAsame host-comment"
    existing = [srv.build_authorized_keys_line(pubkey, "/var/borgbackup/host1")]
    new_line = srv.build_authorized_keys_line(pubkey, "/var/borgbackup/host1")
    updated, already_present = srv.enroll_lines(existing, pubkey, new_line)
    assert already_present is True
    assert updated == existing


# --- revoke_lines ------------------------------------------------------------

def test_revoke_lines_removes_matching_identifier():
    line_a = srv.build_authorized_keys_line("ssh-ed25519 AAAAa", "/var/borgbackup/hosta")
    line_b = srv.build_authorized_keys_line("ssh-ed25519 AAAAb", "/var/borgbackup/hostb")
    kept, removed = srv.revoke_lines([line_a, line_b], "hosta")
    assert kept == [line_b]
    assert removed == 1


def test_revoke_lines_no_match():
    line_a = srv.build_authorized_keys_line("ssh-ed25519 AAAAa", "/var/borgbackup/hosta")
    kept, removed = srv.revoke_lines([line_a], "nonexistent")
    assert kept == [line_a]
    assert removed == 0


def test_revoke_lines_removes_all_matching_duplicates():
    # Two stale entries for the same identifier (e.g. from a prior key
    # rotation) should both be removed by one revoke call.
    line1 = srv.build_authorized_keys_line("ssh-ed25519 AAAA1", "/var/borgbackup/hosta")
    line2 = srv.build_authorized_keys_line("ssh-ed25519 AAAA2", "/var/borgbackup/hosta")
    kept, removed = srv.revoke_lines([line1, line2], "hosta")
    assert kept == []
    assert removed == 2
