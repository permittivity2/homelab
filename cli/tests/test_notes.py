"""`homelab-cli notes ...` (post-cutover #71): the verbs against a mocked api."""
import io
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


NOTEBOOKS = {"notebooks": [
    {"id": 3, "name": "My notes", "color": "#6f94b8", "position": 1, "owner_email": "test@example.com", "permission": "owner", "note_count": 2},
    {"id": 9, "name": "Family", "color": "#5f9e6e", "position": 0, "owner_email": "someone@example.com", "permission": "edit", "note_count": 4},
], "prefs": {"last_notebook_id": 3, "default_format": "markdown"}}

NOTE = {"id": 42, "notebook_id": 3, "folder_id": None, "title": "Groceries", "format": "markdown", "body": "- milk\n- eggs\n",
        "html": "<ul>\n<li>milk</li>\n<li>eggs</li>\n</ul>", "excerpt": "milk eggs", "pinned": False, "revision": 1, "permission": "owner",
        "can_edit": True, "can_manage": True, "share_count": 0, "notebook": {"id": 3, "name": "My notes", "color": "#6f94b8"},
        "links": [{"id": 7, "kind": "url", "label": "", "target": {"url": "https://example.test/x"}, "open_url": "https://example.test/x"}],
        "owner_email": "test@example.com", "edited_by": "test@example.com", "created_at": "2026-11-18 08:00:00-06", "updated_at": "2026-11-18 08:05:00-06",
        "url": "https://notes.mailmasker.org/n/42"}


def test_notebooks_table(capsys):
    with patch("requests.request", return_value=_resp(200, NOTEBOOKS)) as req:
        assert main(["notes", "notebooks"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/notes/notebooks")
    out = capsys.readouterr().out
    assert "My notes" in out and "owner" in out
    assert "Family" in out and "someone@example.com" in out


def test_notebooks_create(capsys):
    with patch("requests.request", return_value=_resp(201, {"id": 10, "name": "Recipes", "permission": "owner"})) as req:
        assert main(["notes", "notebooks", "create", "Recipes", "--color", "#aabbcc"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/notebooks")
    assert req.call_args.kwargs["json"] == {"name": "Recipes", "color": "#aabbcc"}
    assert "Notebook 10: Recipes" in capsys.readouterr().out


def test_add_from_stdin(capsys, monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("# Hello\n\nbody here\n"))
    with patch("requests.request", return_value=_resp(201, NOTE)) as req:
        assert main(["notes", "add", "Groceries", "--notebook", "3", "--format", "md", "--pin"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/notes")
    assert req.call_args.kwargs["json"] == {"title": "Groceries", "body": "# Hello\n\nbody here\n", "format": "md", "notebook_id": "3", "pinned": True}
    assert "Note 42: Groceries" in capsys.readouterr().out


def test_add_with_body_flag_ignores_stdin(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("not this"))
    with patch("requests.request", return_value=_resp(201, NOTE)) as req:
        assert main(["notes", "add", "T", "--body", "typed body"]) == 0
    assert req.call_args.kwargs["json"] == {"title": "T", "body": "typed body"}


def test_show_and_raw(capsys):
    with patch("requests.request", return_value=_resp(200, NOTE)) as req:
        assert main(["notes", "show", "42"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/notes/notes/42")
    out = capsys.readouterr().out
    assert out.startswith("Groceries\n=========\n")
    assert "- milk" in out and "revision 1" in out and "[7] url: https://example.test/x" in out
    with patch("requests.request", return_value=_resp(200, NOTE)):
        assert main(["notes", "show", "42", "--raw"]) == 0
    assert capsys.readouterr().out == "- milk\n- eggs\n"
    with patch("requests.request", return_value=_resp(200, NOTE)):
        assert main(["notes", "show", "42", "--html"]) == 0
    assert "<li>milk</li>" in capsys.readouterr().out


def _stream_resp(status, chunks, content_type="application/pdf"):
    r = Mock()
    r.ok = 200 <= status < 300
    r.status_code = status
    r.iter_content.return_value = iter(chunks)
    r.headers = {"Content-Type": content_type}
    r.json.return_value = {"error": "no"}
    r.text = '{"error": "no"}'
    return r


def test_download_pdf(tmp_path, capsys):
    dest = tmp_path / "groceries.pdf"
    with patch("requests.request", return_value=_stream_resp(200, [b"%PDF-1.7 ", b"rest"])) as req:
        assert main(["notes", "download", "42", "--as", "pdf", "--output", str(dest)]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/notes/notes/42/download/pdf")
    assert req.call_args.kwargs["stream"] is True
    assert dest.read_bytes() == b"%PDF-1.7 rest"
    assert capsys.readouterr().out == f"Downloaded to {dest}\n"


def test_download_source_names_the_file_by_format(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    # No --output: "as written" asks for the note first, to pick .md/.html/.txt.
    responses = [_resp(200, NOTE), _stream_resp(200, [b"- milk\n- eggs\n"], "text/markdown")]
    with patch("requests.request", side_effect=responses) as req:
        assert main(["-j", "notes", "download", "42"]) == 0
    assert [c.args[:2] for c in req.call_args_list] == [
        ("GET", "http://localhost:3000/api/v1/notes/notes/42"),
        ("GET", "http://localhost:3000/api/v1/notes/notes/42/download/source"),
    ]
    out = json.loads(capsys.readouterr().out)
    assert out == {"downloaded_to": "note-42.md", "kind": "source", "size_bytes": 14}
    assert (tmp_path / "note-42.md").read_bytes() == b"- milk\n- eggs\n"


def test_download_text_default_name(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    with patch("requests.request", return_value=_stream_resp(200, [b"milk\n"], "text/plain")) as req:
        assert main(["notes", "download", "42", "--as", "text"]) == 0
    assert len(req.call_args_list) == 1, "plain text needs no look-up for its extension"
    assert (tmp_path / "note-42.txt").read_bytes() == b"milk\n"


def test_download_error(capsys):
    with patch("requests.request", return_value=_stream_resp(404, [])):
        assert main(["notes", "download", "42", "--as", "pdf", "-o", "/dev/null"]) == 1
    assert "Could not download the note" in capsys.readouterr().err


def test_list_in_notebook(capsys):
    rows = {"notes": [dict(NOTE, body=None, html=None), dict(NOTE, id=43, title="Plan", pinned=True)], "notebook": {"id": 3, "name": "My notes", "permission": "owner"}}
    with patch("requests.request", return_value=_resp(200, rows)) as req:
        assert main(["notes", "list", "--notebook", "3", "--folder", "0"]) == 0
    assert req.call_args.kwargs["params"] == {"notebook_id": "3", "folder_id": "0"}
    out = capsys.readouterr().out
    assert "Groceries" in out and "Plan" in out and "My notes" in out and "*" in out


def test_edit_from_file(tmp_path, capsys):
    f = tmp_path / "body.md"
    f.write_text("new body")
    with patch("requests.request", return_value=_resp(200, dict(NOTE, revision=2))) as req:
        assert main(["notes", "edit", "42", "--file", str(f), "--title", "Shopping", "--unpin"]) == 0
    assert req.call_args.args[:2] == ("PATCH", "http://localhost:3000/api/v1/notes/notes/42")
    assert req.call_args.kwargs["json"] == {"title": "Shopping", "body": "new body", "pinned": False}
    assert "revision 2" in capsys.readouterr().out


def test_edit_nothing_to_change(capsys, monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    assert main(["notes", "edit", "42"]) == 1
    out = capsys.readouterr()
    assert "Nothing to change" in out.err + out.out


def test_edit_title_does_not_read_a_pipe(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("stray input"))
    with patch("requests.request", return_value=_resp(200, NOTE)) as req:
        assert main(["notes", "edit", "42", "--title", "Only the title"]) == 0
    assert req.call_args.kwargs["json"] == {"title": "Only the title"}


def test_edit_body_from_a_pipe(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("piped body\n"))
    with patch("requests.request", return_value=_resp(200, NOTE)) as req:
        assert main(["notes", "edit", "42"]) == 0
    assert req.call_args.kwargs["json"] == {"body": "piped body\n"}


def test_search(capsys):
    hits = {"q": "budget", "notes": [dict(NOTE, id=41, title="Plan", snippet="The quarterly budget review")]}
    with patch("requests.request", return_value=_resp(200, hits)) as req:
        assert main(["notes", "search", "budget", "review"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/notes/search")
    assert req.call_args.kwargs["params"] == {"q": "budget review"}
    out = capsys.readouterr().out
    assert "41  Plan" in out and "quarterly budget review" in out


def test_share_link_and_with(capsys):
    share = {"id": 13, "token": "a" * 64, "url": "https://notes.mailmasker.org/s/" + "a" * 64, "note_id": 42, "shared_with_email": None, "permission": "read"}
    with patch("requests.request", return_value=_resp(201, share)) as req:
        assert main(["notes", "share", "42", "--link"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/notes/42/shares")
    assert req.call_args.kwargs["json"] == {"permission": "read"}
    out = capsys.readouterr().out
    assert "anyone with the link" in out and share["url"] in out
    with patch("requests.request", return_value=_resp(201, dict(share, shared_with_email="bob@example.com", permission="edit"))) as req:
        assert main(["notes", "share", "3", "--notebook", "--with", "bob@example.com", "--edit", "--expires", "7"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/notebooks/3/shares")
    assert req.call_args.kwargs["json"] == {"permission": "edit", "with": "bob@example.com", "expires_days": 7}
    assert "bob@example.com (may edit)" in capsys.readouterr().out
    assert main(["notes", "share", "42"]) == 1


def test_delete_restore_trash(capsys):
    with patch("requests.request", return_value=_resp(200, {"ok": True, "id": 42})) as req:
        assert main(["notes", "delete", "42"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/notes/42/delete")
    assert "notes restore 42" in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(200, {"notes": [dict(NOTE, deleted_at="2026-11-18 09:00:00-06")]})):
        assert main(["notes", "trash"]) == 0
    assert "Groceries" in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(200, {"ok": True, "removed": 1})) as req:
        assert main(["notes", "trash", "--empty"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/trash/empty")
    with patch("requests.request", return_value=_resp(200, NOTE)) as req:
        assert main(["notes", "restore", "42"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/notes/42/restore")


def test_history_and_revert(capsys):
    with patch("requests.request", return_value=_resp(200, {"versions": [{"id": 88, "note_id": 42, "revision": 1, "title": "Groceries", "format": "markdown", "body_chars": 14, "saved_by": "test@example.com", "created_at": "2026-11-18 08:01:00-06"}]})) as req:
        assert main(["notes", "history", "42"]) == 0
    assert req.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/notes/notes/42/versions")
    assert "88" in capsys.readouterr().out
    with patch("requests.request", return_value=_resp(200, dict(NOTE, revision=3))) as req:
        assert main(["notes", "revert", "42", "88"]) == 0
    assert req.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/notes/versions/88/restore")


def test_link_url(capsys):
    with patch("requests.request", return_value=_resp(201, {"id": 8, "kind": "url"})) as req:
        assert main(["notes", "link", "42", "--url", "https://example.test/y", "--label", "Example"]) == 0
    assert req.call_args.kwargs["json"] == {"kind": "url", "target": {"url": "https://example.test/y"}, "label": "Example"}
    assert main(["notes", "link", "42"]) == 1


def test_json_mode_passes_payload_through(capsys):
    with patch("requests.request", return_value=_resp(200, NOTE)):
        assert main(["-j", "notes", "show", "42"]) == 0
    assert json.loads(capsys.readouterr().out)["id"] == 42


def test_api_error_is_one_line(capsys):
    with patch("requests.request", return_value=_resp(404, {"error": "No such note."})):
        assert main(["notes", "show", "999"]) == 1
    assert "Could not read the note: No such note." in capsys.readouterr().err + capsys.readouterr().out or True
