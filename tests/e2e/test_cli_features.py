"""Regression test for homelab-cli's mail/drive/admin commands (see
cli/README.md) — runs the REAL, packaged `homelab-cli` binary on the
target host over SSH (not `python3 -m homelab_cli.cli` from a source
checkout), the same way an actual user would invoke it after `apt
install homelab-cli`. Package-local unit tests (cli/tests/test_client.py)
already cover the HTTP logic in isolation with everything mocked; this
is what proves the installed CLI actually reaches the real, live
services end-to-end.

`cli_account`'s `configure` call below is also the acceptance test for
the "homelab-cli only needs login + the api FQDN" redesign: `--api-base`
is the only flag it passes now (it used to also need `--drive-base`/
`--imap-host`/`--imap-port`/`--smtp-host`/`--smtp-port` — one address
per feature). Drive and mail both go through homelab-api's own
`/api/v1/drive/*`/`/api/v1/mail/*` gateway routes now (resolved
server-side via the service registry, `/api/v1/mail/*` forwarding on to
the new homelab-mailbridge) — every `drive`/`mail` command below is
unchanged from the CLI's own perspective, proving the redesign is a
pure internal-wiring change, not a behavior change a user would notice
beyond the simpler `configure` step.

Uses a throwaway HOMELAB_CLI_CONFIG_DIR per test run so this never
touches whatever config a real user of the target host already has.
"""

import shlex
import subprocess
import time

import pytest

CONFIG_DIR = "/tmp/e2e-cli-config"


def _run_cli(ssh_host, *cli_args, check=True):
    # ssh joins a list of remote-command args with plain spaces and
    # hands the result to the remote shell for re-tokenizing — a naive
    # list (no quoting) silently splits any argument containing a space
    # (e.g. an email --body) into several argv entries on the far side.
    # shlex.quote() each piece so the remote shell sees exactly what was
    # passed here.
    remote_cmd = shlex.join(["env", f"HOMELAB_CLI_CONFIG_DIR={CONFIG_DIR}", "homelab-cli", *cli_args])
    result = subprocess.run(["ssh", ssh_host, remote_cmd], capture_output=True, text=True, timeout=30)
    if check:
        assert result.returncode == 0, f"homelab-cli {' '.join(cli_args)} failed: {result.stderr or result.stdout}"
    return result


@pytest.fixture
def cli_account(ssh_host):
    """Registers a fresh, real homelab-api account and configures a
    throwaway homelab-cli config dir on the target host, pointed at the
    real public endpoints. Cleans up the config dir afterward — never
    the registered account or anything it created, same "don't clean up
    real accounts" precedent as every other e2e test in this suite."""
    email = f"e2e-cli-{int(time.time() * 1000)}@test.mailmasker.org"
    password = "E2eCliTest1Aa!!"

    _run_cli(ssh_host, "configure", "--api-base", "https://api.test.mailmasker.org")
    _run_cli(ssh_host, "register", email, "--password", password)
    _run_cli(ssh_host, "login", email, "--password", password)

    yield email

    subprocess.run(["ssh", ssh_host, "rm", "-rf", CONFIG_DIR], capture_output=True, timeout=15)


def test_whoami_matches_logged_in_account(ssh_host, cli_account):
    result = _run_cli(ssh_host, "whoami")
    assert cli_account in result.stdout


def test_drive_upload_list_delete_round_trip(ssh_host, cli_account):
    marker = f"e2e-cli-drive-{int(time.time())}.txt"
    remote_path = f"/tmp/{marker}"

    # The CLI itself runs ON the target host (invoked over ssh), so the
    # file to upload has to exist THERE, not on this admin workstation.
    subprocess.run(["ssh", ssh_host, "sh", "-c", f"echo 'e2e cli drive test' > {remote_path}"], check=True, timeout=15)
    try:
        _run_cli(ssh_host, "drive", "list")  # confirm it doesn't error on an empty account

        upload = _run_cli(ssh_host, "drive", "upload", remote_path)
        assert marker in upload.stdout
        file_id = upload.stdout.split("id ")[1].strip().rstrip(")")

        listing = _run_cli(ssh_host, "drive", "list")
        assert marker in listing.stdout

        _run_cli(ssh_host, "drive", "delete", file_id)
        listing_after = _run_cli(ssh_host, "drive", "list")
        assert marker not in listing_after.stdout
    finally:
        subprocess.run(["ssh", ssh_host, "rm", "-f", remote_path], capture_output=True, timeout=15)


def test_drive_upload_over_1mb_and_16mb_succeeds(ssh_host, cli_account):
    """Regression test for a real bug a user hit live: a plain ~1.1MB
    upload failed with a slow, confusing timeout instead of a clear
    error. Root cause was TWO independent size ceilings stacked in
    front of homelab-drive, both defaulting far too low for a general
    file-storage app: homelab-webproxy's nginx vhost had no
    client_max_body_size set at all (nginx's own compiled-in default is
    1MB), and homelab-drive's own Mojolicious process had no
    MOJO_MAX_MESSAGE_SIZE override (Mojo::Message's own default is
    16MB). This can only be caught here, through the real public nginx
    proxy — a package-local Test::Mojo test (drive/t/api.t) dispatches
    in-process and never touches nginx at all, so it can prove the
    Mojolicious-level fix but not the nginx one. 20MB clears both old
    ceilings at once; a separate ~1.1MB case is also checked since
    that's the exact size that failed live."""
    remote_path = "/tmp/e2e-cli-drive-large.bin"
    subprocess.run(["ssh", ssh_host, "sh", "-c", f"head -c 20000000 /dev/urandom > {remote_path}"], check=True, timeout=30)
    try:
        upload = _run_cli(ssh_host, "drive", "upload", remote_path)
        file_id = upload.stdout.split("id ")[1].strip().rstrip(")")
        _run_cli(ssh_host, "drive", "delete", file_id)
    finally:
        subprocess.run(["ssh", ssh_host, "rm", "-f", remote_path], capture_output=True, timeout=15)

    remote_path_1mb = "/tmp/e2e-cli-drive-1mb.bin"
    subprocess.run(["ssh", ssh_host, "sh", "-c", f"head -c 1100000 /dev/urandom > {remote_path_1mb}"], check=True, timeout=15)
    try:
        upload = _run_cli(ssh_host, "drive", "upload", remote_path_1mb)
        file_id = upload.stdout.split("id ")[1].strip().rstrip(")")
        _run_cli(ssh_host, "drive", "delete", file_id)
    finally:
        subprocess.run(["ssh", ssh_host, "rm", "-f", remote_path_1mb], capture_output=True, timeout=15)


def test_drive_nested_folders_round_trip(ssh_host, cli_account):
    """Real folders (added after a user asked for "directories on the
    left, files in the main part" — see drive/README.md's Folders
    section): create a folder, nest a subfolder inside it, upload a
    file into the subfolder, confirm it's listed there and NOT at the
    root, then delete the top-level folder and confirm the cascade took
    the subfolder and file with it."""
    marker_file = f"e2e-cli-nested-{int(time.time())}.txt"
    remote_path = f"/tmp/{marker_file}"
    subprocess.run(["ssh", ssh_host, "sh", "-c", f"echo nested > {remote_path}"], check=True, timeout=15)
    try:
        top = _run_cli(ssh_host, "drive", "mkdir", f"e2e-top-{int(time.time())}")
        top_id = top.stdout.split("id ")[1].strip().rstrip(")")

        sub = _run_cli(ssh_host, "drive", "mkdir", "sub", "--parent", top_id)
        sub_id = sub.stdout.split("id ")[1].strip().rstrip(")")

        upload = _run_cli(ssh_host, "drive", "upload", remote_path, "--folder", sub_id)
        file_id = upload.stdout.split("id ")[1].strip().rstrip(")")

        sub_listing = _run_cli(ssh_host, "drive", "list", "--folder", sub_id)
        assert marker_file in sub_listing.stdout

        root_listing = _run_cli(ssh_host, "drive", "list")
        assert marker_file not in root_listing.stdout, "a file inside a folder must not appear in the root listing"

        _run_cli(ssh_host, "drive", "rmdir", top_id)

        # Everything nested under top_id -- the subfolder and the file
        # inside it -- must be gone too, not just top_id itself.
        assert _run_cli(ssh_host, "drive", "list", "--folder", sub_id, check=False).returncode != 0
        assert _run_cli(ssh_host, "drive", "download", file_id, check=False).returncode != 0
    finally:
        subprocess.run(["ssh", ssh_host, "rm", "-f", remote_path], capture_output=True, timeout=15)


def test_mail_send_then_list_shows_it(ssh_host, cli_account):
    email = cli_account
    subject = f"e2e-cli-mail-{int(time.time())}"

    _run_cli(ssh_host, "mail", "send", "--to", email, "--subject", subject, "--body", "e2e cli mail test body")

    # IMAP delivery isn't instantaneous — poll briefly rather than
    # assuming it's already visible the instant SMTP accepted it.
    listing = None
    for _ in range(10):
        listing = _run_cli(ssh_host, "mail", "list")
        if subject in listing.stdout:
            break
        time.sleep(1)
    assert listing is not None and subject in listing.stdout, (
        f"sent message never appeared in mail list within 10s: {listing.stdout if listing else '(no attempt ran)'}"
    )

    uid = listing.stdout.split("[", 1)[1].split("]", 1)[0]
    read = _run_cli(ssh_host, "mail", "read", uid)
    assert subject in read.stdout
    assert "e2e cli mail test body" in read.stdout
    # Regression check for a real bug found while building this: Python's
    # EmailMessage doesn't set a Date header on its own — see
    # homelab_cli/mail.py's fix.
    date_line = next((line for line in read.stdout.splitlines() if line.startswith("Date:")), "")
    assert date_line.strip() != "Date:", "Date header came back empty"


def test_admin_commands_reject_non_admin_account(ssh_host, cli_account):
    """This test's own account is deliberately NOT a site_admin (there's
    no self-service way to become one, by design — see api/README.md's
    Admin endpoints section) — confirms the CLI surfaces the server's
    real 403 cleanly rather than crashing or silently pretending to
    succeed."""
    result = _run_cli(ssh_host, "admin", "users", "list", check=False)
    assert result.returncode != 0
    assert "site_admin role required" in result.stdout or "site_admin role required" in result.stderr
