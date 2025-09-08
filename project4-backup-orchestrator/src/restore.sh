#!/usr/bin/env bash
# restore.sh - restore backups created by backup.sh
# Supports restoring from:
#   - directory snapshots
#   - .tar, .tar.gz, .tar.zst artifacts
#
# Usage examples:
#   src/restore.sh --artifact /backups/2025..._nightly.tar.gz --target ./tmp/restore --json
#   src/restore.sh --id 2025..._nightly --dest /backups --target ./tmp/restore --json

set -euo pipefail

# --- Project roots & common helpers ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=src/lib/common.sh
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  # common.sh is usually under src/lib
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/common.sh"
elif [[ -f "${ROOT_DIR}/src/lib/common.sh" ]]; then
  # fallback if launched differently
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/src/lib/common.sh"
else
  # provide minimal shims if common.sh isn't available (tests still run)
  ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  log_info() { printf "%s [INFO] %s\n" "$(ts)" "$*"; }
  die() { printf "[err] %s\n" "$*" >&2; exit 1; }
fi

AUDIT_LOG="${ROOT_DIR}/logs/audit.log"
mkdir -p -- "${ROOT_DIR}/logs" "${ROOT_DIR}/outputs"

# --- CLI parsing ---
restore_artifact=""
restore_id=""
dest_root=""
restore_target=""
want_json="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    restore) shift ;; # allow optional leading subcommand
    --artifact) restore_artifact="${2:-}"; shift 2 ;;
    --id) restore_id="${2:-}"; shift 2 ;;
    --dest) dest_root="${2:-}"; shift 2 ;;
    --target) restore_target="${2:-}"; shift 2 ;;
    --json) want_json="1"; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  restore.sh restore --artifact <path> --target <dir> [--json]
  restore.sh restore --id <backup_id> --dest <backups_root> --target <dir> [--json]

Notes:
  - The restore target directory must already exist and be writable.
  - When using --id, the script searches <backups_root> for:
      <id>.tar.gz, <id>.tar.zst, <id>.tar, <id>/ (directory snapshot)
EOF
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$restore_target" ]] || die "--target required for restore"
[[ -d "$restore_target" ]] || die "restore target '$restore_target' does not exist or is not a directory; create it and re-run"
[[ -w "$restore_target" ]] || die "restore target '$restore_target' is not writable (read-only filesystem?)"

# --- Helpers ---
resolve_artifact_by_id() {
  # $1 id, $2 dest_root
  local id="$1"
  local base="$2"

  [[ -d "$base" ]] || return 1

  local cand
  for cand in \
    "$base/${id}.tar.gz" \
    "$base/${id}.tar.zst" \
    "$base/${id}.tar" \
    "$base/${id}"
  do
    if [[ -e "$cand" ]]; then
      if [[ -d "$cand" ]]; then
        printf "%s|dir\n" "$cand"
      elif [[ "$cand" == *.tar.gz ]]; then
        printf "%s|tar_gz\n" "$cand"
      elif [[ "$cand" == *.tar.zst" ]]; then
        printf "%s|tar_zst\n" "$cand"
      else
        printf "%s|tar\n" "$cand"
      fi
      return 0
    fi
  done
  return 1
}

strip_id_from_path() {
  # Derive an ID from artifact path by stripping known extensions & directory
  local p="$1"
  p="$(basename -- "$p")"
  p="${p%.tar.gz}"
  p="${p%.tar.zst}"
  p="${p%.tar}"
  printf "%s\n" "$p"
}

manifest_stats() {
  # Echo "files bytes" from outputs/<id>/manifest.txt if present, else "0 0"
  local id="$1"
  local manifest="${ROOT_DIR}/outputs/${id}/manifest.txt"
  if [[ -f "$manifest" ]]; then
    # manifest format: "relpath size"
    # Aggregate lines and size sums
    awk '
      BEGIN{files=0; bytes=0}
      NF>=2 {files+=1; bytes+=$NF}
      END{printf "%d %d\n", files, bytes}
    ' "$manifest"
  else
    printf "0 0\n"
  fi
}

audit_restore() {
  # $1 action_string
  local action="$1"
  printf "%s %s id=%s artifact=%s target=%s\n" "$(ts)" "$action" "$backup_id" "$artifact" "$restore_target" >> "$AUDIT_LOG"
}

# --- Resolve artifact & type ---
artifact=""
type=""
backup_id=""

if [[ -n "$restore_artifact" ]]; then
  artifact="$restore_artifact"
  if [[ -d "$artifact" ]]; then
    type="dir"
  elif [[ "$artifact" == *.tar.gz ]]; then
    type="tar_gz"
  elif [[ "$artifact" == *.tar.zst ]]; then
    type="tar_zst"
  elif [[ "$artifact" == *.tar ]]; then
    type="tar"
  else
    die "unknown artifact type: $artifact"
  fi
  backup_id="$(strip_id_from_path "$artifact")"
else
  [[ -n "$restore_id" ]] || die "provide --id or --artifact"
  [[ -n "$dest_root" ]] || die "--dest required when using --id"
  [[ -d "$dest_root" ]] || die "destination root '$dest_root' not found or not a directory"

  local_id="$restore_id"
  # Normalize (strip any provided extension)
  local_id="$(strip_id_from_path "$local_id")"

  resolved="$(resolve_artifact_by_id "$local_id" "$dest_root")" || die "could not locate artifact for id '$local_id' under '$dest_root'"
  artifact="${resolved%|*}"
  type="${resolved#*|}"
  backup_id="$local_id"
fi

# --- Perform restore ---
case "$type" in
  dir)
    log_info "Restoring directory snapshot '${backup_id}' to ${restore_target}"
    rsync -a --delete "${artifact}/" "${restore_target}/"
    ;;
  tar_gz)
    log_info "Restoring tar.gz '${backup_id}' to ${restore_target}"
    tar -xpf "$artifact" -C "$restore_target" -z
    ;;
  tar_zst)
    log_info "Restoring tar.zst '${backup_id}' to ${restore_target}"
    tar --use-compress-program=zstd -xpf "$artifact" -C "$restore_target"
    ;;
  tar)
    log_info "Restoring tar '${backup_id}' to ${restore_target}"
    tar -xpf "$artifact" -C "$restore_target"
    ;;
  *)
    die "unhandled type: $type"
    ;;
esac

# --- Compose JSON / output ---
read -r files_restored bytes_restored < <(manifest_stats "$backup_id") || { files_restored=0; bytes_restored=0; }

audit_restore "restore"

if [[ "$want_json" == "1" ]]; then
  jq -n \
    --arg id "$backup_id" \
    --arg artifact "$artifact" \
    --arg target "$restore_target" \
    --arg mode "$type" \
    --arg timestamp "$(ts)" \
    --arg dest "${dest_root:-}" \
    --argjson files "$files_restored" \
    --argjson bytes "$bytes_restored" \
    '{id: $id, mode: $mode, artifact: $artifact, target: $target, dest: $dest, timestamp: $timestamp, files_restored: $files, bytes_restored: $bytes}'
else
  echo "Restored '$backup_id' into '$restore_target' from '$artifact' ($type)."
fi
