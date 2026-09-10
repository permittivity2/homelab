"""Config + session storage for homelab-cli.

Two separate files, deliberately: config.yml (the API base URL — not
secret, fine to share/version-control-ignore casually) and session.yml
(the token/refresh_token — a real credential, kept 0600).
"""

import os
import stat
from pathlib import Path

import yaml

CONFIG_DIR = Path(os.environ.get("HOMELAB_CLI_CONFIG_DIR", Path.home() / ".config" / "homelab-cli"))
CONFIG_FILE = CONFIG_DIR / "config.yml"
SESSION_FILE = CONFIG_DIR / "session.yml"

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


def load_session():
    if not SESSION_FILE.exists():
        return None
    with open(SESSION_FILE) as f:
        return yaml.safe_load(f)


def save_session(session):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(SESSION_FILE, "w") as f:
        yaml.safe_dump(session, f)
    os.chmod(SESSION_FILE, stat.S_IRUSR | stat.S_IWUSR)  # 0600 — this holds a real refresh_token


def clear_session():
    if SESSION_FILE.exists():
        SESSION_FILE.unlink()
