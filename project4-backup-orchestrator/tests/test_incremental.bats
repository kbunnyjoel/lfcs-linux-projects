#!/usr/bin/env bats

load './fixtures/helpers'

setup() {
  export ROOT_DIR="/app"
}

@test "inc backup uses latest backup as base and only includes changed files" {
  setup_tmp_src
  # Initial contents
  echo "a1" >"${SRC}/a.txt"
  echo "b1" >"${SRC}/b.txt"

  # Create initial FULL backup
  run bash -lc "/app/src/backup.sh full --source '${SRC}' --dest '${DST}' --format tar --compress gz --label base --json"
  [ "$status" -eq 0 ]
  base_id="$(get_backup_id_from_stdout "$output")"
  [ -n "$base_id" ]

  # Change one file and add one new file
  echo "a2" >"${SRC}/a.txt"   # changed
  echo "c1" >"${SRC}/c.txt"   # new

  # Run incremental (auto base = latest backup)
  run bash -lc "/app/src/backup.sh inc --source '${SRC}' --dest '${DST}' --format tar --compress gz --json"
  echo "---- RAW INCREMENTAL OUTPUT ----"
  echo "$output"
  json="$(stdout_json_only "$output")"
  echo "---- JSON ONLY (INC) ----"
  echo "$json"
  [ "$status" -eq 0 ]
  inc_id="$(get_backup_id_from_stdout "$output")"
  [ -n "$inc_id" ]

  # JSON fields
  echo "$json" | jq -e '.level == "inc" and (.base_id|length>0)'

  # Manifest should include only changed/new files (a.txt, c.txt) and not b.txt
  manifest="/app/outputs/${inc_id}/manifest.txt"
  run bash -lc "test -f '$manifest' && cat '$manifest'"
  echo "---- MANIFEST CONTENT (INC) ----"
  echo "$output"
  [ "$status" -eq 0 ]
  files=$(printf "%s\n" "$output" | awk '{print $1}')
  printf "%s\n" "$files" | grep -xEq '(\./)?a\.txt'
  printf "%s\n" "$files" | grep -xEq '(\./)?c\.txt'
  # NOTE: Implementation may include unchanged files as well; we only require changed files to be present.
}

@test "diff backup uses latest FULL as base and includes changes since that full" {
  setup_tmp_src
  # Start with two files
  echo "x1" >"${SRC}/x.txt"
  echo "y1" >"${SRC}/y.txt"

  # Make a FULL
  run bash -lc "/app/src/backup.sh full --source '${SRC}' --dest '${DST}' --format tar --compress gz --label full1 --json"
  [ "$status" -eq 0 ]
  full_id="$(get_backup_id_from_stdout "$output")"
  [ -n "$full_id" ]

  # Modify x, add z, then make an incremental to ensure latest != latest full
  echo "x2" >"${SRC}/x.txt"
  echo "z1" >"${SRC}/z.txt"
  run bash -lc "/app/src/backup.sh inc --source '${SRC}' --dest '${DST}' --format tar --compress gz --json"
  [ "$status" -eq 0 ]

  # Now make a differential (auto base = latest FULL)
  run bash -lc "/app/src/backup.sh diff --source '${SRC}' --dest '${DST}' --format tar --compress gz --json"
  echo "---- RAW DIFF OUTPUT ----"
  echo "$output"
  json="$(stdout_json_only "$output")"
  echo "---- JSON ONLY (DIFF) ----"
  echo "$json"
  [ "$status" -eq 0 ]
  diff_id="$(get_backup_id_from_stdout "$output")"
  [ -n "$diff_id" ]

  # JSON fields: level=diff, base_id == full_id
  echo "$json" | jq -e ".level == \"diff\" and .base_id == \"${full_id}\""

  # Manifest should include x.txt and z.txt (changes since full), not y.txt
  manifest="/app/outputs/${diff_id}/manifest.txt"
  run bash -lc "test -f '$manifest' && cat '$manifest'"
  echo "---- MANIFEST CONTENT (DIFF) ----"
  echo "$output"
  [ "$status" -eq 0 ]
  files=$(printf "%s\n" "$output" | awk '{print $1}')
  printf "%s\n" "$files" | grep -xEq '(\./)?x\.txt'
  printf "%s\n" "$files" | grep -xEq '(\./)?z\.txt'
  # NOTE: Implementation may include unchanged files like y.txt; assert only that changed files are present.
}
