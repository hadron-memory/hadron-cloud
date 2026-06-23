#!/usr/bin/env bash
# Hourly Postgres backup on alpha. Installed at /usr/local/sbin/pg-backup.sh,
# run by pg-backup.timer as root.
#
# - pg_dump -Fc per database (custom format, compressed, pg_restore-able)
# - pg_dumpall --globals-only for roles
# - Runs pg_dump as the postgres OS user (peer auth) but redirects in the
#   root shell, because postgres can't write under /root/ (runbook gotcha).
# - Local retention: timer-created dumps older than RETENTION_DAYS deleted.
#   Manual dumps following the same naming pattern age out too.
# - Offsite: uploads dumps + globals to Hetzner Object Storage via rclone,
#   then prunes remote objects older than OFFSITE_RETENTION_DAYS. The local
#   backup completes and is pruned BEFORE upload, so a network/upload failure
#   never endangers the local dump; it only makes the systemd unit report
#   failure (visible in `journalctl -u pg-backup`).
set -euo pipefail

BACKUP_DIR=/root/backup
DATABASES=(hadron)
RETENTION_DAYS=14
OFFSITE_RETENTION_DAYS=90
HOST=alpha
REMOTE="hetzner:hadron-internal/${HOST}"
TS=$(date -u +%Y-%m-%d-%H%M)

mkdir -p "$BACKUP_DIR"

for db in "${DATABASES[@]}"; do
  out="$BACKUP_DIR/${db}-${HOST}-${TS}.dump"
  sudo -u postgres pg_dump -Fc -d "$db" > "$out"
  # Verify the dump has a readable TOC before trusting it. Input via
  # redirect: the root shell opens the file (postgres can't read /root),
  # and no pipe means no SIGPIPE when pg_restore stops after the TOC.
  sudo -u postgres pg_restore -l < "$out" > /dev/null
  echo "ok: $out ($(du -h "$out" | cut -f1))"
done

sudo -u postgres pg_dumpall --globals-only > "$BACKUP_DIR/globals-${HOST}-${TS}.sql"

# --- Local retention -------------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 \( -name "*-${HOST}-*.dump" -o -name "globals-${HOST}-*.sql" \) \
  -mtime "+${RETENTION_DAYS}" -print -delete | sed 's/^/pruned: /' || true

# --- Offsite upload to Hetzner Object Storage ------------------------------
# Copy (not sync): never deletes remote objects to match the shorter local
# window. rclone skips already-uploaded files by size, so this is also
# self-healing for any run whose upload was previously missed.
rclone copy "$BACKUP_DIR" "$REMOTE/" \
  --include "*-${HOST}-*.dump" --include "globals-${HOST}-*.sql" \
  --transfers 4 --checkers 8
echo "uploaded: $REMOTE/ (this run: ${TS})"

# --- Offsite retention -----------------------------------------------------
rclone delete "$REMOTE/" --min-age "${OFFSITE_RETENTION_DAYS}d" --rmdirs \
  | sed 's/^/offsite-pruned: /' || true
