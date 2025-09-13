#!/usr/bin/env bash
# restart.sh - simple restart simulation for tests
set -euo pipefail

# Touch a global flag that our health check reads to become healthy
touch /tmp/healthy.flag

# Also increment a simple counter for tests that want to assert a restart happened
: "${RESTART_COUNTER_FILE:=/tmp/restart_counter}"
count=0
if [[ -f "$RESTART_COUNTER_FILE" ]]; then
  count=$(cat "$RESTART_COUNTER_FILE" 2>/dev/null || echo 0)
fi
echo $((count+1)) > "$RESTART_COUNTER_FILE"

echo "[fixture] Restarting service..."
exit 0
