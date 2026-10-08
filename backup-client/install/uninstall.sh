#!/usr/bin/env bash
# Stops/disables units and removes installed files. Leaves
# /etc/homelab/backup/client/config.yml (and its SSH key) in place unless
# --purge is passed. Must be run as root.
set -euo pipefail

ETC_DIR=/etc/homelab/backup/client
BIN_DEST=/usr/local/sbin/homelab-backup-client
UNIT_DIR=/etc/systemd/system

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { echo "[uninstall] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "[uninstall] ERROR: must be run as root" >&2
    exit 1
fi

log "stopping and disabling units"
systemctl disable --now homelab-backup-client.service >/dev/null 2>&1 || true
systemctl disable --now homelab-backup-client.timer >/dev/null 2>&1 || true
systemctl disable --now homelab-backup-client-check.service >/dev/null 2>&1 || true
systemctl disable --now homelab-backup-client-check.timer >/dev/null 2>&1 || true
rm -f "$UNIT_DIR/homelab-backup-client.service" "$UNIT_DIR/homelab-backup-client.timer" \
      "$UNIT_DIR/homelab-backup-client-check.service" "$UNIT_DIR/homelab-backup-client-check.timer"
systemctl daemon-reload

# daemon-reload only re-reads unit FILES; it does not clear a unit's
# cached "failed" job state from a run that happened before removal.
systemctl reset-failed homelab-backup-client.service >/dev/null 2>&1 || true
systemctl reset-failed homelab-backup-client.timer >/dev/null 2>&1 || true
systemctl reset-failed homelab-backup-client-check.service >/dev/null 2>&1 || true
systemctl reset-failed homelab-backup-client-check.timer >/dev/null 2>&1 || true

log "removing $BIN_DEST"
rm -f "$BIN_DEST"

if [ "$PURGE" -eq 1 ]; then
    log "purging $ETC_DIR (config, SSH key, homelab-cli session, and all)"
    rm -rf "$ETC_DIR"
else
    log "leaving $ETC_DIR in place (pass --purge to remove config/SSH key too)"
fi

log "uninstall complete"
