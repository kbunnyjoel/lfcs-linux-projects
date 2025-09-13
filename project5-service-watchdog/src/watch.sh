#!/usr/bin/env bash
set -euo pipefail

# --- Paths & libs ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${ROOT_DIR}/src/lib"

# shellcheck source=src/lib/env.sh
source "${LIB_DIR}/env.sh"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info() {
  local line
  line="$(ts) [INFO] $*"
  # stderr (keeps --json stdout clean)
  if ! $QUIET; then
    printf "%s\n" "$line" >&2
  fi
  # file log (best-effort)
  {
    mkdir -p "$(dirname -- "$WATCH_LOG_PATH")" 2>/dev/null || true
    # truncate if > ~5MB
    if [ -f "$WATCH_LOG_PATH" ] && [ "$(wc -c <"$WATCH_LOG_PATH" 2>/dev/null || echo 0)" -gt 5242880 ]; then
      : >"$WATCH_LOG_PATH"
    fi
    printf "%s\n" "$line" >>"$WATCH_LOG_PATH" 2>/dev/null || true
  } || true
}

 # --- Defaults (can be loaded/overridden by env file) ---
WATCH_SERVICES="${WATCH_SERVICES:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-60}"
WATCH_RESTART="${WATCH_RESTART:-false}"
WATCH_NOTIFY="${WATCH_NOTIFY:-stdout}"
WATCH_MAX_RETRIES="${WATCH_MAX_RETRIES:-1}"
WATCH_RETRY_INTERVAL="${WATCH_RETRY_INTERVAL:-1}"
WATCH_LOG_PATH="${WATCH_LOG_PATH:-${ROOT_DIR}/logs/watch.log}"
QUIET="${QUIET:-false}"

# Sprint 3: backoff controls (backward compatible defaults)
WATCH_BACKOFF_MODE="${WATCH_BACKOFF_MODE:-fixed}"          # fixed|exp
WATCH_RETRY_MAX_INTERVAL="${WATCH_RETRY_MAX_INTERVAL:-30}" # seconds cap for exp backoff
WATCH_BACKOFF_JITTER="${WATCH_BACKOFF_JITTER:-0}"          # 0.0..1.0, random jitter fraction

# --- Notifications plumbing ---
: "${NOTIFY_SH:=${ROOT_DIR}/src/lib/notify.sh}"  # can be overridden in tests
send_notify() {
  # usage: send_notify <level> <subject> <body>
  local lvl="$1" subj="$2" body="$3"
  local args=()
  # If caller provided an --env earlier, pass it through
  if [[ -n "${env_name:-}" ]]; then
    args+=(--env "$env_name")
  fi
  if [[ -x "$NOTIFY_SH" ]]; then
    # Notify tool prints JSON; keep it on stderr so stdout is reserved for program output
    "$NOTIFY_SH" send "${args[@]}" --level "$lvl" --subject "$subj" --body "$body" --json 1>&2 || true
  else
    # Fallback to stderr log only
    printf '{"timestamp":"%s","channel":"log","level":%q,"subject":%q,"body":%q}\n' \
      "$(ts)" "$lvl" "$subj" "$body" 1>&2
  fi
}

# --- Service check helpers ---
have_cmd() { command -v "$1" >/dev/null 2>&1; }

check_with_systemctl() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    echo "up"
  else
    # if systemctl knows service but inactive, it exits non-zero
    # treat as "down"
    echo "down"
  fi
}

check_with_pgrep() {
  local svc="$1"
  if pgrep -x "$svc" >/dev/null 2>&1; then
    echo "up"
  else
    echo "down"
  fi
}

check_service() {
  local svc="$1"
  if have_cmd systemctl; then
    check_with_systemctl "$svc"
  elif have_cmd pgrep; then
    check_with_pgrep "$svc"
  else
    echo "unknown"
  fi
}

# Resolve a command path for test temp files or PATH-installed binaries.
resolve_cmd() {
  local cmd="$1"
  local base

  # 1) If directly-executable path, use it
  if [[ -n "$cmd" && -x "$cmd" ]]; then
    echo "$cmd"
    return 0
  fi

  # Derive basename once
  base="$(basename -- "$cmd" 2>/dev/null || echo "$cmd")"

  # 2) If the token includes a slash but doesn't exist, fall back to basename lookup
  if [[ "$cmd" == */* && ! -x "$cmd" ]]; then
    # Try PATH first
    if command -v "$base" >/dev/null 2>&1; then
      command -v "$base"
      return 0
    fi
    # Then ./
    if [[ -x "./$base" ]]; then
      echo "./$base"
      return 0
    fi
    # Bats tmp dir
    if [[ -n "${BATS_TEST_TMPDIR:-}" && -x "${BATS_TEST_TMPDIR}/$base" ]]; then
      echo "${BATS_TEST_TMPDIR}/$base"
      return 0
    fi
    # Generic tmp dir some tests use
    if [[ -n "${TMPDIR:-}" && -x "${TMPDIR}/$base" ]]; then
      echo "${TMPDIR}/$base"
      return 0
    fi
    # Repo fixtures
    if [[ -x "${ROOT_DIR}/tests/fixtures/$base" ]]; then
      echo "${ROOT_DIR}/tests/fixtures/$base"
      return 0
    fi
    if [[ -x "${ROOT_DIR}/tests/$base" ]]; then
      echo "${ROOT_DIR}/tests/$base"
      return 0
    fi
    # Give back original token; will fail at call site if truly missing
    echo "$cmd"
    return 0
  fi

  # 3) Bare command name search order: PATH -> ./ -> BATS_TEST_TMPDIR -> TMPDIR -> tests/fixtures -> tests/
  if [[ "$cmd" != */* ]]; then
    if command -v "$cmd" >/dev/null 2>&1; then
      command -v "$cmd"
      return 0
    fi
    if [[ -x "./$base" ]]; then
      echo "./$base"
      return 0
    fi
    if [[ -n "${BATS_TEST_TMPDIR:-}" && -x "${BATS_TEST_TMPDIR}/$base" ]]; then
      echo "${BATS_TEST_TMPDIR}/$base"
      return 0
    fi
    if [[ -n "${TMPDIR:-}" && -x "${TMPDIR}/$base" ]]; then
      echo "${TMPDIR}/$base"
      return 0
    fi
    if [[ -x "${ROOT_DIR}/tests/fixtures/$base" ]]; then
      echo "${ROOT_DIR}/tests/fixtures/$base"
      return 0
    fi
    if [[ -x "${ROOT_DIR}/tests/$base" ]]; then
      echo "${ROOT_DIR}/tests/$base"
      return 0
    fi
  fi

  # 4) Fallback to original token
  echo "$cmd"
}

# Compute backoff sleep (supports fixed and exponential with optional jitter)
# args: attempt_index retry_interval max_interval mode jitter
backoff_sleep() {
  local attempt="$1" base="$2" cap="$3" mode="$4" jitter="$5"
  local delay
  if [[ "$mode" == "exp" || "$mode" == "exponential" ]]; then
    # exponential: base * 2^attempt, capped
    # use awk for pow without bash 4 math
    delay=$(awk -v b="$base" -v a="$attempt" 'BEGIN { printf "%.6f", b * exp(a*log(2)) }')
    # cap
    delay=$(awk -v d="$delay" -v c="$cap" 'BEGIN { if (d>c) d=c; printf "%.6f", d }')
  else
    delay="$base"
  fi
  # apply jitter if requested (uniform [-(j*b), +(j*b)])
  if awk -v j="$jitter" 'BEGIN { exit (j>0.000001)?0:1 }'; then
    # shellcheck disable=SC2155
    local span; span=$(awk -v d="$delay" -v j="$jitter" 'BEGIN { printf "%.6f", d*j }')
    # shellcheck disable=SC2155
    local r; r=$(awk 'BEGIN { srand(); print (rand()*2)-1 }')
    delay=$(awk -v d="$delay" -v s="$span" -v r="$r" 'BEGIN { printf "%.6f", d + (s*r) }')
    # never negative
    delay=$(awk -v d="$delay" 'BEGIN { if (d<0) d=0; printf "%.6f", d }')
  fi
  printf "%s" "$delay"
}

# --- JSON output builder ---
# args: services... 
emit_json() {
  local -a svcs=("$@")
  local overall="up"
  local first=1
  printf '{'
  printf '"timestamp":"%s",' "$(ts)"
  printf '"services":['
  for s in "${svcs[@]}"; do
    st="$(check_service "$s")"
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"name":"%s","status":"%s"}' "$s" "$st"
    if [[ "$st" != "up" ]]; then
      overall="degraded"
    fi
  done
  printf '],'
  printf '"overall":"%s"' "$overall"
  printf '}\n'
}

usage() {
  cat <<EOF
Usage:
  watch.sh check [--env ENV] [--services "svc1 svc2"] [--json] [--once] [--health-cmd PATH] [--check-cmd PATH] [--start-cmd PATH] [--restart-cmd PATH] [--interval SEC] [--max-retries N] [--retry-interval SEC] [--backoff fixed|exp] [--retry-max-interval SEC] [--jitter FRACTION] [--loop] [--quiet]

Description:
  Checks the status of configured services. If --json is provided, prints JSON to stdout.
  Optionally run an external health command (0=healthy, non-zero=unhealthy). If not --once,
  a single restart via --start-cmd will be attempted and health rechecked.
  Exit codes: 0 = all up/healthy, 1 = any down/unknown/unhealthy, 2 = usage error.

Examples:
  src/watch.sh check --env dev --json
  src/watch.sh check --services "nginx sshd" --json
  src/watch.sh check --health-cmd ./health.sh --start-cmd ./start.sh --json

# Alias: --restart-cmd is accepted as a synonym for --start-cmd
# Alias: --check-cmd is accepted as a synonym for --health-cmd
# Note: --interval is accepted for compatibility; it is parsed but not used in a loop for Sprint 1.
# Note: --max-retries controls how many restart attempts are made when using --health-cmd (default: 1).
# Note: --retry-interval sets seconds between restart attempts (default: $WATCH_RETRY_INTERVAL).
# Note: --backoff selects "fixed" (default) or "exp" (exponential) sleep between retries.
# Note: --retry-max-interval caps exponential backoff (default: $WATCH_RETRY_MAX_INTERVAL).
# Note: --jitter adds randomization (0..1 fraction of delay) to retry sleeps (default: $WATCH_BACKOFF_JITTER).
# Note: --loop enables continuous monitoring; each cycle sleeps for --interval seconds.
# Env defaults: WATCH_HEALTH_CMD and WATCH_START_CMD can supply paths used when --health-cmd/--start-cmd are not passed.
# Env defaults: WATCH_SERVICES, WATCH_INTERVAL, WATCH_MAX_RETRIES, WATCH_RETRY_INTERVAL are also honored.
# Env defaults: WATCH_BACKOFF_MODE (fixed|exp), WATCH_RETRY_MAX_INTERVAL, WATCH_BACKOFF_JITTER
# Note: --quiet suppresses stderr INFO logs but still writes to the file log.
EOF
}


CMD="${1:-}"
shift || true

# Allow calling without the explicit subcommand (default to "check")
# Examples supported:
#   src/watch.sh check --json ...
#   src/watch.sh --check-cmd ./health.sh --json        # no subcommand given
#   src/watch.sh --health-cmd ./h.sh --start-cmd ./s.sh
if [[ -z "${CMD}" || "${CMD}" == -* || "${CMD}" == */* ]]; then
  # Put the first token back into $@ if it existed
  if [[ -n "${CMD}" ]]; then
    set -- "${CMD}" "$@"
  fi
  CMD="check"
fi

env_name=""
json=false
services_override=""
health_cmd=""
start_cmd=""
once=false
interval="${WATCH_INTERVAL}"
max_retries="${WATCH_MAX_RETRIES}"
retry_interval="${WATCH_RETRY_INTERVAL}"
backoff_mode="${WATCH_BACKOFF_MODE}"
retry_max_interval="${WATCH_RETRY_MAX_INTERVAL}"
backoff_jitter="${WATCH_BACKOFF_JITTER}"
loop_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_name="$2"; shift 2;;
    --services) services_override="$2"; shift 2;;
    --json) json=true; shift;;
    --once) once=true; shift;;
    --health-cmd) health_cmd="$2"; shift 2;;
    --check-cmd) health_cmd="$2"; shift 2;;
    --start-cmd) start_cmd="$2"; shift 2;;
    --restart-cmd) start_cmd="$2"; shift 2;;
    --interval)
      [[ $# -ge 2 ]] || { echo "[err] --interval requires a value" >&2; exit 2; }
      interval="$2"; shift 2;;
    --max-retries)
      [[ $# -ge 2 ]] || { echo "[err] --max-retries requires a value" >&2; exit 2; }
      max_retries="$2"; shift 2;;
    --retry-interval)
      [[ $# -ge 2 ]] || { echo "[err] --retry-interval requires a value" >&2; exit 2; }
      retry_interval="$2"; shift 2;;
    --backoff)
      [[ $# -ge 2 ]] || { echo "[err] --backoff requires a value: fixed|exp" >&2; exit 2; }
      backoff_mode="$2"; shift 2;;
    --retry-max-interval)
      [[ $# -ge 2 ]] || { echo "[err] --retry-max-interval requires seconds" >&2; exit 2; }
      retry_max_interval="$2"; shift 2;;
    --jitter)
      [[ $# -ge 2 ]] || { echo "[err] --jitter requires a fraction 0..1" >&2; exit 2; }
      backoff_jitter="$2"; shift 2;;
    --loop)
      loop_mode=true; shift;;
    --quiet) QUIET=true; shift;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "[err] unknown option: $1" >&2; usage; exit 2;;
    *)
      # Back-compat: first bare token after options is the health command
      if [[ -z "$health_cmd" ]]; then
        health_cmd="$1"; shift
      else
        echo "[err] unexpected argument: $1" >&2; usage; exit 2
      fi
      ;;
  esac
done

# If JSON output is requested, suppress stderr INFO logs to keep stdout/JSON consumers clean
if $json; then
  QUIET=true
fi

# If no explicit commands were provided via CLI, use env-backed defaults
if [[ -z "$health_cmd" && -n "${WATCH_HEALTH_CMD:-}" ]]; then
  health_cmd="$WATCH_HEALTH_CMD"
fi
if [[ -z "$start_cmd" && -n "${WATCH_START_CMD:-}" ]]; then
  start_cmd="$WATCH_START_CMD"
fi

# Normalize any provided external command paths so tests can pass temp-file paths
if [[ -n "$health_cmd" ]]; then
  health_cmd="$(resolve_cmd "$health_cmd")"
fi
if [[ -n "$start_cmd" ]]; then
  start_cmd="$(resolve_cmd "$start_cmd")"
fi

emit_health_json() {
  local overall="$1"
  printf '{"timestamp":"%s","services":[],"overall":"%s"}\n' "$(ts)" "$overall"
}

case "$CMD" in
  check|status)
    if [[ -n "$env_name" ]]; then
      load_env "$env_name"
    fi

    if [[ -n "$health_cmd" ]]; then
      log_info "Running external health check: $health_cmd"

      run_health_once() {
        if "$health_cmd" >/dev/null 2>&1; then
          $json && emit_health_json "up" || echo "healthy"
          return 0
        fi
        if $once; then
          send_notify "error" "Unhealthy: ${services_override:-${WATCH_SERVICES:-watchdog}}" "Health check failed (once)"
          if $json; then
            printf '{"timestamp":"%s","services":[],"overall":"degraded","action":"unhealthy","attempts":0}\n' "$(ts)"
          else
            echo "unhealthy"
          fi
          return 1
        fi
        local attempt=0
        while [[ $attempt -lt ${max_retries} ]]; do
          if [[ -n "$start_cmd" ]]; then
            log_info "Attempting restart via: $start_cmd (try $((attempt+1))/${max_retries})"
            if ! "$start_cmd" >/dev/null 2>&1; then
              log_info "Restart command exited non-zero"
            fi
            # Sprint 3 backoff
            local wait_s
            wait_s="$(backoff_sleep "$attempt" "$retry_interval" "$retry_max_interval" "$backoff_mode" "$backoff_jitter")"
            log_info "Waiting ${wait_s}s before recheck"
            # shellcheck disable=SC2003
            sleep "$(printf "%.0f" "$wait_s")"
          else
            break
          fi
          if "$health_cmd" >/dev/null 2>&1; then
            send_notify "info" "Recovered: ${services_override:-${WATCH_SERVICES:-watchdog}}" "Service recovered after restart"
            if $json; then
              printf '{"timestamp":"%s","services":[],"overall":"up","action":"recovered","attempts":%d}\n' "$(ts)" "$((attempt+1))"
            else
              echo "recovered"
            fi
            return 0
          fi
          attempt=$((attempt+1))
        done
        send_notify "error" "Unhealthy: ${services_override:-${WATCH_SERVICES:-watchdog}}" "Health check failed after retries"
        if $json; then
          printf '{"timestamp":"%s","services":[],"overall":"degraded","action":"still-unhealthy","attempts":%d}\n' "$(ts)" "$attempt"
        else
          echo "still-unhealthy"
        fi
        return 1
      }

      if $loop_mode && ! $once; then
        running=true
        trap 'running=false' TERM INT
        rc=0
        while $running; do
          if ! run_health_once; then
            rc=1
          fi
          sleep "$interval"
        done
        exit $rc
      else
        run_health_once
        exit $?
      fi
    fi

    run_services_once() {
      local -a svcs=("${local_services[@]}")
      log_info "Checking services: ${svcs[*]}"
      if $json; then
        out="$(emit_json "${svcs[@]}")"
        echo "$out"
        # If degraded, notify with list of bad services (best-effort)
        if echo "$out" | grep -q '"status":"down"\|"status":"unknown"'; then
          bad_list=""
          if command -v jq >/dev/null 2>&1; then
            bad_list=$(echo "$out" | jq -r '.services[] | select(.status != "up") | .name' | xargs 2>/dev/null || true)
          fi
          subj="Degraded: ${bad_list:-${svcs[*]}}"
          body="One or more services are down or unknown"
          send_notify "error" "$subj" "$body"
        fi
        if echo "$out" | grep -q '"status":"down"\|"status":"unknown"'; then
          return 1
        else
          return 0
        fi
      else
        local any_bad=0
        local st
        for s in "${svcs[@]}"; do
          st="$(check_service "$s")"
          printf "%s: %s\n" "$s" "$st"
          [[ "$st" == "up" ]] || any_bad=1
        done
        if [[ $any_bad -ne 0 ]]; then
          # build bad list (simple, no jq here)
          bad_list=""
          for s in "${svcs[@]}"; do
            st_now=$(check_service "$s")
            [[ "$st_now" == "up" ]] || bad_list+=" $s"
          done
          subj="Degraded: ${bad_list# }"
          body="One or more services are down or unknown"
          send_notify "error" "$subj" "$body"
        fi
        return $any_bad
      fi
    }

    local_services=()
    if [[ -n "$services_override" ]]; then
      # shellcheck disable=SC2206
      local_services=($services_override)
    elif [[ -n "${WATCH_SERVICES}" ]]; then
      # shellcheck disable=SC2206
      local_services=(${WATCH_SERVICES})
    else
      echo "[err] No services provided (use --env or --services or provide a health command)" >&2
      exit 2
    fi

    if $once || ! $loop_mode; then
      run_services_once
      exit $?
    fi

    # loop mode
    running=true
    trap 'running=false' TERM INT
    rc=0
    while $running; do
      if ! run_services_once; then
        rc=1
      fi
      sleep "$interval"
    done
    exit $rc
    ;;

  ""|-h|--help)
    usage
    ;;

  *)
    echo "[err] unknown command: $CMD" >&2
    usage
    exit 2
    ;;
esac
