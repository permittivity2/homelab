#!/usr/bin/env bash
# Installs the homelab-backup-client: dependencies, config skeleton, SSH
# keypair + control-plane enrollment, script, and systemd units. Must be
# run as root. Interactive.
#
# Usage: install.sh [--passphrase-file FILE] [--skip-packages] [--skip-binary]
#   --passphrase-file FILE   Use the passphrase in FILE instead of
#                            auto-generating one. Only consulted on first
#                            install (an existing config.yml is never
#                            overwritten).
#   --skip-packages          Don't apt-install dependencies (used when a
#                            Debian package already declared them).
#   --skip-binary            Don't copy bin/homelab-backup-client into
#                            place (used when a Debian package already
#                            put it in $PATH). Systemd units are still
#                            generated/enabled either way.
#
# This script runs in two contexts: a plain git checkout (REPO_ROOT is
# this script's own parent directory: install/, config/, systemd/, bin/
# as siblings) or a Debian package install, invoked as
# `homelab-backup-client setup` (REPO_ROOT is the package's shared data
# directory, laid out identically). Detected automatically below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGED_DATA_DIR=/usr/share/homelab-backup-client
if [ -d "$SCRIPT_DIR/../config" ] && [ -d "$SCRIPT_DIR/../systemd" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    REPO_ROOT="$PACKAGED_DATA_DIR"
fi
CONFIGEDIT="$REPO_ROOT/install/configedit.py"

ETC_DIR=/etc/homelab/backup/client
CONFIG=$ETC_DIR/config.yml
SSH_DIR=$ETC_DIR/ssh
SSH_KEY=$SSH_DIR/id_ed25519
KEY_ESCROW_DIR=$ETC_DIR/key-escrow
HOMELAB_CLI_CONFIG_DIR=$ETC_DIR/homelab-cli
if [ -x /usr/sbin/homelab-backup-client ]; then
    BIN_DEST=/usr/sbin/homelab-backup-client   # already installed by the .deb
else
    BIN_DEST=/usr/local/sbin/homelab-backup-client
fi
UNIT_DIR=/etc/systemd/system

# Old package's config dir, from before the homelab-borg-service-*
# rename -- see migrate_legacy_config_dir() below.
LEGACY_ETC_DIR=/etc/homelab/borgbackup

# Set by prompt_config_values() when a new passphrase was generated this
# run, so print_summary() can surface it once. Empty if config.yml
# already had a passphrase (nothing new to escrow).
GENERATED_PASSPHRASE=""

PASSPHRASE_FILE=""
SKIP_PACKAGES=0
SKIP_BINARY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --passphrase-file)
            PASSPHRASE_FILE="$2"
            shift 2
            ;;
        --skip-packages)
            SKIP_PACKAGES=1
            shift
            ;;
        --skip-binary)
            SKIP_BINARY=1
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

cfg_get() { python3 "$CONFIGEDIT" get "$CONFIG" "$1"; }
cfg_get_list() { python3 "$CONFIGEDIT" get-list "$CONFIG" "$1"; }
cfg_set() { python3 "$CONFIGEDIT" set-scalar "$CONFIG" "$1" "$2"; }
cfg_set_list() { local key=$1; shift; python3 "$CONFIGEDIT" set-list "$CONFIG" "$key" "$@"; }
cfg_set_databases() { local key=$1; shift; python3 "$CONFIGEDIT" set-databases "$CONFIG" "$key" "$@"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "must be run as root"
    fi
}

install_packages() {
    if [ "$SKIP_PACKAGES" -eq 1 ]; then
        log "skipping package install (--skip-packages)"
        if ! command -v borg >/dev/null 2>&1; then
            die "borg command not available; --skip-packages assumes a Debian package already declared this dependency"
        fi
        if ! command -v homelab-cli >/dev/null 2>&1; then
            die "homelab-cli command not available; --skip-packages assumes a Debian package already declared this dependency"
        fi
        return
    fi

    log "checking required packages"
    local pkgs=()
    dpkg -s borgbackup >/dev/null 2>&1 || pkgs+=(borgbackup)
    dpkg -s python3-yaml >/dev/null 2>&1 || pkgs+=(python3-yaml)
    dpkg -s python3-systemd >/dev/null 2>&1 || pkgs+=(python3-systemd)
    dpkg -s openssh-client >/dev/null 2>&1 || pkgs+=(openssh-client)
    dpkg -s homelab-cli >/dev/null 2>&1 || pkgs+=(homelab-cli)

    if [ "${#pkgs[@]}" -gt 0 ]; then
        log "installing: ${pkgs[*]} (this can take a minute on a fresh host)"
        # DEBIAN_FRONTEND avoids a hung debconf prompt; NEEDRESTART_MODE=a
        # skips needrestart's interactive "which services to restart?"
        # dialog (default on Ubuntu 22.04+) — both can otherwise sit
        # silently waiting for input with no visible output at all,
        # which looks exactly like a hang.
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        apt-get update -qq
        apt-get install -y "${pkgs[@]}"
        log "package install finished"
    else
        log "all required packages already installed"
    fi

    if ! command -v borg >/dev/null 2>&1; then
        die "borg command not available after install; is borgbackup available via apt on this host?"
    fi
    if ! command -v homelab-cli >/dev/null 2>&1; then
        die "homelab-cli command not available after install; is it available via apt on this host?"
    fi
}

# Config-path migration for hosts still on the pre-rename
# /etc/homelab/borgbackup layout (homelab-borg-service-backup-client).
# Copies the old dir forward verbatim -- crucially preserving ssh/ (the
# SSH keypair must never be regenerated, or the existing enrollment
# would be orphaned) and key-escrow/ (the repo passphrase/key exports) --
# and leaves the old copy in place as a rollback breadcrumb. A no-op if
# the old package was never installed on this host, or if the new
# config dir already exists (never overwrites).
migrate_legacy_config_dir() {
    if [ -d "$ETC_DIR" ]; then
        return
    fi
    if [ ! -d "$LEGACY_ETC_DIR" ]; then
        return
    fi
    log "found legacy config at $LEGACY_ETC_DIR, copying forward to $ETC_DIR (old copy left in place)"
    mkdir -p "$(dirname "$ETC_DIR")"
    cp -a "$LEGACY_ETC_DIR" "$ETC_DIR"
}

setup_config_skeleton() {
    migrate_legacy_config_dir
    mkdir -p "$ETC_DIR"
    chmod 700 "$ETC_DIR"
    if [ ! -f "$CONFIG" ]; then
        log "creating $CONFIG from example"
        cp "$REPO_ROOT/config/config.example.yml" "$CONFIG"
    else
        log "$CONFIG already exists, leaving as-is"
    fi
    chmod 600 "$CONFIG"
    chown root:root "$CONFIG"
}

prompt_if_blank() {
    # prompt_if_blank <dotted.key> <prompt text> <default>
    local key=$1 prompt=$2 default=${3:-}
    local current
    current=$(cfg_get "$key")
    if [ -n "$current" ]; then
        return
    fi
    local answer
    read -r -p "$prompt${default:+ [$default]}: " answer
    answer=${answer:-$default}
    if [ -n "$answer" ]; then
        cfg_set "$key" "$answer"
    fi
}

prompt_config_values() {
    # backup_server is now optional -- auto-discovered via `homelab-cli
    # backup server-info` if left blank (see setup_control_plane()) --
    # so, unlike the old borgbackup_server, this is never a hard
    # requirement here.
    prompt_if_blank backup_server "Address of the centralized backup server (blank = auto-discover via homelab-api)" ""

    if [ -z "$(cfg_get encryption.passphrase)" ]; then
        local passphrase
        if [ -n "$PASSPHRASE_FILE" ]; then
            log "reading encryption passphrase from $PASSPHRASE_FILE"
            passphrase=$(cat "$PASSPHRASE_FILE")
            [ -n "$passphrase" ] || die "$PASSPHRASE_FILE is empty"
        else
            # Auto-generated: a per-host unique passphrase beats an
            # admin-chosen one (no reuse across hosts, no weak human
            # passphrases), and it's exported below along with the borg
            # key so it can be escrowed as one unit.
            log "generating a random per-host encryption passphrase"
            passphrase=$(openssl rand -base64 32)
        fi
        cfg_set encryption.passphrase "$passphrase"
        GENERATED_PASSPHRASE="$passphrase"
    fi

    local current_mode
    current_mode=$(cfg_get mode)
    echo "Backup mode (current: ${current_mode:-full_host}):"
    echo "  1) full_host    - everything on the host"
    echo "  2) local_only   - everything except network/virtual mounts"
    echo "  3) homelab_only - homelab app configs + DB dumps only"
    echo "  4) specific     - only paths listed in specific.paths"
    read -r -p "Choose [1-4, blank = keep current]: " mode_choice
    case "$mode_choice" in
        1) cfg_set mode full_host ;;
        2) cfg_set mode local_only ;;
        3) cfg_set mode homelab_only ;;
        4) cfg_set mode specific ;;
        "") ;;
        *) warn "unrecognized choice, keeping current mode" ;;
    esac

    local final_mode
    final_mode=$(cfg_get mode)

    if [ "$final_mode" = "homelab_only" ]; then
        populate_homelab_defaults
    elif [ "$final_mode" = "specific" ]; then
        warn "mode is specific: edit $CONFIG's specific.paths list before the first run"
    fi

    local current_sched
    current_sched=$(cfg_get schedule.mode)
    echo "Schedule (current: ${current_sched:-daily}):"
    echo "  1) hourly"
    echo "  2) daily"
    echo "  3) weekly"
    echo "  4) monthly"
    echo "  5) calendar   - custom systemd OnCalendar= expression"
    echo "  6) continuous - back-to-back runs, no timer"
    read -r -p "Choose [1-6, blank = keep current]: " sched_choice
    case "$sched_choice" in
        1) cfg_set schedule.mode hourly ;;
        2) cfg_set schedule.mode daily ;;
        3) cfg_set schedule.mode weekly ;;
        4) cfg_set schedule.mode monthly ;;
        5)
            cfg_set schedule.mode calendar
            read -r -p "systemd OnCalendar= expression (see man systemd.time): " cal_expr
            cfg_set schedule.calendar "$cal_expr"
            ;;
        6) cfg_set schedule.mode continuous ;;
        "") ;;
        *) warn "unrecognized choice, keeping current schedule" ;;
    esac
}

SSH_PROBE_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

# Every homelab-* package that wants homelab_only mode to protect it
# ships /usr/share/homelab-<pkgname>/backup-paths.txt (one path per
# line, # comments and blank lines ignored) -- a directory dpkg already
# fully owns (created on install, removed automatically on remove/
# purge), so there's no separate registration/cleanup bookkeeping for
# any package to maintain. This auto-discovers whatever's actually
# installed on THIS host with no hardcoded per-package knowledge here,
# and any future package participates just by shipping the file -- see
# CLAUDE.md's "Standard pattern for a new package's Postgres role"
# section for the sibling convention this mirrors. Packages with actual
# data to dump (not just config) additionally ship an executable
# backup-hook.sh -- see dump_databases() in the main script, which is
# what actually runs those.
populate_homelab_defaults() {
    local current_paths
    current_paths=$(cfg_get homelab_only.paths)
    if [ -n "$current_paths" ]; then
        log "homelab_only.paths already set, leaving as-is"
        return
    fi

    log "scanning /usr/share/homelab-*/backup-paths.txt for default backup paths"
    local paths=() manifest line
    declare -A seen=()
    for manifest in /usr/share/homelab-*/backup-paths.txt; do
        [ -f "$manifest" ] || continue
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | xargs)"
            [ -n "$line" ] || continue
            [ -n "${seen[$line]:-}" ] && continue
            seen[$line]=1
            paths+=("$line")
        done < "$manifest"
    done

    if [ "${#paths[@]}" -eq 0 ]; then
        warn "no homelab-*/backup-paths.txt manifests found; leaving homelab_only.paths empty, edit $CONFIG manually"
        return
    fi

    log "detected homelab paths: ${paths[*]}"
    cfg_set_list homelab_only.paths "${paths[@]}"
}

homelab_cli() {
    "$(command -v homelab-cli)" --config "$HOMELAB_CLI_CONFIG_DIR" "$@"
}

# Ensures this host has its own working homelab-cli session, prompting
# for api_url/email/password only if not already configured/validated.
# The password (however obtained) is used exactly once to log in, then
# immediately cleared from config.yml -- only session.json persists the
# credential from then on.
ensure_homelab_cli_session() {
    mkdir -p "$HOMELAB_CLI_CONFIG_DIR"
    chmod 700 "$HOMELAB_CLI_CONFIG_DIR"

    prompt_if_blank homelab_cli.api_url "homelab-api base URL (e.g. https://api.example.internal)" ""
    local api_url
    api_url=$(cfg_get homelab_cli.api_url)
    if [ -z "$api_url" ]; then
        warn "homelab_cli.api_url is blank; skipping homelab-api setup entirely"
        return 1
    fi
    homelab_cli configure --set-api-url "$api_url" >/dev/null

    if homelab_cli validate >/dev/null 2>&1; then
        log "homelab-cli session already valid"
        return 0
    fi

    prompt_if_blank homelab_cli.email "homelab-api login email for this host" "homelabbackup@homelab.internal"
    local email
    email=$(cfg_get homelab_cli.email)
    if [ -z "$email" ]; then
        warn "homelab_cli.email is blank; skipping homelab-api setup entirely"
        return 1
    fi

    local password
    password=$(cfg_get homelab_cli.password)
    if [ -n "$password" ]; then
        log "logging in to homelab-api as $email (using saved homelab_cli.password)"
        if ! printf '%s\n' "$password" | homelab_cli login --email "$email" --password-stdin >/dev/null; then
            warn "homelab-cli login failed; check homelab_cli.email/password and re-run setup" \
                "(unlike the backup server's own 'setup', this client does not create the" \
                "account -- it must already exist; run 'homelab-backup-server setup' on the" \
                "backup server first, or have an admin create it via 'homelab-cli admin user --create')"
            return 1
        fi
    else
        echo "Log in to homelab-api as $email (used once; only the resulting"
        echo "session is kept -- no password is stored at rest):"
        if ! homelab_cli login --email "$email" >/dev/null; then
            warn "homelab-cli login failed; re-run setup to retry" \
                "(this client does not create the account -- it must already exist; run" \
                "'homelab-backup-server setup' on the backup server first, or have an admin" \
                "create it via 'homelab-cli admin user --create')"
            return 1
        fi
    fi

    # Never leave a plaintext password sitting in config.yml once a
    # session has been obtained.
    cfg_set homelab_cli.password ""

    if ! homelab_cli validate >/dev/null 2>&1; then
        warn "homelab-cli session still not valid after login; skipping homelab-api setup"
        return 1
    fi
    return 0
}

# Best-effort UX accelerant: reconciliation happens on its own timer
# regardless (default every 15s, see homelab-backup-server's config.yml),
# but a freshly-installed host still has to wait out at least part of
# that interval before its first backup can run. If the person running
# THIS setup also happens to have their own SSH/sudo access to the backup
# server host (common in a homelab -- same admin installs both sides),
# nudge that timer's service to run right now instead of waiting.
#
# Uses the OPERATOR's own ambient SSH identity/agent/config -- never this
# host's own dedicated backup key (which is restricted to `borg serve`
# and couldn't run this even if it tried). Silently does nothing if that
# access doesn't exist; the poll loop below works unattended either way.
# Set kick_reconcile: false in config.yml to skip attempting this
# entirely (e.g. if an unexpected outbound SSH attempt during setup is
# unwelcome in your environment).
kick_reconcile() {
    local server=$1
    if [ "$(cfg_get kick_reconcile)" = "false" ]; then
        return
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "$server" 'sudo systemctl start homelab-backup-server-reconcile.service' \
        >/dev/null 2>&1; then
        log "nudged homelab-backup-server's reconciliation job to run immediately" \
            "(this only works if you happen to already have your own SSH/sudo" \
            "access to $server -- harmless no-op otherwise, the timer covers it)"
    fi
}

# Onboarding a client no longer involves a human running a manual
# `enroll` command on the backup server at all -- this submits the
# host's pubkey to homelab-api once, then polls waiting for
# homelab-backup-server's own periodic reconciliation job (not any
# action here) to apply it to authorized_keys. Falls back cleanly (warn
# and continue, retried on next `setup` run) if homelab_cli.disabled is
# true or the homelab-api login can't be established -- an admin
# can always fall back to backup_server: hardcoded in config.yml and
# skip this entirely.
setup_control_plane() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    local identifier
    identifier=$(cfg_get hostname)
    if [ -z "$identifier" ]; then
        if [ ! -r /etc/machine-id ]; then
            die "/etc/machine-id not readable and no hostname override set; cannot derive host identifier"
        fi
        identifier="$(hostname)-$(cat /etc/machine-id)"
    fi
    log "host identifier: $identifier"

    if [ ! -f "$SSH_KEY" ]; then
        log "generating dedicated SSH key at $SSH_KEY"
        ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "homelab-backup-client-$identifier" >/dev/null
    fi
    chmod 600 "$SSH_KEY"
    chmod 644 "$SSH_KEY.pub"

    if [ "$(cfg_get homelab_cli.disabled)" = "true" ]; then
        log "homelab_cli.disabled is true; skipping homelab-api enrollment (set backup_server: manually)"
        return
    fi

    if ! ensure_homelab_cli_session; then
        warn "not logged in to homelab-api; skipping enrollment for now"
        warn "re-run 'homelab-backup-client setup' later to retry, or set backup_server: manually"
        return
    fi

    log "submitting enrollment for $identifier"
    if ! homelab_cli backup enroll --identifier "$identifier" --hostname "$(hostname)" --pubkey-file "$SSH_KEY.pub" >/dev/null; then
        warn "enrollment submission failed; re-run 'homelab-backup-client setup' later to retry"
        return
    fi

    local ssh_user server location
    ssh_user=$(cfg_get ssh_backup_server_username); ssh_user=${ssh_user:-borgbackup}
    server=$(cfg_get backup_server)
    if [ -z "$server" ]; then
        local server_info
        server_info=$(homelab_cli backup server-info 2>/dev/null) || true
        if [ -n "$server_info" ]; then
            server=$(printf '%s' "$server_info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hostname",""))' 2>/dev/null) || true
        fi
    fi
    if [ -z "$server" ]; then
        warn "could not determine backup server address to probe; the reconciliation job will still apply your enrollment -- check connectivity manually once a server is known"
        return
    fi

    kick_reconcile "$server"

    echo
    log "no admin action needed -- waiting for homelab-backup-server's own"
    log "reconciliation job (runs on its own timer, every few seconds by"
    log "default) to apply this enrollment to its authorized_keys"
    echo

    local retry_choice probe
    while true; do
        probe=$(echo | ssh -i "$SSH_KEY" "${SSH_PROBE_OPTS[@]}" "${ssh_user}@${server}" 2>&1) || true
        if ! echo "$probe" | grep -qi "Permission denied"; then
            log "passwordless access confirmed"
            return
        fi

        if ! read -r -p "Still waiting on reconciliation; press Enter to re-check (or 's' to skip for now): " retry_choice; then
            warn "no input available; skipping SSH trust check for now"
            return
        fi
        case "$retry_choice" in
            s|S)
                warn "skipping SSH trust check; re-run 'homelab-backup-client setup' later to retry"
                return
                ;;
            *)
                ;;
        esac
    done
}

# Writes stdin's content to $1 atomically (temp file in the same
# directory, then `mv -f` -- a same-filesystem rename, so systemd or a
# just-fired unit can never observe a half-written unit file mid-sed).
# Returns 0 (changed) if the content differs from what's already there
# (or the file didn't exist yet), 1 (unchanged) if it's byte-identical --
# callers use this to skip re-triggering systemd entirely when a setup
# re-run didn't actually change anything, see install_script_and_units().
install_unit_file() {
    local dest=$1 tmp
    tmp=$(mktemp "${dest}.XXXXXX") || die "could not create temp file for $dest"
    cat > "$tmp" || { rm -f "$tmp"; die "could not write $dest"; }
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" || { rm -f "$tmp"; die "could not chmod $tmp"; }
    mv -f "$tmp" "$dest" || die "could not install $dest"
    return 0
}

# Every generated timer here has Persistent=true (a missed run should
# fire on next boot/reload rather than being silently skipped), which
# means restarting/re-enabling the timer for any reason -- even a no-op
# `setup` re-run -- can make systemd immediately fire an unscheduled
# "catch-up" run. install_script_and_units()/install_check_unit() below
# only pay that cost when a unit's content actually changed; when one
# does, log this note so a future "why did a backup run right now" isn't
# a fresh investigation every time.
warn_persistent_catchup() {
    log "note: $1 is Persistent=true -- since its schedule changed, systemd" \
        "may run it once immediately (a one-off catch-up) before settling" \
        "back into its normal interval"
}

install_script_and_units() {
    if [ "$SKIP_BINARY" -eq 1 ]; then
        log "skipping binary install (--skip-binary): using $BIN_DEST"
    else
        log "installing $BIN_DEST"
        install -o root -g root -m 700 "$REPO_ROOT/bin/homelab-backup-client" "$BIN_DEST"
    fi

    local sched_mode
    sched_mode=$(cfg_get schedule.mode); sched_mode=${sched_mode:-daily}

    if [ "$sched_mode" = "continuous" ]; then
        local changed=0
        if install_unit_file "$UNIT_DIR/homelab-backup-client.service" \
            < <(sed "s|__BIN_PATH__|$BIN_DEST|" "$REPO_ROOT/systemd/homelab-backup-client-continuous.service.tmpl"); then
            changed=1
        fi
        if [ -f "$UNIT_DIR/homelab-backup-client.timer" ]; then
            changed=1  # switching away from a timer-based schedule
        fi
        if [ "$changed" -eq 1 ]; then
            log "installing continuous service (no timer)"
            systemctl disable --now homelab-backup-client.timer >/dev/null 2>&1 || true
            rm -f "$UNIT_DIR/homelab-backup-client.timer"
            systemctl daemon-reload
            systemctl enable --now homelab-backup-client.service
        else
            log "continuous service unit unchanged, leaving systemd state as-is"
        fi
    else
        local on_calendar jitter_seconds
        jitter_seconds=$(cfg_get schedule.jitter_seconds); jitter_seconds=${jitter_seconds:-1800}

        case "$sched_mode" in
            hourly)
                on_calendar="hourly"
                ;;
            daily|weekly|monthly)
                on_calendar=$(build_randomized_calendar "$sched_mode")
                ;;
            calendar)
                on_calendar=$(cfg_get schedule.calendar)
                [ -n "$on_calendar" ] || die "schedule.calendar is empty but schedule.mode is calendar"
                ;;
            *) die "unknown schedule.mode: $sched_mode" ;;
        esac

        local service_changed=0 timer_changed=0
        if install_unit_file "$UNIT_DIR/homelab-backup-client.service" \
            < <(sed "s|__BIN_PATH__|$BIN_DEST|" "$REPO_ROOT/systemd/homelab-backup-client.service.tmpl"); then
            service_changed=1
        fi
        if install_unit_file "$UNIT_DIR/homelab-backup-client.timer" \
            < <(sed -e "s|__ON_CALENDAR__|$on_calendar|" -e "s|__JITTER_SECONDS__|$jitter_seconds|" \
                "$REPO_ROOT/systemd/homelab-backup-client.timer.tmpl"); then
            timer_changed=1
        fi

        if [ "$service_changed" -eq 1 ] || [ "$timer_changed" -eq 1 ]; then
            log "installing oneshot service + timer (OnCalendar=$on_calendar, RandomizedDelaySec=$jitter_seconds)"
            systemctl disable --now homelab-backup-client.service >/dev/null 2>&1 || true
            systemctl daemon-reload
            systemctl enable --now homelab-backup-client.timer
            if [ "$timer_changed" -eq 1 ]; then
                warn_persistent_catchup "homelab-backup-client.timer"
            fi
        else
            log "oneshot service + timer unchanged (OnCalendar=$on_calendar), leaving systemd state as-is"
        fi
    fi

    install_check_unit
}

# Installs (or removes, if integrity_check.mode is unset/never) the
# separate borg-check timer. Kept independent of the backup schedule
# above since a full repo check is slower and shouldn't block backups.
install_check_unit() {
    local check_mode
    check_mode=$(cfg_get integrity_check.mode); check_mode=${check_mode:-monthly}

    if [ "$check_mode" = "never" ]; then
        if [ -f "$UNIT_DIR/homelab-backup-client-check.timer" ]; then
            log "integrity_check.mode is never, removing any existing check timer"
            systemctl disable --now homelab-backup-client-check.timer >/dev/null 2>&1 || true
            rm -f "$UNIT_DIR/homelab-backup-client-check.service" "$UNIT_DIR/homelab-backup-client-check.timer"
            systemctl daemon-reload
        fi
        return
    fi

    if [ "$check_mode" != "weekly" ] && [ "$check_mode" != "monthly" ]; then
        warn "unknown integrity_check.mode '$check_mode', defaulting to monthly"
        check_mode="monthly"
    fi

    local service_changed=0 timer_changed=0
    if install_unit_file "$UNIT_DIR/homelab-backup-client-check.service" \
        < <(sed "s|__BIN_PATH__|$BIN_DEST|" "$REPO_ROOT/systemd/homelab-backup-client-check.service.tmpl"); then
        service_changed=1
    fi
    if install_unit_file "$UNIT_DIR/homelab-backup-client-check.timer" \
        < <(sed "s|__ON_CALENDAR__|$check_mode|" "$REPO_ROOT/systemd/homelab-backup-client-check.timer.tmpl"); then
        timer_changed=1
    fi

    if [ "$service_changed" -eq 1 ] || [ "$timer_changed" -eq 1 ]; then
        log "installing integrity check oneshot service + timer (OnCalendar=$check_mode)"
        systemctl daemon-reload
        systemctl enable --now homelab-backup-client-check.timer
        if [ "$timer_changed" -eq 1 ]; then
            warn_persistent_catchup "homelab-backup-client-check.timer"
        fi
    else
        log "integrity check service + timer unchanged (OnCalendar=$check_mode), leaving systemd state as-is"
    fi
}

# Picks (once, persisted) a random hour from schedule.window_hours and a
# random minute, so a fleet of hosts on the same daily/weekly/monthly
# schedule doesn't all hit the backup server at exactly midnight. Prints
# a systemd OnCalendar= expression for the given mode.
build_randomized_calendar() {
    local mode=$1
    local start_hour start_minute
    start_hour=$(cfg_get schedule.start_hour)
    start_minute=$(cfg_get schedule.start_minute)

    if [ -z "$start_hour" ] || [ -z "$start_minute" ]; then
        local window_hours=()
        while IFS= read -r h; do
            [ -n "$h" ] && window_hours+=("$h")
        done < <(cfg_get_list schedule.window_hours)
        if [ "${#window_hours[@]}" -eq 0 ]; then
            window_hours=(23 0 1 2)
        fi
        start_hour=${window_hours[$((RANDOM % ${#window_hours[@]}))]}
        start_minute=$((RANDOM % 60))
        cfg_set schedule.start_hour "$start_hour"
        cfg_set schedule.start_minute "$start_minute"
        log "picked randomized start time: $(printf '%02d:%02d' "$start_hour" "$start_minute") (persisted in $CONFIG)" >&2
    fi

    local hh mm
    hh=$(printf '%02d' "$start_hour")
    mm=$(printf '%02d' "$start_minute")

    case "$mode" in
        daily)   echo "*-*-* ${hh}:${mm}:00" ;;
        weekly)  echo "Mon *-*-* ${hh}:${mm}:00" ;;
        monthly) echo "*-*-01 ${hh}:${mm}:00" ;;
    esac
}

print_summary() {
    echo
    log "install complete"
    log "config:      $CONFIG"
    log "script:      $BIN_DEST"
    log "mode:        $(cfg_get mode)"
    log "schedule:    $(cfg_get schedule.mode)"
    log "homelab-api:  $([ "$(cfg_get homelab_cli.disabled)" = "true" ] && echo "disabled" || echo "$(cfg_get homelab_cli.api_url)")"
    echo
    log "check status with: systemctl status homelab-backup-client.service homelab-backup-client.timer 2>/dev/null"
    log "check logs with:   journalctl -t homelab-backup-client -f"
    log "dry-run a manual test with: $BIN_DEST backup --dry-run --once"

    if [ -n "$GENERATED_PASSPHRASE" ]; then
        echo
        echo "########################################################################"
        echo "# ESCROW THIS NOW — none of the following is backed up anywhere yet.  #"
        echo "########################################################################"
        echo
        echo "  encryption passphrase: $GENERATED_PASSPHRASE"
        echo
        echo "  This passphrase is also saved (mode 600) in:"
        echo "    $CONFIG"
        echo
        echo "  A key export will additionally appear under $KEY_ESCROW_DIR"
        echo "  after the first backup run (see homelab-backup-client backup --once)."
        echo
        echo "  Copy the passphrase and the exported key files to a password"
        echo "  manager / secrets vault AND an offline/paper copy before this host"
        echo "  becomes the disaster this tool exists to recover from."
        echo "########################################################################"
    fi
}

main() {
    require_root
    install_packages
    setup_config_skeleton
    prompt_config_values
    setup_control_plane
    install_script_and_units
    print_summary
}

main "$@"
