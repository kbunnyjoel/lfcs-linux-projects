#!/bin/bash
set -euo pipefail

# Timestamp helper (UTC, ISO-8601-like)
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Log an info message (to stderr)
log_info() {
  printf '%s [INFO] %s\n' "$(ts)" "$*" >&2
}

# Log a warning message (to stderr)
log_warn() {
  printf '%s [WARN] %s\n' "$(ts)" "$*" >&2
}

# Log an error message (to stderr)
log_error() {
  printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2
}
