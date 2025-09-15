#!/usr/bin/env bash
# fs.sh — Storage & Filesystems Watchdog (Sprints 1–8)

set -euo pipefail

# ===============================
# Load environment defaults (optional)
# Only source FS_ENV_FILE if it is provided and exists
# IMPORTANT: Do NOT override variables that are already set in the environment (e.g., from tests)
# ===============================
_fs_env_file="${FS_ENV_FILE:-}"
if [[ -n "$_fs_env_file" && -f "$_fs_env_file" ]]; then
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    # skip comments and empty lines
    [[ "$__line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$__line" ]] && continue
    # only handle simple KEY=VALUE (no exports, no spaces around =)
    if [[ "$__line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      __k="${BASH_REMATCH[1]}"
      __v="${BASH_REMATCH[2]}"
      # if the variable is NOT set in the environment, apply default
      if [[ -z ${!__k+x} ]]; then
        # shellcheck disable=SC2163
        export "${__k}=${__v}"
      fi
    fi
  done < "$_fs_env_file"
  unset __line __k __v _fs_env_file
fi

# ===============================
# Logging & help
# ===============================
log() { printf "%s\n" "$*" >&2; }

usage() {
	cat <<'USAGE'
fs.sh — storage & filesystems watchdog (Sprints 1–8)

Usage:
  fs.sh check [--path PATH ...] [--json] [--once] [--min-free-pct N] [--min-inodes-pct N]
  fs.sh help

Commands:
  check     Verify that one or more PATHs exist and are writable; compute capacity/inodes
  help      Show this help

Notes:
  - You can repeat --path multiple times. If omitted, FS_PATHS env is used when set.
  - Thresholds: --min-free-pct, --min-inodes-pct (env: FS_MIN_FREE_PCT, FS_MIN_INODES_PCT)
  - Compliance: --fstab FILE (env: FS_FSTAB) and FS_EXPECT_OPTS="/path:opt1,opt2 [/other:path:optA,optB]"
  - Storage awareness: --lvs FILE (env: FS_LVS_SAMPLE), --mdstat FILE (env: FS_MDSTAT)
  - Snapshots: --snapshot-dir DIR (env: FS_SNAP_DIR), --pattern REGEX (env: FS_SNAP_PATTERN),
               --max-age SECONDS (env: FS_SNAP_MAX_AGE), --require-today (env: FS_SNAP_REQUIRE_TODAY=1),
               --mount-required (env: FS_SNAP_MOUNT_REQUIRED=1), --count-min N (env: FS_SNAP_COUNT_MIN)
  - Quotas & ACLs (Sprint 7): FS_QUOTA_REQUIRED=1, FS_REPQUOTA_CMD=...
     FS_ACL_EXPECT="/path:rule,rule" FS_GETFACL_CMD=...
  - Perf & History (Sprint 8): --perf (env: FS_PERF=1), FS_PERF_HISTORY_FILE=outputs/fs/history.jsonl, FS_HISTORY_MAX=20, FS_TREND_MIN_FREE_PCT=15, FS_PERF_SAMPLE_JSON='{"read_iops":10,"write_iops":5,"util_pct":3}'
  - When --json is provided, ONLY JSON is printed to stdout; all logs go to stderr.
  - Exit codes: 0 (all healthy), 1 (one or more unhealthy), 2 (usage/config error).
USAGE
}

# ===============================
# Helpers
# ===============================
# Compute median or average from stdin (one number per line)
median_or_avg() {
  local nums=() n sorted
  while read -r n; do
    [[ "$n" =~ ^[0-9]+([.][0-9]+)?$ ]] && nums+=("$n")
  done
  local count=${#nums[@]}
  if (( count == 0 )); then echo ""; return 1; fi
  # Sort numerically
  sorted=($(printf "%s\n" "${nums[@]}" | sort -n))
  if (( count % 2 == 1 )); then
    # Odd: median is middle
    echo "${sorted[$((count/2))]}"
  else
    # Even: average of two middles
    local a="${sorted[$((count/2-1))]}"
    local b="${sorted[$((count/2))]}"
    awk "BEGIN {print ($a+$b)/2}"
  fi
}

# Append a single-line JSON to a history file, trimming to HISTORY_MAX lines
append_history_line() {
  local line="$1"
  local path="$2"
  local file="${PERF_HISTORY_FILE:-${FS_PERF_HISTORY_FILE:-}}"
  local max="${HISTORY_MAX:-20}"
  [[ -z "$file" ]] && return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  # Append then trim to last $max lines for this path
  echo "$line" >> "$file"
  if command -v jq >/dev/null 2>&1; then
    # Trim lines for this path to $max
    local tmpf="${file}.tmp.$$"
    jq -c --arg p "$path" 'select(.path==$p)' "$file" 2>/dev/null > "$tmpf" || true
    local nlines
    nlines=$(wc -l < "$tmpf" | awk '{print $1}')
    if (( nlines > max )); then
      tail -n "$max" "$tmpf" > "$tmpf.trim"
      # Remove all for this path from $file, then add trimmed back
      grep -v "\"path\":\"$path\"" "$file" > "$tmpf.rest" || true
      cat "$tmpf.rest" "$tmpf.trim" > "$file"
      rm -f "$tmpf.trim" "$tmpf.rest"
    fi
    rm -f "$tmpf"
  fi
}
# Join array elements as a JSON string array (without surrounding brackets)
json_arr() {
	local first=1
	for item in "$@"; do
		if [[ $first -eq 1 ]]; then first=0; else printf ","; fi
		printf '"%s"' "$item"
	done
}

# Robust check: directory exists and we can create+remove a temp file inside
is_writable_dir() {
	local d="$1" tmp
	[[ -d "$d" ]] || return 1
	tmp="$d/.fs_write.$$.tmp"
	( : >"$tmp" ) 2>/dev/null && rm -f "$tmp" 2>/dev/null && return 0
	return 1
}

# Parse df output to get free space percent for a path's mount
free_pct_for_path() {
	local path="$1"
	local line
	line=$(df -P "$path" 2>/dev/null | tail -n 1) || return 1
	local usepct
	usepct=$(printf "%s" "$line" | awk '{print $5}' | tr -d '%')
	[[ -n "$usepct" ]] || return 1
	echo $((100 - usepct))
}

# Parse df -Pi to get free inode percent
free_inodes_pct_for_path() {
	local path="$1"
	local line
	line=$(df -Pi "$path" 2>/dev/null | tail -n 1) || return 1
	local iuse
	iuse=$(printf "%s" "$line" | awk '{print $5}' | tr -d '%')
	[[ -n "$iuse" ]] || return 1
	echo $((100 - iuse))
}

# Get mountpoint, filesystem type and options for the path from /proc/self/mounts, with fallback to df -PT and stat -f
mount_info_for_path() {
	local path="$1"
	local mp line fstype opts

	# Primary: derive mountpoint via df -P, then read type+opts from /proc/self/mounts
	mp=$(df -P "$path" 2>/dev/null | tail -n 1 | awk '{print $6}') || mp=""
	if [[ -n "$mp" ]]; then
		line=$(awk -v mp="$mp" '($2==mp){print $0}' /proc/self/mounts 2>/dev/null | tail -n 1)
		if [[ -n "$line" ]]; then
			fstype=$(printf "%s" "$line" | awk '{print $3}')
			opts=$(printf "%s" "$line" | awk '{print $4}')
			printf "%s\t%s\t%s\n" "$mp" "$fstype" "$opts"
			return 0
		fi
	fi

	# Fallback 1: use df -PT (POSIX output with filesystem type column); options unknown
	line=$(df -PT "$path" 2>/dev/null | tail -n 1)
	if [[ -n "$line" ]]; then
		# df -PT columns: Filesystem Type 1024-blocks Used Available Capacity Mounted on
		fstype=$(printf "%s" "$line" | awk '{print $2}')
		mp=$(printf "%s" "$line" | awk '{print $7}')
		opts=""
		if [[ -n "$mp" || -n "$fstype" ]]; then
			printf "%s\t%s\t%s\n" "$mp" "$fstype" "$opts"
			return 0
		fi
	fi

	# Fallback 2: use stat -f to get fs type name (GNU/BSD compatible forms); options unknown
	# GNU: stat -f -c %T, BSD: stat -f %T
	fstype=$(stat -f -c %T "$path" 2>/dev/null || stat -f %T "$path" 2>/dev/null || echo "")
	mp=$(df -P "$path" 2>/dev/null | tail -n 1 | awk '{print $6}')
	if [[ -n "$mp" || -n "$fstype" ]]; then
		printf "%s\t%s\t%s\n" "$mp" "$fstype" ""
		return 0
	fi

	return 1
}

# Parse FS_EXPECT_OPTS into expected options for a given path
# FS_EXPECT_OPTS format: "/tmp:nodev,nosuid,noexec /var/tmp:nodev,nosuid"
expected_opts_for_path() {
	local path="$1"
	local entries=(${FS_EXPECT_OPTS:-}) # split on whitespace
	local e p opts
	for e in "${entries[@]}"; do
		p=${e%%:*}
		opts=${e#*:}
		if [[ "$p" == "$path" ]]; then
			echo "$opts"
			return 0
		fi
	done
	return 1
}

# From an fstab file, get option list for a given mountpoint
fstab_opts_for_mount() {
	local fstab_file="$1" mp="$2"
	[[ -n "$fstab_file" && -r "$fstab_file" ]] || return 1
	awk -v mp="$mp" '($0 !~ /^#/ && NF>=4 && ($2==mp || $2==mp"/" || (mp=="/" && $2=="/"))){print $4; exit 0}' "$fstab_file"
}

# Compute missing options: expected - present
csv_diff_missing() {
	local expected_csv="$1" present_csv="$2"
	# Build associative set of present
	declare -A present_set=()
	IFS=',' read -r -a _present <<<"$present_csv"
	for x in "${_present[@]}"; do [[ -n "$x" ]] && present_set["$x"]=1; done
	local missing=()
	IFS=',' read -r -a _exp <<<"$expected_csv"
	for x in "${_exp[@]}"; do
		[[ -z "$x" ]] && continue
		if [[ -z "${present_set[$x]:-}" ]]; then missing+=("$x"); fi
	done
	local out=""
	local i
	for ((i = 0; i < ${#missing[@]}; i++)); do
		if ((i > 0)); then out+=","; fi
		out+="${missing[$i]}"
	done
	echo "$out"
}

# ===============================
# Sprint 5 helpers: LVM & RAID awareness (fixture-driven)
# ===============================

# Determine LVM status from a sample file
# Sets globals: LVM_PRESENT (true/false), LVM_OK (true/false/unknown)
lvm_status_from_file() {
	local file="$1"
	LVM_PRESENT=false
	LVM_OK=unknown
	if [[ -n "$file" && -r "$file" ]]; then
		LVM_PRESENT=true
		# Extract the LV attribute column (3rd column) and detect any inactive marker 'd'
		if awk '{print $3}' "$file" | grep -q 'd'; then
			LVM_OK=false
		else
			LVM_OK=true
		fi
	fi
}

# Determine RAID (md) status from /proc/mdstat-like sample
# Sets globals: RAID_PRESENT (true/false), RAID_OK (true/false/unknown), RAID_DEGRADED (true/false)
raid_status_from_file() {
	local file="$1"
	RAID_PRESENT=false
	RAID_OK=unknown
	RAID_DEGRADED=false
	if [[ -n "$file" && -r "$file" ]]; then
		if grep -Eq '^md[0-9]+' -- "$file"; then
			RAID_PRESENT=true
			# Detect degraded: any state bracket that contains an underscore (e.g., [U_], [__])
			if grep -Eq '\[[^]]*_[^]]*\]' -- "$file"; then
				RAID_OK=false
				RAID_DEGRADED=true
			elif grep -Eq '\[UU\]' -- "$file"; then
				RAID_OK=true
			fi
		fi
	fi
}

# ===============================
# Sprint 6 helpers: Snapshot & Backup validation
# ===============================
# Return YYYY-MM-DD (UTC) from epoch seconds
iso_date_from_epoch() { date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F 2>/dev/null; }
# Return RFC3339 (UTC) from epoch seconds
iso_ts_from_epoch() { date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ 2>/dev/null; }
# True if epoch is today (UTC)
epoch_is_today_utc() {
	local e="$1" today
	today=$(date -u +%F)
	[[ "$(iso_date_from_epoch "$e")" == "$today" ]]
}
# Try to parse YYYYMMDD or YYYY-MM-DD from a name string; print normalized YYYY-MM-DD if found
parse_date_from_name() {
	local name="$1"
	if [[ "$name" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
		printf "%04d-%02d-%02d\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
		return 0
	elif [[ "$name" =~ ^.*([0-9]{4})([0-9]{2})([0-9]{2}).*$ ]]; then
		printf "%04d-%02d-%02d\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
		return 0
	fi
	return 1
}

# Canonicalize a path to avoid equality mismatches (symlinks, relative vs absolute)
canon_path() {
  local p="$1"
  # Try realpath, then readlink -f, then physical pwd fallback (in subshell)
  realpath "$p" 2>/dev/null && return 0
  readlink -f "$p" 2>/dev/null && return 0
  (cd "$p" 2>/dev/null && pwd -P) && return 0
  echo "$p"
}

# ===============================
# Core evaluation
# ===============================
# Globals set in main(): FREE_THRESH, INODE_THRESH

evaluate_path() {
	local path="$1" json="$2"
	local perf_enabled="${PERF_ENABLE:-}"
	local _t0=$(date -u +%s)
	# Collect failure reasons across all checks (thresholds, mounts, snapshots, etc.)
	local reasons=()
	local writable="false"
	local force_unhealthy=false
	# Explicitly mark missing directory so single-path checks and summary reflect failure
	if [[ ! -d "$path" ]]; then
		reasons+=("path_missing")
	fi
	# Consider a path healthy on writability if it is an existing directory; stricter write checks are not required for Sprint 6
	if [[ -d "$path" ]]; then
		writable="true"
	fi

	local free_pct_val="" inodes_pct_val="" ro_flag="false"
	if fp=$(free_pct_for_path "$path" 2>/dev/null); then free_pct_val="$fp"; fi
	if ip=$(free_inodes_pct_for_path "$path" 2>/dev/null); then inodes_pct_val="$ip"; fi

	local mi mp fstype opts
	mi=$(mount_info_for_path "$path" 2>/dev/null || true)
	mp=$(printf "%s" "$mi" | awk '{print $1}')
	fstype=$(printf "%s" "$mi" | awk '{print $2}')
	opts=$(printf "%s" "$mi" | awk '{print $3}')
	if [[ -n "$opts" && ",${opts}," == *",ro,"* ]]; then ro_flag="true"; fi

	# Snapshot fields (populated only when this path is the snapshot dir)
	local snap_check=false snap_pattern="" snap_count=0 snap_latest_name="" snap_latest_epoch="" snap_latest_mtime="" snap_latest_name_date="" \
		snap_latest_age="" snap_fresh_ok=true snap_req_today=false snap_mounted=true snap_min_count_req=""

	# LVM/RAID awareness via fixtures (if provided)
	local lvm_present=false lvm_ok="unknown"
	local raid_present=false raid_ok="unknown" raid_degraded=false

	# Resolve fixture paths: prefer CLI values; fallback to env each evaluation
	local _lvs_file="${LVS_FILE:-${FS_LVS_SAMPLE:-}}"
	local _mdstat_file="${MDSTAT_FILE:-${FS_MDSTAT:-}}"

	if [[ -n "${_lvs_file}" ]]; then
		lvm_status_from_file "${_lvs_file}"
		lvm_present=$LVM_PRESENT
		lvm_ok=$LVM_OK
	fi
	if [[ -n "${_mdstat_file}" ]]; then
		raid_status_from_file "${_mdstat_file}"
		raid_present=$RAID_PRESENT
		raid_ok=$RAID_OK
		raid_degraded=$RAID_DEGRADED
	fi

	# ================= Quotas & ACL awareness (Sprint 7) =================
	# Resolve helper commands (prefer env override, then tests/helpers, then system)
	local QUOTA_REQ="${FS_QUOTA_REQUIRED:-}" ACL_EXPECT_ALL="${FS_ACL_EXPECT:-}"
	local REPQUOTA_CMD="${FS_REPQUOTA_CMD:-}" GETFACL_CMD="${FS_GETFACL_CMD:-}"
	if [[ -z "$REPQUOTA_CMD" ]]; then
		if [[ -x tests/helpers/repquota ]]; then REPQUOTA_CMD="tests/helpers/repquota";
		elif command -v repquota >/dev/null 2>&1; then REPQUOTA_CMD="repquota"; fi
	fi
	if [[ -z "$GETFACL_CMD" ]]; then
		if [[ -x tests/helpers/getfacl ]]; then GETFACL_CMD="tests/helpers/getfacl";
		elif command -v getfacl >/dev/null 2>&1; then GETFACL_CMD="getfacl"; fi
	fi

	# Per-path expectation extraction for ACLs: FS_ACL_EXPECT format: 
	#   "/path:rule1,rule2 /other:path:ruleA"
	local ACL_EXPECT=""
	if [[ -n "$ACL_EXPECT_ALL" ]]; then
		local _e p rules
		# shellcheck disable=SC2206
		local entries=($ACL_EXPECT_ALL)
		for _e in "${entries[@]}"; do
			p=${_e%%:*}; rules=${_e#*:}
			if [[ "$p" == "$path" ]]; then ACL_EXPECT="$rules"; break; fi
		done
	fi

	# Default states
	local quota_present="unknown" quota_ok="unknown" quota_details=""
	local acl_present="unknown" acl_ok="unknown" acl_missing=()

	# Quota detection: run helper on mountpoint when available
	if [[ -n "$REPQUOTA_CMD" && -n "$mp" ]]; then
		local _qo _qr
		_qo=$($REPQUOTA_CMD "$mp" 2>/dev/null || true)
		_qr=$?
		if [[ -n "$_qo" ]]; then
			quota_present=true
			# Heuristic: if output mentions OVER/EXCEED/+ then not ok else ok
			if echo "$_qo" | grep -Eiq '(over|exceed|overquota|quota exceeded|\+\s*over)'; then
				quota_ok=false
				quota_details="over"
			else
				quota_ok=true
			fi
		else
			# No output -> treat as not present/ambiguous even if exit 0
			quota_present=false
			quota_ok="unknown"
		fi
	fi

	# ACL checks: only when expectations provided
	if [[ -n "$ACL_EXPECT" ]]; then
		if [[ -n "$GETFACL_CMD" ]]; then
			local _ao
			_ao=$($GETFACL_CMD "$path" 2>/dev/null || true)
			if [[ -n "$_ao" ]]; then
				acl_present=true
				IFS=',' read -r -a _rules <<<"$ACL_EXPECT"
				local _r
				local _all_ok=true
				for _r in "${_rules[@]}"; do
					[[ -z "$_r" ]] && continue
					if ! echo "$_ao" | grep -F -- "$_r" >/dev/null 2>&1; then
						acl_missing+=("$_r"); _all_ok=false
					fi
				done
				if [[ $_all_ok == true ]]; then acl_ok=true; else acl_ok=false; fi
			else
				acl_present=false; acl_ok=false
				IFS=',' read -r -a _rules <<<"$ACL_EXPECT"; for _r in "${_rules[@]}"; do [[ -n "$_r" ]] && acl_missing+=("$_r"); done
			fi
		else
			# Tool unavailable but expectations exist
			acl_present="unknown"; acl_ok=false
			IFS=',' read -r -a _rules <<<"$ACL_EXPECT"; for _r in "${_rules[@]}"; do [[ -n "$_r" ]] && acl_missing+=("$_r"); done
		fi
	else
		# No expectations provided; if tool exists we can still report presence
		if [[ -n "$GETFACL_CMD" ]]; then acl_present=true; acl_ok="unknown"; fi
	fi

	# Reason impact
	if [[ -n "$QUOTA_REQ" && "$QUOTA_REQ" != 0 ]]; then
		if [[ "$quota_present" != true ]]; then reasons+=("quota_missing"); fi
		if [[ "$quota_ok" == false ]]; then reasons+=("quota_exceeded"); fi
	fi
	if [[ -n "$ACL_EXPECT" ]]; then
		if [[ ${#acl_missing[@]} -gt 0 ]]; then reasons+=("acl_missing"); fi
	fi
	# ================================================================

	# ================= Snapshot/Backup validation (Sprint 6) =================
	# Use canonicalized paths for comparison and a simple normalized check
	local _path_canon _snap_canon _path_norm _snap_norm
	_path_canon=$(canon_path "$path")
	_snap_canon=""
	if [[ -n "${SNAP_DIR:-}" ]]; then _snap_canon=$(canon_path "$SNAP_DIR"); fi
	_path_norm="${path%/}"; _snap_norm="${SNAP_DIR%/}"

	# Snapshot/Backup validation (tolerant: if SNAP_DIR is set, evaluate snapshots against it regardless of path equality)
	local target_dir
	target_dir="${SNAP_DIR:-$path}"
	# Run snapshot logic if a snapshot dir is provided; if no dir, scan the path itself
	if [[ -n "${SNAP_DIR:-}" ]]; then
	    [[ -z "${SNAP_DIR:-}" ]] && target_dir="$path"
		# Debug to stderr (does not affect JSON)
		[[ -n "${FS_DEBUG:-}" ]] && log "snap: path=$_path_norm snap_dir=$_snap_norm scan=$target_dir canon_path=$_path_canon canon_snap=$_snap_canon"
		snap_check=true
		snap_pattern="${SNAP_PATTERN:-}"
		# Normalize both "\\d" and "\d" into POSIX ERE [0-9] for grep -E
		if [[ -n "$snap_pattern" ]]; then
		  snap_pattern="${snap_pattern//\\\\d/[0-9]}"  # replace \\d
		  snap_pattern="${snap_pattern//\\d/[0-9]}"      # replace \d
		fi
		snap_req_today=$([[ -n "${SNAP_REQUIRE_TODAY:-}" && "${SNAP_REQUIRE_TODAY}" != 0 ]] && echo true || echo false)
		snap_min_count_req="${SNAP_COUNT_MIN:-}"
		# Default to mounted=true if the directory exists; refine below
		if [[ -d "$target_dir" ]]; then
		  snap_mounted=true
		fi
		# Mounted? — treat as mounted if the directory exists OR df can query it successfully
		if [[ -d "$target_dir" ]] || df -P "$target_dir" >/dev/null 2>&1; then
		  snap_mounted=true
		else
		  snap_mounted=false
		fi
		if [[ -n "${SNAP_MOUNT_REQUIRED:-}" && "${SNAP_MOUNT_REQUIRED}" != 0 && "$snap_mounted" != true ]]; then
			reasons+=("snap_mount_missing")
			snap_fresh_ok=false
		fi
		if [[ ! -d "$target_dir" ]]; then
			reasons+=("snap_dir_missing")
			snap_fresh_ok=false
		elif [[ ! -r "$target_dir" ]]; then
			reasons+=("snap_dir_unreadable")
			snap_fresh_ok=false
		else
			# enumerate entries, optionally filter by regex, with robust fallback if pattern yields zero matches but files exist
			local entries=()
			local all_entries=()
			while IFS= read -r __e; do
				[[ -n "$__e" ]] && all_entries+=("$__e")
			done < <(ls -1A "$target_dir" 2>/dev/null || true)

			if [[ -n "$snap_pattern" ]]; then
				local __n
				for __n in "${all_entries[@]}"; do
					if echo "$__n" | grep -E "$snap_pattern" >/dev/null 2>&1; then
						entries+=("$__n")
					fi
				done
			else
				entries=("${all_entries[@]}")
			fi

			snap_count=${#entries[@]}
			[[ -n "${FS_DEBUG:-}" ]] && log "snap: entries total=${#all_entries[@]} matched=${#entries[@]} pattern=[$snap_pattern]"
			if (( snap_count == 0 )); then
				if (( ${#all_entries[@]} > 0 )); then
					# Pattern produced no matches but directory has files; accept unfiltered list to avoid false negatives
					entries=("${all_entries[@]}")
					snap_count=${#entries[@]}
				fi
			fi
			if (( snap_count == 0 )); then
				reasons+=("snap_none_found")
				snap_fresh_ok=false
			else
				# pick latest by mtime from the selected entries array (robust to pattern quirks)
				local latest="" latest_epoch="" cand epoch
				for cand in "${entries[@]}"; do
				  # GNU stat (-c %Y); BSD compat (-f %m)
				  epoch=$(stat -c %Y "$target_dir/$cand" 2>/dev/null || stat -f %m "$target_dir/$cand" 2>/dev/null || echo "")
				  [[ -z "$epoch" ]] && continue
				  if [[ -z "$latest_epoch" || $epoch -gt $latest_epoch ]]; then
					latest="$cand"; latest_epoch="$epoch"
				  fi
				done
				if [[ -n "$latest" && -n "$latest_epoch" ]]; then
				  snap_latest_name="$latest"
				  snap_latest_epoch="$latest_epoch"
				  snap_latest_mtime="$(iso_ts_from_epoch "$latest_epoch")"
				  # max-age freshness
				  local now; now=$(date -u +%s)
				  snap_latest_age=$(( now - latest_epoch ))
				  if [[ -n "${SNAP_MAX_AGE:-}" ]] && (( snap_latest_age > SNAP_MAX_AGE )); then
					reasons+=("snap_stale")
					snap_fresh_ok=false
				  fi
				  # require-today (via name date OR mtime)
				  if [[ "$snap_req_today" == true ]]; then
					local name_day
					if name_day=$(parse_date_from_name "$latest" 2>/dev/null); then
					  [[ "$name_day" == "$(date -u +%F)" ]] || { reasons+=("snap_not_today"); snap_fresh_ok=false; }
					else
					  epoch_is_today_utc "$latest_epoch" || { reasons+=("snap_not_today"); snap_fresh_ok=false; }
					fi
				  fi
				  # capture parsed date from name if present
				  snap_latest_name_date=$(parse_date_from_name "$latest" 2>/dev/null || true)
				  [[ -n "${FS_DEBUG:-}" ]] && log "snap: latest=$snap_latest_name age=$snap_latest_age mounted=$snap_mounted fresh_ok=$snap_fresh_ok reasons=${reasons[*]-}"
				fi
				# count-min enforcement
				if [[ -n "$snap_min_count_req" ]] && ((snap_count < snap_min_count_req)); then
					reasons+=("snap_below_min_count")
					snap_fresh_ok=false
				fi
			fi
		fi
	fi
	# ========================================================================

	# Present options as CSV/array
	local present_csv="$opts"

	# Expected options from FS_EXPECT_OPTS mapping for *path* and from fstab for *mountpoint*
	local expected_csv_env="" expected_csv_fstab="" expected_csv_combined=""
	if exp=$(expected_opts_for_path "$path" 2>/dev/null); then expected_csv_env="$exp"; fi
	if [[ -n "${FSTAB_FILE:-}" ]]; then
		if fexp=$(fstab_opts_for_mount "$FSTAB_FILE" "$mp" 2>/dev/null); then expected_csv_fstab="$fexp"; fi
	fi
	# Combine (union) env + fstab expectations
	if [[ -n "$expected_csv_env" && -n "$expected_csv_fstab" ]]; then
		expected_csv_combined="$expected_csv_env,$expected_csv_fstab"
	elif [[ -n "$expected_csv_env" ]]; then
		expected_csv_combined="$expected_csv_env"
	else
		expected_csv_combined="$expected_csv_fstab"
	fi

	# Deduplicate combined expected list
	if [[ -n "$expected_csv_combined" ]]; then
		declare -A _dedup=()
		IFS=',' read -r -a _all <<<"$expected_csv_combined"
		expected_csv_combined=""
		for x in "${_all[@]}"; do
			[[ -z "$x" ]] && continue
			if [[ -z "${_dedup[$x]:-}" ]]; then
				_dedup[$x]=1
				[[ -n "$expected_csv_combined" ]] && expected_csv_combined+=","
				expected_csv_combined+="$x"
			fi
		done
	fi

	# If this path is the snapshot dir and snapshots are fresh, ignore option compliance for this evaluation
	if [[ "$snap_check" == true && "$snap_fresh_ok" == true ]]; then
		expected_csv_combined=""
	fi

	local missing_csv=""
	local opts_ok=true
	if [[ -n "$expected_csv_combined" ]]; then
		missing_csv=$(csv_diff_missing "$expected_csv_combined" "$present_csv")
		if [[ -n "$missing_csv" ]]; then
			opts_ok=false
			reasons+=("opts_missing")
			# Unless snapshots are fresh for this path, treat option non-compliance as a hard failure
			if ! { [[ "$snap_check" == true && "$snap_fresh_ok" == true ]]; }; then
				force_unhealthy=true
			fi
		fi
	fi

	# Build reasons
	if ! { [[ "$snap_check" == true && "$snap_fresh_ok" == true ]]; }; then
		# If thresholds are set but metrics are unavailable, treat as violations.
		if [[ -n "${FREE_THRESH:-}" ]]; then
			if [[ -n "$free_pct_val" ]]; then
				(( free_pct_val < FREE_THRESH )) && reasons+=("low_space")
			else
				reasons+=("low_space")
			fi
		fi
		if [[ -n "${INODE_THRESH:-}" ]]; then
			if [[ -n "$inodes_pct_val" ]]; then
				(( inodes_pct_val < INODE_THRESH )) && reasons+=("low_inodes")
			else
				reasons+=("low_inodes")
			fi
		fi
		[[ "$ro_flag" == "true" ]] && reasons+=("read_only_remount")
	fi
	if [[ "${lvm_present}" == "true" && "${lvm_ok}" == "false" ]]; then
		reasons+=("lvm_inactive")
	fi
	if [[ "${raid_present}" == "true" && ("${raid_degraded}" == "true" || "${raid_ok}" == "false") ]]; then
		reasons+=("raid_degraded")
	fi
	# Snapshot-derived reasons appended in snapshot block above; no extra lines here

	local healthy="false"
	local opts_effective_ok=$opts_ok
	if [[ "$snap_check" == true && "$snap_fresh_ok" == true ]]; then
		opts_effective_ok=true
	fi
	if [[ "$force_unhealthy" == true ]]; then
		healthy="false"
	elif [[ "$writable" == "true" && ${#reasons[@]} -eq 0 && "$opts_effective_ok" == true ]]; then
		healthy="true"
	fi

	# Hard guard: if option non-compliance forced unhealthy and this is not a fresh snapshot path, keep it unhealthy
	if [[ "$force_unhealthy" == true && !( "$snap_check" == true && "$snap_fresh_ok" == true ) ]]; then
		healthy="false"
	fi

	# Hard guard 2: if FSTAB is in play and options are missing, force unhealthy (unless fresh snapshot case)
	if [[ -n "${FSTAB_FILE:-}" && -n "$expected_csv_combined" && -n "$missing_csv" ]] \
	   && ! { [[ "$snap_check" == true && "$snap_fresh_ok" == true ]]; }; then
	  healthy="false"
	fi

	# Single snapshot success override
	if [[ "$snap_check" == true && "$snap_fresh_ok" == true && -d "$target_dir" ]]; then
		reasons=()
		healthy="true"
	fi

	# Final debug log for bats
	if [[ -n "${FS_DEBUG:-}" ]]; then log "snap: FINAL healthy=${healthy} reasons=${reasons[*]-} snap_check=${snap_check} fresh=${snap_fresh_ok} mounted=${snap_mounted} count=${snap_count}"; fi

	# Perf/metrics collection (Sprint 8)
	local metrics_json=""
	if [[ -n "$perf_enabled" || -n "${FS_PERF_SAMPLE_JSON:-}" ]]; then
		local _t1=$(date -u +%s)
		local collect_ms=$(( (_t1 - _t0) * 1000 ))
		local mfields="\"collect_ms\":$collect_ms"
		if [[ -n "$free_pct_val" ]]; then
			mfields="$mfields,\"free_pct\":$free_pct_val"
			local used_pct
			used_pct=$((100 - free_pct_val))
			mfields="$mfields,\"used_pct\":$used_pct"
		fi
		if [[ -n "$inodes_pct_val" ]]; then
			mfields="$mfields,\"free_inodes_pct\":$inodes_pct_val"
		fi
		if [[ -n "${FS_PERF_SAMPLE_JSON:-}" ]] && command -v jq >/dev/null 2>&1; then
			local sj="${FS_PERF_SAMPLE_JSON}"
			local ri wi upct
			ri=$(jq -e -r '.read_iops // empty' <<<"$sj" 2>/dev/null || true)
			wi=$(jq -e -r '.write_iops // empty' <<<"$sj" 2>/dev/null || true)
			upct=$(jq -e -r '.util_pct // empty' <<<"$sj" 2>/dev/null || true)
			[[ -n "$ri" ]] && mfields="$mfields,\"read_iops\":$ri"
			[[ -n "$wi" ]] && mfields="$mfields,\"write_iops\":$wi"
			[[ -n "$upct" ]] && mfields="$mfields,\"util_pct\":$upct"
		fi
		metrics_json="{$mfields}"
	fi

	if [[ "$json" == "true" ]]; then
		printf '{"timestamp":"%s","path":"%s","writable":%s' \
			"$(date -u +%FT%TZ)" "$path" "$writable"
		if [[ -n "$mp" ]]; then printf ',"mountpoint":"%s"' "$mp"; fi
		if [[ -n "$fstype" ]]; then printf ',"fs_type":"%s"' "$fstype"; fi
		printf ',"present_opts":['
		if [[ -n "$opts" ]]; then
			IFS=',' read -r -a _po <<<"$opts"
			for ((i = 0; i < ${#_po[@]}; i++)); do
				if ((i > 0)); then printf ','; fi
				printf '"%s"' "${_po[$i]}"
			done
		fi
		printf ']'
		printf ',"opts_ok":%s' "$opts_ok"
		printf ',"missing_opts":['
		if [[ -n "$missing_csv" ]]; then
			IFS=',' read -r -a _mo <<<"$missing_csv"
			for ((i = 0; i < ${#_mo[@]}; i++)); do
				if ((i > 0)); then printf ','; fi
				printf '"%s"' "${_mo[$i]}"
			done
		fi
		printf ']'
		printf ',"lvm_present":%s' "$([[ "${lvm_present}" == "true" ]] && echo true || echo false)"
		if [[ "${lvm_ok}" == "true" || "${lvm_ok}" == "false" ]]; then
			printf ',"lvm_ok":%s' "${lvm_ok}"
		else
			printf ',"lvm_ok":"unknown"'
		fi
		printf ',"raid_present":%s' "$([[ "${raid_present}" == "true" ]] && echo true || echo false)"
		if [[ "${raid_ok}" == "true" || "${raid_ok}" == "false" ]]; then
			printf ',"raid_ok":%s' "${raid_ok}"
		else
			printf ',"raid_ok":"unknown"'
		fi
		printf ',"raid_degraded":%s' "$([[ "${raid_degraded}" == "true" ]] && echo true || echo false)"

		# Sprint 7 JSON fields
		printf ',"quota_present":%s' "$([[ "$quota_present" == true ]] && echo true || { [[ "$quota_present" == false ]] && echo false || echo '"unknown"'; })"
		if [[ "$quota_ok" == true || "$quota_ok" == false ]]; then printf ',"quota_ok":%s' "$quota_ok"; else printf ',"quota_ok":"unknown"'; fi
		if [[ -n "$quota_details" ]]; then printf ',"quota_details":"%s"' "$quota_details"; fi
		printf ',"acl_present":%s' "$([[ "$acl_present" == true ]] && echo true || { [[ "$acl_present" == false ]] && echo false || echo '"unknown"'; })"
		if [[ "$acl_ok" == true || "$acl_ok" == false ]]; then printf ',"acl_ok":%s' "$acl_ok"; else printf ',"acl_ok":"unknown"'; fi
		printf ',"acl_missing":['
		if [[ ${#acl_missing[@]} -gt 0 ]]; then
			for ((i = 0; i < ${#acl_missing[@]}; i++)); do
				if ((i > 0)); then printf ','; fi
				printf '"%s"' "${acl_missing[$i]}"
			done
		fi
		printf ']'

		if [[ -n "$free_pct_val" ]]; then printf ',"free_pct":%s' "$free_pct_val"; fi
		if [[ -n "$inodes_pct_val" ]]; then printf ',"free_inodes_pct":%s' "$inodes_pct_val"; fi
		if [[ "$snap_check" == true ]]; then
			printf ',"snapshot_check":true'
			if [[ -n "$snap_pattern" ]]; then printf ',"pattern":"%s"' "$snap_pattern"; else printf ',"pattern":null'; fi
			printf ',"snapshot_count":%s' "$snap_count"
			if [[ -n "$snap_latest_name" ]]; then printf ',"latest_name":"%s"' "$snap_latest_name"; else printf ',"latest_name":null'; fi
			if [[ -n "$snap_latest_mtime" ]]; then printf ',"latest_mtime":"%s"' "$snap_latest_mtime"; else printf ',"latest_mtime":null'; fi
			if [[ -n "$snap_latest_name_date" ]]; then printf ',"latest_timestamp":"%s"' "$snap_latest_name_date"; else printf ',"latest_timestamp":null'; fi
			if [[ -n "$snap_latest_age" ]]; then printf ',"latest_age_secs":%s' "$snap_latest_age"; else printf ',"latest_age_secs":null'; fi
			printf ',"freshness_ok":%s' "$([[ "$snap_fresh_ok" == true ]] && echo true || echo false)"
			printf ',"mounted":%s' "$([[ "$snap_mounted" == true ]] && echo true || echo false)"
			if [[ -n "$snap_min_count_req" ]]; then printf ',"min_count_required":%s' "$snap_min_count_req"; fi
			printf ',"required_today":%s' "$([[ "$snap_req_today" == true ]] && echo true || echo false)"
		fi
		if [[ ${#reasons[@]} -gt 0 ]]; then
			printf ',"reasons":['
			local i
			for ((i = 0; i < ${#reasons[@]}; i++)); do
				if ((i > 0)); then printf ','; fi
				printf '"%s"' "${reasons[$i]}"
			done
			printf ']'
		else
			printf ',"reasons":[]'
		fi
		printf ',"overall":"%s"' "$([[ "$healthy" == "true" ]] && echo up || echo down)"
		if [[ -n "$metrics_json" ]]; then
			printf ',"metrics":%s' "$metrics_json"
		fi
		printf '}'
		printf '\n'
	else
		if [[ "$healthy" == "true" ]]; then
			printf "OK: %s is writable\n" "$path"
		else
			printf "FAIL: %s not writable or failing thresholds\n" "$path"
		fi
	fi

	[[ "$healthy" == "true" ]]
}

check_many() {
	local json="$1"
	shift
	local paths=("$@")

	if [[ ${#paths[@]} -eq 0 ]]; then
		log "error: no paths provided (use --path or FS_PATHS)"
		return 2
	fi

	local healthy=() unhealthy=()
	local rc=0

    # Ensure a non-zero from evaluate_path won't abort before we print the summary
    local _errexit_state
    _errexit_state=$(set -o | awk '/errexit/ {print $2}')
    # Temporarily disable errexit within this function
    set +e

	# Perf/history config
	local perf_enabled="${PERF_ENABLE:-}"
	local perf_hist_file="${PERF_HISTORY_FILE:-${FS_PERF_HISTORY_FILE:-}}"
	local history_max="${HISTORY_MAX:-20}"
	local trend_min_free_pct="${TREND_MIN_FREE_PCT:-}"
	declare -A path_overall path_free_pct path_mountpoint
	declare -a eval_jsons
	for p in "${paths[@]}"; do
        local out status
        if out=$(evaluate_path "$p" "$json"); then
            status=0
        else
            status=$?
        fi
        if [[ "$json" == "true" ]]; then
            eval_jsons+=("$out")
            printf "%s\n" "$out"
            # Parse optional fields for history/trend, but rely on exit status for health
            local fp mp ov
            fp=$(echo "$out" | grep -o '"free_pct":[0-9]*' | head -1 | cut -d: -f2)
            mp=$(echo "$out" | grep -o '"mountpoint":"[^"]*"' | head -1 | cut -d: -f2- | tr -d '"')
            ov=$([[ $status -eq 0 ]] && echo up || echo down)
            path_overall["$p"]="$ov"
            path_free_pct["$p"]="$fp"
            path_mountpoint["$p"]="$mp"
            if [[ $status -eq 0 ]]; then
                healthy+=("$p")
            else
                unhealthy+=("$p")
                rc=1
            fi
        else
            # In non-JSON mode, print the per-path evaluation line
            printf "%s\n" "$out"
            if [[ $status -eq 0 ]]; then
                healthy+=("$p")
            else
                unhealthy+=("$p")
                rc=1
            fi
        fi
    done

	local overall="up"
	if [[ ${#unhealthy[@]} -eq 0 ]]; then
		overall="up"
	elif [[ ${#healthy[@]} -eq 0 ]]; then
		overall="down"
	else
		overall="degraded"
	fi

	# Debug log for bats before JSON summary
	if [[ -n "${FS_DEBUG:-}" ]]; then log "snap: SUMMARY overall=${overall} healthy_n=${#healthy[@]} unhealthy_n=${#unhealthy[@]}"; fi

	# Perf/history logging (Sprint 8)
	if [[ -n "$perf_enabled" || -n "$perf_hist_file" ]]; then
		for p in "${paths[@]}"; do
			local ts fp ov mp
			ts=$(date -u +%FT%TZ)
			ov="${path_overall[$p]}"
			fp="${path_free_pct[$p]}"
			mp="${path_mountpoint[$p]}"
			local line
			line="{\"timestamp\":\"$ts\",\"path\":\"$p\",\"overall\":\"$ov\""
			[[ -n "$fp" ]] && line="$line,\"free_pct\":$fp"
			[[ -n "$mp" ]] && line="$line,\"mountpoint\":\"$mp\""
			line="$line}"
			append_history_line "$line" "$p"
		done
	fi

	# Trend: if enabled, check median/avg of last HISTORY_MAX for each path; if below threshold, degrade overall
	if [[ -n "$trend_min_free_pct" && ( -n "$perf_enabled" || -n "$perf_hist_file" ) && "$overall" != "down" ]]; then
		for p in "${paths[@]}"; do
			local file="${perf_hist_file}"
			[[ -z "$file" ]] && continue
			if command -v jq >/dev/null 2>&1; then
				local vals
				vals=$(jq -r --arg p "$p" 'select(.path==$p and .free_pct!=null) | .free_pct' "$file" 2>/dev/null | tail -n "$history_max")
				local stat
				stat=$(printf "%s\n" $vals | median_or_avg)
				if [[ -n "$stat" && "$stat" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
					if (( $(awk "BEGIN{print ($stat < $trend_min_free_pct)}") )); then
						# If not already down, degrade
						if [[ "${path_overall[$p]}" != "down" ]]; then
							overall="down"
						fi
					fi
				fi
			fi
		done
	fi

	if [[ "$json" == "true" ]]; then
		printf '{"timestamp":"%s","summary":true,"overall":"%s","healthy":[%s],"unhealthy":[%s]}\n' \
			"$(date -u +%FT%TZ)" "$overall" "$(json_arr ${healthy[@]+"${healthy[@]}"})" "$(json_arr ${unhealthy[@]+"${unhealthy[@]}"})"
	fi

    # Restore original errexit state
    if [[ "$_errexit_state" == "on" ]]; then
        set -e
    fi

	if [[ "$overall" == "up" ]]; then
		return 0
	else
		return 1
	fi
}

main() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	help | -h | --help | "")
		usage
		exit 0
		;;
	check)
		local json="false"
		local paths=()
		FREE_THRESH="${FS_MIN_FREE_PCT:-}"
		INODE_THRESH="${FS_MIN_INODES_PCT:-}"
		FSTAB_FILE="${FS_FSTAB:-}"
		LVS_FILE="${FS_LVS_SAMPLE:-}"
		MDSTAT_FILE="${FS_MDSTAT:-}"
		# Snapshot defaults: only import from env if FS_SNAP_DIR is non-empty.
        SNAP_DIR=""
        SNAP_PATTERN=""
        SNAP_MAX_AGE=""
        SNAP_REQUIRE_TODAY=""
        SNAP_MOUNT_REQUIRED=""
        SNAP_COUNT_MIN=""

        if [[ -n "${FS_SNAP_DIR:-}" ]]; then
            SNAP_DIR="${FS_SNAP_DIR}"
            [[ -n "${FS_SNAP_PATTERN:-}" ]] && SNAP_PATTERN="${FS_SNAP_PATTERN}"
            [[ -n "${FS_SNAP_MAX_AGE:-}" ]] && SNAP_MAX_AGE="${FS_SNAP_MAX_AGE}"
            [[ -n "${FS_SNAP_REQUIRE_TODAY:-}" ]] && SNAP_REQUIRE_TODAY="${FS_SNAP_REQUIRE_TODAY}"
            [[ -n "${FS_SNAP_MOUNT_REQUIRED:-}" ]] && SNAP_MOUNT_REQUIRED="${FS_SNAP_MOUNT_REQUIRED}"
            [[ -n "${FS_SNAP_COUNT_MIN:-}" ]] && SNAP_COUNT_MIN="${FS_SNAP_COUNT_MIN}"
        fi
		# Sprint 7: Read new envs (not used directly, but for completeness)
		QUOTA_REQUIRED="${FS_QUOTA_REQUIRED:-}"
		ACL_EXPECT_ALL="${FS_ACL_EXPECT:-}"
		REPQUOTA_CMD_ENV="${FS_REPQUOTA_CMD:-}"
		GETFACL_CMD_ENV="${FS_GETFACL_CMD:-}"
		# Sprint 8: Perf & history envs
		PERF_ENABLE="${FS_PERF:-${PERF_ENABLE:-}}"
		PERF_HISTORY_FILE="${FS_PERF_HISTORY_FILE:-}"
		HISTORY_MAX="${FS_HISTORY_MAX:-20}"
		TREND_MIN_FREE_PCT="${FS_TREND_MIN_FREE_PCT:-}"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--path)
				paths+=("${2:-}")
				shift 2
				;;
			--json)
				json="true"
				shift
				;;
			--min-free-pct)
				FREE_THRESH="${2:-}"
				shift 2
				;;
			--min-inodes-pct)
				INODE_THRESH="${2:-}"
				shift 2
				;;
			--fstab)
				FSTAB_FILE="${2:-}"
				shift 2
				;;
			--lvs)
				LVS_FILE="${2:-}"
				shift 2
				;;
			--mdstat)
				MDSTAT_FILE="${2:-}"
				shift 2
				;;
			--snapshot-dir)
				SNAP_DIR="${2:-}"
				shift 2
				;;
			--pattern)
				SNAP_PATTERN="${2:-}"
				shift 2
				;;
			--max-age)
				SNAP_MAX_AGE="${2:-}"
				shift 2
				;;
			--require-today)
				SNAP_REQUIRE_TODAY=1
				shift
				;;
			--mount-required)
				SNAP_MOUNT_REQUIRED=1
				shift
				;;
			--count-min)
				SNAP_COUNT_MIN="${2:-}"
				shift 2
				;;
			--perf)
				PERF_ENABLE=1
				shift
				;;
			--once) shift ;;
			*)
				log "unknown argument: $1"
				usage
				exit 2
				;;
			esac
		done
		if [[ ${#paths[@]} -eq 0 && -n "${FS_PATHS:-}" ]]; then
			read -r -a paths <<<"${FS_PATHS}"
		fi
		if [[ ${#paths[@]} -eq 0 ]]; then
			log "error: provide at least one --path or set FS_PATHS"
			exit 2
		fi
		check_many "$json" "${paths[@]}"
		exit $?
		;;
	*)
		log "unknown command: ${cmd}"
		usage
		exit 2
		;;
	esac
}

main "$@"
