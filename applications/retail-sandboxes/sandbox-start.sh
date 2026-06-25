#!/bin/bash
# Wait for supervisor network relay before starting Hermes.
# The sandbox namespace routes HTTP through the supervisor proxy.
echo "Waiting for network relay..."
for i in $(seq 1 60); do
  if curl -sf --max-time 3 http://openshell.openshell.svc.cluster.local:8080 >/dev/null 2>&1; then
    echo "Network ready after $((i * 2))s"
    break
  fi
  sleep 2
done
exec /usr/local/bin/hermes-start.sh
