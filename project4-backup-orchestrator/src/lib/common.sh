

#!/usr/bin/env bash
# Common helpers for Project 4: Backup & Restore Orchestrator
# shellcheck shell=bash

set -euo pipefail

# --- Paths ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# --- Messaging helpers ---
color_ok='\033[1;32m'
color_warn='\033[1;33m'
color_err='\033[1;31m'
color_off='\033[0m'

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() {
  local msg=${1:-"error"}
  printf "${color_err}[err]${color_off} %s\n" "$msg" >&2
  exit 1
}

ok() {
  local msg=${1:-"ok"}
  printf "${color_ok}[ok]${color_off} %s\n" "$msg"
}

warn() {
  local msg=${1:-"warn"}
  printf "${color_warn}[warn]${color_off} %s\n" "$msg" >&2
}

# --- Filesystem helpers ---
ensure_dir() {
  local d=${1:?dir}
  mkdir -p -- "$d"
}

# join path segments safely
join_path() {
  local a=${1:?}
  local b=${2:?}
  if [[ "$a" == */ ]]; then printf "%s%s\n" "$a" "$b"; else printf "%s/%s\n" "$a" "$b"; fi
}

# --- JSON helper (requires jq) ---
json_emit() {
  # Usage: json_emit '{"status":"ok","msg":"hello"}' > file
  jq -c .
}

# --- Env loader (optional dev/prod switches) ---
load_env() {
  # load_env dev|prod -> sources env/<name> if present
  local name=${1:-dev}
  local f1="${ROOT_DIR}/env/${name}"
  local f2="${ROOT_DIR}/env/${name}.env"
  if [[ -f "$f1" ]]; then
    # shellcheck disable=SC1090
    source "$f1"
  elif [[ -f "$f2" ]]; then
    # shellcheck disable=SC1090
    source "$f2"
  fi
}

# --- Usage scaffold (scripts override this) ---
usage_common() {
  cat <<EOF
Usage: $0 <command> [options]
Use --help on each script for detailed usage.
EOF
}

# --- Preconditions ---
require_cmd() {
  local c=$1
  command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
}

# Export paths for child scripts
export SCRIPT_DIR ROOT_DIR
