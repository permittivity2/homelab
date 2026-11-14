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


# --- 0.2.0 / cli 0.7.0: grouped output, durations, repeat flags, the new verbs ---

from homelab_cli.cli import _add_minutes, _build_rrule, _calendar_span, _duration_minutes  # noqa: E402


def test_span_and_24h():
    ev = {"all_day": False, "start": "2026-11-20T14:30:00", "end": "2026-11-20T15:30:00"}
    assert _calendar_span(ev) == "2:30 PM - 3:30 PM"
    assert _calendar_span(ev, True) == "14:30 - 15:30"
    assert _calendar_span({"all_day": True, "start": "2026-11-20", "end": "2026-11-21"}) == "all day"
    assert _calendar_span({"all_day": True, "start": "2026-11-20", "end": "2026-11-23"}) == "all day - Sun Nov 22"
    assert _calendar_when(ev, True) == "Fri Nov 20  14:30 - 15:30"


def test_durations():
    assert _duration_minutes("90m") == 90 and _duration_minutes("1h30m") == 90 and _duration_minutes("2h") == 120
    assert _duration_minutes("45") == 45 and _duration_minutes("2d") == 2880 and _duration_minutes("soon") is None
    assert _add_minutes("2026-11-20T14:30", 90) == "2026-11-20T16:00"
    assert _add_minutes("2026-11-20", 2880, all_day=True) == "2026-11-22"
    assert _add_minutes("soon", 10) is None


def test_rrule_builder():
    assert _build_rrule(None) is None
    assert _build_rrule("weekly") == "FREQ=WEEKLY"
    assert _build_rrule("weekly", every=2, on="mo,We", count=10) == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10"
    assert _build_rrule("daily", until="2026-12-31") == "FREQ=DAILY;UNTIL=20261231T235959Z"
    assert _build_rrule("yearly", until="2026-12-31", all_day=True) == "FREQ=YEARLY;UNTIL=20261231"


def test_list_week_sends_a_relative_end_and_the_zone(capsys):
    with patch("requests.request", return_value=_resp(200, dict(LIST, time_format="24h"))) as req:
        assert main(["calendar", "list", "--week", "--timezone", "Europe/Paris"]) == 0
    params = req.call_args.kwargs["params"]
    assert params["to"] == "+7d" and params["timezone"] == "Europe/Paris" and "from" not in params
    assert "14:30 - 15:30" in capsys.readouterr().out, "the account's 24-hour preference is honoured"


def test_list_days_and_grouping(capsys):
    two = dict(LIST, total=2, events=LIST["events"] + [dict(LIST["events"][0], id=8, title="Stand-up", start="2026-11-20T09:00:00", end="2026-11-20T09:15:00", is_recurring=True, permission="read")])
    with patch("requests.request", return_value=_resp(200, two)) as req:
        assert main(["calendar", "list", "--days", "3"]) == 0
    assert req.call_args.kwargs["params"]["to"] == "+3d"
    out = capsys.readouterr().out
    assert out.count("Fri Nov 20  ") == 1, "the day is printed once for the group (the footer writes it with single spaces)"
    assert "repeats, read-only" in out


def test_add_duration_and_weekly_flags(capsys):
    with patch("requests.request", return_value=_resp(201, LIST["events"][0])) as req:
        assert main(["calendar", "add", "Choir", "--start", "2026-11-20T19:00", "--duration", "1h30m", "--weekly", "--on", "mo,we", "--count", "4"]) == 0
    body = req.call_args.kwargs["json"]
    assert body["end"] == "2026-11-20T20:30" and body["repeat"] == "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4"


def test_show_prints_the_event(capsys):
    ev = dict(LIST["events"][0], reminders=[{"minutes_before": 10, "channel": "email"}, {"minutes_before": 60, "channel": "webhook"}],
              url="https://calendar.example.com/?date=2026-11-20&event=7", description="Bring the card")
    with patch("requests.request", return_value=_resp(200, ev)) as req:
        assert main(["calendar", "show", "7"]) == 0
    assert req.call_args.args[1].endswith("/api/v1/calendar/events/7")
    out = capsys.readouterr().out
    assert "Dentist" in out and "10 min before by email; 60 min before by webhook" in out and "Bring the card" in out and "event=7" in out


def test_edit_sends_only_what_changes_and_scope(capsys):
    with patch("requests.request", return_value=_resp(200, dict(LIST["events"][0], title="Dentist (moved)"))) as req:
        assert main(["calendar", "edit", "7", "--title", "Dentist (moved)", "--this", "--occurrence", "2026-11-20T20:30:00Z"]) == 0
    body = req.call_args.kwargs["json"]
    assert body == {"title": "Dentist (moved)", "scope": "this", "recurrence_id": "2026-11-20T20:30:00Z"}
    assert "Saved." in capsys.readouterr().out


def test_edit_with_nothing_to_change_is_an_error(capsys):
    assert main(["calendar", "edit", "7"]) == 1
    assert "Nothing to change" in capsys.readouterr().err


def test_delete_prints_the_restore_hint(capsys):
    with patch("requests.request", return_value=_resp(200, {"ok": True, "id": 7, "scope": "all", "restorable": True})) as req:
        assert main(["calendar", "delete", "7"]) == 0
    assert req.call_args.kwargs["json"] == {"scope": "all"}
    assert "homelab-cli calendar restore 7" in capsys.readouterr().out


def test_delete_this_needs_an_occurrence(capsys):
    assert main(["calendar", "delete", "7", "--this"]) == 1
    assert "--occurrence" in capsys.readouterr().err


def test_restore_and_trash(capsys):
    with patch("requests.request", return_value=_resp(200, LIST["events"][0])):
        assert main(["calendar", "restore", "7"]) == 0
    assert "Restored event 7" in capsys.readouterr().out
    trash = {"events": [dict(LIST["events"][0], deleted_at="2026-11-14T16:02:11")]}
    with patch("requests.request", return_value=_resp(200, trash)):
        assert main(["calendar", "trash"]) == 0
    out = capsys.readouterr().out
    assert "Sat Nov 14" in out and "Dentist" in out and "restore ID" in out


def test_search_groups_hits(capsys):
    with patch("requests.request", return_value=_resp(200, {"q": "dentist", "events": LIST["events"]})) as req:
        assert main(["calendar", "search", "dentist", "soon"]) == 0
    assert req.call_args.kwargs["params"] == {"q": "dentist soon"}
    assert "Dentist" in capsys.readouterr().out


def test_calendars_create_posts_the_name(capsys):
    with patch("requests.request", return_value=_resp(201, {"id": 9, "name": "Family", "timezone": "America/Chicago"})) as req:
        assert main(["calendar", "calendars", "create", "Family", "--color", "#1a2b3c"]) == 0
    assert req.call_args.kwargs["json"] == {"name": "Family", "color": "#1a2b3c"}
    assert "Made calendar 9" in capsys.readouterr().out


def test_share_with_an_account_and_by_link(capsys):
    share = {"id": 12, "shared_with_email": "someone@example.com", "permission": "read", "url": "https://c/e/x"}
    with patch("requests.request", return_value=_resp(201, share)) as req:
        assert main(["calendar", "share", "7", "--with", "someone@example.com"]) == 0
    assert req.call_args.args[1].endswith("/api/v1/calendar/events/7/shares")
    assert req.call_args.kwargs["json"]["email"] == "someone@example.com" and req.call_args.kwargs["json"]["permission"] == "read"
    link = {"id": 13, "shared_with_email": None, "permission": "read", "url": "https://c/c/x", "ics_url": "https://c/c/x.ics"}
    with patch("requests.request", return_value=_resp(201, link)) as req:
        assert main(["calendar", "share", "--calendar", "1", "--link"]) == 0
    assert req.call_args.args[1].endswith("/api/v1/calendar/calendars/1/shares") and req.call_args.kwargs["json"]["email"] is None
    assert "Feed for a phone" in capsys.readouterr().out


def test_share_needs_exactly_one_target(capsys):
    assert main(["calendar", "share", "--with", "someone@example.com"]) == 1
    assert "one of the two" in capsys.readouterr().err


def test_shares_and_unshare(capsys):
    with patch("requests.request", return_value=_resp(200, [{"id": 12, "shared_with_email": "someone@example.com", "permission": "edit", "expires_at": None, "url": "https://c/e/x"}])):
        assert main(["calendar", "shares", "7"]) == 0
    assert "see and edit" in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(200, {"ok": True})) as req:
        assert main(["calendar", "unshare", "12"]) == 0
    assert req.call_args.args[1].endswith("/api/v1/calendar/shares/12/revoke")


def test_suggestions_list_save_dismiss(capsys):
    sugg = {"suggestions": [{"token": "a" * 64, "subject": "Dentist moved", "from": "office@example.com",
                             "proposal": {"title": "Dentist", "start": "2026-11-23T14:30:00", "end": "2026-11-23T15:30:00", "all_day": False, "location": "Delta Dental"}}]}
    with patch("requests.request", return_value=_resp(200, sugg)):
        assert main(["calendar", "suggestions"]) == 0
    assert "Dentist" in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(201, LIST["events"][0])) as req:
        assert main(["calendar", "suggestions", "save", "a" * 64]) == 0
    assert req.call_args.args[1].endswith("/save")
    with patch("requests.request", return_value=_resp(200, {"ok": True})) as req:
        assert main(["calendar", "suggestions", "dismiss", "a" * 64]) == 0
    assert req.call_args.args[1].endswith("/dismiss")


PREFS = {"timezone": "America/Chicago", "week_start": 0, "time_format": "12h", "default_view": "month", "show_shared_events": True,
         "default_reminder_minutes": 10, "all_day_reminder_hour": 9, "default_duration_minutes": 60, "date_format": "mdy", "remind_shared": True, "webhook_url": None}


def test_settings_show_and_change(capsys):
    with patch("requests.request", return_value=_resp(200, PREFS)) as req:
        assert main(["calendar", "settings"]) == 0
    assert req.call_args.args[0] == "GET"
    assert "Dates written as" in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(200, dict(PREFS, date_format="dmy", default_reminder_minutes=15, remind_shared=False, webhook_url=None))) as req:
        assert main(["calendar", "settings", "--date-format", "dmy", "--default-reminder", "15", "--remind-shared", "off", "--webhook", "none", "--week-start", "mon"]) == 0
    assert req.call_args.args[0] == "PUT"
    assert req.call_args.kwargs["json"] == {"week_start": 1, "date_format": "dmy", "default_reminder_minutes": 15, "remind_shared": False, "webhook_url": ""}


def test_account_show_and_mail_links(capsys):
    acct = {"mail_links_enabled": False, "ai": {"available": True, "enabled": False}, "auto": {"enabled": False, "research_at_arrival_allowed": False}, "reminder_addresses": [], "settings_url": "https://c/settings"}
    with patch("requests.request", return_value=_resp(200, dict(acct, mail_links_enabled=True))) as req:
        assert main(["calendar", "account", "--mail-links", "on"]) == 0
    assert req.call_args.args[0] == "PUT" and req.call_args.kwargs["json"] == {"mail_links_enabled": True}
    assert "on" in capsys.readouterr().out


def test_import_dry_run(tmp_path, capsys):
    src = tmp_path / "in.ics"
    src.write_bytes(b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
    result = {"dry_run": True, "created": 2, "updated": 1, "skipped": [], "events": [{"action": "create", "title": "Fair", "start": "2026-12-05", "end": "2026-12-07", "all_day": True}], "calendar": {"name": "Personal"}}
    with patch("requests.request", return_value=_resp(200, result)) as req:
        assert main(["calendar", "import", str(src), "--dry-run"]) == 0
    assert req.call_args.kwargs["params"]["dry_run"] == "1"
    out = capsys.readouterr().out
    assert "Dry run: would create 2 and update 1" in out and "Nothing was written" in out and "Fair" in out


def test_errors_are_json_on_stderr_in_json_mode(capsys):
    with patch("requests.request", return_value=_resp(400, {"error": "The to date must come after the from date."})):
        assert main(["-j", "calendar", "list", "--from", "2026-11-21", "--to", "2026-11-20"]) == 1
    err = json.loads(capsys.readouterr().err)
    assert "to date" in err["error"]
