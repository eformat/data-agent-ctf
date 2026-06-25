#!/bin/bash
# Deploy Hermes sandboxes on OpenShell — one per department.
#
# Creates 3 sandboxes (retail-finance, retail-sales, retail-ops), each with:
#   - Its own OpenShift Route (Keycloak OIDC login)
#   - Its own active Hermes profile + MCP server connection
#   - Its own SpiceDB user identity (fred, sally, alex)
#
# Usage:
#   export OPENAI_API_KEY="sk-..."
#   export OPENSHELL_GATEWAY="prelude2-final"
#   ./deploy-sandbox.sh              # deploy all 3
#   ./deploy-sandbox.sh finance      # deploy just finance
#   ./deploy-sandbox.sh sales ops    # deploy sales + ops

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
NS="openshell"
GATEWAY="${OPENSHELL_GATEWAY:-prelude2-final}"
HERMES_IMAGE="${HERMES_IMAGE:-quay.io/eformat/hermes-openshell:latest}"
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')}"
OIDC_ISSUER="${HERMES_DASHBOARD_OIDC_ISSUER:-https://keycloak-keycloak.apps.sno.sandbox1254.opentlc.com/realms/prelude-m6wl4-vs9lb}"
OIDC_CLIENT="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-hermes-dashboard}"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: OPENAI_API_KEY must be set"
  exit 1
fi

# Which departments to deploy (default: all 3)
DEPTS=("${@:-finance sales ops}")
if [ "${1:-}" = "finance" ] || [ "${1:-}" = "sales" ] || [ "${1:-}" = "ops" ]; then
  DEPTS=("$@")
fi

DEST_CA=$(oc get secret openshell-server-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)

deploy_department() {
  local dept="$1"
  local sandbox_name="retail-${dept}"
  local route_host="${sandbox_name}.${APPS_DOMAIN}"
  local profile="retail-${dept}"

  echo ""
  echo "=== Deploying ${sandbox_name} ==="

  # 1. Prepare upload dir with .env files
  local upload_dir
  upload_dir=$(mktemp -d)
  mkdir -p "$upload_dir/profiles/retail-"{finance,sales,ops}
  echo "GATEWAY_ALLOW_ALL_USERS=true" > "$upload_dir/.env"
  for d in finance sales ops; do
    cp "$upload_dir/.env" "$upload_dir/profiles/retail-${d}/.env"
  done
  # Set the active profile for this sandbox
  echo "$profile" > "$upload_dir/active_profile"

  # 2. Create Route (reencrypt TLS → OpenShell gateway → sandbox)
  echo "--- Route: ${route_host} ---"
  cat << ROUTEEOF | oc apply -n "$NS" -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${sandbox_name}
  namespace: $NS
  annotations:
    haproxy.router.openshift.io/timeout: "3600s"
spec:
  host: ${route_host}
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    destinationCACertificate: |
$(echo "$DEST_CA" | sed 's/^/      /')
  port:
    targetPort: grpc
  to:
    kind: Service
    name: openshell
ROUTEEOF

  # 3. Generate per-department OPA policy (only this dept's MCP server)
  local dept_policy="/tmp/policy-retail-${dept}.yaml"
  sed "/retail-.*-mcp/{/retail-${dept}-mcp/!{N;d;}}" \
      "$DEPLOY_DIR/policy-retail.yaml" > "$dept_policy"

  # 4. Create sandbox
  echo "--- Sandbox: ${sandbox_name} ---"
  openshell sandbox delete "$sandbox_name" -g "$GATEWAY" 2>/dev/null || true
  sleep 3

  openshell sandbox create -g "$GATEWAY" \
    --name "$sandbox_name" \
    --from "$HERMES_IMAGE" \
    --upload "$upload_dir:/sandbox/.hermes" \
    --policy "$dept_policy" \
    --no-tty \
    -- env OPENAI_API_KEY="${OPENAI_API_KEY}" \
           GATEWAY_ALLOW_ALL_USERS=true \
           HERMES_ACTIVE_PROFILE="${profile}" \
           HERMES_DASHBOARD_OIDC_ISSUER="${OIDC_ISSUER}" \
           HERMES_DASHBOARD_OIDC_CLIENT_ID="${OIDC_CLIENT}" \
           HERMES_PUBLIC_URL="https://${route_host}" \
           /usr/local/bin/hermes-start.sh </dev/null >/dev/null 2>&1 &
  local create_pid=$!

  # 5. Wait for Ready
  echo "Waiting for ${sandbox_name}..."
  for i in $(seq 1 60); do
    local status
    status=$(openshell sandbox list -g "$GATEWAY" 2>/dev/null | grep "$sandbox_name" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}' || echo "")
    if [ "$status" = "Ready" ]; then
      echo "${sandbox_name} ready after ~${i}0s"
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "ERROR: ${sandbox_name} did not reach Ready state"
      kill $create_pid 2>/dev/null || true
      rm -rf "$upload_dir"
      return 1
    fi
    sleep 10
  done

  # 6. Expose service
  echo "--- Exposing ${sandbox_name} ---"
  for i in $(seq 1 10); do
    if openshell service expose "$sandbox_name" 9119 -g "$GATEWAY" 2>&1; then
      break
    fi
    [ "$i" -eq 10 ] && echo "ERROR: Failed to expose ${sandbox_name}"
    sleep 3
  done

  # 7. Cleanup
  rm -rf "$upload_dir" "$dept_policy"

  echo "  Dashboard: https://${route_host}"
  echo "  Profile:   ${profile}"
}

# Deploy each department
for dept in ${DEPTS[@]}; do
  deploy_department "$dept"
done

echo ""
echo "=== Deployment Complete ==="
echo ""
for dept in ${DEPTS[@]}; do
  echo "  retail-${dept}: https://retail-${dept}.${APPS_DOMAIN}"
done
echo ""
