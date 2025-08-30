#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
shopt -s extglob

kv_to_json() {
  # Read key=value lines from STDIN and emit a JSON object
  # Robust to values containing '=' and special chars
  local first=1 line key val
  echo "{"
  while IFS= read -r line; do
    # skip empty lines
    [[ -z "$line" ]] && continue
    # split at first '=' only
    key=${line%%=*}
    val=${line#*=}
    # trim leading/trailing whitespace from key and value
    key=${key##+([[:space:]])}; key=${key%%+([[:space:]])}
    val=${val##+([[:space:]])}; val=${val%%+([[:space:]])}
    # escape backslashes and quotes in value
    val=${val//\\/\\\\}
    val=${val//\"/\\\"}
    if (( first )); then
      printf "  \"%s\": \"%s\"\n" "$key" "$val"
      first=0
    else
      printf ",\n  \"%s\": \"%s\"\n" "$key" "$val"
    fi
  done
  echo "}"
}

kv_to_text() {
  awk -F= '{printf "%-18s %s\n", $1, $2}'
}

kv_to_prom() {
  awk -F= '
    {
      key=$1; val=$2
      gsub(/[^A-Za-z0-9_]/,"_",key)
      print tolower(key), val
    }
  '
}
