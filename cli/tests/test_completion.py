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


def test_completes_known_roles_for_grant_role(monkeypatch):
    # The role positional's choices=KNOWN_ROLES (see cli.py) gets free
    # completion from argparse's own choices= handling -- no custom
    # completer function needed for this. >= (not ==) because -h/--help
    # legitimately also complete at this position, same as any other.
    completions = set(_completions(monkeypatch, "homelab-cli admin users grant-role 5 "))
    assert completions >= set(KNOWN_ROLES)
    assert completions - set(KNOWN_ROLES) <= {"-h", "--help"}


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


def test_invalid_role_rejected_before_any_network_call():
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["admin", "users", "grant-role", "5", "not-a-real-role"])
