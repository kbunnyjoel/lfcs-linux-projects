#!/usr/bin/env bash
# AppArmor detection helpers (real-mode aware)
# Provides aa_detect that sets two global variables (read by sec.sh):
#   AA_PRESENT=true|false
#   AA_ENABLED=true|false

set -euo pipefail

aa_detect() {
	# shellcheck disable=SC2034  # exported for consumer script
	AA_PRESENT=false
	# shellcheck disable=SC2034  # exported for consumer script
	AA_ENABLED=false

	local _aastatus="${SEC_AASTATUS:-}"
	[[ -n "$_aastatus" ]] || _aastatus=$(command -v aa-status 2>/dev/null || true)

	if [[ -n "$_aastatus" ]]; then
		# shellcheck disable=SC2034  # exported for consumer script
		AA_PRESENT=true
		local out
		out=$($_aastatus 2>/dev/null || true)
		# Consider enabled if output suggests the module is loaded or profiles in enforce
		if echo "$out" | grep -Eiq 'module is loaded|profiles.*enforce'; then
			# shellcheck disable=SC2034  # exported for consumer script
			AA_ENABLED=true
			return 0
		fi
		# Some aa-status versions exit nonzero when disabled; keep present but disabled=false
		AA_ENABLED=false
		return 0
	fi

	# Fallback: check kernel module parameter (read-only, if present)
	if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
		# shellcheck disable=SC2034  # exported for consumer script
		AA_PRESENT=true
		if grep -Eq 'Y|yes|enforce|complain' /sys/module/apparmor/parameters/enabled 2>/dev/null; then
			# shellcheck disable=SC2034  # exported for consumer script
			AA_ENABLED=true
		fi
		return 0
	fi

	# Not present
	# shellcheck disable=SC2034  # exported for consumer script
	AA_PRESENT=false
	# shellcheck disable=SC2034  # exported for consumer script
	AA_ENABLED=false
}
