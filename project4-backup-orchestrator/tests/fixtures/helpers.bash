# tests/fixtures/helpers.bash
# Common helpers for Project 4 Bats tests

# Ensure strict mode for all helpers
set -euo pipefail

# Derive project root relative to tests dir
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Path shortcuts
scripts_dir="${project_root}/src"
outputs_dir="${project_root}/outputs"
logs_dir="${project_root}/logs"
env_dir="${project_root}/env"


# Helper: make fresh sandbox directories
make_sandbox() {
  : "${BATS_TEST_TMPDIR:=/tmp}"
  SANDBOX="${BATS_TEST_TMPDIR}/p4tests.$$.${BATS_TEST_NAME// /_}"
  SRC_BASE="${SANDBOX}/src"
  DST_BASE="${SANDBOX}/dst"
  mkdir -p "${SRC_BASE}" "${DST_BASE}"
  export SANDBOX SRC_BASE DST_BASE
}

# Helper: create fresh temp SRC/DST directories for a test and export them
# Usage in tests: setup_tmp_src; then write files into "$SRC"; use "$DST" as backup destination
setup_tmp_src() {
  local base="${BATS_TEST_TMPDIR:-/tmp}/p4tests.$$.$RANDOM"
  export SRC="${base}/src"
  export DST="${base}/dst"
  rm -rf -- "${base}"
  mkdir -p -- "${SRC}" "${DST}"
}

# Optional teardown: remove the temp SRC/DST tree created by setup_tmp_src
teardown_tmp_src() {
  if [[ -n "${SRC:-}" ]]; then
    local base
    base="$(dirname "${SRC}")"
    rm -rf -- "${base}"
  fi
}

# Helper: create sample files in $SRC_BASE
populate_src() {
  mkdir -p "${SRC_BASE}/nested"
  printf '%s\n' "alpha" >"${SRC_BASE}/a.txt"
  printf '%s\n' "beta"  >"${SRC_BASE}/nested/c.txt"
  printf '%s\n' "temp"  >"${SRC_BASE}/b.tmp"
}

# Helper: extract backup id from mixed stdout (logs + JSON)
get_backup_id_from_stdout() {
  local out="$1"
  # Force a predictable locale for awk/jq
  export LC_ALL=C
  # Strip anything before the first '{' (handles logs on same or previous lines),
  # then parse the JSON for .id
  local json
  json="$(printf '%s\n' "$out" | awk '
    BEGIN { found=0 }
    {
      if (!found) {
        if (match($0, /\{/)) {
          found=1
          print substr($0, RSTART)
        }
      } else {
        print
      }
    }')"
  printf '%s' "$json" | jq -r '.id'
}

# Helper: return only the JSON object from mixed stdout (logs + JSON)
stdout_json_only() {
  local out="$1"
  export LC_ALL=C
  printf '%s\n' "$out" | awk '
    BEGIN { found=0 }
    {
      if (!found) {
        if (match($0, /\{/)) {
          found=1
          print substr($0, RSTART)
        }
      } else {
        print
      }
    }'
}

# Hook for Bats: setup before each test
setup_file() {
  mkdir -p "${outputs_dir}" "${logs_dir}" "${env_dir}"
}

# Hook for Bats: teardown after each test
teardown_file() {
  rm -rf -- "${SANDBOX:-}"
}

# Helper: print debug message during tests
diag() {
  echo "# DIAG: $*" >&3
}

# Helper: ensure JSON output has required keys
json_required_keys() {
  local json="$1"; shift
  for key in "$@"; do
    if ! echo "$json" | jq -e "has(\"$key\")" >/dev/null; then
      echo "missing key: $key" >&2
      return 1
    fi
  done
}

# ---- Restore/General test helpers (append-only; safe if sourced multiple times) ----

# Create fresh temp SRC and DST directories and assign them to variable names
# passed by the caller. Example:
#   run_setup_tmp_dirs SRC_VAR DST_VAR
# After this call, $SRC_VAR and $DST_VAR are exported environment variables.
run_setup_tmp_dirs() {
  local __src_var="$1"
  local __dst_var="$2"

  local base="${BATS_TEST_TMPDIR:-/tmp}/p4tests.$$.${BATS_TEST_NAME// /_}.$RANDOM"
  local __src="${base}/src"
  local __dst="${base}/dst"

  mkdir -p -- "$__src" "$__dst"

  # Assign into caller's variable names and export them
  eval "$__src_var=\"\$__src\""
  eval "$__dst_var=\"\$__dst\""
  eval "export $__src_var $__dst_var"
}

# Populate files quickly. Usage:
#   run_setup_tmp_files "$DIR" \
#     "a.txt:hello" \
#     "nested/x.txt:world"
# Creates parent directories as needed and writes the provided content verbatim.
run_setup_tmp_files() {
  local dir="$1"; shift || true
  mkdir -p -- "$dir"
  local spec name content
  for spec in "$@"; do
    name="${spec%%:*}"
    content="${spec#*:}"
    mkdir -p -- "$(dirname -- "$dir/$name")"
    printf '%s' "$content" >"$dir/$name"
  done
}

# Extract a JSON field from mixed stdout (logs + JSON).
# Example: json_field_from_stdout "$output" ".id"
json_field_from_stdout() {
  local out="$1"
  local jq_expr="$2"
  stdout_json_only "$out" | jq -r "$jq_expr"
}

# Ensure a directory exists and is empty (useful for restore target setup).
ensure_clean_dir() {
  local path="$1"
  rm -rf -- "$path"
  mkdir -p -- "$path"
}
