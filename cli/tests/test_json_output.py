"""Tests for the global -j/--json output mode. The contract: every
command prints the REAL API response as one JSON payload -- never a
hand-written human sentence, and never a table's derived/friendly
display value (e.g. "send+receive" built from a boolean) -- and a
failure becomes {"error": "..."} on stderr instead of the usual
plaintext line.

Drives main() end-to-end (mocked HTTP only via requests.request), the
same approach test_config.py's _client()-wiring test already uses --
this is fundamentally about argparse + _emit/_emit_error + Client all
wired together, not any one piece in isolation, so table-driven
coverage over a representative sample of command SHAPES (list, show,
create/action, error) is more useful here than one test per command."""

import json
from unittest.mock import Mock, patch

import pytest

from homelab_cli import config as cfgmod
from homelab_cli.cli import main


def _mock_response(status_code, json_body):
    resp = Mock()
    resp.ok = 200 <= status_code < 300
    resp.status_code = status_code
    resp.json.return_value = json_body
    resp.text = str(json_body)
    return resp


@pytest.fixture(autouse=True)
def _isolated_config(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    cfgmod.save_config({"api_base": "http://localhost:3000"})
    cfgmod.save_session({"email": "test@example.com", "token": "tok", "refresh_token": "rt"})


# --- Representative command shapes --------------------------------------

def test_json_list_command_emits_raw_api_array(capsys):
    domains = [{"id": 1, "domain_name": "forge.name", "active": True, "mail_enabled": True, "dns_managed": True}]
    with patch("requests.request", return_value=_mock_response(200, domains)):
        code = main(["-j", "dns", "domains", "list"])
    assert code == 0
    assert json.loads(capsys.readouterr().out) == domains


def test_json_show_command_emits_raw_api_object(capsys):
    domain = {
        "domain_name": "forge.name", "active": True, "mail_enabled": True,
        "dns_managed": True, "created_by": "x", "created_at": "2026-01-01",
    }
    with patch("requests.request", return_value=_mock_response(200, domain)):
        code = main(["-j", "dns", "domains", "show", "forge.name"])
    assert code == 0
    assert json.loads(capsys.readouterr().out) == domain


def test_json_action_command_emits_real_api_response_not_a_sentence(capsys):
    alias = {"source_pattern": "@forge.name", "destination": "me@example.com", "active": True, "send_enabled": True}
    with patch("requests.request", return_value=_mock_response(201, alias)):
        code = main(["-j", "dns", "mail-aliases", "add", "@forge.name", "me@example.com"])
    assert code == 0
    out = capsys.readouterr().out
    assert json.loads(out) == alias
    assert "Added" not in out  # the human sentence must not leak into JSON mode


def test_json_error_is_valid_json_on_stderr(capsys):
    with patch("requests.request", return_value=_mock_response(404, {"error": "not found"})):
        code = main(["-j", "dns", "domains", "show", "nope.example"])
    assert code == 1
    payload = json.loads(capsys.readouterr().err)
    assert payload["error"] == "Could not show domain: not found"


def test_json_login_omits_the_token_but_still_saves_the_session(capsys):
    """The token/refresh_token are already written to session.yml
    (0600) -- no reason to also put a live credential on -j stdout for
    a shell history/log/captured pipeline to pick up."""
    with patch("requests.request", return_value=_mock_response(200, {"token": "secret-jwt", "refresh_token": "secret-refresh"})):
        code = main(["-j", "login", "you@example.com", "--password", "pw"])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"success": True, "email": "you@example.com"}
    assert "secret-jwt" not in json.dumps(out)
    assert cfgmod.load_session()["token"] == "secret-jwt"  # still persisted for real use


def test_json_no_session_error_is_also_json(capsys, tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "no-such-session.yml")
    code = main(["-j", "dns", "domains", "list"])
    assert code == 1
    payload = json.loads(capsys.readouterr().err)
    assert "Not logged in" in payload["error"]


# --- No regression: -j is fully opt-in ----------------------------------

def test_human_mode_output_unchanged_by_the_json_feature(capsys):
    domains = [{"id": 1, "domain_name": "forge.name", "active": True, "mail_enabled": True, "dns_managed": True}]
    with patch("requests.request", return_value=_mock_response(200, domains)):
        code = main(["dns", "domains", "list"])
    assert code == 0
    out = capsys.readouterr().out
    assert "DOMAIN" in out and "forge.name" in out
    with pytest.raises(json.JSONDecodeError):
        json.loads(out)


def test_human_mode_error_still_plaintext_not_json(capsys):
    with patch("requests.request", return_value=_mock_response(404, {"error": "not found"})):
        code = main(["dns", "domains", "show", "nope.example"])
    assert code == 1
    err = capsys.readouterr().err
    assert "Could not show domain" in err
    with pytest.raises(json.JSONDecodeError):
        json.loads(err)


# --- The friction point called out in the design: JSON must carry real
# API fields, never a table's derived/friendly display strings. ---------

def test_json_mail_aliases_list_keeps_real_booleans_not_display_strings(capsys):
    entries = [{"source_pattern": "@forge.name", "destination": "me@x.com", "active": True, "send_enabled": False}]
    with patch("requests.request", return_value=_mock_response(200, entries)):
        code = main(["-j", "dns", "mail-aliases", "list"])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == entries  # NOT "inactive"/"receive-only" -- the real active/send_enabled booleans
    assert out[0]["send_enabled"] is False


def test_json_admin_users_list_keeps_real_types_not_joined_strings(capsys):
    users = [{"id": 1, "email": "a@b.com", "active": True, "roles": ["user", "site_admin"]}]
    with patch("requests.request", return_value=_mock_response(200, users)):
        code = main(["-j", "admin", "users", "list"])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == users
    assert out[0]["active"] is True  # not the string "active"
    assert out[0]["roles"] == ["user", "site_admin"]  # not ", "-joined into one string


def test_json_admin_roles_list_keeps_real_array_and_boolean(capsys):
    roles = [{"name": "auditor", "protected": False, "permissions": ["audit.view"]}]
    with patch("requests.request", return_value=_mock_response(200, roles)):
        code = main(["-j", "admin", "roles", "list"])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == roles
    assert out[0]["protected"] is False  # not the string "no"
    assert out[0]["permissions"] == ["audit.view"]  # not ", "-joined, and not "(none)" when empty elsewhere


def test_json_sessions_list_keeps_full_jti_and_raw_user_agent(capsys):
    """The human table truncates jti to 12 chars and runs user_agent
    through summarize_user_agent() for display -- JSON mode must see
    neither transformation."""
    sessions = [{
        "jti": "a" * 64,
        "user_agent": "Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0",
        "ip_address": "203.0.113.5",
        "first_seen_at": "2026-01-01 00:00:00.123456-05",
        "current": True,
    }]
    with patch("requests.request", return_value=_mock_response(200, sessions)):
        code = main(["-j", "sessions", "list"])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == sessions
    assert out[0]["jti"] == "a" * 64  # not truncated to 12 chars
    assert "Firefox" not in json.dumps(out) or out[0]["user_agent"].startswith("Mozilla")  # raw string, not summarized


def test_json_drive_list_keeps_separate_folders_and_files_shape(capsys):
    """The human table unifies folders+files into one set of rows with
    a synthesized TYPE column -- JSON mode must return the two real,
    separately-shaped API responses instead."""
    folders_resp = [{"id": 1, "name": "Photos"}]
    files_resp = [{"id": 2, "filename": "a.txt", "size_bytes": 10, "uploaded_at": "2026-01-01"}]
    with patch("requests.request", side_effect=[_mock_response(200, folders_resp), _mock_response(200, files_resp)]):
        code = main(["-j", "drive", "list"])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"folders": folders_resp, "files": files_resp}


def test_json_download_command_never_prints_file_bytes(capsys, tmp_path):
    dest = tmp_path / "out.txt"
    resp = Mock()
    resp.ok = True
    resp.status_code = 200
    resp.iter_content = lambda chunk_size: [b"hello world"]
    with patch("requests.request", return_value=resp):
        code = main(["-j", "drive", "download", "42", "--output", str(dest)])
    assert code == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"downloaded_to": str(dest), "size_bytes": 11}
    assert "hello" not in json.dumps(out)
