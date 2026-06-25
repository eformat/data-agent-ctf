#!/bin/bash
# Deploy Kagenti infrastructure: ZTWIM/SPIRE + Kagenti operator + AuthBridge config.
#
# Uses the existing Keycloak realm (no new Keycloak deployment).
# Installs ZTWIM (OpenShift Zero Trust Workload Identity Manager) for SPIRE.
# Installs Kagenti operator for webhook injection and AgentRuntime CRDs.
#
# Prerequisites:
#   - OpenShift 4.19+ cluster
#   - Keycloak accessible at KEYCLOAK_URL
#   - Helm 3
#
# Usage:
#   export KEYCLOAK_ADMIN_USER="temp-admin"
#   export KEYCLOAK_ADMIN_PASSWORD="password"
#   ./deploy-kagenti.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAGENTI_REPO="${KAGENTI_REPO:-~/git/kagenti}"
KAGENTI_EXT_REPO="${KAGENTI_EXT_REPO:-~/git/kagenti-extensions}"

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-keycloak.apps.sno.sandbox1254.opentlc.com}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-prelude-m6wl4-vs9lb}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-temp-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"

SPIRE_NAMESPACE="zero-trust-workload-identity-manager"
SPIRE_TRUST_DOMAIN="${SPIRE_TRUST_DOMAIN:-retail-demo}"
KAGENTI_NAMESPACE="${KAGENTI_NAMESPACE:-kagenti-system}"
TARGET_NAMESPACE="openshell"

APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')}"

if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
  echo "ERROR: KEYCLOAK_ADMIN_PASSWORD must be set"
  exit 1
fi

echo "=== Deploying Kagenti Infrastructure ==="

# ─── Step 1: Install ZTWIM operator (SPIRE for OpenShift) ───
echo "--- Step 1: ZTWIM Operator ---"

# Check if already installed
if oc get csv -n openshift-zero-trust-workload-identity-manager 2>/dev/null | grep -q Succeeded; then
  echo "ZTWIM operator already installed"
else
  cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-zero-trust-workload-identity-manager
  namespace: openshift-zero-trust-workload-identity-manager
spec:
  channel: stable
  installPlanApproval: Automatic
  name: openshift-zero-trust-workload-identity-manager
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  # Create the namespace if needed
  oc create namespace openshift-zero-trust-workload-identity-manager 2>/dev/null || true

  echo "Waiting for ZTWIM operator..."
  for i in $(seq 1 30); do
    if oc get csv -n openshift-zero-trust-workload-identity-manager 2>/dev/null | grep -q Succeeded; then
      echo "ZTWIM operator ready"
      break
    fi
    sleep 10
  done
fi

# ─── Step 2: Configure SPIRE (ZTWIM operands) ───
echo "--- Step 2: SPIRE Configuration ---"

cat << EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: ${SPIRE_TRUST_DOMAIN}
  clusterName: agent-platform
  bundleConfigMap: spire-bundle
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec:
  agentSocketPath: /run/spire/agent-sockets
  pluginName: csi.spiffe.io
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: ${SPIRE_TRUST_DOMAIN}
    country: "US"
    organization: "RH"
  persistence:
    size: "1Gi"
    accessMode: ReadWriteOnce
  datastore:
    databaseType: sqlite3
    connectionString: "/run/spire/data/datastore.sqlite3"
  jwtIssuer: "https://oidc-discovery-provider.${SPIRE_TRUST_DOMAIN}"
---
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec: {}
EOF

echo "Waiting for SPIRE server..."
for i in $(seq 1 30); do
  if oc get pods -n "$SPIRE_NAMESPACE" 2>/dev/null | grep -q 'spire-server.*Running'; then
    echo "SPIRE server ready"
    break
  fi
  sleep 10
done

# ─── Step 3: Install Kagenti operator ───
echo "--- Step 3: Kagenti Operator ---"

if [ -d "$KAGENTI_REPO/charts/kagenti" ]; then
  # Install from local chart with minimal components
  helm upgrade --install kagenti "$KAGENTI_REPO/charts/kagenti" \
    --namespace "$KAGENTI_NAMESPACE" --create-namespace \
    --set openshift=true \
    --set "domain=${APPS_DOMAIN}" \
    --set components.agentOperator.enabled=true \
    --set components.agentNamespaces.enabled=false \
    --set components.mcpGateway.enabled=false \
    --set components.ui.enabled=false \
    --set components.istio.enabled=false \
    --set components.phoenix.enabled=false \
    --set components.mlflow.enabled=false \
    --wait --timeout 5m 2>&1 | tail -5
else
  echo "WARNING: Kagenti repo not found at $KAGENTI_REPO — install operator manually"
fi

# ─── Step 4: Configure Keycloak for AuthBridge ───
echo "--- Step 4: Keycloak Configuration ---"

# Get admin token
ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN_USER}&password=${KEYCLOAK_ADMIN_PASSWORD}" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

# Create token-exchange client for AuthBridge (if not exists)
EXISTING=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=authbridge-token-exchange" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")

if [ "$EXISTING" = "0" ]; then
  echo "Creating authbridge-token-exchange client..."
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "authbridge-token-exchange",
      "name": "AuthBridge Token Exchange",
      "enabled": true,
      "publicClient": false,
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "protocol": "openid-connect"
    }' -w '%{http_code}' -o /dev/null 2>&1
  echo ""
else
  echo "authbridge-token-exchange client already exists"
fi

# ─── Step 5: Create AuthBridge ConfigMaps in target namespace ───
echo "--- Step 5: AuthBridge ConfigMaps ---"

TOKEN_URL="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
JWKS_URL="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"

# authbridge-config
cat << EOF | oc apply -n "$TARGET_NAMESPACE" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-config
  namespace: $TARGET_NAMESPACE
data:
  KEYCLOAK_URL: "${KEYCLOAK_URL}"
  KEYCLOAK_REALM: "${KEYCLOAK_REALM}"
  TOKEN_URL: "${TOKEN_URL}"
  JWKS_URL: "${JWKS_URL}"
EOF

# Keycloak admin credentials for client-registration sidecar (Secret, not in git)
oc create secret generic authbridge-keycloak-admin -n "$TARGET_NAMESPACE" \
  --from-literal=KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USER}" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

# Also create in kagenti-system for the operator
oc create secret generic keycloak-admin-secret -n kagenti-system \
  --from-literal=KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USER}" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "=== Kagenti Infrastructure Deployed ==="
echo ""
echo "  SPIRE trust domain: ${SPIRE_TRUST_DOMAIN}"
echo "  Keycloak realm:     ${KEYCLOAK_REALM}"
echo "  Target namespace:   ${TARGET_NAMESPACE}"
echo ""
echo "Next: Add kagenti.io/inject labels to MCP server deployments"
