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
  runners. `.github/workflows/ci.yml` has two jobs for it:
  - `e2e-suite-lint` runs on every push/PR, on a normal GitHub-hosted
    runner, and only does `pytest --collect-only` — a syntax check,
    not a real run.
  - `e2e-suite-live` runs the suite for real (`pytest tests/e2e/`,
    same as "Running" above) against the live `ct-fleet` target, but
    only on a nightly `schedule:` and on manual `workflow_dispatch` —
    never on push/PR, since a random PR must not get live SSH
    credentials into the fleet. It requires a **self-hosted** runner
    (label `homelab-fleet`) that already has working SSH access to the
    `ct-fleet` hosts configured — GitHub's hosted runners have no path
    into this private network at all. As of this writing no such
    runner is registered against the repo yet (`gh api
    repos/<owner>/<repo>/actions/runners` returns zero), so
    `e2e-suite-live` is currently scaffolding: it will queue
    indefinitely until someone registers that runner. Until then,
    running the suite for real is still a manual, on-demand step done
    from a machine with fleet SSH access (see "Running" above).
