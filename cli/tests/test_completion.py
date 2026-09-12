import io

import argcomplete
import pytest

from homelab_cli.cli import KNOWN_ROLES, build_parser


class _TestCompletionFinder(argcomplete.CompletionFinder):
    """argcomplete's own CompletionFinder tries to open fd 9 for debug
    output, falling back to sys.stderr on failure -- both clash under
    pytest's captured environment (see CompletionFinder._init_debug_stream's
    own docstring, which explicitly names pytest as the reason this
    override point exists) and surface as a noisy-but-harmless
    "Bad file descriptor" warning during finalization. No debug output
    is needed here, so this is just a safe no-op."""

    def _init_debug_stream(self):
        pass


def _completions(monkeypatch, command_line):
    """Simulates pressing <TAB> at the end of command_line and returns
    the resulting completion candidates, using argcomplete's own
    CompletionFinder (the same class argcomplete.autocomplete(), wired
    into cli.py's main(), uses internally) rather than shelling out to a
    real bash process.

    A fresh build_parser() per call is required -- reusing one parser
    instance across multiple completion queries in the same process
    returns stale/wrong results from the second call on (verified
    manually while building this). Not an issue in real usage: a shell
    spawns a brand-new homelab-cli process, and therefore a brand-new
    parser, on every single tab press.
    """
    monkeypatch.setenv("_ARGCOMPLETE", "1")
    monkeypatch.setenv("COMP_LINE", command_line)
    monkeypatch.setenv("COMP_POINT", str(len(command_line)))
    finder = _TestCompletionFinder()
    stream = io.StringIO()
    finder(build_parser(), exit_method=lambda code=0: None, output_stream=stream)
    value = stream.getvalue()
    # argcomplete appends a trailing space to a uniquely-matched
    # completion (the same nicety bash's own filename completion does),
    # which isn't part of the logical completion text -- stripped here
    # so callers can compare plain command/choice names.
    return [c.rstrip(" ") for c in value.split("\x0b")] if value else []


def test_completes_top_level_command_prefix(monkeypatch):
    assert "drive" in _completions(monkeypatch, "homelab-cli dri")


def test_completes_all_top_level_commands(monkeypatch):
    completions = set(_completions(monkeypatch, "homelab-cli "))
    for command in ("configure", "register", "login", "whoami", "logout", "registry", "mail", "drive", "admin"):
        assert command in completions


def test_completes_drive_subcommands(monkeypatch):
    completions = set(_completions(monkeypatch, "homelab-cli drive "))
    assert completions >= {"list", "upload", "download", "delete", "mkdir", "rmdir"}


def test_completes_mail_subcommands(monkeypatch):
    completions = set(_completions(monkeypatch, "homelab-cli mail "))
    assert completions >= {"list", "read", "send"}


def test_completes_nested_subcommands_three_levels_deep(monkeypatch):
    # admin -> users -> {list, grant-role, revoke-role}
    completions = set(_completions(monkeypatch, "homelab-cli admin users "))
    assert completions >= {"list", "grant-role", "revoke-role"}


def test_grant_role_does_not_restrict_completion_to_known_roles(monkeypatch):
    # `admin roles add` (added alongside role_permissions) means the
    # real set of roles is no longer just KNOWN_ROLES's two built-ins --
    # choices=KNOWN_ROLES was REMOVED from this positional on purpose
    # (see cli.py's comment at the grant-role/revoke-role parsers), so
    # there is no longer a fixed completion list here at all -- argparse
    # falls back to file-path-style completion for a plain, unconstrained
    # positional, which is not useful but also not wrong. This test
    # exists to catch a future regression (choices= creeping back in)
    # rather than to assert on the (uninteresting) exact fallback set.
    completions = set(_completions(monkeypatch, "homelab-cli admin users grant-role 5 "))
    assert not (set(KNOWN_ROLES) <= completions - {"-h", "--help"} and completions - set(KNOWN_ROLES) <= {"-h", "--help"}), (
        "grant-role's role argument should not be hard-restricted to KNOWN_ROLES any more -- "
        "a custom role created via 'admin roles add' must be grantable too"
    )


def test_custom_role_name_accepted_by_grant_role(monkeypatch):
    # The actual behavior that matters: a role name that isn't one of
    # the two built-ins parses fine and would reach the server -- the
    # server (not argparse) is what decides whether it's real, same
    # "just attempt the call, let the server decide" philosophy already
    # used for admin users/dns/mail commands throughout this file.
    parser = build_parser()
    args = parser.parse_args(["admin", "users", "grant-role", "5", "some-custom-role"])
    assert args.role == "some-custom-role"


def test_normal_parsing_unaffected_by_autocomplete_wiring():
    # Confirms argcomplete.autocomplete(parser) in main() didn't change
    # ordinary (non-completion) argument parsing -- it's documented (and
    # verified in argcomplete's own source) to be a no-op unless the
    # _ARGCOMPLETE env var is set, which a real shell only sets while
    # actually asking for completions.
    parser = build_parser()
    assert parser.parse_args(["whoami"]).command == "whoami"
    args = parser.parse_args(["admin", "users", "grant-role", "5", "site_admin"])
    assert args.role == "site_admin"


def test_unknown_role_name_no_longer_rejected_client_side():
    # Superseded by role_permissions/`admin roles add`: an arbitrary
    # role name must NOT be rejected at parse time any more, since it
    # might be a real, just-created custom role -- rejecting a truly
    # unknown one is now exclusively the server's job (a clean 400/404),
    # matching every other "just attempt the call" command in this file.
    parser = build_parser()
    args = parser.parse_args(["admin", "users", "grant-role", "5", "not-a-real-role"])
    assert args.role == "not-a-real-role"
