import stat

from homelab_cli import config as cfgmod


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
