"""homelab-cli calendar (post-cutover #82): the WHEN column's formatting, and
the commands end to end through main() with requests.request mocked, the way
test_json_output.py does it."""

import json
from unittest.mock import Mock, patch

import pytest

from homelab_cli import config as cfgmod
from homelab_cli.cli import _calendar_when, main


def _resp(status, body=None, text=None):
    r = Mock()
    r.ok = 200 <= status < 300
    r.status_code = status
    if text is not None:
        r.text = text
        r.json.side_effect = ValueError("not json")
    else:
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


# --- the WHEN column ---------------------------------------------------------

def test_when_timed_same_day():
    assert _calendar_when({"all_day": False, "start": "2026-11-20T14:30:00", "end": "2026-11-20T15:30:00"}) == "Fri Nov 20  2:30 PM - 3:30 PM"


def test_when_timed_across_midnight():
    assert _calendar_when({"all_day": False, "start": "2026-11-20T23:00:00", "end": "2026-11-21T01:00:00"}) == "Fri Nov 20  11:00 PM - Sat Nov 21 1:00 AM"


def test_when_all_day_one_day():
    assert _calendar_when({"all_day": True, "start": "2026-11-20", "end": "2026-11-21"}) == "Fri Nov 20  all day"


def test_when_all_day_several_days_end_is_exclusive():
    assert _calendar_when({"all_day": True, "start": "2026-11-20", "end": "2026-11-23"}) == "Fri Nov 20 - Sun Nov 22  all day"


def test_when_unreadable_dates_fall_back_to_the_raw_strings():
    assert _calendar_when({"all_day": False, "start": "soon", "end": "later"}) == "soon - later"


# --- the commands through main() --------------------------------------------

LIST = {
    "timezone": "America/Chicago", "from": "2026-11-20T00:00:00", "to": "2026-11-21T00:00:00",
    "page": 1, "pages": 1, "limit": 50, "total": 1,
    "events": [{
        "id": 7, "occurrence": None, "title": "Dentist", "all_day": False,
        "start": "2026-11-20T14:30:00", "end": "2026-11-20T15:30:00", "location": "Delta Dental",
        "calendar": {"id": 1, "name": "Personal"}, "permission": "owner",
    }],
}


def test_list_json_is_the_raw_response(capsys):
    with patch("requests.request", return_value=_resp(200, LIST)) as req:
        assert main(["-j", "calendar", "list", "--from", "2026-11-20", "--to", "2026-11-20"]) == 0
    assert json.loads(capsys.readouterr().out) == LIST
    params = req.call_args.kwargs["params"]
    assert params["from"] == "2026-11-20" and params["to"] == "2026-11-20"
    assert params["limit"] == 50 and params["page"] == 1


def test_list_human_table_and_footer(capsys):
    with patch("requests.request", return_value=_resp(200, LIST)):
        assert main(["calendar", "list"]) == 0
    out = capsys.readouterr().out
    assert "Fri Nov 20  2:30 PM - 3:30 PM" in out
    assert "Dentist" in out and "Delta Dental" in out and "Personal" in out
    assert "1 event" in out and "page 1 of 1" in out


def test_list_offers_the_next_page(capsys):
    more = dict(LIST, page=1, pages=3, total=120)
    with patch("requests.request", return_value=_resp(200, more)):
        assert main(["calendar", "list", "--from", "2026-11-20"]) == 0
    assert "--page 2" in capsys.readouterr().out


def test_list_empty_range(capsys):
    with patch("requests.request", return_value=_resp(200, dict(LIST, total=0, events=[]))):
        assert main(["calendar", "list"]) == 0
    assert "(no events" in capsys.readouterr().out


def test_add_sends_the_event_and_prints_it(capsys):
    created = dict(LIST["events"][0], reminder_minutes=10)
    with patch("requests.request", return_value=_resp(201, created)) as req:
        assert main(["calendar", "add", "Dentist", "--start", "2026-11-20T14:30", "--end", "2026-11-20T15:30",
                     "--location", "Delta Dental", "--reminder", "10"]) == 0
    body = req.call_args.kwargs["json"]
    assert body["title"] == "Dentist" and body["start"] == "2026-11-20T14:30" and body["end"] == "2026-11-20T15:30"
    assert body["location"] == "Delta Dental" and body["reminder_minutes"] == 10 and body["all_day"] is False
    assert "Added event 7" in capsys.readouterr().out


def test_add_all_day_sends_no_end_and_no_reminder_when_none(capsys):
    created = dict(LIST["events"][0], all_day=True, start="2026-11-20", end="2026-11-21")
    with patch("requests.request", return_value=_resp(201, created)) as req:
        assert main(["calendar", "add", "Fair", "--start", "2026-11-20", "--all-day", "--reminder", "none"]) == 0
    body = req.call_args.kwargs["json"]
    assert body["all_day"] is True and body["start"] == "2026-11-20" and "end" not in body
    assert body["reminder_minutes"] is None


def test_export_with_a_range_writes_the_file(tmp_path):
    ics = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
    dest = tmp_path / "out.ics"
    with patch("requests.request", return_value=_resp(200, text=ics)) as req:
        assert main(["calendar", "export", "--from", "today", "-o", str(dest)]) == 0
    assert dest.read_bytes().decode() == ics, "written byte for byte, CRLF kept"
    assert req.call_args.args[1].endswith("/api/v1/calendar/events.ics")


def test_export_without_a_range_is_the_whole_calendar_on_stdout(capsys):
    ics = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
    with patch("requests.request", return_value=_resp(200, text=ics)) as req:
        assert main(["calendar", "export"]) == 0
    assert capsys.readouterr().out == ics
    assert req.call_args.args[1].endswith("/api/v1/calendar/export.ics")


def test_import_sends_the_file_as_text_calendar(tmp_path, capsys):
    src = tmp_path / "in.ics"
    src.write_bytes(b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
    result = {"created": 1, "updated": 0, "skipped": [{"uid": "x", "reason": "no start (DTSTART)"}],
              "events": [LIST["events"][0]], "calendar": {"id": 1, "name": "Personal"}}
    with patch("requests.request", return_value=_resp(200, result)) as req:
        assert main(["calendar", "import", str(src)]) == 0
    kw = req.call_args.kwargs
    assert kw["headers"]["Content-Type"].startswith("text/calendar")
    assert kw["data"] == src.read_bytes()
    out = capsys.readouterr().out
    assert "1 new" in out and "skipped 1" in out and "no start" in out


def test_calendars_table(capsys):
    cals = {"timezone": "America/Chicago",
            "own": [{"id": 1, "name": "Personal", "timezone": "America/Chicago", "is_default": True, "permission": "owner", "owner_email": "test@example.com"}],
            "shared": [{"id": 9, "name": "Family", "timezone": "America/Chicago", "is_default": False, "permission": "read", "owner_email": "someone@example.com"}]}
    with patch("requests.request", return_value=_resp(200, cals)):
        assert main(["calendar", "calendars"]) == 0
    out = capsys.readouterr().out
    assert "Personal" in out and "Family" in out and "read" in out


def test_errors_are_json_on_stderr_in_json_mode(capsys):
    with patch("requests.request", return_value=_resp(400, {"error": "The to date must come after the from date."})):
        assert main(["-j", "calendar", "list", "--from", "2026-11-21", "--to", "2026-11-20"]) == 1
    err = json.loads(capsys.readouterr().err)
    assert "to date" in err["error"]
