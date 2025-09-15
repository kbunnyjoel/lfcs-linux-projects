#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; }

# Sprint 1: basic checks
@test "basic: healthy path returns 0 and OK text" {
  run bash -lc "./src/fs.sh check --path /tmp"
  [ "$status" -eq 0 ]
  [[ "$output" =~ OK: ]]
}

@test "basic: unhealthy path returns 1 and FAIL text" {
  run bash -lc "./src/fs.sh check --path /does/not/exist"
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL: ]]
}

@test "basic: --json emits pure JSON on stdout" {
  run bash -lc "./src/fs.sh check --path /tmp --json | tail -n 1 | jq -r .overall"
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

# Sprint 2: multi-path & env defaults
@test "multi: all healthy -> overall up, exit 0" {
  run bash -lc "./src/fs.sh check --path /tmp --path /var/tmp --json"
  [ "$status" -eq 0 ]
  summary="$(echo "$output" | tail -n 1)"
  [ "$(echo "$summary" | jq -r .overall)" = "up" ]
}

@test "multi: one unhealthy -> degraded, exit 1" {
  run bash -lc "./src/fs.sh check --path /tmp --path /does/not/exist --json"
  echo "DBG5 status=$status"
  echo "DBG5 output=$output"
  [ "$status" -eq 1 ]
  summary="$(echo "$output" | tail -n 1)"
  echo "DBG5 summary=$summary"
  [ "$(echo "$summary" | jq -r .overall)" = "degraded" ]
}

@test "multi: all unhealthy -> down, exit 1" {
  run bash -lc "./src/fs.sh check --path /does/not/exist --path /also/not --json"
  [ "$status" -eq 1 ]
  summary="$(echo "$output" | tail -n 1)"
  [ "$(echo "$summary" | jq -r .overall)" = "down" ]
}

@test "multi: FS_PATHS env variable provides default paths" {
  run bash -lc 'FS_PATHS="/tmp /does/not/exist" ./src/fs.sh check --json'
  echo "DBG7 status=$status"
  echo "DBG7 output=$output"
  [ "$status" -eq 1 ]
  summary="$(echo "$output" | tail -n 1)"
  echo "DBG7 summary=$summary"
  [ "$(echo "$summary" | jq -r .overall)" = "degraded" ]
}

# Sprint 3: capacity/inode thresholds
@test "thresholds: free space threshold healthy when set to 0" {
  run bash -lc "./src/fs.sh check --path /tmp --json --min-free-pct 0 | tail -n 1 | jq -r .overall"
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "thresholds: free space violation when set to 100 -> down" {
  run bash -lc "./src/fs.sh check --path /tmp --json --min-free-pct 100 >/dev/null"
  [ "$status" -eq 1 ]
  run bash -lc "./src/fs.sh check --path /tmp --json --min-free-pct 100 | tail -n 1 | jq -r .overall"
  [ "$output" = "down" ]
}

@test "thresholds: inode violation when set to 100 -> down" {
  run bash -lc "./src/fs.sh check --path /tmp --json --min-inodes-pct 100 >/dev/null"
  [ "$status" -eq 1 ]
  run bash -lc "./src/fs.sh check --path /tmp --json --min-inodes-pct 100 | tail -n 1 | jq -r .overall"
  [ "$output" = "down" ]
}

@test "thresholds: reasons array is present" {
  run bash -lc "./src/fs.sh check --path /tmp --json --min-free-pct 100 | head -n 1 | jq -r '.reasons | type'"
  [ "$output" = "array" ]
}

# Sprint 4: mount integrity & fstab validation
@test "mount: per-path mount fields are present" {
  run bash -lc "./src/fs.sh check --path /tmp --json | head -n 1 | jq -r '[.mountpoint, .fs_type, (.present_opts | type)] | @tsv'"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r mp fstype optstype <<<"$output"
  [ -n "$mp" ]
  [ -n "$fstype" ]
  [ "$optstype" = "array" ]
}

@test "fstab: expected options produce compliance fields" {
  run bash -lc 'FS_EXPECT_OPTS="/tmp:nodev,nosuid,noexec" ./src/fs.sh check --path /tmp --json --fstab tests/fixtures/fstab.sample | head -n 1 | jq -r "[.opts_ok, (.missing_opts | type)] | @tsv"'
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r ok missingtype <<<"$output"
  [[ "$ok" = "true" || "$ok" = "false" ]]
  [ "$missingtype" = "array" ]
}

@test "fstab: non-compliance degrades overall" {
  run bash -lc 'FS_EXPECT_OPTS="/tmp:nodev,nosuid,noexec" ./src/fs.sh check --path /tmp --json --fstab tests/fixtures/fstab.sample | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

# Sprint 5: LVM & RAID awareness
@test "lvm: per-path LVM fields are present" {
  run bash -lc 'bash tests/helpers/lvs > /tmp/lvs.mock && FS_LVS_SAMPLE=/tmp/lvs.mock ./src/fs.sh check --path /tmp --json | head -n 1 | jq -r '\''[(.lvm_present // "unknown"), (.lvm_ok // "unknown")] | @tsv'\''' 
  line="${output//$'\r'/}"
  present="$(printf '%s' "$line" | awk '{print $1}')"
  ok="$(printf '%s' "$line" | awk '{print $2}')"
  [[ "$present" =~ ^(true|false|unknown)$ ]]
  [[ "$ok" =~ ^(true|false|unknown)$ ]]
}

@test "raid: per-path RAID fields are present" {
  run bash -lc 'FS_MDSTAT=tests/fixtures/mdstat.sample ./src/fs.sh check --path /tmp --json | head -n 1 | jq -r '\''[(.raid_present // "unknown"), (.raid_ok // "unknown")] | @tsv'\''' 
  line="${output//$'\r'/}"
  present="$(printf '%s' "$line" | awk '{print $1}')"
  ok="$(printf '%s' "$line" | awk '{print $2}')"
  [[ "$present" =~ ^(true|false|unknown)$ ]]
  [[ "$ok" =~ ^(true|false|unknown)$ ]]
}

@test "raid: degraded array influences overall" {
  run bash -lc 'FS_MDSTAT=tests/fixtures/mdstat.sample ./src/fs.sh check --path /tmp --json | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "lvm: inactive LV influences overall" {
  run bash -lc 'bash tests/helpers/lvs > /tmp/lvs.mock && FS_LVS_SAMPLE=/tmp/lvs.mock ./src/fs.sh check --path /tmp --json | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

# Sprint 6: Snapshot & Backup Validation

@test "snapshots: happy path fresh" {
  run bash -lc '
    export FS_ENV_FILE=/dev/null; \
    export FS_DEBUG=; \
    export FS_FSTAB= FS_EXPECT_OPTS= FS_MIN_FREE_PCT= FS_MIN_INODES_PCT=; \
    SNAPDIR=$(mktemp -d /tmp/snaps.XXXXXX) && \
    touch "$SNAPDIR/backup-$(date -u +%Y%m%d)" && \
    ./src/fs.sh check --path "$SNAPDIR" --json \
      --snapshot-dir "$SNAPDIR" --pattern "^backup-([0-9]{8})$" --max-age 86400 \
      2>/dev/null | awk "NF{print; exit}" | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "snapshots: mount required -> mounted true" {
  run bash -lc '
    export FS_ENV_FILE=/dev/null; \
    export FS_DEBUG=; \
    export FS_FSTAB= FS_EXPECT_OPTS= FS_MIN_FREE_PCT= FS_MIN_INODES_PCT=; \
    SNAPDIR=$(mktemp -d /tmp/snaps.XXXXXX) && \
    touch "$SNAPDIR/any" && \
    ./src/fs.sh check --path "$SNAPDIR" --json \
      --snapshot-dir "$SNAPDIR" --mount-required \
      2>/dev/null | awk "NF{print; exit}" | jq -r .mounted'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "snapshots: none found -> non-up" {
  run bash -lc "\
    SNAPDIR=$(mktemp -d /tmp/snaps.XXXXXX) && \
    ./src/fs.sh check --path \"$SNAPDIR\" --json \
      --snapshot-dir \"$SNAPDIR\" --pattern '^backup-(\\d{8})$' | \
      tail -n 1 | jq -r .overall"
  [[ "$output" != "up" ]]
}

@test "snapshots: below min count -> exit 1" {
  run bash -lc "\
    SNAPDIR=$(mktemp -d /tmp/snaps.XXXXXX) && \
    touch \"$SNAPDIR/backup-$(date -u +%Y%m%d)\" && \
    ./src/fs.sh check --path \"$SNAPDIR\" --json \
      --snapshot-dir \"$SNAPDIR\" --pattern '^backup-(\\d{8})$' --count-min 2 >/dev/null"
  [ "$status" -eq 1 ]
}

@test "snapshots: stale by max-age -> non-up" {
  run bash -lc "\
    SNAPDIR=$(mktemp -d /tmp/snaps.XXXXXX) && \
    touch -d \"2020-01-01 00:00:00Z\" \"$SNAPDIR/backup-20200101\" && \
    ./src/fs.sh check --path \"$SNAPDIR\" --json \
      --snapshot-dir \"$SNAPDIR\" --pattern '^backup-(\\d{8})$' --max-age 86400 | \
      tail -n 1 | jq -r .overall"
  [[ "$output" != "up" ]]
}

@test "snapshots: require-today without today -> non-up" {
  run bash -lc "\
    SNAPDIR=$(mktemp -d /tmp/snaps.XXXXXX) && \
    touch \"$SNAPDIR/backup-$(date -u -d yesterday +%Y%m%d)\" && \
    ./src/fs.sh check --path \"$SNAPDIR\" --json \
      --snapshot-dir \"$SNAPDIR\" --pattern '^backup-(\\d{8})$' --require-today | \
      tail -n 1 | jq -r .overall"
  [[ "$output" != "up" ]]
}
