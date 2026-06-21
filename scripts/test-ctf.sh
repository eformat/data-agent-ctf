#!/bin/bash
# End-to-end validation for the Retail CTF deployment.
#
# Checks every component is deployed, healthy, and wired correctly.
# Run after bootstrap + ArgoCD sync completes.
#
# Usage:
#   ./scripts/test-ctf.sh
#   ./scripts/test-ctf.sh --namespace my-ctf

set -uo pipefail

NAMESPACE="${NAMESPACE:-data-agent-ctf}"
GATEWAY="${OPENSHELL_GATEWAY:-prelude2-final}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

PASS=0
FAIL=0

check() {
  local desc="$1" result="$2"
  if [ "$result" = "PASS" ]; then
    echo -e "  ${GREEN}✓${RESET} $desc"
    ((PASS++))
  else
    echo -e "  ${RED}✗${RESET} $desc — ${RED}$result${RESET}"
    ((FAIL++))
  fi
}

echo ""
echo -e "${BOLD}════════════════════════════════════════════${RESET}"
echo -e "${BOLD} Retail CTF Deployment Validation${RESET}"
echo -e "${BOLD} Namespace: ${CYAN}${NAMESPACE}${RESET}"
echo -e "${BOLD}════════════════════════════════════════════${RESET}"

# ── 1. Namespace ──
echo -e "\n${YELLOW}── Namespace ──${RESET}"
if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  check "Namespace ${NAMESPACE} exists" "PASS"
else
  check "Namespace ${NAMESPACE} exists" "NOT FOUND"
fi

# ── 2. Pods ──
echo -e "\n${YELLOW}── Pods ──${RESET}"
for app in minio spicedb-postgres nessie trino; do
  pods=$(oc get pods -n "$NAMESPACE" -l "app=${app}" --no-headers 2>/dev/null | grep -c Running || echo 0)
  if [ "$pods" -gt 0 ]; then
    check "${app} running (${pods} pod(s))" "PASS"
  else
    check "${app} running" "NO RUNNING PODS"
  fi
done

# SpiceDB (different label)
spicedb_pods=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "spicedb.*Running" || echo 0)
if [ "$spicedb_pods" -gt 0 ]; then
  check "SpiceDB running" "PASS"
else
  check "SpiceDB running" "NO RUNNING PODS"
fi

# Keycloak
kc_pods=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "keycloak.*Running" || echo 0)
if [ "$kc_pods" -gt 0 ]; then
  check "Keycloak running" "PASS"
else
  check "Keycloak running" "NO RUNNING PODS"
fi

# MCP servers
for dept in finance sales ops; do
  mcp_ready=$(oc get pods -n "$NAMESPACE" -l "app=retail-${dept}-mcp" --no-headers 2>/dev/null | grep -c Running || echo 0)
  if [ "$mcp_ready" -gt 0 ]; then
    check "retail-${dept}-mcp running" "PASS"
  else
    check "retail-${dept}-mcp running" "NOT RUNNING"
  fi
done

# ── 3. Services ──
echo -e "\n${YELLOW}── Services ──${RESET}"
for svc in minio nessie trino keycloak-service; do
  if oc get svc "$svc" -n "$NAMESPACE" >/dev/null 2>&1; then
    check "Service ${svc}" "PASS"
  else
    check "Service ${svc}" "NOT FOUND"
  fi
done

# ── 4. Routes ──
echo -e "\n${YELLOW}── Routes ──${RESET}"
for route in retail-finance retail-sales retail-ops keycloak; do
  host=$(oc get route "$route" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -n "$host" ]; then
    check "Route ${route} → ${host}" "PASS"
  else
    check "Route ${route}" "NOT FOUND"
  fi
done

# ── 5. SpiceDB schema ──
echo -e "\n${YELLOW}── SpiceDB ──${RESET}"
schema_check=$(oc exec -n "$NAMESPACE" deploy/dev-spicedb -c spicedb -- \
  grpcurl -plaintext -d '{}' localhost:50051 authzed.api.v1.SchemaService/ReadSchema 2>&1 | head -5)
if echo "$schema_check" | grep -q "definition"; then
  check "SpiceDB schema loaded" "PASS"
else
  check "SpiceDB schema loaded" "NO SCHEMA"
fi

# ── 6. Trino tables ──
echo -e "\n${YELLOW}── Trino ──${RESET}"
trino_info=$(curl -sf "http://trino.${NAMESPACE}.svc:8080/v1/info" 2>/dev/null || \
  oc exec -n "$NAMESPACE" deploy/trino-coordinator -c trino -- curl -sf http://localhost:8080/v1/info 2>/dev/null)
if echo "$trino_info" | grep -q "starting\|true"; then
  check "Trino responding" "PASS"
else
  check "Trino responding" "NOT AVAILABLE"
fi

# ── 7. Keycloak realm ──
echo -e "\n${YELLOW}── Keycloak ──${RESET}"
kc_host=$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -n "$kc_host" ]; then
  realm_check=$(curl -sk "https://${kc_host}/realms/retail-ctf" 2>/dev/null)
  if echo "$realm_check" | grep -q "retail-ctf"; then
    check "Keycloak realm retail-ctf" "PASS"
  else
    check "Keycloak realm retail-ctf" "NOT FOUND"
  fi
else
  check "Keycloak realm" "NO ROUTE"
fi

# ── 8. OpenShell sandboxes ──
echo -e "\n${YELLOW}── Sandboxes ──${RESET}"
sandbox_list=$(openshell sandbox list -g "$GATEWAY" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
for dept in finance sales ops; do
  if echo "$sandbox_list" | grep -q "retail-${dept}.*Ready"; then
    check "Sandbox retail-${dept}" "PASS"
  else
    check "Sandbox retail-${dept}" "NOT READY"
  fi
done

# ── 9. CTF flags ──
echo -e "\n${YELLOW}── CTF Flags ──${RESET}"
flag_check=$(oc exec -n "$NAMESPACE" deploy/trino-coordinator -c trino -- \
  trino --server localhost:8080 --catalog finance --schema analytics \
  --execute "SELECT product_line FROM revenue WHERE year=2099" 2>/dev/null)
if echo "$flag_check" | grep -q "FLAG{"; then
  check "CTF flags planted in Trino" "PASS"
else
  check "CTF flags planted in Trino" "NOT FOUND"
fi

# ── Summary ──
echo ""
echo -e "${BOLD}════════════════════════════════════════════${RESET}"
echo -e "${BOLD} Results: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}"
echo -e "${BOLD}════════════════════════════════════════════${RESET}"
echo ""

exit $FAIL
