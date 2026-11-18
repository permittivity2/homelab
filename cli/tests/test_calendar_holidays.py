"""`homelab-cli calendar holidays [on|off]`: the built-in US holidays calendar (#92)."""
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


STATE = {"on": False, "name": "US Holidays", "calendar_id": 12, "events": 404, "from_year": 2025, "through_year": 2036,
         "filled_at": "2026-11-17 20:00:00-06",
         "check": {"year": 2027, "checked_at": "2026-11-17 20:00:05-06", "ok": True, "unknown": [], "note": "17 rows from date.nager.at"}}


def test_holidays_show(capsys):
    with patch("requests.request", return_value=_resp(200, STATE)) as req:
        assert main(["calendar", "holidays"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/calendar/holidays")
    out = capsys.readouterr().out
    assert "US Holidays: off" in out
    assert "404 days 2025-2036" in out
    assert "Nager.Date for 2027 on 2026-11-17: nothing new" in out
    assert "homelab-cli calendar holidays on" in out


def test_holidays_on_and_off(capsys):
    on = dict(STATE, on=True, check=None)
    with patch("requests.request", return_value=_resp(200, on)) as req:
        assert main(["calendar", "holidays", "on"]) == 0
    assert req.call_args.args[:2] == ("PUT", "http://localhost:3000/api/v1/calendar/holidays")
    assert req.call_args.kwargs["json"] == {"on": True}
    out = capsys.readouterr().out
    assert "US Holidays: on (switched just now)" in out and "Nager" not in out and "Switch on" not in out
    with patch("requests.request", return_value=_resp(200, dict(STATE, on=False))) as req:
        assert main(["calendar", "holidays", "off"]) == 0
    assert req.call_args.kwargs["json"] == {"on": False}
    assert "US Holidays: off (switched just now)" in capsys.readouterr().out


def test_holidays_names_what_the_rules_do_not_know(capsys):
    body = dict(STATE, check=dict(STATE["check"], unknown=["Constitution Day"]))
    with patch("requests.request", return_value=_resp(200, body)):
        assert main(["calendar", "holidays"]) == 0
    assert "national holidays the rules do not know: Constitution Day" in capsys.readouterr().out
    failed = dict(STATE, check=dict(STATE["check"], ok=False, note="HTTP 503"))
    with patch("requests.request", return_value=_resp(200, failed)):
        assert main(["calendar", "holidays"]) == 0
    assert "failed on 2026-11-17; it is tried again daily" in capsys.readouterr().out


def test_holidays_json_and_errors(capsys):
    with patch("requests.request", return_value=_resp(200, STATE)):
        assert main(["--json", "calendar", "holidays"]) == 0
    assert json.loads(capsys.readouterr().out)["through_year"] == 2036
    with patch("requests.request", return_value=_resp(401, {"error": "Sign in first."})):
        assert main(["calendar", "holidays", "on"]) == 1
    assert "Could not switch the holidays" in capsys.readouterr().err
    with pytest.raises(SystemExit):
        main(["calendar", "holidays", "maybe"])
