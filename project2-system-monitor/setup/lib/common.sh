#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/monitor.log"
mkdir -p "${LOG_DIR}"


# --- Color helpers ---
if [[ -t 1 ]]; then
  RED="$(tput setaf 1)"
  YELLOW="$(tput setaf 3)"
  GREEN="$(tput setaf 2)"
  RESET="$(tput sgr0)"
else
  RED=""; YELLOW=""; GREEN=""; RESET=""
fi

red()    { printf "%s%s%s\n"   "$RED" "$*" "$RESET"; }
yellow() { printf "%s%s%s\n"   "$YELLOW" "$*" "$RESET"; }
green()  { printf "%s%s%s\n"   "$GREEN" "$*" "$RESET"; }

info() { printf "[*] %s\n" "$*"; }
ok()   { green "[ok] $*"; }
warn() { yellow "[!] $*"; }
fail() { red "[x] $*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

load_env() {
  # default to 'dev' if not provided
  local env_name="${1:-dev}"
  local env_file="${PROJECT_ROOT}/env/${env_name}.env"

  [[ -f "$env_file" ]] || fail "Env file not found: $env_file"
  info "Using env file: $env_file"

  # Stash CLI overrides (only thresholds for now)
  local saved_CPU_WARN="${CPU_WARN:-}"
  local saved_MEM_WARN="${MEM_WARN:-}"
  local saved_DISK_WARN="${DISK_WARN:-}"

  # Export env vars from the file
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  # Ensure ENV is set consistently for downstream logs/formatters
  export ENV="${env_name}"

  # In dev, allow CLI/env overrides to take precedence (prod remains strict)
  if [[ "${env_name}" == "dev" ]]; then
    [[ -n "${saved_CPU_WARN}" ]] && CPU_WARN="${saved_CPU_WARN}"
    [[ -n "${saved_MEM_WARN}" ]] && MEM_WARN="${saved_MEM_WARN}"
    [[ -n "${saved_DISK_WARN}" ]] && DISK_WARN="${saved_DISK_WARN}"
  fi

  # Normalize OUTPUT_DIR to an absolute path under PROJECT_ROOT unless already absolute
  if [[ -z "${OUTPUT_DIR:-}" ]]; then
    OUTPUT_DIR="${PROJECT_ROOT}/outputs"
  else
    case "${OUTPUT_DIR}" in
      /*) : ;;                                  # absolute -> keep as is
      *)  OUTPUT_DIR="${PROJECT_ROOT}/${OUTPUT_DIR#./}" ;;  # relative -> anchor to project root
    esac
  fi
  mkdir -p "${OUTPUT_DIR}"
}

timestamp() { date +"%Y-%m-%dT%H:%M:%S%z"; }

log_warn() {
  echo "$(timestamp) [WARN] $*" >> "${LOG_FILE}"
}
