from unittest.mock import MagicMock, Mock, mock_open, patch

import pytest
import requests

from homelab_cli.client import ApiError, Client


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


def test_registry_list_builds_correct_path_and_returns_list(client):
    payload = [{"feature_name": "homelab-drive", "host": "h", "port": 1}]
    with patch("requests.request", return_value=_mock_response(200, payload)) as m:
        result = client.registry_list()
    assert m.call_args.args[1] == "http://localhost:3000/api/v1/registry"
    assert result == payload


def test_dns_list_domains_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.dns_list_domains("t")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/domains")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer t"


def test_dns_add_domain_sends_flags_and_nameservers(client):
    with patch("requests.request", return_value=_mock_response(201, {"domain_name": "example.org"})) as m:
        client.dns_add_domain("t", "example.org", mail_enabled=False, dns_managed=True, nameservers=["ns1.example.org."])
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/domains")
    body = m.call_args.kwargs["json"]
    assert body == {
        "domain_name": "example.org", "mail_enabled": False, "dns_managed": True,
        "nameservers": ["ns1.example.org."],
    }


def test_dns_add_domain_omits_nameservers_when_not_given(client):
    with patch("requests.request", return_value=_mock_response(201, {})) as m:
        client.dns_add_domain("t", "example.org")
    assert "nameservers" not in m.call_args.kwargs["json"]


def test_dns_set_domain_enabled_builds_correct_request(client):
    with patch("requests.request", return_value=_mock_response(200, {})) as m:
        client.dns_set_domain_enabled("t", "example.org", False)
    assert m.call_args.args[:2] == ("PATCH", "http://localhost:3000/api/v1/domains/example.org")
    assert m.call_args.kwargs["json"] == {"mail_enabled": False}


def test_dns_add_record_builds_correct_request(client):
    with patch("requests.request", return_value=_mock_response(201, {"ok": True})) as m:
        client.dns_add_record("t", "example.org", "example.org", "A", ["203.0.113.10"], ttl=300)
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/domains/example.org/dns/records")
    assert m.call_args.kwargs["json"] == {"name": "example.org", "type": "A", "content": ["203.0.113.10"], "ttl": 300}


def test_dns_delete_record_builds_correct_request(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.dns_delete_record("t", "example.org", "example.org", "A")
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/domains/example.org/dns/records")
    assert m.call_args.kwargs["json"] == {"name": "example.org", "type": "A"}


def test_dns_list_recipient_access_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.dns_list_recipient_access("t")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/domains/recipient-access")


def test_dns_set_recipient_access_omits_reason_when_not_given(client):
    with patch("requests.request", return_value=_mock_response(201, {"ok": True})) as m:
        client.dns_set_recipient_access("t", "bad@example.org", "REJECT")
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/domains/recipient-access")
    assert m.call_args.kwargs["json"] == {"recipient": "bad@example.org", "action": "REJECT"}


def test_dns_set_recipient_access_includes_reason_when_given(client):
    with patch("requests.request", return_value=_mock_response(201, {"ok": True})) as m:
        client.dns_set_recipient_access("t", "bad@example.org", "REJECT", reason="spam")
    assert m.call_args.kwargs["json"] == {"recipient": "bad@example.org", "action": "REJECT", "reason": "spam"}


def test_dns_delete_recipient_access_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.dns_delete_recipient_access("t", "bad@example.org")
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/domains/recipient-access/bad@example.org")


def test_dns_add_mail_alias_defaults_send_enabled_true(client):
    with patch("requests.request", return_value=_mock_response(201, {"ok": True})) as m:
        client.dns_add_mail_alias("t", "@forge.name", "permittivity@mailmasker.org")
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/domains/mail-aliases")
    assert m.call_args.kwargs["json"] == {
        "source_pattern": "@forge.name", "destination": "permittivity@mailmasker.org", "send_enabled": True,
    }


def test_dns_add_mail_alias_no_send(client):
    with patch("requests.request", return_value=_mock_response(201, {"ok": True})) as m:
        client.dns_add_mail_alias("t", "@forge.name", "permittivity@mailmasker.org", send_enabled=False)
    assert m.call_args.kwargs["json"]["send_enabled"] is False


def test_dns_list_mail_aliases_with_and_without_user_filter(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.dns_list_mail_aliases("t")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/domains/mail-aliases")
    assert m.call_args.kwargs["params"] == {}

    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.dns_list_mail_aliases("t", destination="permittivity@mailmasker.org")
    assert m.call_args.kwargs["params"] == {"destination": "permittivity@mailmasker.org"}


def test_dns_set_mail_alias_send_enabled_builds_correct_request(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.dns_set_mail_alias_send_enabled("t", "@forge.name", False)
    assert m.call_args.args[:2] == ("PATCH", "http://localhost:3000/api/v1/domains/mail-aliases/@forge.name")
    assert m.call_args.kwargs["json"] == {"send_enabled": False}


def test_dns_delete_mail_alias_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.dns_delete_mail_alias("t", "@forge.name")
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/domains/mail-aliases/@forge.name")


def test_mail_allowed_senders_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"send": {}, "receive_only": {}})) as m:
        client.mail_allowed_senders("t")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/domains/mail-aliases/mine")


def test_mail_block_posts_recipient_and_action(client):
    with patch("requests.request", return_value=_mock_response(201, {"recipient": "x@y.com"})) as m:
        client.mail_block("t", "x@y.com")
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/domains/recipient-access/mine")
    assert m.call_args.kwargs["json"] == {"recipient": "x@y.com", "action": "REJECT"}


def test_mail_block_includes_reason_when_given(client):
    with patch("requests.request", return_value=_mock_response(201, {})) as m:
        client.mail_block("t", "x@y.com", reason="spam")
    assert m.call_args.kwargs["json"] == {"recipient": "x@y.com", "action": "REJECT", "reason": "spam"}


def test_mail_unblock_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.mail_unblock("t", "x@y.com")
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/domains/recipient-access/mine/x@y.com")


def test_mail_blocked_no_search(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.mail_blocked("t")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/domains/recipient-access/mine")
    assert m.call_args.kwargs["params"] == {}


def test_mail_blocked_with_search(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.mail_blocked("t", q="spam")
    assert m.call_args.kwargs["params"] == {"q": "spam"}


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


# --- Drive, via homelab-api's own /api/v1/drive/* gateway -- same
# Client, same base URL as everything else above (no more separate
# DriveClient/drive_base: see ../README.md). Most of these go through
# the same requests.request-based _request() helper as the rest of
# Client, so _mock_response works for them too; drive_download_file (and
# jobs_download, below) are streamed via Client._send() directly instead
# of _request() (no JSON body to parse), but that's still
# requests.request under the hood (not a separate requests.get call) so
# they get the same transparent refresh-on-401 retry as everything
# else -- _mock_get_response exists only because these need
# iter_content on the mock response, not because they're a different
# HTTP call path. ---

def _mock_get_response(status_code, json_body=None, content=b""):
    resp = Mock()
    resp.ok = 200 <= status_code < 300
    resp.status_code = status_code
    resp.json.return_value = json_body or {}
    resp.text = str(json_body)
    resp.iter_content.return_value = [content] if content else []
    return resp


def test_drive_list_files_sends_bearer_token(client):
    with patch("requests.request", return_value=_mock_response(200, [{"id": 1, "filename": "a.txt"}])) as m:
        result = client.drive_list_files("the-jwt")
    assert result[0]["filename"] == "a.txt"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/drive/files")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"


def test_drive_list_files_error_raises_api_error(client):
    with patch("requests.request", return_value=_mock_response(401, {"error": "not logged in"})):
        with pytest.raises(ApiError) as exc_info:
            client.drive_list_files("bad-token")
    assert exc_info.value.status_code == 401


def test_drive_upload_file_sends_multipart(client):
    fake_path = MagicMock()
    fake_path.name = "report.txt"
    with patch("builtins.open", mock_open(read_data=b"content")):
        with patch("requests.request", return_value=_mock_response(201, {"id": 7, "filename": "report.txt"})) as m:
            result = client.drive_upload_file("the-jwt", fake_path)
    assert result["id"] == 7
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/drive/files")
    assert "file" in m.call_args.kwargs["files"]


def test_drive_download_file_writes_content(client):
    with patch("requests.request", return_value=_mock_get_response(200, content=b"hello world")) as m:
        m_open = mock_open()
        with patch("builtins.open", m_open):
            client.drive_download_file("the-jwt", 7, "/tmp/out.txt")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/drive/files/7")
    m_open.assert_called_once_with("/tmp/out.txt", "wb")
    m_open().write.assert_called_with(b"hello world")


def test_drive_delete_file_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.drive_delete_file("the-jwt", 7)
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/drive/files/7")


def test_drive_list_files_passes_folder_id_when_given(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.drive_list_files("the-jwt", folder_id=5)
    assert m.call_args.kwargs["params"] == {"folder_id": 5}


def test_drive_list_files_omits_folder_id_param_when_not_given(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.drive_list_files("the-jwt")
    assert m.call_args.kwargs["params"] == {}


def test_drive_upload_file_passes_folder_id_as_form_data(client):
    fake_path = MagicMock()
    fake_path.name = "report.txt"
    with patch("builtins.open", mock_open(read_data=b"content")):
        with patch("requests.request", return_value=_mock_response(201, {"id": 7})) as m:
            client.drive_upload_file("the-jwt", fake_path, folder_id=5)
    assert m.call_args.kwargs["data"] == {"folder_id": 5}


def test_drive_list_folders_sends_bearer_token(client):
    with patch("requests.request", return_value=_mock_response(200, [{"id": 3, "name": "Docs"}])) as m:
        result = client.drive_list_folders("the-jwt")
    assert result[0]["name"] == "Docs"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/drive/folders")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"


def test_drive_list_folders_passes_parent_id_when_given(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.drive_list_folders("the-jwt", parent_id=3)
    assert m.call_args.kwargs["params"] == {"parent_id": 3}


def test_drive_create_folder_posts_json_body(client):
    with patch("requests.request", return_value=_mock_response(201, {"id": 3, "name": "Docs"})) as m:
        result = client.drive_create_folder("the-jwt", "Docs", parent_folder_id=1)
    assert result["id"] == 3
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/drive/folders")
    assert m.call_args.kwargs["json"] == {"name": "Docs", "parent_folder_id": 1}


def test_drive_create_folder_omits_parent_when_not_given(client):
    with patch("requests.request", return_value=_mock_response(201, {"id": 3})) as m:
        client.drive_create_folder("the-jwt", "Docs")
    assert m.call_args.kwargs["json"] == {"name": "Docs"}


def test_drive_create_folder_duplicate_name_raises_api_error(client):
    with patch("requests.request", return_value=_mock_response(409, {"error": "a folder with that name already exists here"})):
        with pytest.raises(ApiError) as exc_info:
            client.drive_create_folder("the-jwt", "Docs")
    assert exc_info.value.status_code == 409


def test_drive_delete_folder_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.drive_delete_folder("the-jwt", 3)
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/drive/folders/3")


# --- Mail, via homelab-api's /api/v1/mail/* gateway -- plain HTTP
# calls now, no imaplib/smtplib client-side code at all any more (see
# ../../mailbridge/README.md, which is where that logic actually lives
# now, server-side). ---

def test_mail_list_sends_bearer_token_and_params(client):
    with patch("requests.request", return_value=_mock_response(200, [{"uid": "1", "from": "a@b.com", "subject": "hi", "date": "now"}])) as m:
        result = client.mail_list("the-jwt", mailbox="Sent", limit=5)
    assert result[0]["subject"] == "hi"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/mail/messages")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"
    assert m.call_args.kwargs["params"] == {"mailbox": "Sent", "limit": 5}


def test_mail_read_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"from": "a@b.com", "subject": "hi", "date": "now", "body": "hello"})) as m:
        result = client.mail_read("the-jwt", "42")
    assert result["body"] == "hello"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/mail/messages/42")


def test_mail_read_returns_none_for_404_instead_of_raising(client):
    """A missing uid is a normal, expected outcome (cmd_mail_read prints
    a clean "no message" line) — not something callers should need a
    try/except ApiError just to handle."""
    with patch("requests.request", return_value=_mock_response(404, {"error": "not found"})):
        result = client.mail_read("the-jwt", "999")
    assert result is None


def test_mail_read_other_errors_still_raise(client):
    with patch("requests.request", return_value=_mock_response(401, {"error": "not logged in"})):
        with pytest.raises(ApiError) as exc_info:
            client.mail_read("bad-token", "42")
    assert exc_info.value.status_code == 401


def test_mail_send_posts_json_body(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.mail_send("the-jwt", "to@example.com", "subj", "body text")
    assert m.call_args.args[:2] == ("POST", "http://localhost:3000/api/v1/mail/send")
    assert "from" not in m.call_args.kwargs["json"], "from is omitted, not sent as null, when not given"


def test_mail_send_includes_from_when_given(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.mail_send("the-jwt", "to@example.com", "subj", "body text", from_address="sales@forge.name")
    assert m.call_args.kwargs["json"]["from"] == "sales@forge.name"


# --- Jobs, via homelab-api's /api/v1/jobs/* gateway -> homelab-worker
# (see ../../worker/README.md). jobs_download streams like
# drive_download_file above, so it needs _mock_get_response too. ---

def test_jobs_list_sends_bearer_token_no_params_by_default(client):
    with patch("requests.request", return_value=_mock_response(200, [{"id": 1, "type": "zip", "state": "completed"}])) as m:
        result = client.jobs_list("the-jwt")
    assert result[0]["type"] == "zip"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/jobs")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"
    assert m.call_args.kwargs["params"] == {}


def test_jobs_list_passes_all_type_state_when_given(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.jobs_list("the-jwt", all_users=True, type="zip", state="failed")
    assert m.call_args.kwargs["params"] == {"all": 1, "type": "zip", "state": "failed"}


def test_jobs_list_non_admin_all_raises_403(client):
    """A non-admin passing --all gets the server's own clean 403, not a
    client-side guess about permissions the client can't actually
    verify -- same philosophy as every other site_admin-gated command
    (see cli.py's own comment on the `jobs`/`admin` command trees)."""
    with patch("requests.request", return_value=_mock_response(403, {"error": "site_admin role required for ?all=1"})):
        with pytest.raises(ApiError) as exc_info:
            client.jobs_list("the-jwt", all_users=True)
    assert exc_info.value.status_code == 403


def test_jobs_get_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"id": 7, "state": "running"})) as m:
        result = client.jobs_get("the-jwt", 7)
    assert result["state"] == "running"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/jobs/7")


def test_jobs_get_not_found_raises_api_error(client):
    with patch("requests.request", return_value=_mock_response(404, {"error": "not found"})):
        with pytest.raises(ApiError) as exc_info:
            client.jobs_get("the-jwt", 999)
    assert exc_info.value.status_code == 404


def test_jobs_download_writes_content(client):
    with patch("requests.request", return_value=_mock_get_response(200, content=b"zip bytes")) as m:
        m_open = mock_open()
        with patch("builtins.open", m_open):
            client.jobs_download("the-jwt", 7, "/tmp/out.zip")
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/jobs/7/download")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"
    m_open.assert_called_once_with("/tmp/out.zip", "wb")
    m_open().write.assert_called_with(b"zip bytes")


def test_jobs_download_not_ready_raises_api_error(client):
    """A job still pending/running 409s (see worker/README.md's
    Controller::Jobs::download) -- surfaced the same way as any other
    non-ok response, not silently written as a truncated/empty file."""
    resp = _mock_get_response(409, json_body={"error": "job is not finished (state: running)"})
    resp.ok = False
    with patch("requests.request", return_value=resp):
        with pytest.raises(ApiError) as exc_info:
            client.jobs_download("the-jwt", 7, "/tmp/out.zip")
    assert exc_info.value.status_code == 409


# --- Transparent refresh-on-401 (Client._send) -- what lets a
# homelab-cli session outlive a single ~30-minute JWT without the user
# re-running `login`. See client.py's own comments on _send/_try_refresh
# for the exact contract; these tests are the executable version of it. ---

def test_expired_token_triggers_one_refresh_then_succeeds(client):
    client.refresh_token = "old-refresh"
    responses = [
        _mock_response(401, {"error": "token expired"}),                              # original call, stale JWT
        _mock_response(200, {"token": "new-jwt", "refresh_token": "new-refresh"}),     # POST /auth/refresh
        _mock_response(200, [{"id": 1, "domain_name": "forge.name"}]),                 # retried original call
    ]
    with patch("requests.request", side_effect=responses) as m:
        result = client.dns_list_domains("stale-jwt")

    assert result == [{"id": 1, "domain_name": "forge.name"}]
    assert m.call_count == 3
    assert m.call_args_list[1].args[:2] == ("POST", "http://localhost:3000/api/v1/auth/refresh")
    assert m.call_args_list[1].kwargs["json"] == {"refresh_token": "old-refresh"}
    # The retried call must use the NEW token, not the original stale one.
    assert m.call_args_list[2].kwargs["headers"]["Authorization"] == "Bearer new-jwt"
    # The rotated refresh_token is retained for any future refresh.
    assert client.refresh_token == "new-refresh"


def test_on_token_refreshed_callback_fires_with_new_tokens(client):
    seen = []
    client.refresh_token = "old-refresh"
    client.on_token_refreshed = lambda t, rt: seen.append((t, rt))
    responses = [
        _mock_response(401, {"error": "token expired"}),
        _mock_response(200, {"token": "new-jwt", "refresh_token": "new-refresh"}),
        _mock_response(200, []),
    ]
    with patch("requests.request", side_effect=responses):
        client.dns_list_domains("stale-jwt")
    assert seen == [("new-jwt", "new-refresh")]


def test_refresh_token_itself_invalid_raises_clear_session_expired_error_no_loop(client):
    client.refresh_token = "also-expired"
    responses = [
        _mock_response(401, {"error": "token expired"}),                     # original call
        _mock_response(401, {"error": "invalid or expired refresh_token"}),  # refresh attempt also fails
    ]
    with patch("requests.request", side_effect=responses) as m:
        with pytest.raises(ApiError) as exc_info:
            client.dns_list_domains("stale-jwt")

    assert m.call_count == 2, "must not retry the refresh itself, and must not retry the original call again"
    assert exc_info.value.status_code == 401
    assert "session expired" in exc_info.value.message
    assert "login" in exc_info.value.message


def test_401_with_no_refresh_token_raises_immediately_unchanged(client):
    """No refresh_token on hand (e.g. never logged in) must behave
    exactly like before this feature existed -- no refresh attempted."""
    assert client.refresh_token is None
    with patch("requests.request", return_value=_mock_response(401, {"error": "not logged in"})) as m:
        with pytest.raises(ApiError) as exc_info:
            client.dns_list_domains("whatever")
    assert m.call_count == 1
    assert exc_info.value.status_code == 401
    assert exc_info.value.message == "not logged in"


def test_401_on_an_unauthenticated_call_never_attempts_refresh(client):
    """login()/register() carry no Authorization header at all -- a 401
    from a bad password must never be mistaken for an expired-JWT
    situation, even if a refresh_token happens to be set."""
    client.refresh_token = "some-refresh"
    with patch("requests.request", return_value=_mock_response(401, {"error": "invalid email or password"})) as m:
        with pytest.raises(ApiError) as exc_info:
            client.login("a@b.com", "wrong")
    assert m.call_count == 1
    assert exc_info.value.message == "invalid email or password"


# --- User-Agent: every request identifies itself as homelab-cli instead
# of requests' own generic default, so a CLI-originated session reads
# clearly in `sessions list` (see api/migrations/007-session-metadata.sql). ---

def test_every_request_sends_an_identifiable_user_agent(client):
    with patch("requests.request", return_value=_mock_response(200, {"email": "a@b.com"})) as m:
        client.introspect("the-jwt")
    ua = m.call_args.kwargs["headers"]["User-Agent"]
    assert ua.startswith("homelab-cli/")


def test_caller_supplied_user_agent_is_never_clobbered(client):
    with patch("requests.request", return_value=_mock_response(200, {})) as m:
        client._request("GET", "/whatever", headers={"User-Agent": "custom-ua"})
    assert m.call_args.kwargs["headers"]["User-Agent"] == "custom-ua"


# --- Sessions: list/revoke, via homelab-api's /api/v1/auth/sessions
# (see api/migrations/007-session-metadata.sql and App.pm's
# _sessions_* handlers). ---

def test_sessions_list_no_user_by_default(client):
    with patch("requests.request", return_value=_mock_response(200, [{"jti": "abc", "current": True}])) as m:
        result = client.sessions_list("the-jwt")
    assert result[0]["jti"] == "abc"
    assert m.call_args.args[:2] == ("GET", "http://localhost:3000/api/v1/auth/sessions")
    assert m.call_args.kwargs["headers"]["Authorization"] == "Bearer the-jwt"
    assert m.call_args.kwargs["params"] == {}


def test_sessions_list_passes_user_when_given(client):
    with patch("requests.request", return_value=_mock_response(200, [])) as m:
        client.sessions_list("the-jwt", user="other@b.com")
    assert m.call_args.kwargs["params"] == {"user": "other@b.com"}


def test_sessions_list_non_admin_user_raises_403(client):
    with patch("requests.request", return_value=_mock_response(403, {"error": "site_admin role required"})):
        with pytest.raises(ApiError) as exc_info:
            client.sessions_list("the-jwt", user="other@b.com")
    assert exc_info.value.status_code == 403


def test_sessions_revoke_builds_correct_path(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.sessions_revoke("the-jwt", "abc123")
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/auth/sessions/abc123")
    assert m.call_args.kwargs["params"] == {}


def test_sessions_revoke_passes_user_when_given(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True})) as m:
        client.sessions_revoke("the-jwt", "abc123", user="other@b.com")
    assert m.call_args.kwargs["params"] == {"user": "other@b.com"}


def test_sessions_revoke_others_sends_except_current_true(client):
    with patch("requests.request", return_value=_mock_response(200, {"ok": True, "revoked": 3})) as m:
        result = client.sessions_revoke_others("the-jwt")
    assert result["revoked"] == 3
    assert m.call_args.args[:2] == ("DELETE", "http://localhost:3000/api/v1/auth/sessions")
    assert m.call_args.kwargs["params"] == {"except_current": "true"}
