#!/usr/bin/env bash
# Hourly Postgres backup on alpha. Installed at /usr/local/sbin/pg-backup.sh,
# run by pg-backup.timer as root.
#
# - pg_dump -Fc per database (custom format, compressed, pg_restore-able)
# - pg_dumpall --globals-only for roles
# - Runs pg_dump as the postgres OS user (peer auth) but redirects in the
#   root shell, because postgres can't write under /root/ (runbook gotcha).
# - Local retention: timer-created dumps older than RETENTION_HOURS deleted.
#   Manual dumps following the same naming pattern age out too.
# - Offsite (2026-10-28, Holger): uploads dumps + globals to the dedicated
#   bucket baragaun-alpha-backups under hourly/; the first run of each UTC day
#   also copies them (server side) to daily/, and on Sundays to weekly/.
#   Retention is the bucket's lifecycle rules (hourly 3d, daily 30d, weekly
#   90d), so this script never deletes offsite. The local
#   backup completes before upload; local pruning happens only after a
#   successful upload, so an upload failure retains local dumps and makes
#   the systemd unit report failure (visible in `journalctl -u pg-backup.service`).
set -euo pipefail

BACKUP_DIR=${PG_BACKUP_DIR:-/root/backup}
DATABASES=(hadron)
RETENTION_HOURS=12   # 2026-11-07 Holger: local 12 h; off-site tiers are the longer history (was RETENTION_DAYS=2)
HOST=alpha
BUCKET="hetzner:baragaun-alpha-backups"
REMOTE="${BUCKET}/hourly"
TS=$(date -u +%Y-%m-%d-%H%M)
DAY=$(date -u +%Y-%m-%d)

mkdir -p "$BACKUP_DIR"

# --- Local pruning: runs on EVERY exit, not only after a good run -----------
# 2026-10-19 (Holger-authorized after the 2026-10-17 disk-full outage): with
# `set -e`, a failed dump or upload used to exit before the prune ran, so a
# bad hour left every old dump on the disk and the next hours piled on top,
# plus a 0-byte file for each failed dump. Now:
#  - a zero-byte dump/globals file is a failed backup and is always removed;
#  - an AGED file (older than RETENTION_HOURS) is removed only if a file of the
#    SAME NAME and SIZE is verifiably offsite; if the offsite listing fails,
#    nothing aged is deleted (the old rule's safety, kept);
#  - the run's exit status is preserved.
# PG_BACKUP_PRUNE_ONLY=1 skips the dump and upload (ops/test); PG_BACKUP_PRUNE_DRY=1
# only prints what would be removed.
PRUNE_ONLY=${PG_BACKUP_PRUNE_ONLY:-0}
PRUNE_DRY=${PG_BACKUP_PRUNE_DRY:-0}
prune_local() {
  local f name size listing line remote_name remote_size
  while IFS= read -r f; do
    if [ "$PRUNE_DRY" = 1 ]; then echo "would-prune-empty: $f"; else rm -f -- "$f" && echo "pruned-empty: $f"; fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*-${HOST}-*.dump" -o -name "globals-${HOST}-*.sql" \) -size 0)
  if ! listing=$(rclone lsf --files-only --format "sp" --separator ";" "$REMOTE/" \
        --include "*-${HOST}-*.dump" --include "globals-${HOST}-*.sql" 2>/dev/null); then
    echo "prune: offsite listing failed; keeping every aged local file" >&2
    return 0
  fi
  # TRANSITION, remove after 2026-10-31: dumps made before the 2026-10-28 bucket
  # move are offsite only in the old location (a server-side copy to the new
  # bucket fails with NoSuchKey), so they also count as offsite there.
  if [ "$(date -u +%Y%m%d)" -le 20261031 ]; then
    local legacy
    if legacy=$(rclone lsf --files-only --format "sp" --separator ";" "hetzner:hadron-internal/${HOST}/" \
          --include "*-${HOST}-2026-10-2[6-8]-*.dump" --include "globals-${HOST}-2026-10-2[6-8]-*.sql" 2>/dev/null); then
      listing+=$'\n'"$legacy"
    fi
  fi
  declare -A offsite=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    remote_size=${line%%;*}; remote_name=${line#*;}
    offsite["$remote_name"]=$remote_size
  done <<< "$listing"
  while IFS= read -r f; do
    name=$(basename "$f"); size=$(stat -c %s "$f")
    if [ "${offsite[$name]:-x}" = "$size" ]; then
      if [ "$PRUNE_DRY" = 1 ]; then echo "would-prune: $f"; else rm -f -- "$f" && echo "pruned: $f"; fi
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*-${HOST}-*.dump" -o -name "globals-${HOST}-*.sql" \) \
            -size +0 -mmin "+$((RETENTION_HOURS * 60))")
}
trap 'rc=$?; prune_local || true; exit "$rc"' EXIT
[ "$PRUNE_ONLY" = 1 ] && exit 0

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

# --- Offsite upload to Hetzner Object Storage ------------------------------
# Copy (not sync): never deletes remote objects. rclone skips already-uploaded
# files by size, so a missed upload heals on the next run. --max-age 3h: only
# this run's files and a missed hour or two. Wider windows re-upload a backlog
# at ~1.4 MB/s and hold the oneshot unit for hours (2026-10-28), and an old
# local dump whose hourly/ copy expired (3d) must never be re-uploaded.
rclone copy "$BACKUP_DIR" "$REMOTE/" \
  --include "*-${HOST}-*.dump" --include "globals-${HOST}-*.sql" \
  --max-age 3h --transfers 4 --checkers 8
echo "uploaded: $REMOTE/ (this run: ${TS})"

# --- Local retention: done by prune_local (EXIT trap above), also on failure --

# --- Daily / weekly tiers (server-side copies; lifecycle rules expire them) --
# The first run of a UTC day that finds no daily/ copy for that day promotes
# this run's files; on Sundays the same files also go to weekly/.
promote() {
  local tier=$1
  if [ -z "$(rclone lsf "${BUCKET}/${tier}/" --files-only --include "*-${HOST}-${DAY}-*")" ]; then
    for f in "${DATABASES[@]/%/-${HOST}-${TS}.dump}" "globals-${HOST}-${TS}.sql"; do
      rclone copyto "$REMOTE/$f" "${BUCKET}/${tier}/$f"
    done
    echo "promoted: ${tier}/ (${TS})"
  fi
}
promote daily
[ "$(date -u +%u)" = 7 ] && promote weekly
exit 0
