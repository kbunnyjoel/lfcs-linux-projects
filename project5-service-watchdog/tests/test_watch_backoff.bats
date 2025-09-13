#!/usr/bin/env bats
# Basic functional tests for watch.sh using temp inline health/restart scripts
# No external fixtures or Docker required.

setup() {
  TMPDIR="$(mktemp -d)"
  export TMPDIR
  HEALTH_CMD="${TMPDIR}/health.sh"
  RESTART_CMD="${TMPDIR}/restart.sh"

  chmod +x src/watch.sh 2>/dev/null || true

  printf '0\n' > "${TMPDIR}/restart_counter"

  cat > "${TMPDIR}/health.sh" <<'HSH'
#!/usr/bin/env bash
set -euo pipefail
cfile="${TMPDIR}/health_count"
cur=$(cat "$cfile" 2>/dev/null || echo 0)
echo $((cur+1)) > "$cfile"

if [ -n "${HEALTH_THRESHOLD:-}" ]; then
  if [ "$((cur+1))" -ge "${HEALTH_THRESHOLD}" ]; then
    exit 0
  else
    exit 1
  fi
else
  case "${HEALTH_MODE:-unhealthy}" in
    healthy) exit 0 ;;
    unhealthy)
      if [ -f "${TMPDIR}/healthy.flag" ]; then exit 0; else exit 1; fi
      ;;
    *) echo "unknown HEALTH_MODE=${HEALTH_MODE}" >&2; exit 2 ;;
  esac
fi
HSH
  chmod +x "${TMPDIR}/health.sh"

  cat > "${TMPDIR}/restart.sh" <<'RSH'
#!/usr/bin/env bash
set -euo pipefail
cfile="${TMPDIR}/restart_counter"
cur=$(cat "$cfile" 2>/dev/null || echo 0)
echo $((cur+1)) > "$cfile"
if [ "${RESTART_SETS_HEALTH:-0}" = "1" ]; then
  : > "${TMPDIR}/healthy.flag"
fi
exit 0
RSH
  chmod +x "${TMPDIR}/restart.sh"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "healthy check exits 0 and does not restart" {
  run bash -lc "HEALTH_MODE=healthy TMPDIR='${TMPDIR}' src/watch.sh check \
    --health-cmd '${TMPDIR}/health.sh' \
    --start-cmd '${TMPDIR}/restart.sh' \
    --restart-cmd '${TMPDIR}/restart.sh' \
    --json >/dev/null"
  echo "OUTPUT: $output"
  [ "$status" -eq 0 ]
  [ "$(cat "${TMPDIR}/restart_counter")" -eq 0 ]
}

@test "unhealthy triggers single restart and then passes with retry" {
  run bash -lc "HEALTH_MODE=unhealthy RESTART_SETS_HEALTH=1 TMPDIR='${TMPDIR}' src/watch.sh check \
    --health-cmd '${TMPDIR}/health.sh' \
    --start-cmd '${TMPDIR}/restart.sh' \
    --restart-cmd '${TMPDIR}/restart.sh' \
    --max-retries 1 --json >/dev/null"
  echo "OUTPUT: $output"
  [ "$status" -eq 0 ]
  [ "$(cat "${TMPDIR}/restart_counter")" -eq 1 ]
}

@test "unhealthy with --once performs check only (no restart) and exits non-zero" {
  run bash -lc "HEALTH_MODE=unhealthy TMPDIR='${TMPDIR}' src/watch.sh check \
    --health-cmd '${TMPDIR}/health.sh' \
    --start-cmd '${TMPDIR}/restart.sh' \
    --restart-cmd '${TMPDIR}/restart.sh' \
    --once --json >/dev/null"
  echo "OUTPUT: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "${TMPDIR}/restart_counter")" -eq 0 ]
}
