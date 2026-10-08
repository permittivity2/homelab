# homelab-backup-client / homelab-backup-server

Two packages, one source repo, built on classic **borg** (1.x):

- **`homelab-backup-client`** — installed on every host being backed up.
  Pushes encrypted archives to a centralized backup server over SSH.
  Driven entirely by a per-host config in `/etc/homelab/backup/client/`
  and run under systemd (timer for periodic schedules, a long-running
  service for continuous mode).
- **`homelab-backup-server`** — installed once, on the centralized
  backup server. Creates the `borgbackup` system user/group and backup
  directory, and applies enrollment/revocation requests to its own
  `authorized_keys` via a periodic reconciliation job (or the manual
  `enroll`/`list`/`revoke` commands, kept as an emergency fallback).

This tool exists to let an administrator restore a homelab host's
**config or data** to a point in time after a disaster — general
homelab-recovery backup, not narrowly `/etc/homelab/*` config only (see
`mode:` below), and not a general end-user-data (Drive files, mailboxes)
backup tool.

## Control plane: homelab-api / homelab-cli

Both packages authenticate to `homelab-api` as their own service
account, via `homelab-cli`, in their own isolated `--config` directory
(so a service account's session never collides with a human's). This
replaces two things the previous `homelab-borg-service-backup-*`
packages did differently:

- **Enrollment** used to require a human to run `enroll <identifier>
  <pubkey>` on the backup server by hand for every client. Now, `setup`
  on the client just submits its pubkey via `homelab-cli backup enroll`
  once; `homelab-backup-server`'s own reconciliation job (running on its
  own timer) polls for pending enrollments/revocations and applies them
  to `authorized_keys` automatically. No SSH or sudo access to the
  backup server is ever needed from the client side, same as before —
  onboarding is just no longer a manual step.
- **Run-history reporting** used to have the client write directly to a
  PostgreSQL database with its own dedicated credentials. Now it reports
  through `homelab-cli backup report-run`/`report-check` instead,
  reusing the same identity layer every other `homelab-*` package
  standardizes on. Still best-effort: a control-plane hiccup only logs a
  warning, never fails or blocks an actual backup.

`homelab_cli.disabled: true` in a client's config.yml opts it out of the
control plane entirely (requires `backup_server` to be set explicitly,
since server discovery also goes through homelab-cli).

## Server setup

```
sudo apt install ./homelab-backup-server_*.deb
sudo homelab-backup-server setup
```

`setup` is interactive (backup-server hostname/IP, control-plane account,
reconciliation interval) and idempotent (safe to re-run). It:

1. Installs `borgbackup` (the `Conflicts: borgbackup2` in
   `debian/control` prevents the v1/v2 binary-name mismatch that used to
   break every client backup with `sh: 1: borg: not found`).
2. Creates the `borgbackup` system user/group (no login shell) if
   missing, and the backup directory (default `/var/borgbackup`), owned
   by `borgbackup`.
3. Establishes this server's own homelab-cli session (prompting for the
   control-plane account if not already logged in) and registers itself
   via `homelab-cli backup set-server-info` — this is what lets a
   never-before-enrolled client discover which server to talk to.
4. Installs and enables `homelab-backup-server-reconcile.timer`, which
   polls for pending enrollments/revocations and applies them to
   `~borgbackup/.ssh/authorized_keys`.

`enroll`/`list`/`revoke`/`admin-recovery-key` remain available as
manual/emergency-fallback commands even with the reconciliation job
running.

## Client install

```
sudo apt install ./homelab-backup-client_*.deb
sudo homelab-backup-client setup
```

(Or, for a non-packaged install: `sudo ./install/install.sh`.)

This is interactive and root-only. It will:

1. Check for/install `borgbackup`, `python3-yaml`, `python3-systemd`,
   `homelab-cli`.
2. Create `/etc/homelab/backup/client/config.yml` from
   `config/config.example.yml` (only if it doesn't already exist) — or,
   if this host still has the pre-rename
   `/etc/homelab/borgbackup/` config from
   `homelab-borg-service-backup-client`, copy it forward instead (SSH
   keypair and repo passphrase are never regenerated; the old copy is
   left in place, not deleted).
3. Prompt for anything required but unset: backup mode, schedule.
   `backup_server` is optional — leave it blank to auto-discover via
   `homelab-cli backup server-info` at run time. A per-host encryption
   passphrase is **generated automatically** (see Encryption & key
   escrow below) — pass `--passphrase-file FILE` to supply your own
   instead.
4. If mode is `homelab_only`, pre-populate `homelab_only.paths`/
   `databases` by detecting installed `homelab-*` packages.
5. Generate a dedicated SSH key (`/etc/homelab/backup/client/ssh/`), log
   in to homelab-api (if not already validated), and submit
   `homelab-cli backup enroll` with this host's identifier/pubkey — no
   admin action needed on the backup server; it's picked up by that
   server's own reconciliation timer within a few minutes.
6. Install the script to `/usr/local/sbin/homelab-backup-client` and the
   appropriate systemd unit(s), then enable+start them.
7. Print a one-time summary telling you exactly what to escrow and
   where, if a new passphrase was generated.

Re-run `install.sh`/`setup` any time to pick up a changed `schedule.mode`
(it regenerates the systemd units) — it will not overwrite an existing
`config.yml` or SSH key.

## Uninstall

```
sudo ./install/uninstall.sh          # stops/removes units + binary, keeps config
sudo ./install/uninstall.sh --purge  # also removes /etc/homelab/backup/client entirely
```

## Encryption & key escrow

Every repo is created with borg's `repokey` encryption (the key lives
inside the repo itself, so it travels with it wherever the repo is
replicated) protected by a **passphrase unique to that host**, generated
automatically by `install.sh`. Leaving `encryption.passphrase` blank is
a hard error unless `encryption.allow_unencrypted: true` is explicitly
set — silent unencrypted backups are not the default, since this tool
can back up anything up to and including a full host, secrets and all.

On top of the passphrase, the first successful backup run also exports
the repo's key independently via `borg key export` into
`/etc/homelab/backup/client/key-escrow/<identifier>.key` (plus a
`--paper` printable copy at `<identifier>-paper.txt`). This is a safety
net against repo metadata damage, not a substitute for the passphrase.

**None of this is backed up anywhere off the source host automatically.**
The whole point of this tool is surviving the loss of a host — so before
that happens, copy both the generated passphrase (printed once by
`install.sh`, and stored in `config.yml`) and the exported key files to:

1. A password manager / self-hosted secrets manager, and
2. An offline/paper copy (the `--paper` export is meant to be printed or
   transcribed).

See `admin-recovery-key` below for the SSH-side equivalent of this
problem.

## Restoring onto a fresh/replacement host

Run once, on the backup server (part of the `homelab-backup-server`
package, not per client host), to generate a broader-scoped **admin
recovery key**:

```
sudo homelab-backup-server admin-recovery-key
```

This key can `list`/`extract` **any** host's repo under
`backup_location` (still restricted to `borg serve`, never an
interactive shell) — it exists so a restore doesn't depend on the very
host key that a disaster may have destroyed along with everything else.
Escrow its private key the same way as passphrases above.

Disaster recovery runbook, once a host is gone and you're rebuilding it
(or restoring to any other machine):

1. Reimage/provision the replacement host, install `borgbackup` and this
   package (`sudo ./install/install.sh`, or the `.deb` — see Packaging
   below). You do **not** need to finish configuring it as a backup
   client to restore from it.
2. Retrieve the escrowed passphrase for the **original** host's repo,
   and the admin recovery key from step above.
3. List what's available:
   ```
   homelab-backup-client list-archives \
       --host <original-identifier> --server <backup-server-address> \
       --ssh-key /path/to/admin-recovery/id_ed25519 \
       --passphrase-file /path/to/escrowed-passphrase
   ```
4. Extract into a staging directory (never straight onto `/`):
   ```
   homelab-backup-client restore \
       --host <original-identifier> --server <backup-server-address> \
       --ssh-key /path/to/admin-recovery/id_ed25519 \
       --passphrase-file /path/to/escrowed-passphrase \
       --archive <archive-name> --target /var/tmp/restore
   ```
5. Review `/var/tmp/restore` and manually copy what's needed into place
   — a restore is a reviewable staging step, not an automatic overwrite.

`--host`/`--server`/`--ssh-user`/`--location`/`--ssh-key`/
`--passphrase-file` on `list-archives`/`restore` all fall back to the
local `config.yml` (and, beyond that, homelab-cli server discovery) when
omitted, so restoring a specific file on a still-alive host (no disaster
involved) just needs `homelab-backup-client list-archives` / `restore
--archive ... --target ...` with no overrides.

To find which archive has the file/directory you need before extracting
anything, pass `--archive NAME` to `list-archives` to list that
archive's contents instead of the repo's archive names:
```
homelab-backup-client list-archives                          # archive names
homelab-backup-client list-archives --archive <archive-name>  # that archive's files
```
Tab completion offers real archive names after `--archive` on both
`list-archives` and `restore` (it shells out to `list-archives
--names-only` under the hood, reusing whatever `--host`/`--server`/etc.
overrides are already on the command line) — falls back to no
suggestions if the repo can't be reached quickly, nothing has been
enrolled/backed up yet, or passwordless sudo isn't set up for this
command.

## Run-history reporting (optional, via homelab-cli)

Unless `homelab_cli.disabled: true` is set, every `backup`/`check` run
reports its outcome via `homelab-cli backup report-run`/`report-check`:
status, timing, and — for backups, via `borg create --json` — real
original/compressed/deduplicated size and file count. Query it back out
with `homelab-cli backup host-runs <identifier>`.

**This never touches Postgres directly** — homelab-api owns the schema
and all writes go through its REST API, authenticated as this host's own
service-account session. A reporting failure (control-plane outage, bad
session, etc.) only ever logs a warning — it never fails or blocks an
actual backup.

## Config reference

See `config/config.example.yml` for the full documented schema. Key
points:

- **Host identifier**: `hostname` in config, or
  `<system-hostname>-<contents of /etc/machine-id>` if unset. If
  `/etc/machine-id` is unreadable and no override is set, the script
  logs to journald and exits cleanly (exit 0) rather than guessing.
- **mode**: `full_host` | `local_only` | `homelab_only` | `specific`.
  `exclude:` (regex list) applies on top of whichever mode is chosen.
- **backup_server** / **ssh_backup_server_username** /
  **backup_server_location**: all optional. Leave `backup_server` blank
  to auto-discover via `homelab-cli backup server-info`; set it
  explicitly to hardcode a server (keeps working through a homelab-api
  outage, or lets you opt out of the control plane with
  `homelab_cli.disabled: true`).
- **schedule.mode**: `hourly` | `daily` | `weekly` | `monthly` |
  `calendar` (raw systemd `OnCalendar=` expression) | `continuous`
  (script loops immediately after each successful run; no timer).
  `daily`/`weekly`/`monthly` don't fire at exact midnight — install.sh
  picks a random hour (from `schedule.window_hours`, default an 11pm-3am
  window: `[23, 0, 1, 2]`) and minute once, persists it into
  `schedule.start_hour`/`start_minute`, and reuses that same time on
  every re-run (clear both to re-roll). On top of that, every
  timer-driven mode (including `hourly`/`calendar`) gets an additional
  `RandomizedDelaySec` from `schedule.jitter_seconds` (default 1800).
  Together this keeps a fleet of hosts from all hitting the backup
  server at once.
- **retention**: `borg prune` runs after every successful backup using
  `keep_daily`/`keep_weekly`/`keep_monthly`/`keep_yearly`.
- **encryption.passphrase**: auto-generated per host at install; see
  Encryption & key escrow above. `encryption.allow_unencrypted: true` is
  the (discouraged) escape hatch to back up without a passphrase.
- **integrity_check.mode**: `never` | `weekly` | `monthly` (default).
  Runs `borg check` (read-only, never `--repair`) on its own timer,
  separate from the backup schedule since a full check is slower and
  shouldn't block backups. A corrupted repo is only useful to discover
  before a real disaster recovery attempt needs it.
- **homelab_cli.\***: control-plane config — `config_dir` (this host's
  isolated homelab-cli session directory), `api_url`, `email`,
  `password` (used once during setup, then cleared), `disabled`. See
  Control plane above.

## Commands

```
homelab-backup-client backup [--dry-run] [--once] [--config PATH]
homelab-backup-client check [--config PATH]
homelab-backup-client list-archives [--host ID] [--server S] [--ssh-user U]
                                     [--location DIR] [--ssh-key PATH]
                                     [--passphrase-file PATH]
                                     [--archive NAME] [--names-only]
homelab-backup-client restore --archive NAME --target DIR [--paths ...]
                               [--dry-run] [same overrides as list-archives]
homelab-backup-client setup [--passphrase-file PATH]
```

Running the binary with no subcommand (or one starting with a flag) is
still accepted and behaves as `backup`, for compatibility with older
invocations and the systemd units.

## Manual testing

```
/usr/local/sbin/homelab-backup-client backup --dry-run --once
journalctl -t homelab-backup-client -f
```

`--dry-run` prints the resolved sources, exclude patterns, and the exact
`borg create`/`borg prune` commands without executing them. `--once`
forces a single run even when `schedule.mode: continuous`.

## Unit tests

```
sudo apt-get install python3-pytest   # or: pip install pytest
pytest tests/
```

Covers the pure-logic functions of both the client (pattern building per
mode, host identifier resolution, repo URL construction, passphrase
fallback order, the bare-args-means-`backup` command detection) and the
server CLI (identifier validation, `authorized_keys` line construction/
parsing, `enroll`/`revoke` idempotency) with no real `borg`/SSH/network/
filesystem-user/homelab-cli calls — the manual dry-run testing above
covers integration-level behavior.

## Packaging

One Debian source package (`debian/`) builds two binary packages —
`homelab-backup-client` and `homelab-backup-server` — sharing a single
changelog/version. A `build-package.sh` (modeled on
`homelab-api/build-package.sh`) builds both `.deb`s and publishes them to
the same shared apt repository used by the rest of this homelab's
`homelab-*` packages. See `debian/` and `build-package.sh` at the repo
root.

Both packages require `homelab-cli` to be installed and reachable
against a live `homelab-api` before their own `setup` can complete
enrollment/registration — see the rollout order in the redesign plan if
bootstrapping a brand-new environment from scratch.
