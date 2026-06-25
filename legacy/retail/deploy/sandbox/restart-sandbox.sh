#!/bin/bash
# Restart a single retail sandbox. Deletes, recreates, waits, exposes.
# Usage: ./restart-sandbox.sh <dept>   (finance|sales|ops)
#        ./restart-sandbox.sh all      (all 3)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
GATEWAY="${OPENSHELL_GATEWAY:-prelude2-final}"
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')}"
HERMES_IMAGE="${HERMES_IMAGE:-quay.io/eformat/hermes-openshell:latest}"
OIDC_ISSUER="${HERMES_DASHBOARD_OIDC_ISSUER:-https://keycloak-keycloak.apps.sno.sandbox1254.opentlc.com/realms/prelude-m6wl4-vs9lb}"
OIDC_CLIENT="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-hermes-dashboard}"

if [ -z "${OPENAI_API_KEY:-}" ]; then echo "ERROR: OPENAI_API_KEY must be set"; exit 1; fi

restart_one() {
  local dept="$1"
  local name="retail-${dept}"
  echo "=== Restarting ${name} ==="

  openshell sandbox delete "$name" -g "$GATEWAY" 2>/dev/null || true
  sleep 3

  UPLOAD_DIR=$(mktemp -d)
  mkdir -p "$UPLOAD_DIR/profiles/retail-"{finance,sales,ops}
  echo "GATEWAY_ALLOW_ALL_USERS=true" > "$UPLOAD_DIR/.env"
  for d in finance sales ops; do cp "$UPLOAD_DIR/.env" "$UPLOAD_DIR/profiles/retail-${d}/.env"; done
  echo "retail-${dept}" > "$UPLOAD_DIR/active_profile"

  # Generate per-department OPA policy (only this dept's MCP server)
  local dept_policy="/tmp/policy-retail-${dept}.yaml"
  sed "/retail-.*-mcp/{/retail-${dept}-mcp/!{N;d;}}" \
      "$DEPLOY_DIR/policy-retail.yaml" > "$dept_policy"

  timeout 120 openshell sandbox create -g "$GATEWAY" \
    --name "$name" --from "$HERMES_IMAGE" \
    --upload "$UPLOAD_DIR:/sandbox/.hermes" \
    --policy "$dept_policy" \
    --no-tty \
    -- env OPENAI_API_KEY="${OPENAI_API_KEY}" \
           GATEWAY_ALLOW_ALL_USERS=true \
           HERMES_ACTIVE_PROFILE="retail-${dept}" \
           HERMES_PUBLIC_URL="https://${name}.${APPS_DOMAIN}" \
           HERMES_DASHBOARD_OIDC_ISSUER="${OIDC_ISSUER}" \
           HERMES_DASHBOARD_OIDC_CLIENT_ID="${OIDC_CLIENT}" \
           /usr/local/bin/hermes-start.sh </dev/null >/dev/null 2>&1 &
  local pid=$!

  local ready=false
  for i in $(seq 1 40); do
    local status=$(openshell sandbox list -g "$GATEWAY" 2>/dev/null | grep "$name" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}')
    if [ "$status" = "Ready" ]; then ready=true; break; fi
    echo "  Waiting for ${name}... (${i}/40, status=${status:-not found})"
    sleep 10
  done

  if ! $ready; then
    echo "  WARNING: ${name} not Ready after 400s, attempting expose anyway"
  fi

  local expose_ok=false
  for i in $(seq 1 5); do
    if openshell service expose "$name" 9119 -g "$GATEWAY" 2>&1; then
      expose_ok=true; break
    fi
    echo "  Expose retry ${i}/5..."; sleep 5
  done
  if ! $expose_ok; then echo "  WARNING: expose failed for ${name}"; fi
  rm -rf "$UPLOAD_DIR" "$dept_policy"
  echo "  ${name}: https://${name}.${APPS_DOMAIN}"
}

DEPTS="${1:-all}"
if [ "$DEPTS" = "all" ]; then
  for dept in finance sales ops; do restart_one "$dept"; done
else
  for dept in "$@"; do restart_one "$dept"; done
fi
