# homelab-cli

Command-line client for `homelab-api`. The one package in this
ecosystem allowed to be Python (see `CLAUDE.md`'s Language section) —
everything else ships as Perl.

```bash
homelab-cli configure https://login.test.mailmasker.org   # set api_base once
homelab-cli register you@test.mailmasker.org
homelab-cli login you@test.mailmasker.org
homelab-cli whoami
homelab-cli registry lookup homelab-drive
homelab-cli logout
```

Session (`token`/`refresh_token`) is stored `0600` in
`~/.config/homelab-cli/session.yml`, separate from the non-secret
`api_base` in `config.yml` in the same directory.

## Testing

```bash
pip install -e '.[dev]' pytest   # or just: pip install requests pyyaml pytest
python3 -m pytest tests/
```

No live infrastructure needed — `test_client.py` mocks the HTTP layer,
`test_config.py` uses `tmp_path`/`monkeypatch` for the config/session
files (including verifying `session.yml` is actually written `0600`,
not just intended to be).
