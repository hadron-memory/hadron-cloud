#!/usr/bin/env bash
# Safe producer-failure checks for pg-backup.sh; uses only temporary files and stubs.
set -euo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -u && $2 == postgres ]] || exit 1
shift 2
exec "$@"
EOF
cat > "$work/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
printf 'partial dump\n'
[[ ${FAIL_STAGE:-} != dump ]] || exit 23
printf 'complete dump\n'
EOF
cat > "$work/bin/pg_restore" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
[[ ${FAIL_STAGE:-} != verify ]] || exit 24
EOF
cat > "$work/bin/pg_dumpall" <<'EOF'
#!/usr/bin/env bash
printf 'partial globals\n'
[[ ${FAIL_STAGE:-} != globals ]] || exit 25
printf 'complete globals\n'
EOF
cat > "$work/bin/rclone" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == copy ]]; then
  # Model the two final-name include rules in pg-backup.sh. The test asserts
  # that an interrupted run's .partial file is never eligible for upload.
  find "$2" -maxdepth 1 -type f \( -name '*-alpha-*.dump' -o -name 'globals-alpha-*.sql' \) \
    -print | sort > "$UPLOAD_MANIFEST"
  [[ ${FAIL_UPLOAD:-0} != 1 ]] || exit 26
fi
EOF
chmod +x "$work/bin/"*

prepare_case() {
  case_dir="$work/$1"
  mkdir -p "$case_dir/backup"
  sed "s@^BACKUP_DIR=/root/backup\$@BACKUP_DIR=\"$case_dir/backup\"@" \
    "$source_dir/pg-backup.sh" > "$case_dir/pg-backup.sh"
  : > "$case_dir/upload-manifest"
}

run_backup() {
  PATH="$work/bin:$PATH" UPLOAD_MANIFEST="$case_dir/upload-manifest" \
    FAIL_STAGE="${FAIL_STAGE:-}" FAIL_UPLOAD="${FAIL_UPLOAD:-0}" \
    bash "$case_dir/pg-backup.sh" > "$case_dir/run.log" 2>&1
}

assert_no_backup_files() {
  [[ -z $(find "$case_dir/backup" -maxdepth 1 -type f -print) ]] || {
    echo "unexpected file after $1 failure:" >&2
    find "$case_dir/backup" -maxdepth 1 -type f -print >&2
    exit 1
  }
  [[ ! -s "$case_dir/upload-manifest" ]] || {
    echo "rclone saw a file after $1 failure" >&2
    exit 1
  }
}

for failure in dump verify globals; do
  prepare_case "$failure"
  if FAIL_STAGE="$failure" run_backup; then
    echo "expected $failure to fail" >&2
    exit 1
  fi
  assert_no_backup_files "$failure"
done

prepare_case interrupted
printf 'interrupted partial\n' > "$case_dir/backup/.hadron-alpha-old.dump.partial.dead"
run_backup
[[ $(find "$case_dir/backup" -maxdepth 1 -name 'hadron-alpha-*.dump' | wc -l | tr -d ' ') == 1 ]]
[[ $(find "$case_dir/backup" -maxdepth 1 -name 'globals-alpha-*.sql' | wc -l | tr -d ' ') == 1 ]]
[[ $(wc -l < "$case_dir/upload-manifest" | tr -d ' ') == 2 ]]
! grep -q partial "$case_dir/upload-manifest"
[[ -f "$case_dir/backup/.hadron-alpha-old.dump.partial.dead" ]]

# A same-minute invocation must not truncate a completed backup.
dump=$(find "$case_dir/backup" -maxdepth 1 -name 'hadron-alpha-*.dump' -print -quit)
before=$(shasum -a 256 "$dump")
if run_backup; then
  echo 'expected existing final name to refuse a second run' >&2
  exit 1
fi
[[ $(shasum -a 256 "$dump") == "$before" ]]

prepare_case upload
if FAIL_UPLOAD=1 run_backup; then
  echo 'expected upload failure' >&2
  exit 1
fi
[[ $(find "$case_dir/backup" -maxdepth 1 -name 'hadron-alpha-*.dump' | wc -l | tr -d ' ') == 1 ]]
[[ $(find "$case_dir/backup" -maxdepth 1 -name 'globals-alpha-*.sql' | wc -l | tr -d ' ') == 1 ]]
[[ -z $(find "$case_dir/backup" -maxdepth 1 -name '*.partial.*' -print) ]]

echo 'pg-backup staging tests passed'
