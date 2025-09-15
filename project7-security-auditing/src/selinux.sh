#!/usr/bin/env bash
# SELinux detection helpers (real-mode aware)
# Provides se_detect that sets two global variables:
#   SE_PRESENT=true|false
#   SE_MODE=enforcing|permissive|disabled|unknown

set -euo pipefail

# Normalize string to lowercase
_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

se_detect() {
	# shellcheck disable=SC2034  # exported for consumer script
	SE_PRESENT=false
	# shellcheck disable=SC2034  # exported for consumer script
	SE_MODE="unknown"
	local _getenforce="${SEC_GETENFORCE:-}"
	local _sestatus="${SEC_SESTATUS:-}"

	[[ -n "$_getenforce" ]] || _getenforce=$(command -v getenforce 2>/dev/null || true)
	[[ -n "$_sestatus" ]] || _sestatus=$(command -v sestatus 2>/dev/null || true)

	if [[ -n "$_getenforce" ]]; then
		# shellcheck disable=SC2034  # exported for consumer script
		SE_PRESENT=true
		local m
		m=$($_getenforce 2>/dev/null || echo "unknown")
		m=$(_lower "$m")
		case "$m" in
		enforcing | permissive | disabled)
			# shellcheck disable=SC2034  # exported for consumer script
			SE_MODE="$m"
			;;
		*)
			# shellcheck disable=SC2034  # exported for consumer script
			SE_MODE="unknown"
			;;
		esac
		return 0
	fi

	if [[ -n "$_sestatus" ]]; then
		# Typical outputs contain lines:
		#   SELinux status:                 enabled|disabled
		#   Current mode:                   enforcing|permissive
		local out status mode
		out=$($_sestatus 2>/dev/null || true)
		status=$(echo "$out" | awk -F: '/SELinux status/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
		status=$(_lower "${status:-}")
		if [[ "$status" == "enabled" ]]; then
			# shellcheck disable=SC2034  # exported for consumer script
			SE_PRESENT=true
			mode=$(echo "$out" | awk -F: '/Current mode/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
			mode=$(_lower "${mode:-}")
			case "$mode" in
			enforcing | permissive)
				# shellcheck disable=SC2034  # exported for consumer script
				SE_MODE="$mode"
				;;
			*)
				# shellcheck disable=SC2034  # exported for consumer script
				SE_MODE="unknown"
				;;
			esac
		elif [[ "$status" == "disabled" ]]; then
			# shellcheck disable=SC2034  # exported for consumer script
			SE_PRESENT=true
			# shellcheck disable=SC2034  # exported for consumer script
			SE_MODE="disabled"
		else
			# Unknown status
			# shellcheck disable=SC2034  # exported for consumer script
			SE_PRESENT=false
			# shellcheck disable=SC2034  # exported for consumer script
			SE_MODE="unknown"
		fi
		return 0
	fi

	# Neither tool available
	# shellcheck disable=SC2034  # exported for consumer script
	SE_PRESENT=false
	# shellcheck disable=SC2034  # exported for consumer script
	SE_MODE="unknown"
}
