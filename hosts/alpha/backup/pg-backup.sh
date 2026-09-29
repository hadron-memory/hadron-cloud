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
#   backup completes before upload; local pruning happens only after a
#   successful upload, so an upload failure retains local dumps and makes
#   the systemd unit report failure (visible in `journalctl -u pg-backup.service`).
set -euo pipefail

BACKUP_DIR=/root/backup
DATABASES=(hadron)
RETENTION_DAYS=7
OFFSITE_RETENTION_DAYS=90
HOST=alpha
REMOTE="hetzner:hadron-internal/${HOST}"
TS=$(date -u +%Y-%m-%d-%H%M)

mkdir -p "$BACKUP_DIR"

staged_files=()
final_files=()
cleanup_staging() {
  for staged in "${staged_files[@]}"; do
    rm -f -- "$staged"
  done
}
trap cleanup_staging EXIT
trap 'exit 1' HUP INT TERM

for db in "${DATABASES[@]}"; do
  out="$BACKUP_DIR/${db}-${HOST}-${TS}.dump"
  if [[ -e "$out" ]]; then
    echo "refusing to overwrite existing backup: $out" >&2
    exit 1
  fi
  staged=$(mktemp "$BACKUP_DIR/.${db}-${HOST}-${TS}.dump.partial.XXXXXX")
  staged_files+=("$staged")
  final_files+=("$out")
  sudo -u postgres pg_dump -Fc -d "$db" > "$staged"
  # Verify the dump has a readable TOC before trusting it. Input via
  # redirect: the root shell opens the file (postgres can't read /root),
  # and no pipe means no SIGPIPE when pg_restore stops after the TOC.
  sudo -u postgres pg_restore -l < "$staged" > /dev/null
done

globals_out="$BACKUP_DIR/globals-${HOST}-${TS}.sql"
if [[ -e "$globals_out" ]]; then
  echo "refusing to overwrite existing backup: $globals_out" >&2
  exit 1
fi
staged=$(mktemp "$BACKUP_DIR/.globals-${HOST}-${TS}.sql.partial.XXXXXX")
staged_files+=("$staged")
final_files+=("$globals_out")
sudo -u postgres pg_dumpall --globals-only > "$staged"

# All producers and the TOC check have succeeded. Hard-link each complete
# file into its final name without replacing an existing backup. Publish
# globals first, so an interruption cannot leave a final dump without its
# matching globals. Each link is atomic on this filesystem; incomplete
# .partial files remain excluded from a later rclone copy.
for ((i=${#staged_files[@]}-1; i>=0; i--)); do
  ln -- "${staged_files[$i]}" "${final_files[$i]}"
  rm -f -- "${staged_files[$i]}"
  echo "ok: ${final_files[$i]} ($(du -h "${final_files[$i]}" | cut -f1))"
done

# --- Offsite upload to Hetzner Object Storage ------------------------------
# Copy (not sync): never deletes remote objects to match the shorter local
# window. rclone skips already-uploaded files by size, so this is also
# self-healing for any run whose upload was previously missed.
rclone copy "$BACKUP_DIR" "$REMOTE/" \
  --include "*-${HOST}-*.dump" --include "globals-${HOST}-*.sql" \
  --transfers 4 --checkers 8
echo "uploaded: $REMOTE/ (this run: ${TS})"

# --- Local retention -------------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 \( -name "*-${HOST}-*.dump" -o -name "globals-${HOST}-*.sql" \) \
  -mmin "+$((RETENTION_DAYS * 1440))" -print -delete | sed 's/^/pruned: /' || true

# --- Offsite retention -----------------------------------------------------
# Same --include filters as the upload: never prune backups of other kinds
# (e.g. a future MongoDB or host-config dump) that may share the alpha/ prefix.
rclone delete "$REMOTE/" --min-age "${OFFSITE_RETENTION_DAYS}d" --rmdirs \
  --include "*-${HOST}-*.dump" --include "globals-${HOST}-*.sql" \
  | sed 's/^/offsite-pruned: /' || true
