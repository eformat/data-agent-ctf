#!/bin/bash
# Wait for supervisor network relay before starting Hermes.
# Parse host:port from OPENSHELL_ENDPOINT (already set in sandbox env).
GW_HOST=$(echo "${OPENSHELL_ENDPOINT}" | sed 's|https\?://||;s|:.*||')
GW_PORT=$(echo "${OPENSHELL_ENDPOINT}" | sed 's|.*:||')
echo "Waiting for network relay (${GW_HOST}:${GW_PORT})..."
for i in $(seq 1 60); do
  if python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('${GW_HOST}',${GW_PORT})); s.close()" 2>/dev/null; then
    echo "Network ready after $((i * 2))s"
    break
  fi
  sleep 2
done
exec /usr/local/bin/hermes-start.sh
