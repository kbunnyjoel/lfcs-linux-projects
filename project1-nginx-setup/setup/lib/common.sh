#!/bin/bash
set -euo pipefail

# --- UI helpers --------------------------------------------------------------
is_tty() { [[ -t 1 ]]; }
if is_tty; then
  GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"; RED="$(printf '\033[31m')"; BOLD="$(printf '\033[1m')"; RESET="$(printf '\033[0m')"
else
  GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi
info(){ echo "${YELLOW}[*]${RESET} $*"; }
ok(){ echo "${GREEN}[ok]${RESET} $*"; }
fail(){ echo "${RED}[x]${RESET} $*"; exit 1; }

# --- Paths -------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="${ROOT_DIR}/env"

require_brew() {
  command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install from https://brew.sh"
}

brew_prefix() {
  brew --prefix 2>/dev/null || echo "/opt/homebrew"
}

HOMEBREW_PREFIX="$(brew_prefix)"
NGINX_ETC="${HOMEBREW_PREFIX}/etc/nginx"
NGINX_CONF="${NGINX_ETC}/nginx.conf"
SERVERS_DIR="${NGINX_ETC}/servers"
CERT_DIR="${NGINX_ETC}/certs"
ACCESS_LOG="${HOMEBREW_PREFIX}/var/log/nginx/access.log"
ERROR_LOG="${HOMEBREW_PREFIX}/var/log/nginx/error.log"

# --- Env loader --------------------------------------------------------------
load_env() {
  local env_name="${1:-dev}"
  local env_file="${ENV_DIR}/${env_name}.env"
  [[ -f "$env_file" ]] || fail "Env file not found: $env_file"
  # shellcheck disable=SC1090
  source "$env_file"

  : "${PORT:?PORT missing in $env_file}"
  : "${WEBROOT:?WEBROOT missing in $env_file}"
  : "${SERVER_NAME:?SERVER_NAME missing in $env_file}"
  : "${ENABLE_SSL:?ENABLE_SSL missing in $env_file}"
  : "${MARKER_TEXT:?MARKER_TEXT missing in $env_file}"

  if [[ "$PORT" == "80" ]]; then
    HTTP_URL="http://${SERVER_NAME}"
  else
    HTTP_URL="http://${SERVER_NAME}:${PORT}"
  fi
  HTTPS_URL="https://${SERVER_NAME}"
}
