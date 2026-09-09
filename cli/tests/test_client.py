from unittest.mock import MagicMock, Mock, mock_open, patch

import pytest
import requests

from homelab_cli.client import ApiError, Client, DriveClient


@pytest.fixture
def client():
    return Client("http://localhost:3000")


def _mock_response(status_code, json_body):
    resp = Mock()
    resp.ok = 200 <= status_code < 300
    resp.status_code = status_code
    resp.json.return_value = json_body
    resp.text = str(json_body)
    return resp


def test_login_success(client):
    with patch("requests.request", return_value=_mock_response(200, {"token": "t", "refresh_token": "r", "email": "a@b.com"})) as m:
        result = client.login("a@b.com", "pw")
    assert result["token"] == "t"
    m.assert_called_once()
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/auth/login")


def test_login_failure_raises_api_error_with_message(client):
    with patch("requests.request", return_value=_mock_response(401, {"error": "invalid email or password"})):
        with pytest.raises(ApiError) as exc_info:
            client.login("a@b.com", "wrong")
    assert exc_info.value.status_code == 401
    assert "invalid email or password" in exc_info.value.message


def test_connection_error_raises_api_error_not_requests_exception(client):
    """A network-level failure (host down, DNS failure, etc.) should
    surface as our own ApiError, not leak a raw requests exception —
    callers (the CLI commands) only catch ApiError."""
    with patch("requests.request", side_effect=requests.exceptions.ConnectionError("refused")):
        with pytest.raises(ApiError) as exc_info:
            client.introspect("some-token")
    assert exc_info.value.status_code == 0


def test_non_json_error_response_falls_back_to_raw_text(client):
    resp = Mock()
    resp.ok = False
    resp.status_code = 502
    resp.json.side_effect = ValueError("not json")
    resp.text = "Bad Gateway"
    with patch("requests.request", return_value=resp):
        with pytest.raises(ApiError) as exc_info:
            client.introspect("t")
    assert "Bad Gateway" in exc_info.value.message


def test_registry_lookup_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"feature_name": "homelab-sso", "host": "h", "port": 1})) as m:
        client.registry_lookup("homelab-sso")
    assert m.call_args.args[1] == "http://localhost:3000/api/v1/registry/homelab-sso"


def test_api_base_trailing_slash_is_stripped():
    c = Client("http://localhost:3000/")
    with patch("requests.request", return_value=_mock_response(200, {})) as m:
        c.introspect("t")
    # A double slash here would indicate the trailing-slash strip didn't happen.
    assert "//api" not in m.call_args.args[1]


def test_admin_list_users_sends_bearer_token(client):
    with patch("requests.request", return_value=_mock_response(200, [{"id": 1, "email": "a@b.com", "active": True, "roles": ["user"]}])) as m:
        result = client.admin_list_users("the-jwt")
    assert result[0]["email"] == "a@b.com"
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"


def test_admin_grant_role_posts_role_body():
    c = Client("http://localhost:3000")
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        c.admin_grant_role("the-jwt", 5, "site_admin")
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/admin/users/5/roles")
    assert m.call_args.kwargs["json"] == {"role": "site_admin"}


def test_admin_grant_role_403_raises_api_error():
    c = Client("http://localhost:3000")
    with patch("requests.request", return_value=_mock_response(403, {"error": "site_admin role required"})):
        with pytest.raises(ApiError) as exc_info:
            c.admin_grant_role("the-jwt", 5, "site_admin")
    assert exc_info.value.status_code == 403


def test_admin_revoke_role_builds_correct_path():
    c = Client("http://localhost:3000")
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        c.admin_revoke_role("the-jwt", 5, "site_admin")
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/admin/users/5/roles/site_admin")


# --- DriveClient — a separate upstream service (homelab-drive), so a
# separate set of tests using plain requests.get/post/delete rather than
# Client's requests.request-based _request() helper. ---

def _mock_get_response(status_code, json_body=None, content=b""):
    resp = Mock()
    resp.ok = 200 <= status_code < 300
    resp.status_code = status_code
    resp.json.return_value = json_body or {}
    resp.text = str(json_body)
    resp.iter_content.return_value = [content] if content else []
    return resp


def test_drive_list_files_sends_bearer_token():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.get", return_value=_mock_get_response(200, [{"id": 1, "filename": "a.txt"}])) as m:
        result = dc.list_files()
    assert result[0]["filename"] == "a.txt"
    assert m.call_args.args[0] == "http://localhost:2501/api/v1/files"
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"


def test_drive_list_files_error_raises_api_error():
    dc = DriveClient("http://localhost:2501", "bad-token")
    with patch("requests.get", return_value=_mock_get_response(401, {"error": "not logged in"})):
        with pytest.raises(ApiError) as exc_info:
            dc.list_files()
    assert exc_info.value.status_code == 401


def test_drive_upload_file_sends_multipart():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    fake_path = MagicMock()
    fake_path.name = "report.txt"
    with patch("builtins.open", mock_open(read_data=b"content")):
        with patch("requests.post", return_value=_mock_get_response(201, {"id": 7, "filename": "report.txt"})) as m:
            result = dc.upload_file(fake_path)
    assert result["id"] == 7
    assert m.call_args.args[0] == "http://localhost:2501/api/v1/files"
    assert "file" in m.call_args.kwargs["files"]


def test_drive_download_file_writes_content():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.get", return_value=_mock_get_response(200, content=b"hello world")):
        m_open = mock_open()
        with patch("builtins.open", m_open):
            dc.download_file(7, "/tmp/out.txt")
    m_open.assert_called_once_with("/tmp/out.txt", "wb")
    m_open().write.assert_called_with(b"hello world")


def test_drive_delete_file_builds_correct_path():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.delete", return_value=_mock_get_response(200, {"ok": True})) as m:
        dc.delete_file(7)
    assert m.call_args.args[0] == "http://localhost:2501/api/v1/files/7"


def test_drive_list_files_passes_folder_id_when_given():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.get", return_value=_mock_get_response(200, [])) as m:
        dc.list_files(folder_id=5)
    assert m.call_args.kwargs["params"] == {"folder_id": 5}


def test_drive_list_files_omits_folder_id_param_when_not_given():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.get", return_value=_mock_get_response(200, [])) as m:
        dc.list_files()
    assert m.call_args.kwargs["params"] == {}


def test_drive_upload_file_passes_folder_id_as_form_data():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    fake_path = MagicMock()
    fake_path.name = "report.txt"
    with patch("builtins.open", mock_open(read_data=b"content")):
        with patch("requests.post", return_value=_mock_get_response(201, {"id": 7})) as m:
            dc.upload_file(fake_path, folder_id=5)
    assert m.call_args.kwargs["data"] == {"folder_id": 5}


def test_drive_list_folders_sends_bearer_token():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.get", return_value=_mock_get_response(200, [{"id": 3, "name": "Docs"}])) as m:
        result = dc.list_folders()
    assert result[0]["name"] == "Docs"
    assert m.call_args.args[0] == "http://localhost:2501/api/v1/folders"
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"


def test_drive_list_folders_passes_parent_id_when_given():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.get", return_value=_mock_get_response(200, [])) as m:
        dc.list_folders(parent_id=3)
    assert m.call_args.kwargs["params"] == {"parent_id": 3}


def test_drive_create_folder_posts_json_body():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.post", return_value=_mock_get_response(201, {"id": 3, "name": "Docs"})) as m:
        result = dc.create_folder("Docs", parent_folder_id=1)
    assert result["id"] == 3
    assert m.call_args.args[0] == "http://localhost:2501/api/v1/folders"
    assert m.call_args.kwargs["json"] == {"name": "Docs", "parent_folder_id": 1}


def test_drive_create_folder_omits_parent_when_not_given():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.post", return_value=_mock_get_response(201, {"id": 3})) as m:
        dc.create_folder("Docs")
    assert m.call_args.kwargs["json"] == {"name": "Docs"}


def test_drive_create_folder_duplicate_name_raises_api_error():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.post", return_value=_mock_get_response(409, {"error": "a folder with that name already exists here"})):
        with pytest.raises(ApiError) as exc_info:
            dc.create_folder("Docs")
    assert exc_info.value.status_code == 409


def test_drive_delete_folder_builds_correct_path():
    dc = DriveClient("http://localhost:2501", "the-jwt")
    with patch("requests.delete", return_value=_mock_get_response(200, {"ok": True})) as m:
        dc.delete_folder(3)
    assert m.call_args.args[0] == "http://localhost:2501/api/v1/folders/3"
