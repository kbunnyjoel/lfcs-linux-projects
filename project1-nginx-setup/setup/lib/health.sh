#!/bin/bash
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- Defaults (can be overridden by env/*.env) -------------------------------
: "${HEALTH_RETRIES:=20}"            # how many attempts
: "${HEALTH_DELAY:=0.5}"             # seconds between attempts
: "${HEALTH_ALLOW_REDIRECTS:=false}" # true to allow 301/302
if [[ "${HEALTH_ALLOW_REDIRECTS}" == "true" ]]; then
  : "${HEALTH_EXPECTED:=200,301,302}"
else
  : "${HEALTH_EXPECTED:=200}"
fi

# Normalize expected codes into a regex: e.g., "200,301,302" -> "^(200|301|302)$"
to_code_regex() { echo "$1" | tr ',' '|' | awk '{print "^(" $0 ")$"}'; }
HEALTH_EXPECTED_REGEX="$(to_code_regex "${HEALTH_EXPECTED}")"

# Internal: poll a URL with curl, return HTTP code and (optional) body snippet
_poll_url() {
  local url="$1" use_insecure="${2:-false}" code tmpfile
  tmpfile="$(mktemp -t health_body.XXXXXX)"
  if [[ "${use_insecure}" == "true" ]]; then
    code="$(curl -k -s -o "${tmpfile}" -w '%{http_code}' "${url}" || true)"
  else
    code="$(curl -s -o "${tmpfile}" -w '%{http_code}' "${url}" || true)"
  fi
  echo "${code} ${tmpfile}"
}

_check_generic() {
  local proto="$1" url="$2" insecure="${3:-false}" marker="${MARKER_TEXT:-}"
  info "${proto} check: ${url} (retries=${HEALTH_RETRIES}, delay=${HEALTH_DELAY}s, expect=${HEALTH_EXPECTED})"
  local tries=0 code body_file preview
  while true; do
    tries=$((tries+1))
    read -r code body_file <<< "$(_poll_url "${url}" "${insecure}")"

    if [[ "${code}" =~ ${HEALTH_EXPECTED_REGEX} ]]; then
      if [[ -n "${marker}" ]]; then
        if grep -q "${marker}" "${body_file}"; then
          ok "${proto} OK (${code}) — marker found"
          rm -f "${body_file}" || true
          return 0
        else
          info "Marker not found yet; retrying…"
        fi
      else
        ok "${proto} OK (${code})"
        rm -f "${body_file}" || true
        return 0
      fi
    else
      info "Got HTTP ${code}; retrying…"
    fi

    if [[ "${tries}" -ge "${HEALTH_RETRIES}" ]]; then
      preview="$(head -c 400 "${body_file}" 2>/dev/null || true)"
      echo "---- ${proto} FAILURE DEBUG ----"
      echo "Last code: ${code}"
      echo "Body (first 400 bytes):"
      echo "${preview}"
      echo "-------------------------------"
      rm -f "${body_file}" || true
      fail "${proto} endpoint did not pass health check after ${HEALTH_RETRIES} attempts."
    fi

    rm -f "${body_file}" || true
    sleep "${HEALTH_DELAY}"
  done
}

check_http() {
  local url="$1"
  _check_generic "HTTP" "${url}" "false"
}

check_https() {
  local url="$1"
  _check_generic "HTTPS" "${url}" "true"
}

# Optional: run both and summarize (useful in orchestrator scripts)
check_summary() {
  local http_url="$1" https_url="$2" ssl_enabled="${3:-false}"
  local ok_http="no" ok_https="n/a"

  if check_http "${http_url}"; then ok_http="yes"; fi
  if [[ "${ssl_enabled}" == "true" ]]; then
    if check_https "${https_url}"; then ok_https="yes"; else ok_https="no"; fi
  fi

  echo "Health Summary → HTTP:${ok_http} HTTPS:${ok_https}"
}
