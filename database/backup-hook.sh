#!/bin/sh
# Run by homelab-borg-service-backup-client's homelab_only mode as
# backup-hook.sh <output-dir>. Dumps every database in the cluster --
# not just one hardcoded name -- so any homelab-* package's Postgres
# data gets backed up automatically wherever this package is installed,
# with no separate per-app dump logic needed anywhere else. Runs as the
# postgres OS user via peer auth -- no stored credential, and no
# "role ... does not exist" problem regardless of which OS user invokes
# this script.
set -eu

OUT_DIR="$1"
sudo -u postgres pg_dumpall > "$OUT_DIR/pg_dumpall.sql"
