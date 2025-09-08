#!/usr/bin/env bats

# Rotation / retention policy tests
# These assume the rotate subcommand exists on src/backup.sh
# Interface under test (expected):
#   /app/src/backup.sh rotate --dest <root> [--keep-full N] [--keep-inc N] [--max-age-days D] [--json]
#
# Notes:
# - We use the same helpers fixture used by other test files.
# - Each test operates in a unique tmp directory created via mktemp to avoid cross-test bleed.

bats_load_safe "./fixtures/helpers"

setup_file() {
  export BACKUP="/app/src/backup.sh"
}

teardown() {
  # nothing yet
  true
}

# Utility: list artifacts (.tar.gz and snapshot dirs) under a dest root
list_artifacts() {
  local dest_root="$1"
  find "$dest_root" -mindepth 1 -maxdepth 1 \
    \( -type f -name "*.tar.gz" -o -type f -name "*.tar.zst" -o -type f -name "*.tar" -o -type d \) \
    -printf '%f\n' | sort
}

@test "rotate keeps last 2 FULL backups and prunes older ones" {
  run bash -lc 'tmpd=$(mktemp -d); src="$tmpd/src"; dst="$tmpd/dst"; mkdir -p "$src" "$dst"; \
    echo a >"$src/a.txt"; \
    # create 3 FULL backups with distinct ids
    /app/src/backup.sh full --source "$src" --dest "$dst" --format tar --compress gz --label f1 --json > /dev/null; \
    sleep 1; echo b >>"$src/a.txt"; \
    /app/src/backup.sh full --source "$src" --dest "$dst" --format tar --compress gz --label f2 --json > /dev/null; \
    sleep 1; echo c >>"$src/a.txt"; \
    /app/src/backup.sh full --source "$src" --dest "$dst" --format tar --compress gz --label f3 --json > /dev/null; \
    echo "=== ARTIFACTS BEFORE ==="; ls -l "$dst" | sed -n "1,200p"; \
    echo "=== OUTPUT SUMMARIES BEFORE ==="; find /app/outputs -maxdepth 2 -type f -name summary.json -ls 2>/dev/null || true; \
    # rotate: keep last 2 fulls
    /app/src/backup.sh rotate --dest "$dst" --keep-full 2 --json > /tmp/rotate.json 2>/tmp/rotate.log || true; \
    echo "--- ROTATE LOG ---"; sed -n "1,200p" /tmp/rotate.log || true; \
    echo "--- ROTATE JSON ---"; sed -n "1,200p" /tmp/rotate.json || true; \
    echo "=== ARTIFACTS AFTER ==="; ls -l "$dst" | sed -n "1,200p"; \
    echo "=== OUTPUT SUMMARIES AFTER ==="; find /app/outputs -maxdepth 2 -type f -name summary.json -ls 2>/dev/null || true; \
    cnt=$(ls -1 "$dst" | wc -l); echo "REMAINING_COUNT=$cnt"; test $cnt -eq 2'
  [ "$status" -eq 0 ]
}

@test "rotate prunes by max-age-days (older than 30 days removed)" {
  run bash -lc 'tmpd=$(mktemp -d); src="$tmpd/src"; dst="$tmpd/dst"; mkdir -p "$src" "$dst"; \
    echo a >"$src/a.txt"; \
    fresh_json=$(/app/src/backup.sh full --source "$src" --dest "$dst" --format tar --compress gz --json); \
    fresh=$(echo "$fresh_json" | jq -r .artifact); \
    sleep 1; echo "b" >>"$src/a.txt"; \
    old_json=$(/app/src/backup.sh full --source "$src" --dest "$dst" --format tar --compress gz --json); \
    old=$(echo "$old_json" | jq -r .artifact); \
    touch -d "40 days ago" "$old"; \
    echo "FRESH=$fresh"; echo "OLD=$old"; ls -l "$dst"; \
    /app/src/backup.sh rotate --dest "$dst" --max-age-days 30 --json > /tmp/rotate_age.json 2>/tmp/rotate_age.log || true; \
    echo "--- ROTATE AGE LOG ---"; sed -n "1,200p" /tmp/rotate_age.log || true; \
    echo "--- ROTATE AGE JSON ---"; sed -n "1,200p" /tmp/rotate_age.json || true; \
    echo "AFTER:"; ls -l "$dst"; \
    test -f "$fresh" && test ! -f "$old"'
  [ "$status" -eq 0 ]
}

@test "rotate keeps only last incremental between fulls when --keep-inc=1" {
  run bash -lc 'tmpd=$(mktemp -d); src="$tmpd/src"; dst="$tmpd/dst"; mkdir -p "$src" "$dst"; \
    echo base >"$src/file.txt"; \
    base_json=$(/app/src/backup.sh full --source "$src" --dest "$dst" --format tar --compress gz --label base --json); \
    base_id=$(echo "$base_json" | jq -r .id); echo "BASE_ID=$base_id"; \
    echo v2 >>"$src/file.txt"; \
    inc1_json=$(/app/src/backup.sh inc --source "$src" --dest "$dst" --format tar --compress gz --json); \
    inc1_art=$(echo "$inc1_json" | jq -r .artifact); \
    sleep 1; echo v3 >>"$src/file.txt"; \
    inc2_json=$(/app/src/backup.sh inc --source "$src" --dest "$dst" --format tar --compress gz --json); \
    inc2_art=$(echo "$inc2_json" | jq -r .artifact); \
    echo "INC1=$inc1_art"; echo "INC2=$inc2_art"; ls -l "$dst"; \
    /app/src/backup.sh rotate --dest "$dst" --keep-inc 1 --json > /tmp/rotate_inc.json 2>/tmp/rotate_inc.log || true; \
    echo "--- ROTATE INC LOG ---"; sed -n "1,200p" /tmp/rotate_inc.log || true; \
    echo "--- ROTATE INC JSON ---"; sed -n "1,200p" /tmp/rotate_inc.json || true; \
    echo "AFTER:"; ls -l "$dst"; \
    test -f "$inc2_art" && test ! -f "$inc1_art"'
  [ "$status" -eq 0 ]
}
