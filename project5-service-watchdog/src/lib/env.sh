#!/usr/bin/env bash
# env.sh - Environment loader for Project 5
load_env() {
  local env_name="$1"
  local env_file="${ROOT_DIR}/env/${env_name}.env"
  if [[ ! -f "$env_file" ]]; then
    echo "[err] Environment file not found: $env_file" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$env_file"
}
