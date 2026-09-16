"""Config + profile storage for homelab-cli.

Two separate files, deliberately: config.yml (the API base URL — not
secret, fine to share/version-control-ignore casually) and profiles.yml
(every logged-in identity's token/refresh_token — real credentials, kept
0600).

profiles.yml holds MULTIPLE logged-in identities at once (e.g. a
site_admin account and an ordinary account), so you can switch between
them without re-authenticating:

    active: test-admin@test.mailmasker.org
    profiles:
      test-admin@test.mailmasker.org: {token: ..., refresh_token: ...}
      test-user@test.mailmasker.org:  {token: ..., refresh_token: ...}

`active` is the identity commands use by default. It's only ever set by
`login` or `profile use` — never guessed, even when exactly one profile
is stored — so there's no silent "which account am I running as" surprise.
"""

import os
import stat
from pathlib import Path

import yaml

CONFIG_DIR = Path(os.environ.get("HOMELAB_CLI_CONFIG_DIR", Path.home() / ".config" / "homelab-cli"))
CONFIG_FILE = CONFIG_DIR / "config.yml"
PROFILES_FILE = CONFIG_DIR / "profiles.yml"
# Pre-multi-profile file shape ({email, token, refresh_token} flat) —
# read once, by _migrate_legacy_session() below, then deleted. Not
# written by anything anymore.
_LEGACY_SESSION_FILE = CONFIG_DIR / "session.yml"

# homelab-api is the ONLY address homelab-cli needs (see ../README.md):
# drive and mail both go through its own /api/v1/drive/* and
# /api/v1/mail/* gateway routes now, which resolve the real backend
# via the service registry server-side. This file used to also need
# drive_base/imap_host/imap_port/smtp_host/smtp_port.
DEFAULT_CONFIG = {
    "api_base": "http://localhost:3000",
}


def load_config():
    if not CONFIG_FILE.exists():
        return dict(DEFAULT_CONFIG)
    with open(CONFIG_FILE) as f:
        return {**DEFAULT_CONFIG, **(yaml.safe_load(f) or {})}


def save_config(config):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        yaml.safe_dump(config, f)


def _write_profiles_file(data):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(PROFILES_FILE, "w") as f:
        yaml.safe_dump(data, f)
    os.chmod(PROFILES_FILE, stat.S_IRUSR | stat.S_IWUSR)  # 0600 — real refresh_tokens live here


def _migrate_legacy_session():
    """One-time upgrade from the old single-session session.yml (flat
    {email, token, refresh_token}) to the new multi-profile shape.
    Runs at most once: the legacy file is deleted afterward so this
    never fires again and there's no second stale credential file left
    on disk (see the dead session.json/config.json found this session —
    not repeating that here)."""
    if not _LEGACY_SESSION_FILE.exists():
        return None
    with open(_LEGACY_SESSION_FILE) as f:
        legacy = yaml.safe_load(f)
    if not legacy or not legacy.get("email"):
        _LEGACY_SESSION_FILE.unlink()
        return None
    data = {
        "active": legacy["email"],
        "profiles": {
            legacy["email"]: {
                "token": legacy.get("token"),
                "refresh_token": legacy.get("refresh_token"),
            },
        },
    }
    _write_profiles_file(data)
    _LEGACY_SESSION_FILE.unlink()
    return data


def load_profiles():
    """Returns {"active": email_or_None, "profiles": {email: {token,
    refresh_token}}}. Never raises — a missing/empty file just means no
    profiles yet."""
    if not PROFILES_FILE.exists():
        migrated = _migrate_legacy_session()
        if migrated is not None:
            return migrated
        return {"active": None, "profiles": {}}
    with open(PROFILES_FILE) as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("active", None)
    data.setdefault("profiles", {})
    return data


def save_profiles(data):
    _write_profiles_file(data)


def get_session(email=None):
    """Returns {email, token, refresh_token} for `email`, or for the
    active profile if `email` is omitted, or None if there's nothing to
    return (no such profile, or nothing active). The returned shape
    matches the old flat session.yml's so every existing call site
    (session["token"], session["refresh_token"]) keeps working
    unchanged."""
    data = load_profiles()
    target = email or data["active"]
    if not target:
        return None
    profile = data["profiles"].get(target)
    if not profile:
        return None
    return {"email": target, **profile}


def upsert_profile(email, token, refresh_token):
    data = load_profiles()
    data["profiles"][email] = {"token": token, "refresh_token": refresh_token}
    save_profiles(data)


def set_active(email):
    """Raises KeyError if `email` has no stored profile — callers turn
    that into a clean CLI error message rather than silently activating
    an identity with no credentials behind it."""
    data = load_profiles()
    if email not in data["profiles"]:
        raise KeyError(email)
    data["active"] = email
    save_profiles(data)


def remove_profile(email):
    """No-op if `email` isn't stored. If it was the active profile,
    active becomes unset — never auto-falls-back to another stored
    profile, matching the "no silent default" rule everywhere else in
    this file."""
    data = load_profiles()
    if email not in data["profiles"]:
        return
    del data["profiles"][email]
    if data["active"] == email:
        data["active"] = None
    save_profiles(data)


def clear_all_profiles():
    save_profiles({"active": None, "profiles": {}})
