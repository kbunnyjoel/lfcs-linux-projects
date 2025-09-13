#!/usr/bin/env bash
# notify.sh - Notification helper for Project 5 (Service Watchdog)
# Supports: JSON stdout, stderr logs, and simple email (sendmail if present),
# with a safe fallback to append to logs/notify.log (for tests/containers).
set -euo pipefail

# ---------------------------
# Helpers
# ---------------------------
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "${LOG_DIR}"

log_info() { [[ -n "${LOG_SILENT:-}" ]] || printf "%s [INFO] %s\n" "$(ts)" "$*" >&2; }
log_err()  { [[ -n "${LOG_SILENT:-}" ]] || printf "%s [ERR] %s\n"  "$(ts)" "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage:
  notify.sh send [--env ENV] [--to ADDRESS] [--from ADDRESS] [--subject TEXT] [--body TEXT] [--level LEVEL] [--channel email|log] [--smtp-account NAME] [--smtp-bin PATH] [--json] [--dry-run]

Description:
  Sends a notification. Prefers msmtp if available (using ~/.msmtprc), otherwise tries sendmail.
  If neither mailer is available or no recipient is provided, the message is appended to logs/notify.log.
  When --json is provided, a JSON summary is printed to stdout (side effects still occur).

Environment (via --env or pre-exported):
  EMAIL_TO, EMAIL_FROM     - default recipient/sender
  NOTIFY_CHANNEL           - currently "email" or "log" (default: "email")
  SMTP_ACCOUNT             - (optional) msmtp account name to use (e.g., "gmail")
  SMTP_BIN                 - (optional) path to msmtp binary; overrides auto-detect

CLI overrides:
  --smtp-account NAME       - overrides SMTP_ACCOUNT for this invocation
  --smtp-bin PATH           - overrides SMTP_BIN for this invocation

  SUBJECT_PREFIX           - (optional) string prefixed to the subject (e.g., "[PROD] ")

Examples:
  src/lib/notify.sh send --env dev --subject "Watchdog OK" --body "All healthy" --level info --json
  src/lib/notify.sh send --to ops@example.com --subject "Service down" --body "nginx unhealthy" --level error
  src/lib/notify.sh send --channel log --subject "Dry run" --body "No send" --dry-run --json
EOF
}

# ---------------------------
# Env loading (accepts env/<name> or env/<name>.env)
# ---------------------------
ENV_NAME="${ENV_NAME:-}"
load_env() {
  local name="$1"
  [[ -n "$name" ]] || return 0

  local base="${ROOT_DIR}/env/${name}"
  local path=""
  if [[ -f "$base" ]]; then
    path="$base"
  elif [[ -f "${base}.env" ]]; then
    path="${base}.env"
  fi

  if [[ -n "$path" ]]; then
    # shellcheck disable=SC1090
    . "$path"
    log_info "Loaded env '${name}' from ${path}"
  else
    log_err "env '${name}' not found at ${base} or ${base}.env"
    exit 3
  fi
}

# ---------------------------
# Email + fallback senders
# ---------------------------
append_log() {
  local subj="$1" body="$2" level="$3"
  printf "%s [%s] %s :: %s\n" "$(ts)" "$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')" "$subj" "$body" >> "${LOG_DIR}/notify.log"
  log_info "Appended notification to ${LOG_DIR}/notify.log"
}

send_via_msmtp() {
  local to="$1" from="$2" subject="$3" body="$4"

  # Pick msmtp binary
  local msmtp_bin="${SMTP_BIN:-}"
  if [[ -z "$msmtp_bin" ]] && command -v msmtp >/dev/null 2>&1; then
    msmtp_bin="$(command -v msmtp)"
  fi
  [[ -n "$msmtp_bin" ]] || return 1

  # Optional account selection
  local account_opts=()
  if [[ -n "${SMTP_ACCOUNT:-}" ]]; then
    account_opts=(-a "$SMTP_ACCOUNT")
  fi

  log_info "Sending email via ${msmtp_bin} to ${to}"
  {
    echo "From: ${from}"
    echo "To: ${to}"
    echo "Subject: ${subject}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    echo "${body}"
  } | "$msmtp_bin" "${account_opts[@]}" -t
}

send_via_sendmail() {
  local to="$1" from="$2" subject="$3" body="$4"
  local sendmail_bin=""
  if command -v sendmail >/dev/null 2>&1; then
    sendmail_bin="$(command -v sendmail)"
  elif [[ -x /usr/sbin/sendmail ]]; then
    sendmail_bin="/usr/sbin/sendmail"
  fi

  if [[ -n "$sendmail_bin" ]]; then
    log_info "Sending email via ${sendmail_bin} to ${to}"
    {
      echo "From: ${from}"
      echo "To: ${to}"
      echo "Subject: ${subject}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      echo "${body}"
    } | "${sendmail_bin}" -t
    return 0
  fi
  return 1
}

send_notification() {
  local channel="$1" to="$2" from="$3" subject="$4" body="$5" level="$6"
  status=""
  case "$channel" in
    email)
      if [[ -n "$to" ]]; then
        if send_via_msmtp "$to" "$from" "$subject" "$body"; then
          status="sent"
          return 0
        elif send_via_sendmail "$to" "$from" "$subject" "$body"; then
          status="sent"
          return 0
        fi
      fi
      # Fallback to log
      append_log "$subject" "$body" "$level"
      status="logged"
      ;;
    log|"")
      append_log "$subject" "$body" "$level"
      status="logged"
      ;;
    *)
      log_err "unknown NOTIFY_CHANNEL: $channel (falling back to log)"
      append_log "$subject" "$body" "$level"
      status="logged"
      ;;
  esac
}

# ---------------------------
# CLI
# ---------------------------
CMD="${1:-}"

# If invoked with no command, exit quietly (useful for presence checks in tests)
if [[ -z "$CMD" ]]; then
  exit 0
fi

# Consume the command argument now that we know it's present
shift

# Only supported subcommand is 'send'
if [[ "$CMD" != "send" ]]; then
  usage
  exit 2
fi

json=0
subject=""
body=""
level="info"
to="${EMAIL_TO:-}"
from="${EMAIL_FROM:-}"
notify_channel="${NOTIFY_CHANNEL:-email}"
dry_run=0

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)         ENV_NAME="${2:-}"; shift 2 ;;
    --to)          to="${2:-}"; shift 2 ;;
    --from)        from="${2:-}"; shift 2 ;;
    --subject)     subject="${2:-}"; shift 2 ;;
    --body)        body="${2:-}"; shift 2 ;;
    --level)       level="${2:-}"; shift 2 ;;
    --channel)     notify_channel="${2:-}"; shift 2 ;;
    --smtp-account) SMTP_ACCOUNT="${2:-}"; shift 2 ;;
    --smtp-bin)     SMTP_BIN="${2:-}"; shift 2 ;;
    --dry-run)     dry_run=1; shift ;;
    --json)        json=1; shift ;;
    --help|-h)     usage; exit 0 ;;
    *)
      log_err "unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

# Load env if provided (do this before silencing logs so errors are visible)
[[ -n "$ENV_NAME" ]] && load_env "$ENV_NAME"

# If JSON was requested, silence stderr logs to keep stdout strictly JSON
# (only after successful env load, so missing-env errors are emitted)
if [[ "$json" -eq 1 ]]; then
  LOG_SILENT=1
fi

# Optional subject prefix (from env or pre-exported variable)
if [[ -n "${SUBJECT_PREFIX:-}" ]]; then
  subject="${SUBJECT_PREFIX}${subject}"
fi

# Defaults from env after load
# Default recipient falls back to user's email if not provided by CLI/env
to="${to:-${EMAIL_TO:-bunnyjoel391@gmail.com}}"
from="${from:-${EMAIL_FROM:-no-reply@localhost}}"
notify_channel="${notify_channel:-${NOTIFY_CHANNEL:-email}}"

# Basic validation
[[ -n "$subject" ]] || subject="Notification ($(ts))"
[[ -n "$body" ]]    || body="(no body)"
[[ -n "$level" ]]   || level="info"

# Perform send (unless --dry-run)
if [[ "$dry_run" -eq 1 ]]; then
  status="dry-run"
else
  send_notification "$notify_channel" "$to" "$from" "$subject" "$body" "$level"
fi

# JSON summary to stdout if requested
if [[ "$json" -eq 1 ]]; then
  jq -n \
    --arg ts "$(ts)" \
    --arg channel "$notify_channel" \
    --arg to "$to" \
    --arg from "$from" \
    --arg subject "$subject" \
    --arg body "$body" \
    --arg level "$level" \
    --arg status "${status:-sent}" \
    --argjson dry_run ${dry_run} \
    '{timestamp:$ts, channel:$channel, to:$to, from:$from, subject:$subject, body:$body, level:$level, status:$status, dry_run:$dry_run}'
fi
