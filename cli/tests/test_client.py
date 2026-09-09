from unittest.mock import Mock, patch

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


def test_api_base_trailing_slash_is_stripped():
    c = Client("http://localhost:3000/")
    with patch("requests.request", return_value=_mock_response(200, {})) as m:
        c.introspect("t")
    # A double slash here would indicate the trailing-slash strip didn't happen.
    assert "//api" not in m.call_args.args[1]
