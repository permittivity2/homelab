"""`homelab-cli calendar devices`: the app passwords a phone signs in to CalDAV with (#84)."""
import json
from unittest.mock import Mock, patch

import pytest

from homelab_cli import config as cfgmod
from homelab_cli.cli import main


def _resp(status, body=None):
    r = Mock()
    r.ok = 200 <= status < 300
    r.status_code = status
    r.json.return_value = body
    r.text = json.dumps(body)
    return r


@pytest.fixture(autouse=True)
def _isolated_config(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    monkeypatch.setattr(cfgmod, "PROFILES_FILE", tmp_path / "profiles.yml")
    monkeypatch.setattr(cfgmod, "_LEGACY_SESSION_FILE", tmp_path / "session.yml")
    cfgmod.save_config({"api_base": "http://localhost:3000"})
    cfgmod.upsert_profile("test@example.com", "tok", "rt")
    cfgmod.set_active("test@example.com")


def test_devices_list(capsys):
    body = {"devices": [{"id": 3, "label": "Dana's iPhone", "created_at": "2026-11-17 01:00:00-06",
                         "last_used_at": None, "last_used_agent": None}],
            "server": "https://calendar.example", "username": "test@example.com"}
    with patch("requests.request", return_value=_resp(200, body)) as req:
        assert main(["calendar", "devices"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/calendar/devices")
    out = capsys.readouterr().out
    assert "Dana's iPhone" in out and "never" in out and "https://calendar.example" in out
    with patch("requests.request", return_value=_resp(200, {"devices": [], "server": "s", "username": "u"})):
        assert main(["calendar", "devices", "list"]) == 0
    assert "No devices" in capsys.readouterr().out


def test_devices_add_shows_the_secret_once(capsys):
    made = {"id": 4, "label": "Dana's iPhone", "secret": "abcd-efgh-jkmn-pqrs-tuvw-xyz2",
            "server": "https://calendar.example", "username": "test@example.com"}
    with patch("requests.request", return_value=_resp(201, made)) as req:
        assert main(["calendar", "devices", "add", "Dana's", "iPhone"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/calendar/devices")
    assert req.call_args.kwargs["json"] == {"label": "Dana's iPhone"}
    out = capsys.readouterr().out
    assert "abcd-efgh-jkmn-pqrs-tuvw-xyz2" in out and "shown once" in out and "https://calendar.example" in out


def test_devices_revoke(capsys):
    with patch("requests.request", return_value=_resp(200, {"ok": True, "id": 4})) as req:
        assert main(["calendar", "devices", "revoke", "4"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/calendar/devices/4/revoke")
    assert "Revoked device 4" in capsys.readouterr().out


def test_devices_json(capsys):
    body = {"devices": [{"id": 3, "label": "L"}], "server": "s", "username": "u"}
    with patch("requests.request", return_value=_resp(200, body)):
        assert main(["-j", "calendar", "devices"]) == 0
    assert json.loads(capsys.readouterr().out)["devices"][0]["id"] == 3
