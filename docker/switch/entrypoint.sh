#!/usr/bin/env bash
set -euo pipefail

# Start both switchd and relay in the same container
echo "[entrypoint] Starting radio-switchd + radio-hls-relay"

python3 /app/switchd.py &
SWITCHD_PID=$!

# Give switchd a moment to create /run/radio/active
sleep 2

python3 /app/relay.py &
RELAY_PID=$!

# Wait for either to exit (shouldn't happen), then restart container
wait -n $SWITCHD_PID $RELAY_PID
echo "[entrypoint] A process exited unexpectedly, container will restart"
exit 1
