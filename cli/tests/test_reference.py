"""homelab-cli against the API reference (../developer/reference/*.yml,
published as developer.mailmasker.org by homelab-developer).

The rule (post-cutover item 49): an API call homelab-cli makes is
documented in homelab-developer FIRST, and homelab-cli changes after. These
tests are what hold it:

- every API call in homelab_cli/client.py has an entry in the reference,
  so a new call without one fails here, and with it the package build;
- every `cli:` command the reference shows runs through homelab-cli's real
  argument parser, so the site can never show a command that doesn't
  exist or takes other arguments.

Abilities with `cli: none` are the gap list: no command yet.
"""

import ast
import pathlib
import shlex

import pytest
import yaml

from homelab_cli.cli import build_parser

HERE = pathlib.Path(__file__).resolve()
REFERENCE = HERE.parents[2] / "developer" / "reference"
CLIENT = HERE.parents[1] / "homelab_cli" / "client.py"
# What the site fills in for {me} and {domain}.
FILL = {"{me}": "you@example.com", "{domain}": "example.com"}
METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE"}


def _abilities():
    for path in sorted(REFERENCE.glob("*.yml")):
        doc = yaml.safe_load(path.read_text()) or {}
        for ability in doc.get("abilities") or []:
            yield path.name, ability


def _commands():
    out = []
    for name, ability in _abilities():
        cli = ability.get("cli")
        if ability.get("who") == "fleet" or not cli or cli == "none":
            continue
        for key, value in FILL.items():
            cli = cli.replace(key, value)
        out.append(pytest.param(cli, id=f"{name}:{ability.get('id')}"))
    return out


def _path_text(node):
    """A path literal as text, each {expression} of an f-string as '{}'."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value if isinstance(v, ast.Constant) else "{}" for v in node.values)
    return None


def _paths_in(node):
    """Every /api/v1 path literal anywhere inside an expression (both arms of
    `a if x else b`, say)."""
    out = []
    # The literal pieces of an f-string are nodes of their own too: skip
    # them, so f"/api/v1/x/{y}" counts once, whole.
    pieces = {id(v) for sub in ast.walk(node) if isinstance(sub, ast.JoinedStr) for v in sub.values}
    for sub in ast.walk(node):
        text = None if id(sub) in pieces else _path_text(sub)
        if text and text.startswith("/api/v1"):
            out.append(text)
    return out


def _client_calls():
    """(method, path, line) for every self._request(...) in client.py. A path
    held in a variable is followed to what the function assigns it."""
    tree = ast.parse(CLIENT.read_text())
    calls = []
    for func in ast.walk(tree):
        if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        assigned = {}
        for node in ast.walk(func):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        assigned.setdefault(target.id, []).append(node.value)
        for node in ast.walk(func):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "_request" and len(node.args) >= 2):
                continue
            method, path = node.args[0], node.args[1]
            if not (isinstance(method, ast.Constant) and method.value in METHODS):
                continue
            if isinstance(path, ast.Name):
                paths = [p for value in assigned.get(path.id, []) for p in _paths_in(value)]
            else:
                paths = _paths_in(path)
            calls.extend((method.value, p, node.lineno) for p in paths)
    return calls


def _documented(method, path, entries):
    """Whether some entry is this call: same method, and the same path segment
    by segment, where the client's {} and the entry's :name match anything."""
    want = path.split("?", 1)[0].rstrip("/").split("/")
    for e_method, e_path in entries:
        if e_method != method:
            continue
        have = e_path.rstrip("/").split("/")
        if len(have) == len(want) and all(
                w == "{}" or h.startswith(":") or w == h for w, h in zip(want, have)):
            return True
    return False


def test_reference_is_there():
    assert REFERENCE.is_dir(), f"{REFERENCE} is missing"
    assert any(True for _ in _abilities()), "no abilities in the reference"


def test_the_client_is_read():
    calls = _client_calls()
    # client.py has had well over 60; far fewer means this test stopped
    # finding them, not that the client shrank.
    assert len(calls) > 60, f"only {len(calls)} API calls found in {CLIENT}"
    assert ("POST", "/api/v1/auth/login") in {(m, p) for m, p, _ in calls}


def test_every_api_call_homelab_cli_makes_is_documented():
    entries = [(a.get("method"), a.get("path") or "") for _, a in _abilities()]
    missing = sorted({f"{m} {p}  (client.py line {line})" for m, p, line in _client_calls()
                      if not _documented(m, p, entries)})
    assert not missing, (
        "homelab-cli calls these, but developer/reference/ has no entry for them.\n"
        "Document them in homelab-developer first (see developer/reference/README.md), "
        "then change homelab-cli:\n  " + "\n  ".join(missing))


@pytest.mark.parametrize("command", _commands())
def test_every_command_the_reference_shows_parses(command):
    argv = shlex.split(command)
    assert argv[0] == "homelab-cli", f"not a homelab-cli command: {command}"
    try:
        build_parser().parse_args(argv[1:])
    except SystemExit as e:  # argparse's way of saying "no such command / bad arguments"
        pytest.fail(f"homelab-cli does not accept: {command} (exit {e.code})")


def test_gap_list_is_reported():
    """Not a failure: prints the abilities with no command yet (pytest -s)."""
    gaps = [f"{name}:{a.get('id')}" for name, a in _abilities()
            if a.get("who") != "fleet" and a.get("cli") == "none"]
    print(f"\n{len(gaps)} abilities have no homelab-cli command yet:")
    for gap in gaps:
        print(f"  {gap}")


def test_the_matcher():
    entries = [("GET", "/api/v1/drive/files/:id"), ("POST", "/api/v1/drive/folders/:id/restore")]
    assert _documented("GET", "/api/v1/drive/files/{}", entries)
    assert _documented("POST", "/api/v1/drive/{}/{}/restore", entries)
    assert not _documented("DELETE", "/api/v1/drive/files/{}", entries), "the method counts"
    assert not _documented("GET", "/api/v1/drive/files/{}/thumb", entries), "so does every segment"
