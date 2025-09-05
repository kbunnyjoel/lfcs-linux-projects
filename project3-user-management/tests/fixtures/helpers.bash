# tests/fixtures/helpers.bash
#!/usr/bin/env bash

# Fail test if a command is missing
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    return 1
  fi
}

# Simple assertion: check file exists
assert_file_exists() {
  local f="$1"
  [ -f "$f" ] || { echo "Expected file $f not found"; return 1; }
}

# Example: ensure running as root inside container
require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "This test must run as root"; return 1; }
}
