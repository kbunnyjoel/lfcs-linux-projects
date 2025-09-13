#!/usr/bin/env bash
# restart.sh - test fixture stub
# Simulates restarting a service for Project 5 watchdog

echo "[fixture] Restarting service..."
touch /tmp/healthy.flag
exit 0
 
#!/usr/bin/env bash
# restart.sh - test fixture stub for Project 5 watchdog
# Simulates restarting a service:
#  - touches a restart flag (path from $RESTART_FLAG or default)
#  - marks service healthy by creating a health flag (path from $HEALTHY_FLAG or default)

set -euo pipefail

RESTART_FLAG="${RESTART_FLAG:-/tmp/restarted.flag}"
HEALTHY_FLAG="${HEALTHY_FLAG:-/tmp/healthy.flag}"

echo "[fixture] Restarting service..."
# Record that a restart happened (used by tests)
touch "$RESTART_FLAG"
# Make the next health check succeed
touch "$HEALTHY_FLAG"

exit 0
