#!/bin/bash
# Wait for supervisor network relay before starting Hermes.
echo "Waiting for network relay..."
for i in $(seq 1 60); do
  if getent hosts openshell.openshell.svc.cluster.local >/dev/null 2>&1; then
    echo "Network ready after $((i * 2))s"
    break
  fi
  sleep 2
done
exec /usr/local/bin/hermes-start.sh
