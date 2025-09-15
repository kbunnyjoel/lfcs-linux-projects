#!/usr/bin/env bash
# sec.sh — Security & Auditing Watchdog (Project 7, Sprint 1)

set -euo pipefail

log() { printf "%s\n" "$*" >&2; }
ts() { date -u +%FT%TZ; }

usage() {
	cat <<'USAGE'
sec.sh — security & auditing watchdog

Usage:
  sec.sh check [--json]
               [--firewall required]
               [--selinux enforcing|permissive|disabled]
               [--apparmor required]
               [--audit rules FILE]
               [--auth max-failed N]
               [--aide required]
  sec.sh help

Notes:
  - Mocks can be injected via env:
      SEC_FIREWALLCTL, SEC_GETENFORCE, SEC_AASTATUS, SEC_AUDITCTL, SEC_LASTB, SEC_AIDE
  - Exit codes: 0 (all healthy), 1 (one or more unhealthy), 2 (usage error)
USAGE
}

json_bool() { [[ "$1" == "true" ]] && echo true || echo false; }

# JSON array joiner for safe output
json_arr() {
	local first=1 item
	for item in "$@"; do
		if ((first)); then first=0; else printf ","; fi
		printf '"%s"' "$item"
	done
}

# Return cmd path if exists, else empty
find_cmd() { command -v "$1" 2>/dev/null || true; }

check_firewall() {
	# Inputs: FW_REQUIRED (true/false)
	local required="$1" json="$2"
	local ctl="${SEC_FIREWALLCTL:-}"
	local present=false active=false ok=true
	if [[ -z "$ctl" ]]; then
		# Prefer firewall-cmd, fallback to nft/iptables presence
		if ctl=$(find_cmd firewall-cmd); then :; fi
	fi
	if [[ -n "$ctl" ]]; then
		present=true
		# firewalld like
		if out=$("$ctl" state 2>/dev/null || true); then
			if echo "$out" | grep -qi running; then active=true; else active=false; fi
		else
			# heuristic: consider present but not active
			active=false
		fi
	else
		# Fallbacks: nft or iptables-save
		local nft="${SEC_NFT:-}"
		local ipts="${SEC_IPTABLESSAVE:-}"
		[[ -n "$nft" ]] || nft=$(find_cmd nft)
		[[ -n "$ipts" ]] || ipts=$(find_cmd iptables-save)
		if [[ -n "$nft" ]]; then
			# Consider active if ruleset lists any chain/table beyond the implicit inet/bridge defaults
			local nout
			nout=$($nft list ruleset 2>/dev/null || true)
			if [[ -n "$nout" ]]; then
				present=true
				if echo "$nout" | grep -Eq 'table\s+|chain\s+'; then active=true; fi
			fi
		fi
		if [[ "$active" != true && -n "$ipts" ]]; then
			local iout
			iout=$($ipts 2>/dev/null || true)
			if [[ -n "$iout" ]]; then
				present=true
				# Count appended rules lines (-A) as heuristic for activity
				if echo "$iout" | grep -Eq '^-A\s'; then active=true; fi
			fi
		fi
	fi
	if [[ "$required" == true ]]; then
		[[ "$present" == true && "$active" == true ]] || ok=false
	fi
	if [[ "$json" == true ]]; then
		printf '{"timestamp":"%s","component":"firewall","present":%s,"active":%s,"ok":%s}\n' \
			"$(ts)" "$(json_bool "$present")" "$(json_bool "$active")" "$(json_bool "$ok")"
	else
		printf "FIREWALL: present=%s active=%s\n" "$present" "$active"
	fi
	[[ "$ok" == true ]]
}

check_selinux() {
	# Inputs: REQUIRED_MODE (empty|enforcing|permissive|disabled)
	local req_mode="$1" json="$2"
	local present=false mode="unknown" ok=true
	# Try helper if available
	if [[ -r "$(dirname "$0")/selinux.sh" ]]; then
		# shellcheck disable=SC1091
		. "$(dirname "$0")/selinux.sh"
		if command -v se_detect >/dev/null 2>&1; then
			se_detect
			present=$SE_PRESENT
			mode=$SE_MODE
		fi
	fi
	# Fallback to direct getenforce if helper not used
	if [[ "$mode" == "unknown" ]]; then
		local getenforce="${SEC_GETENFORCE:-}"
		[[ -n "$getenforce" ]] || getenforce=$(find_cmd getenforce)
		if [[ -n "$getenforce" ]]; then
			present=true
			mode=$("$getenforce" 2>/dev/null || echo "unknown")
			mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')
		fi
	fi
	if [[ -n "$req_mode" ]]; then
		if [[ "$present" == true ]]; then
			[[ "$mode" == "$req_mode" ]] || ok=false
		else
			ok=false
		fi
	fi
	if [[ "$json" == true ]]; then
		printf '{"timestamp":"%s","component":"selinux","present":%s,"mode":"%s","ok":%s}\n' \
			"$(ts)" "$(json_bool "$present")" "$mode" "$(json_bool "$ok")"
	else
		printf "SELINUX: present=%s mode=%s\n" "$present" "$mode"
	fi
	[[ "$ok" == true ]]
}

check_apparmor() {
	# Inputs: REQUIRED (true/false)
	local required="$1" json="$2"
	local present=false enabled=false ok=true
	# Try helper if available
	if [[ -r "$(dirname "$0")/apparmor.sh" ]]; then
		# shellcheck disable=SC1091
		. "$(dirname "$0")/apparmor.sh"
		if command -v aa_detect >/dev/null 2>&1; then
			aa_detect
			present=$AA_PRESENT
			enabled=$AA_ENABLED
		fi
	fi
	# Fallback to direct aa-status parse if helper unavailable
	if [[ "$present" == false && "$enabled" == false ]]; then
		local aactl="${SEC_AASTATUS:-}"
		[[ -n "$aactl" ]] || aactl=$(find_cmd aa-status)
		if [[ -n "$aactl" ]]; then
			present=true
			if out=$("$aactl" 2>/dev/null || true); then
				echo "$out" | grep -Eiq 'profiles.*enforce|module is loaded' && enabled=true
			fi
		fi
	fi
	if [[ "$required" == true ]]; then
		[[ "$present" == true && "$enabled" == true ]] || ok=false
	fi
	if [[ "$json" == true ]]; then
		printf '{"timestamp":"%s","component":"apparmor","present":%s,"enabled":%s,"ok":%s}\n' \
			"$(ts)" "$(json_bool "$present")" "$(json_bool "$enabled")" "$(json_bool "$ok")"
	else
		printf "APPARMOR: present=%s enabled=%s\n" "$present" "$enabled"
	fi
	[[ "$ok" == true ]]
}

check_audit() {
	# Inputs: RULES_FILE (optional)
	local rules_file="$1" json="$2"
	local auditctl="${SEC_AUDITCTL:-}"
	local present=false rules_loaded=0 rules_required=0 ok=true
	[[ -n "$auditctl" ]] || auditctl=$(find_cmd auditctl)
	local loaded=""
	if [[ -n "$auditctl" ]]; then
		present=true
		loaded=$("$auditctl" -l 2>/dev/null || true)
	fi
	if [[ -n "$rules_file" && -r "$rules_file" ]]; then
		# Normalize loaded rules: trim comments/whitespace and collapse spaces
		local loaded_norm
		loaded_norm=$(printf "%s\n" "$loaded" | sed -e 's/#.*$//' -e 's/^[ \t]*//' -e 's/[ \t]*$//' -e 's/[ \t][ \t]*/ /g')
		local missing_rules=()
		while IFS= read -r line || [[ -n "$line" ]]; do
			# drop comments/blank
			[[ "$line" =~ ^[[:space:]]*# ]] && continue
			[[ -z "$line" ]] && continue
			# normalize required rule
			local req
			req=$(printf "%s" "$line" | sed -e 's/#.*$//' -e 's/^[ \t]*//' -e 's/[ \t]*$//' -e 's/[ \t][ \t]*/ /g')
			[[ -z "$req" ]] && continue
			rules_required=$((rules_required + 1))
			if printf "%s\n" "$loaded_norm" | grep -Fq -- "$req"; then
				rules_loaded=$((rules_loaded + 1))
			else
				missing_rules+=("$req")
			fi
		done <"$rules_file"
		[[ $rules_loaded -ge $rules_required && $rules_required -gt 0 ]] || ok=false
	fi
	if [[ "$json" == true ]]; then
		printf '{"timestamp":"%s","component":"audit","present":%s,"rules_required":%d,"rules_loaded":%d' \
			"$(ts)" "$(json_bool "$present")" "$rules_required" "$rules_loaded"
		if [[ -n "${missing_rules+x}" ]]; then
			printf ',"missing_rules":[%s]' "$(json_arr ${missing_rules[@]+"${missing_rules[@]}"})"
		else
			printf ',"missing_rules":[]'
		fi
		printf ',"ok":%s}\n' "$(json_bool "$ok")"
	else
		printf "AUDIT: present=%s required=%d loaded=%d\n" "$present" "$rules_required" "$rules_loaded"
	fi
	[[ "$ok" == true ]]
}

check_auth() {
	# Inputs: MAX_FAILED (optional integer)
	local max_failed="$1" json="$2"
	local lastb="${SEC_LASTB:-}"
	local present=false failed=0 ok=true
	[[ -n "$lastb" ]] || lastb=$(find_cmd lastb)
	if [[ -n "$lastb" ]]; then
		present=true
		# Mock contract: lastb --count prints number of failed logins (24h)
		failed=$("$lastb" --count 2>/dev/null || echo 0)
	fi
	if [[ -n "$max_failed" ]]; then
		if ! [[ "$failed" =~ ^[0-9]+$ ]]; then failed=999999; fi
		((failed <= max_failed)) || ok=false
	fi
	if [[ "$json" == true ]]; then
		printf '{"timestamp":"%s","component":"auth","present":%s,"failed_24h":%d,"ok":%s}\n' \
			"$(ts)" "$(json_bool "$present")" "$failed" "$(json_bool "$ok")"
	else
		printf "AUTH: present=%s failed_24h=%d\n" "$present" "$failed"
	fi
	[[ "$ok" == true ]]
}

check_aide() {
	# Inputs: REQUIRED (true/false)
	local required="$1" json="$2"
	local aide="${SEC_AIDE:-}"
	local present=false ok=true
	local added="" changed="" removed=""
	[[ -n "$aide" ]] || aide=$(find_cmd aide)
	if [[ -n "$aide" ]]; then
		present=true
		local out rc
		out=$("$aide" --check 2>/dev/null || true)
		rc=$?
		# Parse common AIDE summary formats
		added=$(echo "$out" | awk -F: '/[Aa]dded entries/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
		changed=$(echo "$out" | awk -F: '/[Cc]hanged entries/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
		removed=$(echo "$out" | awk -F: '/[Rr]emoved entries/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
		if [[ -z "$added" ]]; then added=$(echo "$out" | grep -Eo 'added=[0-9]+' | head -1 | cut -d= -f2); fi
		if [[ -z "$changed" ]]; then changed=$(echo "$out" | grep -Eo 'changed=[0-9]+' | head -1 | cut -d= -f2); fi
		if [[ -z "$removed" ]]; then removed=$(echo "$out" | grep -Eo 'removed=[0-9]+' | head -1 | cut -d= -f2); fi
		# ok if exit code zero or explicit zero counts
		if [[ $rc -ne 0 ]]; then ok=false; fi
		if [[ -n "$added$changed$removed" ]]; then
			# If any numeric fields present and non-zero, not ok
			local a="${added:-0}" c="${changed:-0}" r="${removed:-0}"
			if [[ "$a" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$r" =~ ^[0-9]+$ ]]; then
				if ((a > 0 || c > 0 || r > 0)); then ok=false; fi
			fi
		fi
	fi
	if [[ "$required" == true ]]; then
		[[ "$present" == true && "$ok" == true ]] || ok=false
	else
		# not required -> ok does not affect health
		ok=true
	fi
	if [[ "$json" == true ]]; then
		printf '{"timestamp":"%s","component":"aide","present":%s' "$(ts)" "$(json_bool "$present")"
		if [[ -n "$added" ]]; then printf ',"added":%s' "$added"; else printf ',"added":null'; fi
		if [[ -n "$changed" ]]; then printf ',"changed":%s' "$changed"; else printf ',"changed":null'; fi
		if [[ -n "$removed" ]]; then printf ',"removed":%s' "$removed"; else printf ',"removed":null'; fi
		printf ',"ok":%s}\n' "$(json_bool "$ok")"
	else
		printf "AIDE: present=%s ok=%s\n" "$present" "$ok"
	fi
	[[ "$ok" == true ]]
}

check() {
	local json=false
	local fw_required=false
	local selinux_mode=""
	local aa_required=false
	local audit_rules=""
	local auth_max=""
	local aide_required=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json=true
			shift
			;;
		--firewall)
			[[ "${2:-}" == "required" ]] || {
				log "--firewall requires 'required'"
				return 2
			}
			fw_required=true
			shift 2
			;;
		--selinux)
			selinux_mode="${2:-}"
			shift 2
			;;
		--apparmor)
			[[ "${2:-}" == "required" ]] || {
				log "--apparmor requires 'required'"
				return 2
			}
			aa_required=true
			shift 2
			;;
		--audit)
			[[ "${2:-}" == "rules" && -n "${3:-}" ]] || {
				log "--audit rules FILE"
				return 2
			}
			audit_rules="${3}"
			shift 3
			;;
		--auth)
			[[ "${2:-}" == "max-failed" && -n "${3:-}" ]] || {
				log "--auth max-failed N"
				return 2
			}
			auth_max="${3}"
			shift 3
			;;
		--aide)
			[[ "${2:-}" == "required" ]] || {
				log "--aide requires 'required'"
				return 2
			}
			aide_required=true
			shift 2
			;;
		*)
			log "unknown argument: $1"
			return 2
			;;
		esac
	done

	local healthy=() unhealthy=()
	local rc=0
	local _errexit_state
	_errexit_state=$(set -o | awk '/errexit/ {print $2}')
	set +e

	if check_firewall "$fw_required" "$json"; then healthy+=(firewall); else
		unhealthy+=(firewall)
		rc=1
	fi
	if check_selinux "$selinux_mode" "$json"; then healthy+=(selinux); else
		unhealthy+=(selinux)
		rc=1
	fi
	if check_apparmor "$aa_required" "$json"; then healthy+=(apparmor); else
		unhealthy+=(apparmor)
		rc=1
	fi
	if check_audit "$audit_rules" "$json"; then healthy+=(audit); else
		unhealthy+=(audit)
		rc=1
	fi
	if check_auth "$auth_max" "$json"; then healthy+=(auth); else
		unhealthy+=(auth)
		rc=1
	fi
	if check_aide "$aide_required" "$json"; then healthy+=(aide); else
		unhealthy+=(aide)
		rc=1
	fi

	local overall="up"
	if [[ ${#unhealthy[@]} -eq 0 ]]; then
		overall="up"
	elif [[ ${#healthy[@]} -eq 0 ]]; then
		overall="down"
	else overall="degraded"; fi

	if [[ "$json" == true ]]; then
		# Print a compact JSON summary with proper arrays
		printf '{"timestamp":"%s","summary":true,"overall":"%s","healthy":[%s],"unhealthy":[%s]}\n' \
			"$(ts)" "$overall" "$(json_arr ${healthy[@]+"${healthy[@]}"})" "$(json_arr ${unhealthy[@]+"${unhealthy[@]}"})"
	fi

	if [[ "$_errexit_state" == "on" ]]; then set -e; fi
	[[ "$overall" == "up" ]]
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
		check "$@"
		exit $?
		;;
	*)
		log "unknown command: $cmd"
		usage
		exit 2
		;;
	esac
}

main "$@"
