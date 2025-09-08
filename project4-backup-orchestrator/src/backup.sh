#!/usr/bin/env bash
# Project 4: Backup & Restore Orchestrator
# backup.sh — Sprint 1: full backups (tar or directory), excludes, manifest, JSON summary, audit log.
# shellcheck shell=bash

set -euo pipefail

# --- Paths & libs ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Allow execution from /backup.sh symlink inside container
if [[ "$0" == "/backup.sh" && -x "${ROOT_DIR}/src/backup.sh" ]]; then
    exec "${ROOT_DIR}/src/backup.sh" "$@"
fi


# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/env.sh
source "${LIB_DIR}/env.sh"
# shellcheck source=lib/rsync.sh
source "${LIB_DIR}/rsync.sh" 2>/dev/null || true

# Fallback for write_manifest if not provided by common.sh
if ! declare -F write_manifest >/dev/null 2>&1; then
  write_manifest() {
    local root="$1"; local out="$2"; shift 2
    local excludes=("$@")
    (
      set -euo pipefail
      cd "$root"
      mapfile -d '' files < <(find . -type f -print0 | LC_ALL=C sort -z)
      : >"$out"
      for f in "${files[@]}"; do
        local rel="${f#./}"
        local skip=0
        for pat in "${excludes[@]}"; do
          [[ -n "$pat" ]] || continue
          [[ "$rel" == $pat ]] && { skip=1; break; }
        done
        (( skip )) && continue
        printf '%s %s\n' "$rel" "$(stat -c '%s' -- "$rel")" >>"$out"
      done
    )
  }
fi

# Collect --exclude values here (declared early so set -u is safe)
declare -a exclude_args=()

require_cmd date
require_cmd find
require_cmd tar
require_cmd rsync
require_cmd sha256sum
require_cmd jq

# --- Usage ---
usage() {
  cat <<EOF
Usage: $0 full|inc|diff [options]

Options:
  --source PATH            Source directory to back up (defaults to \$BACKUP_SRC if set)
  --dest PATH              Destination root (defaults to \$BACKUP_DEST if set)
  --format tar|dir         Output format (default: tar)
  --compress gz|zstd|none  Compression for tar format (default: gz)
  --label NAME             Optional label for the backup id
  --exclude PATTERN        Exclude glob (repeatable)
  --base ID                Base backup id (for inc/diff). If omitted, auto-discover latest.
  --env NAME               Load env/NAME (dev, prod, ...)
  --json                   Emit JSON summary to stdout (in addition to file)
  -h, --help               Show this help

Examples:
  # Full backups
  $0 full --source /data/src --dest /backups --format tar --compress gz --exclude "*.tmp" --label nightly
  $0 full --env dev --format dir

  # Incremental since the most recent backup (inc/diff detection described below)
  $0 inc  --source /data/src --dest /backups --format dir --label hourly

  # Differential since the last full backup
  $0 diff --source /data/src --dest /backups --format tar --compress gz --label daily

  # Restore examples
  $0 restore --id <BACKUP_ID> --target /restore/dir
  $0 restore --artifact /backups/ID.tar.gz --target /restore/dir

  # Scheduling helper
  $0 schedule [--full-cron "0 2 * * *"] [--inc-cron "0 * * * *"] [--rotate-cron "30 2 * * 0"] \
               [--rotate-keep-full N] [--rotate-keep-inc N] [--rotate-max-age N] \
               [--env NAME | --source PATH --dest PATH] [--format tar|dir] [--compress gz|zstd|none]
    Prints ready-to-paste crontab lines that call this script with the provided options.
    Examples:
      $0 schedule --env prod
      $0 schedule --env prod --full-cron "5 2 * * *" --inc-cron "15 * * * *" \
                  --rotate-cron "45 2 * * 0" --rotate-keep-full 7 --rotate-keep-inc 2 --rotate-max-age 30
EOF
}

# --- Defaults ---
CMD=${1:-}
[[ -n "${CMD}" ]] || { usage; exit 1; }
shift || true

format="tar"
compress="gz"
label=""
json_flag=0
source_path=""
dest_root=""

level="$CMD"            # full|inc|diff
base_id=""

# Restore-related vars
restore_id=""
restore_artifact=""
restore_target=""

# Rotation-related defaults
keep_full=0
keep_inc=0
max_age_days=0
dry_run=0

# Schedule defaults
full_cron="0 2 * * *"
inc_cron="0 * * * *"
rotate_cron="30 2 * * 0"
rotate_keep_full=7
rotate_keep_inc=1
rotate_max_age=30

# --- Parse args ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_path=${2:-}; shift 2;;
    --dest) dest_root=${2:-}; shift 2;;
    --format) format=${2:-}; shift 2;;
    --compress) compress=${2:-}; shift 2;;
    --label) label=${2:-}; shift 2;;
    --exclude) exclude_args+=("$2"); shift 2;;
    --base) base_id=${2:-}; shift 2;;
    --env) ENV_NAME=${2:-}; shift 2;;
    --json) json_flag=1; shift;;
    --id) restore_id=${2:-}; shift 2;;
    --artifact) restore_artifact=${2:-}; shift 2;;
    --target) restore_target=${2:-}; shift 2;;
    --keep-full) keep_full=${2:-0}; shift 2;;
    --keep-inc) keep_inc=${2:-0}; shift 2;;
    --max-age-days) max_age_days=${2:-0}; shift 2;;
    --dry-run) dry_run=1; shift;;
    --full-cron) full_cron=${2:-"0 2 * * *"}; shift 2;;
    --inc-cron) inc_cron=${2:-"0 * * * *"}; shift 2;;
    --rotate-cron) rotate_cron=${2:-"30 2 * * 0"}; shift 2;;
    --rotate-keep-full) rotate_keep_full=${2:-7}; shift 2;;
    --rotate-keep-inc) rotate_keep_inc=${2:-1}; shift 2;;
    --rotate-max-age) rotate_max_age=${2:-30}; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

# Build exclude option arrays for tar and rsync from any --exclude args (skip empties)
tar_excludes=()
rsync_excludes=()
for pat in "${exclude_args[@]:-}"; do
  [[ -n "$pat" ]] || continue
  tar_excludes+=("--exclude=$pat")
  rsync_excludes+=("--exclude=$pat")
done

# --- Env loading (non-fatal if missing) ---
if [[ -n "${ENV_NAME:-}" ]]; then
  if ! load_env "$ENV_NAME"; then
    warn "env '$ENV_NAME' not found; continuing with CLI args"
  fi
fi

# Fall back to env vars if CLI not provided

source_path=${source_path:-${BACKUP_SRC:-}}
dest_root=${dest_root:-${BACKUP_DEST:-}}

# Create logs/outputs always (these are inside the repo and writable)
ensure_dir "${ROOT_DIR}/logs"
ensure_dir "${ROOT_DIR}/outputs"

# Only ensure destination root for backup commands; for restore or schedule we do not mkdir on --dest
if [[ "$CMD" != "restore" && "$CMD" != "schedule" ]]; then
  [[ -n "$dest_root" ]] || die "--dest required"
  ensure_dir "$dest_root"
fi
# --- Helper to escape cron args ---
cron_escape() {
  local s="$1"
  case "$s" in
    *[[:space:]\|\&\;\<\>\(\)\$\`\"\'\*\?\[\]]*)
      # Escape any existing single quotes within the string for safe single-quoting.
      local esc
      esc=$(printf '%s' "$s" | sed "s/'/'\"'\"'/g")
      printf "'%s'" "$esc"
      ;;
    *)
      printf '%s' "$s"
      ;;
  esac
}

# --- Restore helpers ---
resolve_artifact_by_id() {
  local id="$1" dest="$2"
  local base="$dest/$id"
  # Prefer directory snapshot if present
  if [[ -d "$base" ]]; then
    printf '%s|dir\n' "$base"
    return 0
  fi
  # Try known tar names
  if [[ -f "$base.tar.gz" ]]; then
    printf '%s|tar_gz\n' "$base.tar.gz"; return 0
  fi
  if [[ -f "$base.tar.zst" ]]; then
    printf '%s|tar_zst\n' "$base.tar.zst"; return 0
  fi
  if [[ -f "$base.tar" ]]; then
    printf '%s|tar\n' "$base.tar"; return 0
  fi
  return 1
}

# --- Helpers for base discovery ---
list_backups_in_dest() {
  local dest="$1"
  # list directories and tar artifacts that look like IDs
  find "$dest" -maxdepth 1 -mindepth 1 -printf "%f\n" 2>/dev/null | sort
}

find_latest_full_id() {
  local dest="$1"
  # A "full" can be either a directory named like ID[_label] or a tar(.gz|.zst) starting with ID
  # We can't perfectly infer "full" vs "inc/diff" just from filenames; we will use the presence
  # of a corresponding summary.json in outputs to check its "level":"full".
  local latest=""
  local outputs_dir="${ROOT_DIR}/outputs"
  while IFS= read -r id; do
    # normalize id (strip extensions if tar file)
    id="${id%.tar}"
    id="${id%.tar.gz}"
    id="${id%.tar.zst}"
    local summary="${outputs_dir}/${id}/summary.json"
    if [[ -f "$summary" ]] && jq -e '.level == "full"' <"$summary" >/dev/null 2>&1; then
      latest="$id"
    fi
  done < <(list_backups_in_dest "$dest")
  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

find_latest_any_id() {
  local dest="$1"
  local latest=""
  local outputs_dir="${ROOT_DIR}/outputs"
  while IFS= read -r id; do
    id="${id%.tar}"
    id="${id%.tar.gz}"
    id="${id%.tar.zst}"
    if [[ -f "${outputs_dir}/${id}/summary.json" ]]; then
      latest="$id"
    fi
  done < <(list_backups_in_dest "$dest")
  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

# --- JSON summary writer ---
write_summary_json() {
  local json_path=$1; shift
  local mode=$1; shift            # tar|dir
  local comp=$1; shift            # gz|zstd|none
  local src=$1; shift
  local dest=$1; shift
  local artifact=$1; shift
  local manifest=$1; shift
  local level_field=$1; shift     # full|inc|diff
  local base_field=$1; shift      # base id or empty

  local file_count total_bytes
  file_count=$(awk 'END{print NR}' "$manifest")
  total_bytes=$(awk '{s+=$2} END{print s+0}' "$manifest")

  jq -n --arg id "$backup_id" \
        --arg mode "$mode" \
        --arg compress "$comp" \
        --arg source "$src" \
        --arg dest "$dest" \
        --arg artifact "$artifact" \
        --arg manifest "$manifest" \
        --arg timestamp "$(ts)" \
        --arg level "$level_field" \
        --arg base_id "$base_field" \
        --argjson files "$file_count" \
        --argjson bytes "$total_bytes" \
        '{id: $id, level: $level, base_id: $base_id, mode: $mode, compress: $compress, source: $source, dest: $dest, artifact: $artifact, manifest: $manifest, timestamp: $timestamp, files: $files, bytes: $bytes}' \
        > "$json_path"
}

# --- Audit helper ---
audit_line() {
  local action=$1; shift
  printf '%s %s id=%s src=%s dest=%s %s\n' "$(ts)" "$action" "$backup_id" "$source_path" "$dest_root" "${1:+artifact=$1}"
}

artifact_for_id() {
  local id="$1" dest="$2"
  local base="$dest/$id"
  if [[ -d "$base" ]]; then
    printf '%s|dir\n' "$base"; return 0
  fi
  if [[ -f "$base.tar.gz" ]]; then printf '%s|tar_gz\n' "$base.tar.gz"; return 0; fi
  if [[ -f "$base.tar.zst" ]]; then printf '%s|tar_zst\n' "$base.tar.zst"; return 0; fi
  if [[ -f "$base.tar" ]]; then printf '%s|tar\n' "$base.tar"; return 0; fi
  return 1
}

id_sort_key() {
  # IDs are already sortable lexicographically (YYYYMMDDTHHMMSSZ[_label])
  # Strip label for pure chronological comparisons.
  local id="$1"
  printf '%s\n' "${id%%_*}"
}

# --- Execute command ---
case "$CMD" in
  restore)
    # Validate inputs
    [[ -n "$restore_target" ]] || die "--target required for restore"
    # Do not attempt to create the restore target; require caller to provide an existing, writable dir
    if [[ ! -d "$restore_target" ]]; then
      die "restore target '$restore_target' does not exist or is not a directory; create it and re-run"
    fi
    if [[ ! -w "$restore_target" ]]; then
      die "restore target '$restore_target' is not writable (read-only filesystem?)"
    fi

    art=""
    type=""
    if [[ -n "$restore_artifact" ]]; then
      art="$restore_artifact"
      if [[ -d "$art" ]]; then type="dir";
      elif [[ "$art" == *.tar.gz ]]; then type="tar_gz";
      elif [[ "$art" == *.tar.zst ]]; then type="tar_zst";
      elif [[ "$art" == *.tar ]]; then type="tar";
      else die "unknown artifact type: $art"; fi
      # Derive backup_id from filename or directory name (strip in correct order)
      backup_id="$(basename -- "$art")"
      backup_id="${backup_id%.tar.gz}"
      backup_id="${backup_id%.tar.zst}"
      backup_id="${backup_id%.tar}"
    else
      [[ -n "$restore_id" ]] || die "provide --id or --artifact"
      # When using --id, require a readable --dest but do NOT create it (might be read-only)
      [[ -n "$dest_root" ]] || die "--dest required when using --id"
      [[ -d "$dest_root" ]] || die "destination root '$dest_root' not found or not a directory"

      # Strip extensions in the correct order for lookup consistency
      rid="$restore_id"
      rid="${rid%.tar.gz}"
      rid="${rid%.tar.zst}"
      rid="${rid%.tar}"

      resolved=""
      if ! resolved="$(resolve_artifact_by_id "$rid" "$dest_root")"; then
        die "could not locate artifact for id '$rid' under '$dest_root'"
      fi
      art="${resolved%|*}"; type="${resolved#*|}"
      backup_id="$rid"
    fi

    case "$type" in
      dir)
        log_info "Restoring directory snapshot '$backup_id' to $restore_target"
        rsync -a --delete "${art}/" "$restore_target/"
        ;;
      tar_gz)
        log_info "Restoring tar.gz '$backup_id' to $restore_target"
        tar -xpf "$art" -C "$restore_target" -z
        ;;
      tar_zst)
        log_info "Restoring tar.zst '$backup_id' to $restore_target"
        tar --use-compress-program=zstd -xpf "$art" -C "$restore_target"
        ;;
      tar)
        log_info "Restoring tar '$backup_id' to $restore_target"
        tar -xpf "$art" -C "$restore_target"
        ;;
      *) die "unsupported artifact type: $type";;
    esac

    # Write a minimal restore summary (optional JSON)
    meta_dir="${ROOT_DIR}/outputs/${backup_id}"
    ensure_dir "$meta_dir"
    restore_json="$meta_dir/restore_${backup_id}.json"
    jq -n --arg id "$backup_id" \
          --arg target "$restore_target" \
          --arg artifact "$art" \
          --arg timestamp "$(ts)" \
          '{action:"restore", id:$id, target:$target, artifact:$artifact, timestamp:$timestamp}' >"$restore_json"

    # Audit
    ensure_dir "${ROOT_DIR}/logs"
    audit_log="${ROOT_DIR}/logs/audit.log"
    audit_line "restore" "$art" >> "$audit_log"

    if (( json_flag == 1 )); then
      cat "$restore_json"
    else
      ok "Restore complete: id=$backup_id -> $restore_target"
    fi
    exit 0
    ;;
  full)
    # Initialize backup id, metadata dirs, and exclude arrays
    ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
    backup_id="$ts_utc"
    [[ -n "$label" ]] && backup_id+="_${label}"

    art_dir="${dest_root}/${backup_id}"
    meta_dir="${ROOT_DIR}/outputs/${backup_id}"
    ensure_dir "$meta_dir"

    if [[ "$format" == "tar" ]]; then
      # artifact path
      case "$compress" in
        gz)   artifact="${dest_root}/${backup_id}.tar.gz"; tar_comp_flag="-z";;
        zstd) artifact="${dest_root}/${backup_id}.tar.zst"; tar_comp_flag="--use-compress-program=zstd";;
        none) artifact="${dest_root}/${backup_id}.tar"; tar_comp_flag="";;
        *) die "unknown --compress: $compress";;
      esac

      # Create tar from source with excludes
      log_info "Creating tar artifact: $artifact"
      ensure_dir "$(dirname "$artifact")"
      (
        cd "${source_path}" >/dev/null
        # build tar args
        if [[ "$compress" == "gz" ]]; then
          tar -cpf - ${tar_excludes[@]:-} . | gzip -c > "$artifact"
        elif [[ "$compress" == "zstd" ]]; then
          tar -cpf - ${tar_excludes[@]:-} . | zstd -q -z -T0 -o "$artifact"
        else
          tar -cpf "$artifact" ${tar_excludes[@]:-} .
        fi
      )

      # Save a baseline SNAR file for tar full so future inc/diff can reference it
      if [[ "$format" == "tar" ]]; then
        snar_path="${meta_dir}/tar.snar"
        # Create an initial snapshot file by scanning the tree once (no archive output)
        # We do this by creating an empty archive to /dev/null which updates the snar.
        ( cd "${source_path}" && tar --listed-incremental="$snar_path" -cpf - ${tar_excludes[@]:-} . >/dev/null )
      fi

      # For manifest, compute against source tree (it mirrors content of tar)
      manifest_path="${meta_dir}/manifest.txt"
      log_info "Writing manifest: $manifest_path"
      write_manifest "$source_path" "$manifest_path" "${exclude_args[@]:-}"

      # Summary JSON
      summary_json="${meta_dir}/summary.json"
      write_summary_json "$summary_json" "$format" "$compress" "$source_path" "$dest_root" "$artifact" "$manifest_path" "full" ""

    elif [[ "$format" == "dir" ]]; then
      artifact="$art_dir"
      ensure_dir "$artifact"
      log_info "Syncing directory snapshot to: $artifact"
      if declare -F rsync_full_snapshot_dir >/dev/null; then
        rsync_full_snapshot_dir "${source_path}" "$artifact" "${exclude_args[*]:-}"
      else
        rsync -a --delete ${rsync_excludes[@]:-} "${source_path}/" "$artifact/"
      fi

      manifest_path="${meta_dir}/manifest.txt"
      log_info "Writing manifest: $manifest_path"
      write_manifest "$artifact" "$manifest_path" "${exclude_args[@]:-}"

      summary_json="${meta_dir}/summary.json"
      write_summary_json "$summary_json" "$format" "$compress" "$source_path" "$dest_root" "$artifact" "$manifest_path" "full" ""

    else
      die "unknown --format: $format"
    fi

    # Audit log
    ensure_dir "${ROOT_DIR}/logs"
    audit_log="${ROOT_DIR}/logs/audit.log"
    audit_line "backup-full" "$artifact" >> "$audit_log"
    if (( json_flag == 0 )); then
      ok "Backup complete: id=$backup_id"
    fi

    # Emit JSON to stdout if requested (use clean FD 3)
    if (( json_flag == 1 )); then
      cat "$summary_json"
    fi
    exit 0
    ;;

  inc)
    # Determine base id: prefer --base, else latest any
    if [[ -z "$base_id" ]]; then
      base_id="$(find_latest_any_id "$dest_root" || true)"
    fi
    [[ -n "$base_id" ]] || die "no base backup found; provide --base ID"

    # Paths for metadata/artifacts
    ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
    backup_id="${ts_utc}"
    [[ -n "$label" ]] && backup_id+="_${label}"
    art_dir="${dest_root}/${backup_id}"
    meta_dir="${ROOT_DIR}/outputs/${backup_id}"
    ensure_dir "$meta_dir"

    if [[ "$format" == "dir" ]]; then
      # rsync snapshot using --link-dest to previous backup directory
      # Resolve base path: if the base artifact is a tar, we cannot hardlink; require base dir snapshot.
      base_path="${dest_root}/${base_id}"
      [[ -d "$base_path" ]] || die "base '$base_id' is not a directory snapshot; use diff with tar or provide a dir base"
      artifact="$art_dir"
      ensure_dir "$artifact"
      log_info "Incremental snapshot to: $artifact (base=$base_id)"
      if declare -F rsync_incremental_snapshot_dir >/dev/null; then
        rsync_incremental_snapshot_dir "${source_path}" "$artifact" "$base_path" "${exclude_args[*]:-}"
      else
        rsync -a --delete ${rsync_excludes[@]:-} --link-dest="$base_path" "${source_path}/" "$artifact/"
      fi
      manifest_path="${meta_dir}/manifest.txt"
      log_info "Writing manifest: $manifest_path"
      write_manifest "$artifact" "$manifest_path" "${exclude_args[@]:-}"
      summary_json="${meta_dir}/summary.json"
      write_summary_json "$summary_json" "$format" "$compress" "$source_path" "$dest_root" "$artifact" "$manifest_path" "inc" "$base_id"

    elif [[ "$format" == "tar" ]]; then
      # tar incremental using --listed-incremental, based on previous snapshot file
      base_snar="${ROOT_DIR}/outputs/${base_id}/tar.snar"
      [[ -f "$base_snar" ]] || die "base snar not found for '$base_id' (expected ${base_snar})"
      case "$compress" in
        gz)   artifact="${dest_root}/${backup_id}.tar.gz";;
        zstd) artifact="${dest_root}/${backup_id}.tar.zst";;
        none) artifact="${dest_root}/${backup_id}.tar";;
        *) die "unknown --compress: $compress";;
      esac
      ensure_dir "$(dirname "$artifact")"
      work_snar="${meta_dir}/tar.snar"
      cp -f "$base_snar" "$work_snar"
      log_info "Creating tar incremental: $artifact (base=$base_id)"
      if [[ "$compress" == "gz" ]]; then
        ( cd "${source_path}" && tar --listed-incremental="$work_snar" -cpf - ${tar_excludes[@]:-} . | gzip -c > "$artifact" )
      elif [[ "$compress" == "zstd" ]]; then
        ( cd "${source_path}" && tar --listed-incremental="$work_snar" -cpf - ${tar_excludes[@]:-} . | zstd -q -z -T0 -o "$artifact" )
      else
        ( cd "${source_path}" && tar --listed-incremental="$work_snar" -cpf "$artifact" ${tar_excludes[@]:-} . )
      fi
      manifest_path="${meta_dir}/manifest.txt"
      log_info "Writing manifest: $manifest_path"
      write_manifest "$source_path" "$manifest_path" "${exclude_args[@]:-}"
      summary_json="${meta_dir}/summary.json"
      write_summary_json "$summary_json" "$format" "$compress" "$source_path" "$dest_root" "$artifact" "$manifest_path" "inc" "$base_id"
    else
      die "unknown --format: $format"
    fi

    ensure_dir "${ROOT_DIR}/logs"
    audit_log="${ROOT_DIR}/logs/audit.log"
    audit_line "backup-inc" "$artifact" >> "$audit_log"
    (( json_flag == 0 )) && ok "Incremental complete: id=$backup_id base=$base_id"
    (( json_flag == 1 )) && cat "$summary_json"
    exit 0
    ;;

  diff)
    # Determine base id: prefer --base, else latest full
    if [[ -z "$base_id" ]]; then
      base_id="$(find_latest_full_id "$dest_root" || true)"
    fi
    [[ -n "$base_id" ]] || die "no full base backup found; provide --base ID"

    ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
    backup_id="${ts_utc}"
    [[ -n "$label" ]] && backup_id+="_${label}"
    art_dir="${dest_root}/${backup_id}"
    meta_dir="${ROOT_DIR}/outputs/${backup_id}"
    ensure_dir "$meta_dir"

    if [[ "$format" == "dir" ]]; then
      base_path="${dest_root}/${base_id}"
      [[ -d "$base_path" ]] || die "base '$base_id' is not a directory snapshot; use tar diff or provide dir base"
      artifact="$art_dir"
      ensure_dir "$artifact"
      log_info "Differential snapshot to: $artifact (base(full)=$base_id)"
      if declare -F rsync_diff_snapshot_dir >/dev/null; then
        rsync_diff_snapshot_dir "${source_path}" "$artifact" "$base_path" "${exclude_args[*]:-}"
      else
        rsync -a --delete ${rsync_excludes[@]:-} --link-dest="$base_path" "${source_path}/" "$artifact/"
      fi
      manifest_path="${meta_dir}/manifest.txt"
      log_info "Writing manifest: $manifest_path"
      write_manifest "$artifact" "$manifest_path" "${exclude_args[@]:-}"
      summary_json="${meta_dir}/summary.json"
      write_summary_json "$summary_json" "$format" "$compress" "$source_path" "$dest_root" "$artifact" "$manifest_path" "diff" "$base_id"

    elif [[ "$format" == "tar" ]]; then
      base_snar="${ROOT_DIR}/outputs/${base_id}/tar.snar"
      [[ -f "$base_snar" ]] || die "full base snar not found for '$base_id' (expected ${base_snar})"
      case "$compress" in
        gz)   artifact="${dest_root}/${backup_id}.tar.gz";;
        zstd) artifact="${dest_root}/${backup_id}.tar.zst";;
        none) artifact="${dest_root}/${backup_id}.tar";;
        *) die "unknown --compress: $compress";;
      esac
      ensure_dir "$(dirname "$artifact")"
      work_snar="${meta_dir}/tar.snar"
      cp -f "$base_snar" "$work_snar"
      log_info "Creating tar differential: $artifact (base(full)=${base_id})"
      if [[ "$compress" == "gz" ]]; then
        ( cd "${source_path}" && tar --listed-incremental="$work_snar" -cpf - ${tar_excludes[@]:-} . | gzip -c > "$artifact" )
      elif [[ "$compress" == "zstd" ]]; then
        ( cd "${source_path}" && tar --listed-incremental="$work_snar" -cpf - ${tar_excludes[@]:-} . | zstd -q -z -T0 -o "$artifact" )
      else
        ( cd "${source_path}" && tar --listed-incremental="$work_snar" -cpf "$artifact" ${tar_excludes[@]:-} . )
      fi
      manifest_path="${meta_dir}/manifest.txt"
      log_info "Writing manifest: $manifest_path"
      write_manifest "$source_path" "$manifest_path" "${exclude_args[@]:-}"
      summary_json="${meta_dir}/summary.json"
      write_summary_json "$summary_json" "$format" "$compress" "$source_path" "$dest_root" "$artifact" "$manifest_path" "diff" "$base_id"
    else
      die "unknown --format: $format"
    fi

    ensure_dir "${ROOT_DIR}/logs"
    audit_log="${ROOT_DIR}/logs/audit.log"
    audit_line "backup-diff" "$artifact" >> "$audit_log"
    (( json_flag == 0 )) && ok "Differential complete: id=$backup_id base=$base_id"
    (( json_flag == 1 )) && cat "$summary_json"
    exit 0
    ;;

  rotate)
    [[ -n "$dest_root" ]] || die "--dest required for rotate"
    # Gather all known backups in dest with their metadata
    mapfile -t raw_items < <(list_backups_in_dest "$dest_root")
    declare -A level_by_id
    declare -A art_by_id
    declare -A type_by_id
    ids=()

    for item in "${raw_items[@]}"; do
      id="$item"
      id="${id%.tar.gz}"; id="${id%.tar.zst}"; id="${id%.tar}"
      # artifact path & type
      if resolved="$(artifact_for_id "$id" "$dest_root")"; then
        art="${resolved%|*}"; typ="${resolved#*|}"
        art_by_id["$id"]="$art"
        type_by_id["$id"]="$typ"
      else
        # skip items without recognizable artifact
        continue
      fi
      # level from summary.json (required to decide full/inc)
      summary="${ROOT_DIR}/outputs/${id}/summary.json"
      if [[ -f "$summary" ]]; then
        lvl="$(jq -r '.level // ""' "$summary" 2>/dev/null || true)"
      else
        lvl=""
      fi
      # Fallback: if unknown, assume 'full' for directories, otherwise empty
      if [[ -z "$lvl" ]]; then
        if [[ "${type_by_id[$id]}" == "dir" ]]; then
          lvl="full"
        else
          lvl=""
        fi
      fi
      level_by_id["$id"]="$lvl"
      ids+=("$id")
    done

    # Sort ids chronologically by their leading timestamp
    IFS=$'\n' sorted_ids=($(printf '%s\n' "${ids[@]}" | awk '{print $0}' | sort))
    unset IFS

    # Build list of full ids in order
    full_ids=()
    for id in "${sorted_ids[@]}"; do
      [[ "${level_by_id[$id]}" == "full" ]] && full_ids+=("$id")
    done

    # Determine which IDs to delete
    declare -A delete_map=()

    # Rule 1: keep last N FULLs
    if (( keep_full > 0 )); then
      n_full=${#full_ids[@]}
      if (( n_full > keep_full )); then
        # mark older fulls (and anything strictly older than the first kept full) for deletion by age window
        first_kept_full="${full_ids[$((n_full-keep_full))]}"
        for id in "${sorted_ids[@]}"; do
          # anything older than first_kept_full gets eligible for deletion (subject to other rules)
          if [[ "$(id_sort_key "$id")" < "$(id_sort_key "$first_kept_full")" ]]; then
            delete_map["$id"]=1
          fi
        done
      fi
    fi

    # Rule 2: within each span between FULLs, keep only last K incrementals
    if (( keep_inc > 0 )); then
      # Walk segments: from full_i (inclusive) to just before full_{i+1}
      for (( i=0; i<${#full_ids[@]}; i++ )); do
        seg_start="${full_ids[$i]}"
        seg_end_key="Z"  # beyond any timestamp
        if (( i+1 < ${#full_ids[@]} )); then
          seg_end_key="$(id_sort_key "${full_ids[$((i+1))]}")"
        fi
        # collect incs in this segment
        seg_incs=()
        for id in "${sorted_ids[@]}"; do
          key="$(id_sort_key "$id")"
          if [[ "$key" < "$(id_sort_key "$seg_start")" ]] || [[ "$key" > "$seg_end_key" ]] || [[ "$key" == "$seg_end_key" ]]; then
            continue
          fi
          if [[ "${level_by_id[$id]}" == "inc" ]]; then
            seg_incs+=("$id")
          fi
        done
        # if more than keep_inc, mark older ones for deletion
        if (( ${#seg_incs[@]} > keep_inc )); then
          # keep the last keep_inc; delete the rest
          for (( j=0; j<${#seg_incs[@]}-keep_inc; j++ )); do
            delete_map["${seg_incs[$j]}"]=1
          done
        fi
      done
    fi

    # Rule 3: max-age-days pruning
    if (( max_age_days > 0 )); then
      now_epoch=$(date -u +%s)
      cutoff_epoch=$(date -u -d "-${max_age_days} days" +%s)
      for id in "${sorted_ids[@]}"; do
        art="${art_by_id[$id]}"
        # prefer filesystem mtime for age
        if [[ -e "$art" ]]; then
          mtime_epoch=$(date -u -r "$art" +%s 2>/dev/null || stat -c %Y "$art" 2>/dev/null || echo "$now_epoch")
          if (( mtime_epoch < cutoff_epoch )); then
            delete_map["$id"]=1
          fi
        fi
      done
    fi

    # Compute final deletion list (ids where delete_map set)
    pruned_ids=()
    for id in "${sorted_ids[@]}"; do
      if [[ -n "${delete_map[$id]:-}" ]] && [[ "${delete_map[$id]}" -eq 1 ]]; then
        pruned_ids+=("$id")
      fi
    done

    # Execute deletions
    for id in "${pruned_ids[@]}"; do
      art="${art_by_id[$id]}"
      outdir="${ROOT_DIR}/outputs/${id}"
      if (( dry_run == 1 )); then
        log_info "[dry-run] would remove '$art' and '$outdir'"
        continue
      fi
      if [[ -d "$art" ]]; then
        rm -rf -- "$art"
      else
        rm -f -- "$art" "$art.tar" "$art.tar.gz" "$art.tar.zst" 2>/dev/null || true
      fi
      rm -rf -- "$outdir"
    done

    # Audit
    ensure_dir "${ROOT_DIR}/logs"
    audit_log="${ROOT_DIR}/logs/audit.log"
    backup_id="rotation"
    audit_line "rotate" "kept_full=${keep_full} kept_inc=${keep_inc} max_age_days=${max_age_days}" >> "$audit_log"

    if (( json_flag == 1 )); then
      jq -n --argjson deleted "$(printf '%s\n' "${pruned_ids[@]:-}" | jq -R . | jq -s .)" \
            --arg kept_full "$keep_full" \
            --arg kept_inc "$keep_inc" \
            --arg max_age_days "$max_age_days" \
            '{deleted:$deleted, kept_full:($kept_full|tonumber), kept_inc:($kept_inc|tonumber), max_age_days:($max_age_days|tonumber)}'
    else
      ok "Rotation complete: deleted ${#pruned_ids[@]} backups"
    fi
    exit 0
    ;;

  schedule)
    # We only print cron lines; we do not install them.
    # Require either --env NAME, or both --source and --dest to construct commands.
    if [[ -z "${ENV_NAME:-}" && ( -z "$source_path" || -z "$dest_root" ) ]]; then
      die "schedule: provide --env NAME or both --source and --dest"
    fi
    # Build the common flags that represent the environment/config
    common_flags=()
    if [[ -n "${ENV_NAME:-}" ]]; then
      common_flags+=(--env "$(cron_escape "$ENV_NAME")")
    else
      common_flags+=(--source "$(cron_escape "$source_path")" --dest "$(cron_escape "$dest_root")")
    fi
    # Add optional format/compress/label/excludes to the scheduled commands
    [[ -n "$format" ]] && common_flags+=(--format "$(cron_escape "$format")")
    [[ -n "$compress" ]] && common_flags+=(--compress "$(cron_escape "$compress")")
    for pat in "${exclude_args[@]:-}"; do
      [[ -n "$pat" ]] && common_flags+=(--exclude "$(cron_escape "$pat")")
    done

    script_path="${ROOT_DIR}/src/backup.sh"
    log_dir="${ROOT_DIR}/logs"
    ensure_dir "$log_dir"

    # Print a header and three cron lines
    echo "# Add the following to crontab (crontab -e). Uses bash and logs to ${log_dir}."
    echo "SHELL=/bin/bash"
    echo "MAILTO="

    # FULL line
    printf '%s %q full %s --json >> %q 2>&1\n' \
      "$full_cron" "$script_path" "$(printf '%s ' "${common_flags[@]}")" "${log_dir}/full.log"

    # INCREMENTAL line
    printf '%s %q inc %s --json >> %q 2>&1\n' \
      "$inc_cron" "$script_path" "$(printf '%s ' "${common_flags[@]}")" "${log_dir}/inc.log"

    # ROTATION line
    printf '%s %q rotate %s --keep-full %d --keep-inc %d --max-age-days %d >> %q 2>&1\n' \
      "$rotate_cron" "$script_path" "$(printf '%s ' "${common_flags[@]}")" \
      "$rotate_keep_full" "$rotate_keep_inc" "$rotate_max_age" "${log_dir}/rotate.log"

    exit 0
    ;;
  *)
    usage; die "unknown command: $CMD";;
esac
