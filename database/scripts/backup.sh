#!/bin/sh
# Nightly pg_dump backup, only run at all if homelab-database/enable_backups
# was answered "true" (postinst installs/removes the cron.d entry that
# calls this script based on that answer -- this script itself has no
# opinion, it just dumps). Never touches WAL/PITR; per-database logical
# dumps only, matching the plan's explicit "opt-in, not a bigger backup
# culture change" scope decision.
set -eu

DEST=/var/backups/homelab-database
RETAIN_DAYS=7

mkdir -p "$DEST"

for db in $(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname != 'postgres'"); do
    sudo -u postgres pg_dump -Fc "$db" > "$DEST/${db}.$(date +%Y%m%d).dump.tmp"
    mv "$DEST/${db}.$(date +%Y%m%d).dump.tmp" "$DEST/${db}.$(date +%Y%m%d).dump"
done

find "$DEST" -name '*.dump' -mtime "+$RETAIN_DAYS" -delete
