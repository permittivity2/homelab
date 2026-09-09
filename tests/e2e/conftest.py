"""Shared fixtures for the end-to-end regression suite.

See tests/e2e/README.md before adding a new test file. Every fix to a
real bug gets a regression test here that stays in the suite permanently
— see CLAUDE.md's "Testing discipline" section.
"""

import pathlib

import pytest
import yaml

E2E_DIR = pathlib.Path(__file__).parent
ENV_FILE = E2E_DIR / "env.yml"
ENV_EXAMPLE_FILE = E2E_DIR / "env.example.yml"


@pytest.fixture(scope="session")
def env_config():
    """The active target environment's config (hostnames, not secrets).

    Falls back to env.example.yml with a warning if env.yml hasn't been
    created yet, so `pytest --collect-only` and CI's collection-only lint
    job both work without requiring a real env.yml to exist.
    """
    path = ENV_FILE if ENV_FILE.exists() else ENV_EXAMPLE_FILE
    with open(path) as f:
        config = yaml.safe_load(f)
    active = config["active_target"]
    return config["targets"][active]


@pytest.fixture(scope="session")
def ssh_host(env_config):
    """The `ssh <host>` alias for the active target, for tests that need
    to shell out (e.g. `subprocess.run(["ssh", ssh_host, ...])`)."""
    return env_config["ssh_host"]
