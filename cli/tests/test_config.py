import stat
from types import SimpleNamespace
from unittest.mock import Mock, patch

from homelab_cli import config as cfgmod
from homelab_cli.cli import _client, _require_session


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


def _isolate(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "PROFILES_FILE", tmp_path / "profiles.yml")
    monkeypatch.setattr(cfgmod, "_LEGACY_SESSION_FILE", tmp_path / "session.yml")


def test_profiles_file_is_saved_with_owner_only_permissions(tmp_path, monkeypatch):
    """profiles.yml holds real refresh_tokens for every stored account —
    must never be group/world readable, regardless of the process umask."""
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t", "r")

    mode = stat.S_IMODE((tmp_path / "profiles.yml").stat().st_mode)
    assert mode == stat.S_IRUSR | stat.S_IWUSR, f"expected 0600, got {oct(mode)}"


def test_load_profiles_returns_empty_shape_when_no_file_exists(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    assert cfgmod.load_profiles() == {"active": None, "profiles": {}}


def test_get_session_returns_none_when_nothing_stored(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    assert cfgmod.get_session() is None


def test_upsert_then_set_active_makes_get_session_resolve_it(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t", "r")
    assert cfgmod.get_session() is None, "stored but not active yet — must not be silently picked"
    cfgmod.set_active("a@b.com")
    session = cfgmod.get_session()
    assert session == {"email": "a@b.com", "token": "t", "refresh_token": "r"}


def test_get_session_by_explicit_email_ignores_active(tmp_path, monkeypatch):
    """This is the --as EMAIL path: a specific profile can be read
    without it being (or becoming) the active one."""
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("admin@b.com", "admin-t", "admin-r")
    cfgmod.upsert_profile("user@b.com", "user-t", "user-r")
    cfgmod.set_active("admin@b.com")

    session = cfgmod.get_session(email="user@b.com")
    assert session == {"email": "user@b.com", "token": "user-t", "refresh_token": "user-r"}
    assert cfgmod.load_profiles()["active"] == "admin@b.com", "reading by name must not switch active"


def test_set_active_raises_for_unknown_profile(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    try:
        cfgmod.set_active("nobody@b.com")
        assert False, "expected KeyError"
    except KeyError:
        pass


def test_remove_profile_clears_active_if_it_was_the_active_one(tmp_path, monkeypatch):
    """No silent fallback to another stored profile — matches the
    'always require an explicit choice' design."""
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t1", "r1")
    cfgmod.upsert_profile("b@b.com", "t2", "r2")
    cfgmod.set_active("a@b.com")

    cfgmod.remove_profile("a@b.com")
    data = cfgmod.load_profiles()
    assert data["active"] is None
    assert list(data["profiles"]) == ["b@b.com"]


def test_remove_profile_leaves_active_alone_if_a_different_profile_is_removed(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t1", "r1")
    cfgmod.upsert_profile("b@b.com", "t2", "r2")
    cfgmod.set_active("a@b.com")

    cfgmod.remove_profile("b@b.com")
    assert cfgmod.load_profiles()["active"] == "a@b.com"


def test_remove_profile_is_a_noop_for_an_unknown_email(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    cfgmod.remove_profile("nobody@b.com")  # must not raise


def test_clear_all_profiles(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t1", "r1")
    cfgmod.set_active("a@b.com")
    cfgmod.clear_all_profiles()
    assert cfgmod.load_profiles() == {"active": None, "profiles": {}}


def test_legacy_session_file_is_migrated_once_then_deleted(tmp_path, monkeypatch):
    """Existing single-session users (session.yml, flat {email, token,
    refresh_token}) must not be logged out by upgrading to multi-profile
    support — this runs automatically on first read, and never leaves a
    second stale credential file sitting around afterward."""
    _isolate(tmp_path, monkeypatch)
    import yaml
    legacy = tmp_path / "session.yml"
    legacy.write_text(yaml.safe_dump({"email": "old@b.com", "token": "old-t", "refresh_token": "old-r"}))

    data = cfgmod.load_profiles()
    assert data == {"active": "old@b.com", "profiles": {"old@b.com": {"token": "old-t", "refresh_token": "old-r"}}}
    assert not legacy.exists(), "legacy session.yml must be removed after a successful migration"
    assert (tmp_path / "profiles.yml").exists()

    # Second read must not re-run the migration (nothing left to migrate,
    # and the new file is now the sole source of truth).
    assert cfgmod.load_profiles() == data


def test_no_migration_when_neither_file_exists(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    assert cfgmod.load_profiles() == {"active": None, "profiles": {}}


# --- _require_session / _client resolution (active vs --as) -------------

def test_require_session_with_no_profiles_at_all(tmp_path, monkeypatch, capsys):
    _isolate(tmp_path, monkeypatch)
    args = SimpleNamespace(json=False, as_user=None)
    assert _require_session(args) is None
    assert "Not logged in" in capsys.readouterr().err


def test_require_session_with_profiles_but_none_active(tmp_path, monkeypatch, capsys):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t", "r")
    args = SimpleNamespace(json=False, as_user=None)
    assert _require_session(args) is None
    assert "No active profile" in capsys.readouterr().err


def test_require_session_resolves_the_active_profile(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "t", "r")
    cfgmod.set_active("a@b.com")
    args = SimpleNamespace(json=False, as_user=None)
    session = _require_session(args)
    assert session["email"] == "a@b.com"


def test_require_session_as_user_overrides_active_without_switching_it(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("admin@b.com", "admin-t", "admin-r")
    cfgmod.upsert_profile("user@b.com", "user-t", "user-r")
    cfgmod.set_active("admin@b.com")

    args = SimpleNamespace(json=False, as_user="user@b.com")
    session = _require_session(args)
    assert session["email"] == "user@b.com"
    assert cfgmod.load_profiles()["active"] == "admin@b.com"


def test_require_session_as_user_unknown_profile_is_a_clean_error(tmp_path, monkeypatch, capsys):
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("admin@b.com", "admin-t", "admin-r")
    cfgmod.set_active("admin@b.com")

    args = SimpleNamespace(json=False, as_user="ghost@b.com")
    assert _require_session(args) is None
    assert "Not logged in as ghost@b.com" in capsys.readouterr().err


def _mock_response(status_code, json_body):
    resp = Mock()
    resp.ok = 200 <= status_code < 300
    resp.status_code = status_code
    resp.json.return_value = json_body
    resp.text = str(json_body)
    return resp


def test_client_wiring_persists_a_refreshed_token_to_the_active_profile(tmp_path, monkeypatch):
    """End-to-end (mocked HTTP only) proof that cli.py's _client() really
    connects Client's refresh-on-401 retry to config.py's profile
    storage: a 401 mid-command must leave the RIGHT profile holding the
    NEW token/refresh_token on disk, not just in the Client instance's
    own memory that then gets discarded."""
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("a@b.com", "stale-jwt", "old-refresh")
    cfgmod.set_active("a@b.com")

    responses = [
        _mock_response(401, {"error": "token expired"}),
        _mock_response(200, {"token": "new-jwt", "refresh_token": "new-refresh"}),
        _mock_response(200, [{"id": 1, "domain_name": "forge.name"}]),
    ]
    args = SimpleNamespace(json=False, as_user=None)
    client = _client(args)
    with patch("requests.request", side_effect=responses):
        result = client.dns_list_domains(cfgmod.get_session()["token"])

    assert result == [{"id": 1, "domain_name": "forge.name"}]
    on_disk = cfgmod.get_session()
    assert on_disk["token"] == "new-jwt"
    assert on_disk["refresh_token"] == "new-refresh"
    assert on_disk["email"] == "a@b.com", "unrelated profile fields must survive the refresh untouched"


def test_client_wiring_refresh_with_as_user_updates_that_profile_not_active(tmp_path, monkeypatch):
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    _isolate(tmp_path, monkeypatch)
    cfgmod.upsert_profile("admin@b.com", "admin-jwt", "admin-refresh")
    cfgmod.upsert_profile("user@b.com", "stale-jwt", "old-refresh")
    cfgmod.set_active("admin@b.com")

    responses = [
        _mock_response(401, {"error": "token expired"}),
        _mock_response(200, {"token": "new-jwt", "refresh_token": "new-refresh"}),
        _mock_response(200, [{"id": 1, "domain_name": "forge.name"}]),
    ]
    args = SimpleNamespace(json=False, as_user="user@b.com")
    client = _client(args)
    with patch("requests.request", side_effect=responses):
        client.dns_list_domains(cfgmod.get_session(email="user@b.com")["token"])

    assert cfgmod.get_session(email="user@b.com")["token"] == "new-jwt"
    assert cfgmod.get_session(email="admin@b.com")["token"] == "admin-jwt", "the active profile must be untouched"


def test_client_wiring_no_session_means_no_refresh_token_on_the_client(tmp_path, monkeypatch):
    _isolate(tmp_path, monkeypatch)
    monkeypatch.setattr(cfgmod, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(cfgmod, "CONFIG_FILE", tmp_path / "config.yml")
    client = _client()
    assert client.refresh_token is None
