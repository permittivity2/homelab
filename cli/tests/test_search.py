"""`homelab-cli search`: the site search, with the calendar as a source (#90)."""
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


EVENT = {"id": 7, "title": "Haircut at Par Exsalonce", "location": "11849 College Blvd", "calendar": "My calendar",
         "start": "2026-11-16T13:30:00", "end": "2026-11-16T14:30:00", "all_day": 0, "is_recurring": 0,
         "when": "Mon, Nov 16 · 1:30 – 2:30 PM", "url": "https://calendar.example/?date=2026-11-16&event=7"}
MAIL = {"message_id": 1, "subject": "Haircut receipt", "mailbox": "INBOX", "from_addr": "shop@example.com",
        "sent_at": "2026-11-10 10:00:00-06", "size_bytes": 1200}


def test_search_prints_the_calendar_first_and_asks_for_related(capsys):
    body = {"account": "test@example.com", "indexed": True, "filters": {}, "mail": [MAIL], "drive": [],
            "calendar": {"ok": 1, "events": [EVENT],
                         "related": [dict(EVENT, id=9, title="Barber", why="a haircut by another name")],
                         "related_note": None, "ai": {"available": 1, "enabled": 1}}}
    with patch("requests.request", return_value=_resp(200, body)) as req:
        assert main(["search", "haircut"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/search")
    assert req.call_args.kwargs["params"] == {"q": "haircut", "limit": 25, "related": 1}
    out = capsys.readouterr().out
    assert out.index("CALENDAR (1)") < out.index("EMAIL (1)")
    assert "Haircut at Par Exsalonce" in out and "Mon Nov 16" in out and "My calendar" in out
    assert "Related by meaning" in out and "Barber" in out and "a haircut by another name" in out
    assert "Haircut receipt" in out


def test_search_source_words_and_no_related(capsys):
    body = {"indexed": True, "mail": [], "drive": [], "calendar": None}
    with patch("requests.request", return_value=_resp(200, body)) as req:
        assert main(["search", "haircut", "--source", "mail", "--no-related"]) == 0
    assert req.call_args.kwargs["params"] == {"q": "haircut", "source": "mail", "limit": 25}
    assert "No matches." in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(200, body)) as req:
        assert main(["search", "haircut", "--source", "calendar"]) == 0
    assert req.call_args.kwargs["params"] == {"q": "haircut", "source": "calendar", "limit": 25, "related": 1}


def test_search_says_where_the_calendar_ai_switch_is(capsys):
    body = {"indexed": True, "mail": [], "drive": [],
            "calendar": {"ok": 1, "events": [], "related": [], "related_note": "Turn on AI in Settings to also find events by meaning.",
                         "ai": {"available": 1, "enabled": 0}}}
    with patch("requests.request", return_value=_resp(200, body)):
        assert main(["search", "doctor"]) == 0
    out = capsys.readouterr().out
    assert "Turn on AI in the calendar's settings to also find events by meaning." in out
    assert "No matches." not in out


def test_search_calendar_failure_and_empty_index(capsys):
    body = {"indexed": False, "mail": [], "drive": [], "calendar": {"ok": 0, "error": "unavailable", "status": 502}}
    with patch("requests.request", return_value=_resp(200, body)):
        assert main(["search", "doctor"]) == 0
    out = capsys.readouterr().out
    assert "CALENDAR" in out and "could not be searched just now" in out
    assert "Nothing of yours has been indexed yet." in out


def test_search_json_carries_the_calendar(capsys):
    body = {"indexed": True, "mail": [], "drive": [], "calendar": {"ok": 1, "events": [EVENT], "related": [], "ai": {}}}
    with patch("requests.request", return_value=_resp(200, body)):
        assert main(["-j", "search", "haircut"]) == 0
    assert json.loads(capsys.readouterr().out)["calendar"]["events"][0]["id"] == 7
