#!/usr/bin/env bash
# Nightly Postgres backup on alpha. Installed at /usr/local/sbin/pg-backup.sh,
# run by pg-backup.timer as root.
#
# - pg_dump -Fc per database (custom format, compressed, pg_restore-able)
# - pg_dumpall --globals-only for roles
# - Runs pg_dump as the postgres OS user (peer auth) but redirects in the
#   root shell, because postgres can't write under /root/ (runbook gotcha).
# - Retention: timer-created dumps older than RETENTION_DAYS are deleted.
#   Manual dumps following the same naming pattern age out too.
set -euo pipefail

BACKUP_DIR=/root/backup
DATABASES=(hadron)
RETENTION_DAYS=14
HOST=alpha
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

find "$BACKUP_DIR" -maxdepth 1 \( -name "*-${HOST}-*.dump" -o -name "globals-${HOST}-*.sql" \) \
  -mtime "+${RETENTION_DAYS}" -print -delete | sed 's/^/pruned: /' || true
