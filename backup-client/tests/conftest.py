"""Loads scripts that have no .py extension (so they aren't importable
the normal way) as modules, before test collection imports them by name."""
import importlib.machinery
import importlib.util
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load(module_name, script_path):
    loader = importlib.machinery.SourceFileLoader(module_name, str(script_path))
    spec = importlib.util.spec_from_loader(module_name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    loader.exec_module(module)


_load("homelab_backup_client", REPO_ROOT / "bin" / "homelab-backup-client")

# The sibling borg-backup-server package is out of scope for this
# package's own rewrite (a separate effort owns it) -- loaded under both
# its old and new module name here since tests/test_server.py (also out
# of scope) may reference either depending on how far along that rename
# is when this runs.
_SERVER_SCRIPT = REPO_ROOT.parent / "borg-backup-server" / "homelab-backup-server"
if not _SERVER_SCRIPT.exists():
    _SERVER_SCRIPT = REPO_ROOT.parent / "borg-backup-server" / "homelab-borg-service-backup-server"
_load("homelab_backup_server", _SERVER_SCRIPT)
_load("homelab_borg_service_backup_server", _SERVER_SCRIPT)
