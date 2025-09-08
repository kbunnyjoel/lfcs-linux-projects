#!/usr/bin/env bats

bats_load_safe ./fixtures/helpers

setup_file() {
  # Ensure clean outputs/logs between runs so JSON and audit lines are predictable
  rm -rf outputs logs
  mkdir -p outputs logs
}

@test "restore from --artifact (tar.gz) into existing target dir" {
  run_setup_tmp_dirs src dst
  run_setup_tmp_files "$src" "a.txt:hello" "b.txt:world"

  # Make full tar.gz backup and capture JSON
  run bash -lc "/app/src/backup.sh full --source '$src' --dest '$dst' --format tar --compress gz --json 2>/dev/null"
  [ "$status" -eq 0 ]
  artifact="$(echo "$output" | jq -r '.artifact')"
  [ -n "$artifact" ]

  # Prepare target and restore
  target="/tmp/bats-restore-artifact.$$"
  mkdir -p "$target"
  run bash -lc "/app/src/backup.sh restore --artifact '$artifact' --target '$target' --json 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "restore" and .id and .artifact and .target' >/dev/null

  # Assert files and content restored
  run bash -lc "ls -1A '$target' | sort"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.txt"* ]]
  [[ "$output" == *"b.txt"* ]]
  run bash -lc "cat '$target/a.txt'"
  [ "$status" -eq 0 ]
  [[ "$output" == "hello" ]]
  run bash -lc "cat '$target/b.txt'"
  [ "$status" -eq 0 ]
  [[ "$output" == "world" ]]
}

@test "restore from --id resolves artifact in --dest" {
  run_setup_tmp_dirs src dst
  run_setup_tmp_files "$src" "x.txt:one" "y.txt:two"

  run bash -lc "/app/src/backup.sh full --source '$src' --dest '$dst' --format tar --compress gz --label r1 --json 2>/dev/null"
  [ "$status" -eq 0 ]
  bid="$(echo "$output" | jq -r '.id')"
  [ -n "$bid" ]

  target="/tmp/bats-restore-id.$$"
  mkdir -p "$target"
  run bash -lc "/app/src/backup.sh restore --id '$bid' --dest '$dst' --target '$target' --json 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e ".action == \"restore\" and .id == \"$bid\"" >/dev/null

  run bash -lc "ls -1A '$target' | sort"
  [ "$status" -eq 0 ]
  [[ "$output" == *"x.txt"* ]]
  [[ "$output" == *"y.txt"* ]]
}

@test "restore fails when target dir does not exist (clear message, non-zero)" {
  run_setup_tmp_dirs src dst
  run_setup_tmp_files "$src" "a.txt:zzz"

  run bash -lc "/app/src/backup.sh full --source '$src' --dest '$dst' --format tar --compress gz --json 2>/dev/null"
  [ "$status" -eq 0 ]
  artifact="$(echo "$output" | jq -r '.artifact')"

  # Do NOT create target
  target="/tmp/bats-restore-missing.$$"
  run bash -lc "/app/src/backup.sh restore --artifact '$artifact' --target '$target'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist or is not a directory"* ]]
}

@test "restore with --id but missing --dest prints error" {
  run_setup_tmp_dirs src dst
  run_setup_tmp_files "$src" "a.txt:zzz"

  run bash -lc "/app/src/backup.sh full --source '$src' --dest '$dst' --format tar --compress gz --json 2>/dev/null"
  [ "$status" -eq 0 ]
  bid="$(echo "$output" | jq -r '.id')"

  mkdir -p /tmp/bats-restore-ok.$$
  run bash -lc "/app/src/backup.sh restore --id '$bid' --target '/tmp/bats-restore-ok.$$'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dest required when using --id"* ]]
}
# ==== Restore test helpers (idempotent guards) ====
if ! declare -F run_setup_tmp_dirs >/dev/null 2>&1; then
  run_setup_tmp_dirs() {
    # usage: run_setup_tmp_dirs var_src var_dst
    local _src="/tmp/bats-src-$$" _dst="/tmp/bats-dst-$$"
    mkdir -p "$_src" "$_dst"
    eval "$1='$_src'"
    eval "$2='$_dst'"
  }
fi

if ! declare -F run_setup_tmp_files >/dev/null 2>&1; then
  run_setup_tmp_files() {
    # usage: run_setup_tmp_files <dir> "name:content"...
    local dir="$1"; shift
    mkdir -p "$dir"
    local spec name content
    for spec in "$@"; do
      name="${spec%%:*}"
      content="${spec#*:}"
      printf '%s' "$content" > "$dir/$name"
    done
  }
fi
