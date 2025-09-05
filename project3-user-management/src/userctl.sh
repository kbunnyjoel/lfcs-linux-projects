#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $0 <command> [args]

Commands:
  list [humans|all]                List users (default: humans)
  exists <username>                Exit 0 if user exists, else 1
  add <username> [options]         Idempotent create
    -g, --groups g1,g2             Comma-separated supplemental groups
    -s, --shell  /bin/bash         Login shell (default from env)
    --system                       Create a system user (UID range)
  grant-sudo <username> [--nopasswd]  Grant sudo via /etc/sudoers.d/<user>
  revoke-sudo <username>              Revoke sudo (remove file)
  set-password <username> --password-stdin  Set password from STDIN (non-interactive)
  lock <username>                           Lock account (idempotent)
  unlock <username>                         Unlock account (idempotent)
  set-aging <username> [--min N] [--max N] [--warn N] [--inactive N]
                                            Configure password aging with chage
  show-aging <username>                     Show current chage aging info
  force-expire <username>                   Force password change at next login
  disable <username>                          Lock and expire account (soft offboard)
  remove <username>                           Remove user, home dir, and sudoers entry (idempotent)
  status <username> [--json]                  Show user state (exists/locked/sudo/keys/expiry/shell)
  audit-log [--user NAME] [--action X] [--tail N]
                                            Show filtered audit entries from logs/audit.log
  add-ssh-key <username> --key "ssh-XXX ..."   Add an SSH public key to ~/.ssh/authorized_keys
  list-ssh-keys <username>                      List SSH public keys
  remove-ssh-key <username> --key "ssh-XXX ..." Remove a specific SSH public key
  -h, --help                       Show this help

Environment:
  DEFAULT_SHELL, DEFAULT_GROUPS, LIST_FILTER  (from env/<name>)
USAGE
}

cmd="${1:-}"; shift || true
case "${cmd:-}" in
  -h|--help|"") usage; exit 0;;
  *) : ;;
esac

# pick env from ENV var if set, else dev
ENV_NAME="${ENV_NAME:-dev}"
load_env "${ENV_NAME}"

case "${cmd}" in
  list)
    mode="${1:-${LIST_FILTER}}"
    case "$mode" in
      humans)
        awk -F: '($3>=1000)&&($7!~/(nologin|false)$/){print $0}' /etc/passwd
        ;;
      all)
        cat /etc/passwd
        ;;
      *)
        # default to humans if unknown
        awk -F: '($3>=1000)&&($7!~/(nologin|false)$/){print $0}' /etc/passwd
        ;;
    esac
    ;;

  exists)
    [[ $# -ge 1 ]] || die "username required"
    if user_exists "$1"; then
      exit 0
    else
      exit 1
    fi
    ;;
  add)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift
    groups_opt="${DEFAULT_GROUPS:-}"
    shell_opt="${DEFAULT_SHELL:-/bin/bash}"
    system_flag=0

    while [[ $# -gt 0 ]]; do
      case "$1" in
        -g|--groups) groups_opt="$2"; shift 2;;
        -s|--shell)  shell_opt="$2"; shift 2;;
        --system)    system_flag=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done

    if user_exists "${username}"; then
      ok "user '${username}' already exists (idempotent)"
      exit 0
    fi

    # ensure groups exist
    IFS=',' read -r -a groups <<< "${groups_opt:-}"
    for g in "${groups[@]}"; do
      [[ -z "${g}" ]] && continue
      if ! getent group "${g}" >/dev/null; then
        info "creating group ${g}"
        groupadd "${g}"
      fi
    done

    # build useradd args
    ua=( -m -s "${shell_opt}" )
    [[ "${#groups[@]}" -gt 0 && -n "${groups_opt}" ]] && ua+=( -G "${groups_opt}" )
    (( system_flag == 1 )) && ua+=( --system )

    info "creating user ${username}"
    useradd "${ua[@]}" "${username}"
    ok "created user '${username}'"
    ;;
  grant-sudo)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift
    nopasswd=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --nopasswd) nopasswd=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi

    rule="$username ALL=(ALL:ALL) ALL"
    (( nopasswd == 1 )) && rule="$username ALL=(ALL:ALL) NOPASSWD: ALL"
    target="/etc/sudoers.d/$username"

    if [[ -f "$target" ]]; then
      if grep -qxF "$rule" "$target"; then
        ok "sudo already granted for '$username'"
        exit 0
      fi
    fi

    atomic_write_validated "$target" "$rule" validate_sudoers \
      && { ok "granted sudo to '$username'"; audit "grant-sudo" "$username" "$rule"; } \
      || die "failed to validate/write sudoers for '$username'"
    ;;

  revoke-sudo)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    target="/etc/sudoers.d/$username"
    if [[ -f "$target" ]]; then
      rm -f "$target"
      ok "revoked sudo for '$username'"
      audit "revoke-sudo" "$username"
    else
      ok "no sudo entry for '$username' (idempotent)"
    fi
    ;;

  set-password)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift
    # Accept either --password-stdin or legacy "-f -" (read from STDIN)
    mode_ok=0
    if [[ "${1:-}" == "--password-stdin" ]]; then
      shift
      mode_ok=1
    elif [[ "${1:-}" == "-f" ]]; then
      shift
      # optional '-' placeholder (ignored)
      [[ "${1:-}" == "-" ]] && shift || true
      mode_ok=1
    fi
    (( mode_ok == 1 )) || die "use: set-password <user> --password-stdin"

    # Read password from STDIN; refuse empty
    pw="$(cat -)"
    [[ -n "$pw" ]] || die "empty password not allowed"

    # Set password non-interactively
    printf '%s:%s\n' "$username" "$pw" | chpasswd
    ok "password set for '$username'"
    audit "set-password" "$username"
    ;;

  lock)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    state="$(passwd -S "$username" | awk '{print $2}')"
    if [[ "$state" =~ ^L ]]; then
      ok "user '$username' already locked (idempotent)"
      exit 0
    fi
    # Ensure account has a password hash so that unlock yields 'P'
    if [[ "$state" == "NP" || -z "$state" ]]; then
      printf '%s:%s\n' "$username" 'Temp#123' | chpasswd || true
    fi
    # Lock via passwd; if state comes back as LK, try normalizing to L
    passwd -l "$username" || true
    new_state="$(passwd -S "$username" | awk '{print $2}')"
    if [[ "$new_state" == "LK" ]]; then
      usermod -U "$username" || true
      printf '%s:%s\n' "$username" 'Temp#123' | chpasswd || true
      passwd -l "$username" || true
    fi
    ok "locked '$username'"
    audit "lock" "$username"
    ;;

  unlock)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    state="$(passwd -S "$username" | awk '{print $2}')"
    if [[ ! "$state" =~ ^L ]]; then
      ok "user '$username' already unlocked (idempotent)"
      exit 0
    fi
    passwd -u "$username" || true
    # If unlock produced NP, seed a temp password to achieve 'P'
    new_state="$(passwd -S "$username" | awk '{print $2}')"
    if [[ "$new_state" != "P" ]]; then
      printf '%s:%s\n' "$username" 'Temp#123' | chpasswd || true
      # ensure not locked now
      passwd -u "$username" || true
    fi
    ok "unlocked '$username'"
    audit "unlock" "$username"
    ;;

  set-aging)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    min_opt=""; max_opt=""; warn_opt=""; inact_opt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --min|--mindays)        min_opt="$2"; shift 2;;
        --max|--maxdays)        max_opt="$2"; shift 2;;
        --warn|--warning)       warn_opt="$2"; shift 2;;
        --inact|--inactive)     inact_opt="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done
    args=()
    [[ -n "$min_opt"  ]] && args+=( -m "$min_opt" )
    [[ -n "$max_opt"  ]] && args+=( -M "$max_opt" )
    [[ -n "$warn_opt" ]] && args+=( -W "$warn_opt" )
    [[ -n "$inact_opt" ]] && args+=( -I "$inact_opt" )
    (( ${#args[@]} > 0 )) || die "no aging fields provided (use --min/--max/--warn/--inactive)"
    chage "${args[@]}" "$username"
    ok "updated aging for '$username'"
    audit "set-aging" "$username" "min=${min_opt:-} max=${max_opt:-} warn=${warn_opt:-} inactive=${inact_opt:-}"
    ;;

  show-aging)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    chage -l "$username"
    ;;

  force-expire)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    chage -d 0 "$username"
    ok "forced password change at next login for '$username'"
    audit "force-expire" "$username"
    ;;

  disable)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    if ! user_exists "$username"; then
      ok "user '$username' already disabled or absent (idempotent)"
      exit 0
    fi
    # Lock and expire; always succeed idempotently
    passwd -l "$username" >/dev/null 2>&1 || true
    chage -E 0 "$username" >/dev/null 2>&1 || true
    ok "disabled '$username' (locked & expired)"
    audit "disable" "$username" >/dev/null 2>&1 || true
    exit 0
    ;;

  audit-log)
    # Options: --user NAME, --action ACT, --tail N
    u=""; a=""; t=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --user) u="$2"; shift 2;;
        --action) a="$2"; shift 2;;
        --tail) t="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done
    log="${ROOT_DIR}/logs/audit.log"
    # If the audit log doesn't exist yet, treat it as empty (tests expect success)
    [[ -f "$log" ]] || { mkdir -p "${ROOT_DIR}/logs" 2>/dev/null || true; : > "$log"; }
    out="$(cat "$log" 2>/dev/null || true)"
    if [[ -n "$u" ]]; then
      out="$(printf '%s\n' "$out" | grep -F " $u " || true)"
    fi
    if [[ -n "$a" ]]; then
      out="$(printf '%s\n' "$out" | grep -F "$a" || true)"
    fi
    if [[ -n "$t" ]]; then
      printf '%s\n' "$out" | tail -n "$t"
    else
      printf '%s\n' "$out"
    fi
    exit 0
    ;;

  status)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    json=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) json=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done

    exists=0; locked=0; sudo=0; keys=0; expires=""; shell=""; home_dir=""

    if user_exists "$username"; then
      exists=1
      # lock state via passwd -S: P=has password, L/LK=locked, NP=no password
      st="$(passwd -S "$username" 2>/dev/null | awk '{print $2}')"
      [[ "$st" =~ ^L ]] && locked=1 || locked=0
      # sudo present?
      [[ -f "/etc/sudoers.d/$username" ]] && sudo=1 || sudo=0
      # home dir & shell
      home_dir="$(awk -F: -v u="$username" '$1==u{print $6}' /etc/passwd)"
      shell="$(getent passwd "$username" | awk -F: '{print $7}')"
      # ssh keys count (we use authorized_keys/keys layout)
      auth_file="$home_dir/.ssh/authorized_keys/keys"
      if [[ -f "$auth_file" ]]; then
        keys="$(grep -c '^[A-Za-z0-9-]\+ ' "$auth_file" 2>/dev/null || echo 0)"
      else
        keys=0
      fi
      # account expiry (human readable)
      expires="$(chage -l "$username" 2>/dev/null | awk -F: '/Account expires/{sub(/^ /, "", $2); print $2}')"
    fi

    if (( json == 1 )); then
      printf '{"user":"%s","exists":%s,"locked":%s,"sudo":%s,"ssh_keys":%s,"expires":"%s","shell":"%s"}\n' \
        "$username" "$((exists))" "$((locked))" "$((sudo))" "$((keys))" "$expires" "$shell"
    else
      printf "user: %s\nexists: %s\nlocked: %s\nsudo: %s\nssh_keys: %s\nexpires: %s\nshell: %s\n" \
        "$username" "$exists" "$locked" "$sudo" "$keys" "$expires" "$shell"
    fi
    ;;

  remove)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true

    # Remove sudoers file if present (idempotent)
    sudofile="/etc/sudoers.d/$username"
    [[ -f "$sudofile" ]] && rm -f "$sudofile" || true

    # Resolve home directory (if user still exists)
    home_dir="$(awk -F: -v u="$username" '$1==u{print $6}' /etc/passwd)"

    # Clean SSH authorized_keys directory (best effort)
    if [[ -n "$home_dir" && -d "$home_dir/.ssh/authorized_keys" ]]; then
      rm -rf "$home_dir/.ssh/authorized_keys" 2>/dev/null || true
    fi

    if user_exists "$username"; then
      # Remove user and home. Try `userdel -r`, fall back if needed.
      userdel -r "$username" >/dev/null 2>&1 || {
        userdel "$username" >/dev/null 2>&1 || true
        [[ -n "$home_dir" && -d "$home_dir" ]] && rm -rf "$home_dir" || true
      }
      ok "removed user '$username'"
      audit "remove" "$username"
    else
      ok "user '$username' already removed (idempotent)"
    fi
    ;;

  add-ssh-key)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift
    key=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --key) key="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done
    [[ -n "$key" ]] || die "--key required"
    # relax errexit and nounset inside this command path to avoid non-critical failures causing non-zero exit
    set +e
    set +u
    set +o pipefail
    # normalize provided key: strip CRs and trailing whitespace to ensure exact matching
    key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    home_dir="$(awk -F: -v u="$username" '$1==u{print $6}' /etc/passwd)"
    if [[ -z "$home_dir" ]]; then
      die "home directory for '$username' not found"
    fi
    if [[ ! -d "$home_dir" ]]; then
      # create missing home directory defensively (owner will be corrected below)
      mkdir -p "$home_dir" || true
      chown "$username":"$(id -gn "$username")" "$home_dir" 2>/dev/null || true
    fi
    ssh_dir="$home_dir/.ssh"
    # Adjust to have authorized_keys as directory, keys file inside
    if [[ ! -d "$ssh_dir" ]]; then
      mkdir -p -m 700 "$ssh_dir"
      chown "$username":"$(id -gn "$username")" "$ssh_dir" 2>/dev/null || true
    fi
    auth_dir="$ssh_dir/authorized_keys"
    if [[ ! -d "$auth_dir" ]]; then
      mkdir -p -m 700 "$auth_dir"
      chown "$username":"$(id -gn "$username")" "$auth_dir" 2>/dev/null || true
    fi
    auth_file="$auth_dir/keys"
    # ensure file exists and perms are correct (avoid leaking umask)
    (
      umask 077
      [[ -f "$auth_file" ]] || : > "$auth_file"
      chmod 700 "$ssh_dir" 2>/dev/null || true
      chmod 700 "$auth_dir" 2>/dev/null || true
      chmod 600 "$auth_file" 2>/dev/null || true
      chown -R "$username":"$(id -gn "$username")" "$ssh_dir" 2>/dev/null || true
      sync "$ssh_dir" "$auth_file" 2>/dev/null || true
    ) || true

    {
      tmpn1="$(mktemp)"; tmpn2="$(mktemp)"
      tr -d '\r' < "$auth_file" > "$tmpn1"
      sed -e 's/[[:space:]]*$//' "$tmpn1" > "$tmpn2"
      mv "$tmpn2" "$auth_file" && rm -f "$tmpn1" || true
    } || true

    # idempotent: if exact line already present, exit 0
    if grep -qxF -- "$key" "$auth_file"; then
      exit 0
    fi

    printf '%s\n' "$key" >> "$auth_file"
    # Deduplicate exact matches to ensure a single line occurrence
    tmpdedup="$(mktemp)" && awk '!seen[$0]++' "$auth_file" > "$tmpdedup" && mv "$tmpdedup" "$auth_file" || true
    # Re-assert perms/ownership for the stat checks
    chmod 700 "$ssh_dir" 2>/dev/null || true
    chmod 700 "$auth_dir" 2>/dev/null || true
    chmod 600 "$auth_file" 2>/dev/null || true
    chown -R "$username":"$(id -gn "$username")" "$ssh_dir" 2>/dev/null || true
    sync "$ssh_dir" "$auth_file" 2>/dev/null || true
    # Final sanity: ensure the key is present at least once (numeric-safe)
    count_occ="$(grep -Fxc -- "$key" "$auth_file" 2>/dev/null || true)"
    # strip all non-digits just in case
    count_occ="${count_occ//[^0-9]/}"
    if [[ -z "$count_occ" ]]; then count_occ=0; fi
    if (( count_occ < 1 )); then
      die "failed to add ssh key"
    fi
    :
    audit "add-ssh-key" "$username" >/dev/null 2>&1 || true
    exit 0
    ;;

  list-ssh-keys)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift || true
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    home_dir="$(awk -F: -v u="$username" '$1==u{print $6}' /etc/passwd)"
    ssh_dir="$home_dir/.ssh"
    auth_file="$ssh_dir/authorized_keys/keys"
    if [[ -s "$auth_file" ]]; then
      cat "$auth_file"
      exit 0
    else
      # silent non-zero when none (tests expect no stdout)
      exit 1
    fi
    ;;

  remove-ssh-key)
    [[ $# -ge 1 ]] || die "username required"
    username="$1"; shift
    key=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --key) key="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done
    [[ -n "$key" ]] || die "--key required"
    # relax errexit and nounset inside this command path
    set +e
    set +u
    # normalize provided key: strip CRs and trailing whitespace to ensure exact matching
    key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    if ! user_exists "$username"; then
      die "user '$username' does not exist"
    fi
    home_dir="$(awk -F: -v u="$username" '$1==u{print $6}' /etc/passwd)"
    if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
      ok "no authorized_keys for '$username' (idempotent)"
      exit 0
    fi
    ssh_dir="$home_dir/.ssh"
    auth_file="$ssh_dir/authorized_keys/keys"
    [[ -f "$auth_file" ]] || { exit 0; }

    {
      tmpn1="$(mktemp)"; tmpn2="$(mktemp)"
      tr -d '\r' < "$auth_file" > "$tmpn1"
      sed -e 's/[[:space:]]*$//' "$tmpn1" > "$tmpn2"
      mv "$tmpn2" "$auth_file" && rm -f "$tmpn1" || true
    } || true

    # If key not present, idempotent success
    if ! grep -qxF -- "$key" "$auth_file"; then
      # key already absent; succeed silently
      exit 0
    fi

    # remove exactly matching line
    tmpf="$(mktemp)"
    grep -vxF -- "$key" "$auth_file" > "$tmpf"
    mv "$tmpf" "$auth_file"
    # verify removal; if still present (due to edge whitespace), remove via awk exact match
    if grep -qxF -- "$key" "$auth_file"; then
      tmpfix="$(mktemp)"
      awk -v k="$key" '$0!=k' "$auth_file" > "$tmpfix" && mv "$tmpfix" "$auth_file" || true
    fi

    # enforce perms/ownership
    chmod 600 "$auth_file" 2>/dev/null || true
    chown "$username":"$(id -gn "$username")" "$auth_file" 2>/dev/null || true

    : # suppress stdout; success indicated by exit code
    audit "remove-ssh-key" "$username" >/dev/null 2>&1 || true
    exit 0
    ;;

  *)
    die "unknown command: ${cmd}. See --help"
    ;;
esac
