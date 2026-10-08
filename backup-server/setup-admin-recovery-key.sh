#!/usr/bin/env bash
# Generates a single "admin recovery" SSH keypair for restoring ANY
# host's repo on this borgbackup_server, without depending on that
# host's own (possibly destroyed) dedicated key.
#
# Run this ONCE, directly on borgbackup_server (not on a client host).
# The private half is printed at the end — copy it to a password
# manager/secrets vault AND an offline/paper copy immediately. Treat it
# like root's SSH key: it can read (list/extract) every repo under
# backup_location, though it can only ever run `borg serve` (never an
# interactive shell) via the forced-command restriction below.
#
# Usage: setup-admin-recovery-key.sh [--backup-user USER] [--backup-location DIR]
set -euo pipefail

BACKUP_USER=borgbackup
BACKUP_LOCATION=/var/borgbackup
KEY_DIR=/root/homelab-backup-client-admin-recovery
KEY_PATH="$KEY_DIR/id_ed25519"

while [ $# -gt 0 ]; do
    case "$1" in
        --backup-user)
            BACKUP_USER="$2"; shift 2 ;;
        --backup-location)
            BACKUP_LOCATION="$2"; shift 2 ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1 ;;
    esac
done

log()  { echo "[setup-admin-recovery-key] $*"; }
die()  { echo "[setup-admin-recovery-key] ERROR: $*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    die "must be run as root"
fi

user_home=$(getent passwd "$BACKUP_USER" | cut -d: -f6)
[ -n "$user_home" ] || die "backup user '$BACKUP_USER' not found on this host"

if [ -f "$KEY_PATH" ]; then
    log "admin recovery key already exists at $KEY_PATH, not regenerating"
else
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"
    log "generating admin recovery keypair at $KEY_PATH"
    ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -C "homelab-backup-client-admin-recovery" >/dev/null
    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"
fi

pubkey=$(cat "$KEY_PATH.pub")
# Scoped to the whole backup tree (not one host's subdirectory, unlike a
# per-host key) but still a forced command, never an interactive shell.
line="command=\"borg serve --restrict-to-repository ${BACKUP_LOCATION}\",restrict ${pubkey}"

mkdir -p "$user_home/.ssh"
touch "$user_home/.ssh/authorized_keys"
if grep -qF "$pubkey" "$user_home/.ssh/authorized_keys"; then
    log "admin recovery key already present in $user_home/.ssh/authorized_keys"
else
    echo "$line" >> "$user_home/.ssh/authorized_keys"
    log "installed admin recovery key in $user_home/.ssh/authorized_keys"
fi
chmod 700 "$user_home/.ssh"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$BACKUP_USER":"$BACKUP_USER" "$user_home/.ssh"

echo
echo "########################################################################"
echo "# ESCROW THIS NOW — this private key is not backed up anywhere else.  #"
echo "########################################################################"
echo
echo "  private key: $KEY_PATH"
echo
cat "$KEY_PATH"
echo
echo "  Copy this key to a password manager/secrets vault AND an offline/"
echo "  paper copy. It is the fallback path to restore ANY host's repo on"
echo "  this server when that host's own dedicated key is gone. Use it with:"
echo
echo "    homelab-backup-client list-archives --host <identifier> --server $(hostname) \\"
echo "        --ssh-user $BACKUP_USER --location $BACKUP_LOCATION --ssh-key <path-to-this-key>"
echo "########################################################################"
