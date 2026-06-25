#!/bin/bash
# Deploy the Acme Retail authorization demo on OpenShift
#
# Prerequisites:
#   - oc CLI logged in as cluster-admin
#   - helm 3.x installed
#   - openshell CLI installed (v0.0.54+)
#   - cert-manager deployed on cluster
#   - zed CLI installed (for SpiceDB fixtures)
#
# Usage:
#   export OPENAI_API_KEY="sk-..."
#   ./deploy.sh
#
# To tear down:
#   ./deploy.sh teardown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Configuration ────────────────────────────────────────────
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')}"
OPENSHELL_NS="openshell"
SPICEDB_NS="spicedb"
TRINO_NS="trino"
MINIO_NS="minio"
OPENSHELL_CHART_VERSION="0.0.62"
HERMES_IMAGE="quay.io/eformat/hermes-openshell:latest"
MCP_IMAGE="quay.io/eformat/retail-mcp-server:latest"
KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-temp-admin}"
KEYCLOAK_ADMIN_PASS="${KEYCLOAK_ADMIN_PASS:-}"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: OPENAI_API_KEY must be set"
  exit 1
fi

# ─── Teardown ─────────────────────────────────────────────────
if [ "${1:-}" = "teardown" ]; then
  echo "=== Tearing down retail demo ==="
  openshell sandbox delete retail-hermes -g prelude2-os 2>/dev/null || true
  helm uninstall openshell -n "$OPENSHELL_NS" 2>/dev/null || true
  helm uninstall hermes -n "$OPENSHELL_NS" 2>/dev/null || true
  helm uninstall trino -n "$TRINO_NS" 2>/dev/null || true
  oc delete ns "$OPENSHELL_NS" "$SPICEDB_NS" "$TRINO_NS" "$MINIO_NS" 2>/dev/null || true
  oc delete ns agent-sandbox-system 2>/dev/null || true
  echo "Done"
  exit 0
fi

echo "=== Deploying Acme Retail Authorization Demo ==="
echo "  Apps domain: $APPS_DOMAIN"

# ─── Phase 1: SpiceDB ────────────────────────────────────────
echo ""
echo "=== Phase 1: SpiceDB ==="

echo "Installing SpiceDB operator..."
oc apply --server-side -f https://github.com/authzed/spicedb-operator/releases/latest/download/bundle.yaml
oc apply --server-side -f "$SCRIPT_DIR/../../../deploy/spicedb/operator-install.yaml" 2>/dev/null || \
  oc apply --server-side -f "$REPO_ROOT/examples/retail/deploy/spicedb/load-fixtures.sh" 2>/dev/null || true
oc patch deployment spicedb-operator -n spicedb-operator --type=json \
  --patch '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"256Mi"}]' 2>/dev/null || true
oc rollout status deployment/spicedb-operator -n spicedb-operator --timeout=120s

echo "Deploying PostgreSQL + SpiceDB..."
oc create ns "$SPICEDB_NS" 2>/dev/null || true
oc apply -f "$SCRIPT_DIR/spicedb/" -n "$SPICEDB_NS" 2>/dev/null || \
  oc apply -k ~/git/mcp-for-public-health/deploy/spicedb/ -n "$SPICEDB_NS"
echo "Waiting for SpiceDB..."
sleep 30
oc rollout status deployment/spicedb-postgres -n "$SPICEDB_NS" --timeout=120s || true

# ─── Phase 1b: OpenShift Groups ──────────────────────────────
echo ""
echo "=== Creating OpenShift groups ==="
oc apply -f "$SCRIPT_DIR/identity/groups.yaml"

# ─── Phase 2: MinIO + Trino ──────────────────────────────────
echo ""
echo "=== Phase 2: Data Lakehouse ==="

echo "Deploying MinIO..."
oc apply -k ~/git/openshift-minio/overlays/cluster-dev
oc rollout status deployment/minio -n "$MINIO_NS" --timeout=120s

echo "Creating warehouse bucket..."
oc run minio-setup --rm -i --restart=Never -n "$MINIO_NS" \
  --image=minio/mc:latest \
  --command -- /bin/sh -c '
    export MC_CONFIG_DIR=/tmp/mc
    mc alias set local http://minio:9000 minio minio1234
    mc mb --ignore-existing local/warehouse
  ' || true

echo "Deploying Nessie + Trino..."
oc create ns "$TRINO_NS" 2>/dev/null || true
oc apply -f ~/git/trino-chart/nessie/ -n "$TRINO_NS"
oc create secret generic trino-credentials -n "$TRINO_NS" \
  --from-literal=S3_ACCESS_KEY=minio --from-literal=S3_SECRET_KEY=minio1234 \
  --dry-run=client -o yaml | oc apply -f -
helm upgrade --install trino ~/git/trino-chart/trino -n "$TRINO_NS" \
  -f "$SCRIPT_DIR/trino/values.yaml"
oc rollout status deployment/trino-coordinator -n "$TRINO_NS" --timeout=180s

echo "Creating Nessie branches and schemas..."
NESSIE_POD="deployment/nessie"
MAIN_HASH=$(oc exec -n "$TRINO_NS" $NESSIE_POD -- curl -s http://localhost:19120/api/v2/trees/main | python3 -c "import sys,json; print(json.load(sys.stdin)['reference']['hash'])")
for branch in finance sales ops; do
  oc exec -n "$TRINO_NS" $NESSIE_POD -- curl -s -X POST \
    "http://localhost:19120/api/v2/trees?name=${branch}&type=BRANCH" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"BRANCH\",\"name\":\"main\",\"hash\":\"${MAIN_HASH}\"}" 2>/dev/null || true
done

echo "Creating Trino schemas and tables..."
TRINO="oc exec -n $TRINO_NS deployment/trino-coordinator -- trino --execute"
for catalog in finance sales ops; do
  $TRINO "CREATE SCHEMA IF NOT EXISTS ${catalog}.analytics" 2>/dev/null || true
done

# Finance tables
$TRINO "CREATE TABLE IF NOT EXISTS finance.analytics.revenue (year INTEGER, month INTEGER, region VARCHAR, product_line VARCHAR, revenue_usd_k DOUBLE)"
$TRINO "CREATE TABLE IF NOT EXISTS finance.analytics.expenses (year INTEGER, month INTEGER, department VARCHAR, category VARCHAR, amount_usd_k DOUBLE)"
$TRINO "CREATE TABLE IF NOT EXISTS finance.analytics.margins (year INTEGER, quarter INTEGER, product_line VARCHAR, revenue_usd_k DOUBLE, cogs_usd_k DOUBLE, gross_margin_pct DOUBLE)"
$TRINO "CREATE TABLE IF NOT EXISTS finance.analytics.forecasts (year INTEGER, quarter INTEGER, region VARCHAR, target_usd_k DOUBLE, actual_usd_k DOUBLE, variance_pct DOUBLE)"
# Sales tables
$TRINO "CREATE TABLE IF NOT EXISTS sales.analytics.orders (order_id VARCHAR, order_date DATE, customer_id VARCHAR, region VARCHAR, product_line VARCHAR, quantity INTEGER, revenue_usd DOUBLE, channel VARCHAR)"
$TRINO "CREATE TABLE IF NOT EXISTS sales.analytics.pipeline (opportunity_id VARCHAR, stage VARCHAR, probability_pct DOUBLE, expected_revenue_usd DOUBLE, sales_rep VARCHAR, region VARCHAR, created_date DATE, expected_close_date DATE)"
$TRINO "CREATE TABLE IF NOT EXISTS sales.analytics.customers (customer_id VARCHAR, segment VARCHAR, region VARCHAR, acquisition_date DATE, lifetime_value_usd DOUBLE, channel VARCHAR)"
$TRINO "CREATE TABLE IF NOT EXISTS sales.analytics.acquisition_costs (year INTEGER, quarter INTEGER, channel VARCHAR, spend_usd_k DOUBLE, new_customers INTEGER, cac_usd DOUBLE)"
# Operations tables
$TRINO "CREATE TABLE IF NOT EXISTS ops.analytics.inventory (date DATE, sku VARCHAR, warehouse VARCHAR, quantity_on_hand INTEGER, reorder_point INTEGER, days_of_supply DOUBLE)"
$TRINO "CREATE TABLE IF NOT EXISTS ops.analytics.shipments (shipment_id VARCHAR, order_id VARCHAR, warehouse VARCHAR, carrier VARCHAR, ship_date DATE, delivery_date DATE, transit_days INTEGER, status VARCHAR)"
$TRINO "CREATE TABLE IF NOT EXISTS ops.analytics.warehouses (warehouse_id VARCHAR, region VARCHAR, year INTEGER, month INTEGER, capacity_pallets INTEGER, utilization_pct DOUBLE, operating_cost_usd_k DOUBLE)"
$TRINO "CREATE TABLE IF NOT EXISTS ops.analytics.returns (return_id VARCHAR, order_id VARCHAR, sku VARCHAR, return_date DATE, reason VARCHAR, refund_usd DOUBLE)"

echo "Trino tables created"

# ─── Phase 3: Console Plugin ─────────────────────────────────
echo ""
echo "=== Phase 3: Console Plugin ==="
oc create ns openshell-authz 2>/dev/null || true
helm upgrade --install openshell-authz "$SCRIPT_DIR/../../../openshell-authz-plugin/chart" 2>/dev/null || \
  helm upgrade --install openshell-authz ~/git/openshell-authz-plugin/chart \
    -n openshell-authz \
    --set spicedb.endpoint=dev.${SPICEDB_NS}.svc.cluster.local:50051 \
    --set spicedb.token=averysecretpresharedkey \
    --set spicedb.insecure=true
oc rollout status deployment/openshell-authz-plugin -n openshell-authz --timeout=120s || true

# ─── Phase 4: MCP Servers ────────────────────────────────────
echo ""
echo "=== Phase 4: MCP Servers ==="
oc create ns "$OPENSHELL_NS" 2>/dev/null || true
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "$OPENSHELL_NS"
oc apply -f "$SCRIPT_DIR/mcp-server/deployment.yaml"
oc rollout status deployment/retail-finance-mcp deployment/retail-sales-mcp deployment/retail-ops-mcp \
  -n "$OPENSHELL_NS" --timeout=120s

# ─── Phase 5: Agent Sandbox Controller ────────────────────────
echo ""
echo "=== Phase 5: Agent Sandbox Controller ==="
oc apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml
oc rollout status deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=120s

# ─── Phase 6: OpenShell Gateway ──────────────────────────────
echo ""
echo "=== Phase 6: OpenShell Gateway ==="

OPENSHELL_HELM_ARGS=(
  --version "$OPENSHELL_CHART_VERSION"
  --namespace "$OPENSHELL_NS"
  --set certManager.enabled=true
  --set "certManager.serverDnsNames={openshell,openshell.${OPENSHELL_NS}.svc,openshell.${OPENSHELL_NS}.svc.cluster.local,localhost,openshell.localhost,*.openshell.localhost,*.${APPS_DOMAIN},openshell.${APPS_DOMAIN}}"
  --set "pkiInitJob.serverDnsNames={*.${APPS_DOMAIN},openshell.${APPS_DOMAIN}}"
  --set podSecurityContext.fsGroup=null
  --set securityContext.runAsUser=null
  --set server.tls.clientCaSecretName=""
  --set server.auth.allowUnauthenticatedUsers=true
  --set grpcRoute.enabled=true
  --set grpcRoute.gateway.create=true
  --set grpcRoute.gateway.className=openshift-default
)

if [ -n "$KEYCLOAK_ISSUER" ]; then
  OPENSHELL_HELM_ARGS+=(
    --set "server.oidc.issuer=$KEYCLOAK_ISSUER"
    --set server.oidc.audience=openshell-cli
    --set server.oidc.rolesClaim=realm_access.roles
  )
fi

helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart "${OPENSHELL_HELM_ARGS[@]}"
oc rollout status statefulset/openshell -n "$OPENSHELL_NS" --timeout=180s

# ─── Phase 7: Hermes Sandbox ─────────────────────────────────
echo ""
echo "=== Phase 7: Hermes Sandbox ==="

# API key secret
oc create secret generic hermes-api-key -n "$OPENSHELL_NS" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | oc apply -f -

# Port-forward to OpenShell gateway for CLI commands
oc port-forward svc/openshell 10880:8080 -n "$OPENSHELL_NS" &
PF_PID=$!
sleep 5

# Register gateway with CLI (mTLS certs)
MTLS_DIR="$HOME/.config/openshell/gateways/retail-deploy/mtls"
mkdir -p "$MTLS_DIR"
oc -n "$OPENSHELL_NS" get secret openshell-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$MTLS_DIR/ca.crt"
oc -n "$OPENSHELL_NS" get secret openshell-client-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
oc -n "$OPENSHELL_NS" get secret openshell-client-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"
openshell gateway add https://127.0.0.1:10880 --local --name retail-deploy 2>/dev/null || true

# Delete existing sandbox if present
openshell sandbox delete retail-hermes -g retail-deploy 2>/dev/null || true

# Create sandbox with config upload
echo "Creating Hermes sandbox..."
openshell sandbox create -g retail-deploy \
  --name retail-hermes \
  --from "$HERMES_IMAGE" \
  --upload "$SCRIPT_DIR/hermes-config:/sandbox/.hermes" \
  --policy "$SCRIPT_DIR/policy-retail.yaml" \
  --no-tty \
  -- /usr/local/bin/hermes dashboard --host 0.0.0.0 --port 9119 --insecure &
CREATE_PID=$!

# Wait for sandbox to be ready
for i in $(seq 1 30); do
  STATUS=$(openshell sandbox list -g retail-deploy 2>/dev/null | grep retail-hermes | awk '{print $NF}')
  if [ "$STATUS" = "Ready" ]; then
    echo "Sandbox ready"
    break
  fi
  sleep 10
done

# Expose service (clean URL, no double dash)
openshell service expose retail-hermes 9119 -g retail-deploy 2>/dev/null || true

# Inject API key env var from Secret
oc patch sandbox retail-hermes -n "$OPENSHELL_NS" --type=json -p='[
  {"op":"add","path":"/spec/podTemplate/spec/containers/0/env/-","value":{"name":"OPENAI_API_KEY","valueFrom":{"secretKeyRef":{"name":"hermes-api-key","key":"OPENAI_API_KEY"}}}}
]' 2>/dev/null || true

# Kill port-forward
kill $PF_PID 2>/dev/null || true
kill $CREATE_PID 2>/dev/null || true

# ─── Phase 8: Route ──────────────────────────────────────────
echo ""
echo "=== Phase 8: Route ==="

DEST_CA=$(oc get secret openshell-server-tls -n "$OPENSHELL_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)

cat << ROUTEEOF | oc apply -n "$OPENSHELL_NS" -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: retail-hermes
spec:
  host: retail-hermes.${APPS_DOMAIN}
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

# ─── Done ─────────────────────────────────────────────────────
echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Dashboard:       https://retail-hermes.${APPS_DOMAIN}"
echo "Console Plugin:  OpenShift Console → Platform Auth"
echo "Trino:           trino.${TRINO_NS}.svc.cluster.local:8080"
echo "SpiceDB:         dev.${SPICEDB_NS}.svc.cluster.local:50051"
echo ""
echo "Demo users: fred (finance), sally (sales), alex (ops), prelude (admin)"
echo ""
echo "To load SpiceDB fixtures:"
echo "  oc port-forward svc/dev 10051:50051 -n $SPICEDB_NS &"
echo "  ZED_FLAGS='--insecure --endpoint=localhost:10051 --token=averysecretpresharedkey'"
echo "  $SCRIPT_DIR/spicedb/load-fixtures.sh"
echo ""
echo "To load Trino sample data:"
echo "  oc port-forward svc/trino 10080:8080 -n $TRINO_NS &"
echo "  python3 $SCRIPT_DIR/trino/load-data.py --host localhost --port 10080"
