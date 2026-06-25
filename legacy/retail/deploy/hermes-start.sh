#!/bin/bash
# Hermes Agent sandbox entrypoint for the retail demo.
#
# Port layout:
#   Hermes Gateway (chat API):  127.0.0.1:18642
#   Hermes Dashboard (web UI):  0.0.0.0:9119 (gated mode — Hermes OIDC)
#
# Dashboard binds 0.0.0.0 which activates Hermes gated/OAuth mode.
# Users authenticate via Keycloak OIDC — no external OAuth proxy needed.
#
# Secrets: OPENAI_API_KEY is passed via `env` on the sandbox create command.
# Config writing is idempotent — on first boot it writes configs with the real
# API key. On subsequent boots (PVC-backed restarts) existing configs are kept.

export TERM=xterm-256color
export HERMES_HOME=/sandbox/.hermes
export HERMES_TUI_DIR="/opt/hermes/ui-tui"

# Active profile — prefer env var (injected at sandbox create), fall back to file
ACTIVE="${HERMES_ACTIVE_PROFILE:-$(cat /sandbox/.hermes/active_profile 2>/dev/null || echo "retail-sales")}"
echo "$ACTIVE" > /sandbox/.hermes/active_profile
set -a
[ -f /sandbox/.hermes/.env ] && source /sandbox/.hermes/.env
[ -f "/sandbox/.hermes/profiles/${ACTIVE}/.env" ] && source "/sandbox/.hermes/profiles/${ACTIVE}/.env"
set +a

# Self-hosted OIDC provider for Hermes gated mode (Keycloak)
export HERMES_DASHBOARD_OIDC_ISSUER="${HERMES_DASHBOARD_OIDC_ISSUER:-https://keycloak-keycloak.apps.sno.sandbox1254.opentlc.com/realms/prelude-m6wl4-vs9lb}"
export HERMES_DASHBOARD_OIDC_CLIENT_ID="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-hermes-dashboard}"

# Public URL (for OAuth redirects)
PUBLIC_URL="${HERMES_PUBLIC_URL:-https://retail-hermes.apps.prelude-m6wl4-vs9lb.sandbox1832.opentlc.com}"

# Write config.yaml files ONLY on first boot (when configs still have the
# placeholder or don't exist). On PVC-backed restarts, preserve user edits.
# Derive department from active profile for MCP upstream URL
DEPT=$(echo "$ACTIVE" | sed 's/retail-//')
export MCP_UPSTREAM_URL="http://retail-${DEPT}-mcp.openshell.svc.cluster.local:9090"
export INFERENCE_UPSTREAM_URL="http://maas.apps.ocp.cloud.rhai-tmm.dev/prelude-maas/qwen36-27b"
export MCP_PROXY_PORT=8889

if [ -n "${OPENAI_API_KEY:-}" ]; then
  for profile_dir in /sandbox/.hermes/profiles/retail-*/; do
    [ -d "$profile_dir" ] || continue
    pdept=$(basename "$profile_dir" | sed 's/retail-//')
    cat > "${profile_dir}/config.yaml" << CFGEOF
model:
  provider: custom
  model: qwen36-27b
  base_url: http://127.0.0.1:${MCP_PROXY_PORT}/v1
  api_key: "proxy-managed"
dashboard:
  theme: redhat
  public_url: "${PUBLIC_URL}"
mcp_servers:
  retail-${pdept}:
    url: http://127.0.0.1:${MCP_PROXY_PORT}/mcp
CFGEOF
  done

  cat > /sandbox/.hermes/config.yaml << CFGEOF
model:
  provider: custom
  model: qwen36-27b
  base_url: http://127.0.0.1:${MCP_PROXY_PORT}/v1
  api_key: "proxy-managed"
dashboard:
  theme: redhat
  public_url: "${PUBLIC_URL}"
mcp_servers: {}
CFGEOF

  # Normalize config on first boot
  /usr/local/bin/hermes config migrate 2>/dev/null || true
fi

# Start dashboard FIRST — it runs the auth proxy on :8889.
# The proxy must be ready before the gateway tries MCP connections.
GATEWAY_HEALTH_URL="http://127.0.0.1:18642" \
  /usr/local/bin/hermes dashboard \
    --host 0.0.0.0 \
    --port 9119 \
    --skip-build \
    --no-open &
DASHBOARD_PID=$!

# Wait for auth proxy to be ready
for i in $(seq 1 30); do
  if curl -sf --max-time 2 "http://127.0.0.1:${MCP_PROXY_PORT}/health" >/dev/null 2>&1 || \
     python3 -c "import socket; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1',${MCP_PROXY_PORT})); s.close()" 2>/dev/null; then
    break
  fi
  sleep 1
done
sleep 2

# Wait for outbound network to be ready. The sandbox supervisor's
# transparent proxy needs a few seconds after the relay bridge is
# established before outbound HTTP connections work reliably.
# Without this, the MCP proxy's initial connection fails with 503,
# which permanently kills the hermes MCP event loop.
for i in $(seq 1 30); do
  if curl -sf --max-time 3 "${MCP_UPSTREAM_URL}/mcp" -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"ping","id":0}' >/dev/null 2>&1; then
    echo "MCP upstream reachable"
    break
  fi
  sleep 2
done

# Strip all credentials from env before starting the gateway.
# The dashboard holds them in memory; the agent must never see them.
unset OPENAI_API_KEY 2>/dev/null

# Start gateway after proxy is ready
API_SERVER_ENABLED=true API_SERVER_PORT=18642 API_SERVER_HOST=127.0.0.1 \
  API_SERVER_KEY="spice-must-flow-$(date +%s | sha256sum | head -c 16)" \
  /usr/local/bin/hermes gateway run --accept-hooks &
GATEWAY_PID=$!

sleep infinity
