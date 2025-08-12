#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/nginx.sh"
source "${LIB_DIR}/tls.sh"
source "${LIB_DIR}/health.sh"


print_usage() {
  echo "Usage:"
  echo "  $0 dev [--bg]         # Start in development mode (foreground by default, or use --bg for background mode)"
  echo "  $0 prod               # Start in production mode"
  echo "  $0 --env dev [--bg]   # Alternative way to specify development mode"
  echo "  $0 --env prod         # Alternative way to specify production mode"
  echo
  echo "Options:"
  echo "  --bg         Run nginx in background mode (development only, via brew services)"
  echo "  -h, --help   Show this help message"
  echo
  echo "Examples:"
  echo "  $0 dev           # Development, foreground mode"
  echo "  $0 dev --bg      # Development, background mode"
  echo "  $0 prod          # Production"
}

if [[ $# -eq 0 ]]; then
  print_usage
  exit 0
fi

ENV="dev"
DEV_BACKGROUND=false
# Parse args: allow positional 'dev|prod' or --env dev|prod, and --help, and --bg
while [[ $# -gt 0 ]]; do
  case "$1" in
    dev|prod)
      ENV="$1"; shift ;;
    --env)
      ENV="${2:-dev}"; shift 2 ;;
    --env=*)
      ENV="${1#*=}"; shift ;;
    --bg)
      DEV_BACKGROUND=true; shift ;;
    -h|--help|help|-?|--usage)
      print_usage; exit 0 ;;
    *)
      echo "Unknown argument: $1"; print_usage; exit 1 ;;
  esac
done

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Invalid environment: $ENV"
  print_usage
  exit 1
fi

require_brew
load_env "$ENV"

info "Using env file: ${ENV_DIR}/${ENV}.env"

info "LFCS Project 1 — env=${ENV}"
install_nginx
deploy_site
configure_port

if [[ "$ENV" == "dev" ]]; then
  if [[ "$DEV_BACKGROUND" == true ]]; then
    info "Starting nginx in background mode for development using brew services..."
    brew services start nginx
  else
    info "Starting nginx in foreground mode for development..."
    /opt/homebrew/opt/nginx/bin/nginx -g "daemon off;"
  fi
else
  stop_nginx_if_running
  ensure_tls
  start_nginx

  check_http "$HTTP_URL"
  [[ "${ENABLE_SSL}" == "true" ]] && check_https "$HTTPS_URL" || true

  HTTPS_DISPLAY=$([[ "${ENABLE_SSL}" == "true" ]] && echo "${HTTPS_URL}" || echo "(disabled)")

  echo
  echo "All set ✅
 - Env:         ${ENV}
 - HTTP URL:    ${HTTP_URL}
 - HTTPS URL:   ${HTTPS_DISPLAY}
 - Web root:    ${WEBROOT}
 - nginx.conf:  ${NGINX_CONF} (backup exists if previously run)
 - Access log:  ${ACCESS_LOG}
 - Error log:   ${ERROR_LOG}
"
fi
