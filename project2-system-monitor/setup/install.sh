#!/usr/bin/env bash
set -euo pipefail
trap 'ec=$?; echo "[error] install.sh failed at line $LINENO with exit $ec while running: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/monitor.sh
source "${LIB_DIR}/monitor.sh"
# shellcheck source=lib/formatters.sh
source "${LIB_DIR}/formatters.sh"
# shellcheck source=lib/alerts.sh
source "${LIB_DIR}/alerts.sh"

print_usage() {
  cat <<USAGE
Usage:
  ./install.sh dev
  ./install.sh prod
  ./install.sh --help

Behavior:
  - Loads env from env/<env>.env
  - Collects CPU/MEM/DISK/LOAD and process checks
  - Collects top processes if enabled in env
  - Writes outputs to ./outputs in formats configured via env
USAGE
}

if [[ $# -eq 0 ]]; then print_usage; exit 0; fi

ENV="dev"
while [[ $# -gt 0 ]]; do
  case "$1" in
    dev|prod) ENV="$1"; shift ;;
    -h|--help|help|-?|--usage) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
  esac
done


load_env "$ENV"

# ---- Safe defaults to avoid unbound variable errors with `set -u` ----
# If env file doesn't define these, fall back to sensible defaults
: "${OUTPUT_DIR:=${SCRIPT_DIR}/outputs}"
: "${FORMAT:=text}"
: "${INTERVAL:=0}"
: "${CHECK_PROCESSES:=}"
# ----------------------------------------------------------------------


# Run-once collection and output logic
run_once() {
  echo "[debug] run_once: starting collection..."
  local TMP_KV
  TMP_KV="$(mktemp -t p2kv.XXXXXX)"
  echo "[debug] run_once: using temp file $TMP_KV"
  # Temporarily allow undefined vars and errors in sourced helper functions; restore afterwards
  set +eu
  echo "[debug] vars: OUTPUT_DIR='${OUTPUT_DIR:-}' FORMAT='${FORMAT:-}' INTERVAL='${INTERVAL:-}' CHECK_PROCESSES='${CHECK_PROCESSES:-}'"
  {
    echo "TIMESTAMP=$(timestamp)"
    collect_cpu        || warn "collect_cpu failed; continuing"
    collect_mem        || warn "collect_mem failed; continuing"
    collect_disk       || warn "collect_disk failed; continuing"
    collect_load       || warn "collect_load failed; continuing"
    IFS=, read -r -a procs <<< "${CHECK_PROCESSES:-}"
    for p in "${procs[@]}"; do
      [[ -n "${p}" ]] && check_process "${p}" || warn "check_process '${p}' failed; continuing"
    done
    collect_top_procs  || warn "collect_top_procs failed (likely unsupported flags on this OS); continuing"
  } > "$TMP_KV"
  coll_ec=$?
  set -e
  echo "[debug] run_once: collection block complete, exit code=${coll_ec}"

  mkdir -p "${OUTPUT_DIR:-${SCRIPT_DIR}/outputs}"
  echo "[*] Writing outputs to ${OUTPUT_DIR:-${SCRIPT_DIR}/outputs}"

  if [[ "${FORMAT:-}" == *text* ]]; then
    echo "[debug] writing text output..."
    <"$TMP_KV" kv_to_text  > "${OUTPUT_DIR}/latest.txt" || warn "kv_to_text failed; file may be missing"
  fi
  if [[ "${FORMAT:-}" == *json* ]]; then
    echo "[debug] writing json output..."
    <"$TMP_KV" kv_to_json  > "${OUTPUT_DIR}/latest.json" || warn "kv_to_json failed; file may be missing"
  fi
  if [[ "${FORMAT:-}" == *prom* ]]; then
    echo "[debug] writing prom output..."
    <"$TMP_KV" kv_to_prom  > "${OUTPUT_DIR}/latest.prom" || warn "kv_to_prom failed; file may be missing"
  fi

  # Restore strict modes
  set -u
  echo "[debug] evaluating alerts..."
  if evaluate_alerts "$TMP_KV"; then
    ok "All checks within thresholds."
  else
    warn "One or more thresholds exceeded. See console warnings and outputs."
  fi

  echo "[debug] cleaning up temp file"
  rm -f "$TMP_KV"
  ok "Monitoring run complete (${ENV}). See: ${OUTPUT_DIR:-${SCRIPT_DIR}/outputs}/latest.*"
  set -u
}

# Watch mode: if INTERVAL > 0, loop; otherwise run once
if [[ "${INTERVAL:-0}" -gt 0 ]]; then
  info "Watch mode: running every ${INTERVAL}s (Ctrl-C to stop)"
  while true; do
    echo "== $(timestamp) =="
    run_once
    sleep "${INTERVAL}"
  done
else
  run_once
fi
