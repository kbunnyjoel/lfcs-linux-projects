#!/usr/bin/env bash
set -euo pipefail

# Logging helpers
info(){ printf '[*] %s\n' "$*"; }
ok(){   printf '[ok] %s\n' "$*"; }
warn(){ printf '[warn] %s\n' "$*" >&2; }
err(){  printf '[err] %s\n' "$*" >&2; }

die(){ err "$*"; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# Load env if present
load_env() {
  local env_name="${1:-dev}"
  if [[ -f "${ROOT_DIR}/env/${env_name}" ]]; then
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/env/${env_name}"
  fi
  : "${DEFAULT_SHELL:=/bin/bash}"
  : "${DEFAULT_GROUPS:=}"
  : "${LIST_FILTER:=humans}"
}


# --- Sprint 2 helpers: audit & validated atomic writes ---
# Append an audit line: timestamp action user details
audit() {
  local action="$1" user="$2" details="${3:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "${ROOT_DIR}/logs"
  printf '%s %s %s %s\n' "$ts" "$action" "$user" "$details" >> "${ROOT_DIR}/logs/audit.log"
}

# Validate a sudoers file using visudo -cf
validate_sudoers() {
  local file="$1"
  visudo -cf "$file" >/dev/null 2>&1
}

# Write $2 to a temp file, validate with $3 (validator func), then move to $1
# Usage: atomic_write_validated /etc/sudoers.d/alice "content" validate_sudoers
atomic_write_validated() {
  local target="$1" content="$2" validator_func="$3"
  local dir tmp
  dir="$(dirname -- "$target")"
  tmp="$(mktemp "${dir}/.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  # shellcheck disable=SC2119
  if "$validator_func" "$tmp"; then
    chmod 0440 "$tmp"
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

# USER helpers
user_exists() {
  if id -u "$1" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# List “human” users: uid >= 1000 (Ubuntu/Debian default), excluding nobody
list_users() {
  local mode="${1:-humans}"
  if [[ "${mode}" == "humans" ]]; then
    awk -F: '$3 >= 1000 && $1 != "nobody" { print $1 }' /etc/passwd | sort
  else
    cut -d: -f1 /etc/passwd | sort
  fi
}
