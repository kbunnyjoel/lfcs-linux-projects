#!/usr/bin/env bats

# Basic tests for src/watch.sh. These focus on single-iteration ("--once")
# behaviour and simple restart side‑effects, without requiring JSON parsing.

# If you have a shared helpers file, load it; otherwise continue silently.
bats_load_safe "./fixtures/helpers"

setup() {
  TMPDIR="$(mktemp -d)"
  mkdir -p "$TMPDIR"

  # Tiny helpers we control inside the test sandbox
  HEALTH_FILE="$TMPDIR/health.state"
  RESTART_FLAG="$TMPDIR/restarted.flag"

  # Health script: exits 0 when HEALTH_FILE contains "ok", otherwise 1
  cat >"$TMPDIR/health.sh" <<'HSH'
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="${HEALTH_FILE:-}"
if [[ -z "${STATE_FILE}" ]]; then
  echo "HEALTH_FILE not set" >&2; exit 2
fi
if [[ -f "$STATE_FILE" ]] && grep -qx "ok" "$STATE_FILE"; then
  exit 0
else
  exit 1
fi
HSH
  chmod +x "$TMPDIR/health.sh"

  # Restart script: marks a flag and flips health to ok
  cat >"$TMPDIR/restart.sh" <<'RSH'
#!/usr/bin/env bash
set -euo pipefail
: >"${RESTART_FLAG:?}"
echo ok >"${HEALTH_FILE:?}"
exit 0
RSH
  chmod +x "$TMPDIR/restart.sh"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "healthy check exits 0 and does not restart" {
  # Start healthy
  echo ok >"$HEALTH_FILE"

  run bash -lc "HEALTH_FILE='$HEALTH_FILE' RESTART_FLAG='$RESTART_FLAG' TMPDIR='$TMPDIR' \
    src/watch.sh --health-cmd '$TMPDIR/health.sh' \
                  --restart-cmd '$TMPDIR/restart.sh' \
                  --interval 0 --max-retries 0 --once"

  echo "OUTPUT: $output"
  [ "$status" -eq 0 ]
  [ ! -f "$RESTART_FLAG" ]
}

@test "unhealthy triggers single restart and then passes with retry" {
  # Start unhealthy (no health.state), expect one restart then success
  run bash -lc "HEALTH_FILE='$HEALTH_FILE' RESTART_FLAG='$RESTART_FLAG' TMPDIR='$TMPDIR' \
    src/watch.sh --health-cmd '$TMPDIR/health.sh' \
                  --restart-cmd '$TMPDIR/restart.sh' \
                  --interval 0 --max-retries 1"

  echo "OUTPUT: $output"
  [ "$status" -eq 0 ]
  [ -f "$RESTART_FLAG" ]
}

@test "unhealthy with --once performs check only (no restart) and exits non-zero" {
  # Start unhealthy and run with --once > should not restart, should fail
  run bash -lc "HEALTH_FILE='$HEALTH_FILE' RESTART_FLAG='$RESTART_FLAG' TMPDIR='$TMPDIR' \
    src/watch.sh --health-cmd '$TMPDIR/health.sh' \
                  --restart-cmd '$TMPDIR/restart.sh' \
                  --interval 0 --max-retries 0 --once"

  echo "OUTPUT: $output"
  [ "$status" -ne 0 ]
  [ ! -f "$RESTART_FLAG" ]
}

@test "healthy emits JSON with overall=up when --json" {
  # Start healthy and request JSON output; verify structure without depending on service list
  echo ok >"$HEALTH_FILE"

  run bash -lc "HEALTH_FILE='$HEALTH_FILE' RESTART_FLAG='$RESTART_FLAG' TMPDIR='$TMPDIR' \
    src/watch.sh --health-cmd '$TMPDIR/health.sh' \
                  --restart-cmd '$TMPDIR/restart.sh' \
                  --interval 0 --max-retries 0 --once --json"

  echo "RAW OUTPUT: $output"
  [ "$status" -eq 0 ]
  # Extract the last JSON object from mixed stdout (logs + JSON)
  json_only="$(printf '%s\n' "$output" | awk '/^{/{buf=$0} END{print buf}')"
  echo "JSON ONLY: $json_only"
  echo "$json_only" | jq -e '.overall == "up" and (.timestamp|length>0)' >/dev/null
}

@test "unhealthy emits JSON with overall=degraded and exits non-zero when --once --json" {
  # Start unhealthy; do not restart; expect non-zero and JSON with degraded
  run bash -lc "HEALTH_FILE='$HEALTH_FILE' RESTART_FLAG='$RESTART_FLAG' TMPDIR='$TMPDIR' \
    src/watch.sh --health-cmd '$TMPDIR/health.sh' \
                  --restart-cmd '$TMPDIR/restart.sh' \
                  --interval 0 --max-retries 0 --once --json"

  echo "RAW OUTPUT: $output"
  [ "$status" -ne 0 ]
  # Extract the last JSON object (overall/degraded) in case logs or notify JSON precede it
  json_only="$(printf '%s\n' "$output" | awk '/^{/{buf=$0} END{print buf}')"
  echo "JSON ONLY: $json_only"
  echo "$json_only" | jq -e '.overall == "degraded" and (.timestamp|length>0)' >/dev/null
  [ ! -f "$RESTART_FLAG" ]
}
