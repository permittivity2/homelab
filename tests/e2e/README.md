# End-to-end regression suite

This is the cross-feature regression suite described in the repo's
`CLAUDE.md` ("Testing discipline"). It's the one deliberate place this
repo uses Python — everything else shipped is Perl.

## Setup

```bash
cd tests/e2e
cp env.example.yml env.yml   # edit active_target if needed — hostnames only, no secrets
pip install -r requirements.txt
```

## Running

```bash
# The whole accumulated suite — this is what you run before considering
# any fix or new feature done, not just the new test you just added.
pytest tests/e2e/

# A single capability:
pytest tests/e2e/test_dns_delegation.py
```

## Rules (see CLAUDE.md for the full statement)

- Every new feature adds at least one test file here before being done.
- Every bug fix adds a regression test reproducing the bug, and it stays
  in the suite forever.
- This suite needs a real, pre-provisioned target host (see
  `env.example.yml`) — it does not run unmodified against arbitrary CI
  runners. GitHub Actions only lints/collects it
  (`pytest --collect-only`); running it for real is on-demand/scheduled
  against the actual test environment.
