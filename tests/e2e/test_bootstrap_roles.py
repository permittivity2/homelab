"""Phase 1 regression test: homelab-bootstrap-app-role produces correctly
split runtime/migrate Postgres roles for real, both locally AND over a
genuine SSH hop to a different host.

The remote-path half of this file is the regression test for a real bug
found 2026-09-09 building homelab-dovecot: OpenSSH concatenates ALL of
its own trailing command arguments with plain spaces and hands the
joined string to the REMOTE shell to parse (see ssh(1)). The script's
SCRAM-secret-fetch query was passed to `psql -tAc` as a separate argv
element — its embedded single quotes got reinterpreted by that remote
shell before psql ever saw them intact, so `run_remote()` could never
have worked, even though every unit test passed (they only ever exercise
the local path — see common/t/bootstrap-role.t). Fixed by piping the
query via psql's stdin instead (no -c, so psql executes stdin as a
script), the same technique the DDL-apply step already used safely.

This lives in tests/e2e/, not common/t/, because exercising the remote
path for real needs a second real, reachable Postgres host — this repo's
e2e suite already documents that constraint (see README.md) and already
provides an `ssh_host` fixture for exactly this shape of test. Run from
the admin workstation (same assumption every other file in this suite
makes): the *outer* process here is the "remote-invoking side" for the
script's own SSH hop, so it needs real `ssh <alias>` trust to
test-static-internet-ip, same as every other command run all session.
"""

import pathlib
import subprocess
import time

import pytest

REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
BOOTSTRAP_SCRIPT = REPO_ROOT / "common" / "script" / "homelab-bootstrap-app-role"


def _psql_on_host(ssh_host, sql, role=None, password=None):
    """Runs one SQL statement as a given role (or as the postgres
    superuser if role is None) against the shared `homelab` database,
    via SSH to ssh_host. Returns the CompletedProcess."""
    if role is None:
        remote_cmd = f"sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1 -c \"{sql}\""
    else:
        # Direct to Postgres (5432), NOT pgbouncer (6432) -- this test only
        # runs the bootstrap script itself, never the separate
        # homelab-bootstrap-pgbouncer-entry step, so neither role is
        # registered with pgbouncer yet. Matches CLAUDE.md's design anyway:
        # the migrate role is deliberately NEVER registered with pgbouncer
        # at all, only ever connecting directly.
        remote_cmd = (
            f"PGPASSWORD={password!r} psql -h 127.0.0.1 -p 5432 -U {role} -d homelab -X -q -c \"{sql}\""
        )
    return subprocess.run(["ssh", ssh_host, remote_cmd], capture_output=True, text=True, timeout=20)


def _parse_kv_output(text):
    creds = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            creds[k] = v
    return creds


@pytest.fixture
def throwaway_feature():
    return f"e2etest{int(time.time())}"


@pytest.fixture
def cleanup_role_and_schema(ssh_host, throwaway_feature):
    yield
    _psql_on_host(ssh_host, f'DROP SCHEMA IF EXISTS "{throwaway_feature}" CASCADE')
    _psql_on_host(ssh_host, f'DROP ROLE IF EXISTS "{throwaway_feature}_runtime"')
    _psql_on_host(ssh_host, f'DROP ROLE IF EXISTS "{throwaway_feature}_migrate"')


def test_remote_bootstrap_produces_working_split_roles(ssh_host, throwaway_feature, cleanup_role_and_schema):
    """Runs the REAL bootstrap script from the admin workstation with
    --db-host pointed at a genuinely different machine (ssh_host) —
    exercises run_remote(), not run_local() (see module docstring)."""
    result = subprocess.run(
        ["perl", str(BOOTSTRAP_SCRIPT), "--feature", throwaway_feature,
         "--schema", throwaway_feature, "--db-host", ssh_host],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, (
        f"bootstrap over a real SSH hop failed (stdout={result.stdout!r}): {result.stderr}"
    )

    creds = _parse_kv_output(result.stdout)
    for key in ("RUNTIME_ROLE", "RUNTIME_PASSWORD", "RUNTIME_SCRAM_SECRET",
                "MIGRATE_ROLE", "MIGRATE_PASSWORD", "MIGRATE_SCRAM_SECRET"):
        assert creds.get(key), f"missing {key} in bootstrap output — remote secret fetch likely broke again"

    # The split-role property itself, verified for real: migrate can DDL,
    # runtime can immediately CRUD what migrate just created (the
    # FOR ROLE default-privileges property), runtime cannot DDL at all.
    r = _psql_on_host(ssh_host, f'CREATE TABLE "{throwaway_feature}".widgets (id SERIAL PRIMARY KEY, name TEXT)',
                       role=creds["MIGRATE_ROLE"], password=creds["MIGRATE_PASSWORD"])
    assert r.returncode == 0, f"migrate role could not CREATE TABLE: {r.stderr}"

    r = _psql_on_host(ssh_host, f'INSERT INTO "{throwaway_feature}".widgets (name) VALUES (\'x\')',
                       role=creds["RUNTIME_ROLE"], password=creds["RUNTIME_PASSWORD"])
    assert r.returncode == 0, f"runtime role could not INSERT into a table migrate just created: {r.stderr}"

    r = _psql_on_host(ssh_host, f'DROP TABLE "{throwaway_feature}".widgets',
                       role=creds["RUNTIME_ROLE"], password=creds["RUNTIME_PASSWORD"])
    assert r.returncode != 0, "runtime role was able to DROP TABLE — it must have no DDL rights at all"


def test_remote_bootstrap_is_idempotent(ssh_host, throwaway_feature, cleanup_role_and_schema):
    script = str(BOOTSTRAP_SCRIPT)
    first = subprocess.run(
        ["perl", script, "--feature", throwaway_feature, "--schema", throwaway_feature, "--db-host", ssh_host],
        capture_output=True, text=True, timeout=30,
    )
    assert first.returncode == 0
    second = subprocess.run(
        ["perl", script, "--feature", throwaway_feature, "--schema", throwaway_feature, "--db-host", ssh_host],
        capture_output=True, text=True, timeout=30,
    )
    assert second.returncode == 0, f"re-running bootstrap over SSH must succeed: {second.stderr}"
