import stat
from unittest.mock import Mock, patch

from homelab_cli import config as cfgmod
from homelab_cli.cli import _client


def test_load_config_returns_default_when_no_file_exists(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    config = cfgmod.load_config()
    assert config["api_base"] == "http://localhost:3000"


def test_save_and_load_config_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    cfgmod.save_config({"api_base": "https://api.test.mailmasker.org"})
    assert cfgmod.load_config()["api_base"] == "https://api.test.mailmasker.org"


def test_session_file_is_saved_with_owner_only_permissions(tmp_path, monkeypatch):
    """session.yml holds a real refresh_token — must never be group/world
    readable, regardless of the process umask."""
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    cfgmod.save_session({"email": "a@b.com", "token": "t", "refresh_token": "r"})

    mode = stat.S_IMODE((tmp_path / "session.yml").stat().st_mode)
    assert mode == stat.S_IRUSR | stat.S_IWUSR, f"expected 0600, got {oct(mode)}"


def test_load_session_returns_none_when_no_session_exists(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    assert cfgmod.load_session() is None


def test_clear_session_removes_the_file(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    cfgmod.save_session({"token": "t"})
    assert (tmp_path / "session.yml").exists()
    cfgmod.clear_session()
    assert not (tmp_path / "session.yml").exists()


def test_clear_session_is_a_noop_when_nothing_to_clear(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    cfgmod.clear_session()  # must not raise


def _mock_response(status_code, json_body):
    resp = Mock()
    resp.ok = 200 <= status_code < 300
    resp.status_code = status_code
    resp.json.return_value = json_body
    resp.text = str(json_body)
    return resp


def test_client_wiring_persists_a_refreshed_token_to_session_file(tmp_path, monkeypatch):
    """End-to-end (mocked HTTP only) proof that cli.py's _client() really
    connects Client's refresh-on-401 retry to config.py's session
    storage: a 401 mid-command must leave session.yml holding the NEW
    token/refresh_token on disk, not just in the Client instance's own
    memory that then gets discarded."""
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    cfgmod.save_session({"email": "a@b.com", "token": "stale-jwt", "refresh_token": "old-refresh"})

    responses = [
        _mock_response(401, {"error": "token expired"}),
        _mock_response(200, {"token": "new-jwt", "refresh_token": "new-refresh"}),
        _mock_response(200, [{"id": 1, "domain_name": "forge.name"}]),
    ]
    client = _client()
    with patch("requests.request", side_effect=responses):
        result = client.dns_list_domains(cfgmod.load_session()["token"])

    assert result == [{"id": 1, "domain_name": "forge.name"}]
    on_disk = cfgmod.load_session()
    assert on_disk["token"] == "new-jwt"
    assert on_disk["refresh_token"] == "new-refresh"
    assert on_disk["email"] == "a@b.com", "unrelated session fields must survive the refresh untouched"


def test_client_wiring_no_session_means_no_refresh_token_on_the_client(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "SESSION_FILE", tmp_path / "session.yml")
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    client = _client()
    assert client.refresh_token is None
