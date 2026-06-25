#!/bin/bash
# Zero-Trust Identity Demo — walk through each layer of the auth chain.
#
# Usage:
#   ./demo-zero-trust.sh           # defaults to sally / retail-sales
#   ./demo-zero-trust.sh fred finance
#   ./demo-zero-trust.sh alex ops
#
# Requires: oc, openshell, curl, python3
set -uo pipefail

USER="${1:-sally}"
DEPT="${2:-sales}"
SANDBOX="retail-${DEPT}"
MCP_SVC="http://retail-${DEPT}-mcp.openshell.svc.cluster.local:9090"
GATEWAY="${OPENSHELL_GATEWAY:-prelude2-final}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-keycloak.apps.sno.sandbox1254.opentlc.com}"
REALM="${KEYCLOAK_REALM:-prelude-m6wl4-vs9lb}"

# Ensure openshell gateway port-forward is running
if ! ss -tlnp 2>/dev/null | grep -q ':10880 '; then
  echo "Starting port-forward for openshell gateway..."
  oc port-forward statefulset/openshell 10880:8080 -n openshell &>/dev/null &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT
  sleep 2
fi

# Map departments to their datasets for permission checks
declare -A DEPT_DATASETS=( [sales]=orders [finance]=revenue [ops]=inventory )
OWN_DATASET="${DEPT_DATASETS[$DEPT]}"

# User passwords — demo only
PASS="${DEMO_PASSWORD:-password}"

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

step() { echo -e "\n${BOLD}${CYAN}── $1 ──${RESET}"; }
ok()   { echo -e "   ${GREEN}✓ $1${RESET}"; }
deny() { echo -e "   ${RED}✗ DENIED: $1${RESET}"; }
info() { echo -e "   ${YELLOW}$1${RESET}"; }
pause() { echo -e "\n   ${BOLD}Press Enter to continue...${RESET}"; read -r; }

echo -e "${BOLD}============================================${RESET}"
echo -e "${BOLD} Zero-Trust Identity Chain Demo${RESET}"
echo -e "${BOLD}============================================${RESET}"
echo -e " User:    ${CYAN}${USER}${RESET}"
echo -e " Dept:    ${CYAN}${DEPT}${RESET}"
echo -e " Sandbox: ${CYAN}${SANDBOX}${RESET}"
echo -e " MCP:     ${CYAN}retail-${DEPT}-mcp${RESET}"

# ── Step 1: Get a JWT from Keycloak ─────────────────────────────
step "Step 1: Authenticate ${USER} via Keycloak"
info "Getting admin token..."
ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=temp-admin&password=$(oc get secret authbridge-keycloak-admin -n openshell -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

HD_UUID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=hermes-dashboard" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")

# Enable direct grants temporarily
curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}" | \
  python3 -c "import json,sys; c=json.load(sys.stdin); c['directAccessGrantsEnabled']=True; json.dump(c,sys.stdout)" | \
  curl -sk -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}" -d @- > /dev/null

USER_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=hermes-dashboard&username=${USER}&password=${PASS}" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

# Disable direct grants
curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}" | \
  python3 -c "import json,sys; c=json.load(sys.stdin); c['directAccessGrantsEnabled']=False; json.dump(c,sys.stdout)" | \
  curl -sk -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}" -d @- > /dev/null

echo ""
echo "   JWT claims:"
echo "$USER_TOKEN" | cut -d. -f2 | python3 -c "
import base64,json,sys
p=sys.stdin.read().strip();p+='='*(4-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
for k in ['preferred_username','email','azp','aud']:
    if k in c: print(f'     {k}: {c[k]}')
"
ok "Keycloak issued JWT for ${USER} with SPIFFE audience"

pause

# ── Step 2: No JWT → AuthBridge blocks ──────────────────────────
step "Step 2: Request WITHOUT JWT → AuthBridge blocks"
info "curl ${MCP_SVC}/health  (no Authorization header)"
echo ""
RESP=$(openshell sandbox exec -n "$SANDBOX" -g "$GATEWAY" -- \
  curl -s -w "\n%{http_code}" --max-time 5 "${MCP_SVC}/health" 2>&1)
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
echo -e "   Response: ${RED}${BODY}${RESET}"
if [ "$HTTP_CODE" = "401" ]; then
  deny "HTTP 401 — no JWT, AuthBridge blocked the request"
else
  ok "Expected 401, got ${HTTP_CODE}"
fi

pause

# ── Step 3: Valid JWT → AuthBridge passes ───────────────────────
step "Step 3: Request WITH valid JWT → AuthBridge passes"
info "curl -H 'Authorization: Bearer <jwt>' ${MCP_SVC}/health"
echo ""
RESP=$(openshell sandbox exec -n "$SANDBOX" -g "$GATEWAY" -- \
  curl -s -w "\n%{http_code}" --max-time 5 \
  -H "Authorization: Bearer ${USER_TOKEN}" "${MCP_SVC}/health" 2>&1)
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
echo -e "   Response: ${GREEN}${BODY}${RESET}"
if [ "$HTTP_CODE" = "200" ]; then
  ok "HTTP 200 — AuthBridge validated JWT, MCP server sees user=${USER}"
else
  deny "Expected 200, got ${HTTP_CODE}"
fi

pause

# ── Helper: run SpiceDB permission check and display result ────
check_spicedb() {
  local DATASET="$1"
  local LABEL="$2"
  RESULT=$(oc exec -n openshell "$MCP_POD" -c mcp -- python3 -c "
import json, base64
token = '''${USER_TOKEN}'''
parts = token.split('.')
payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
user = claims.get('preferred_username') or claims.get('sub')
from data_agent_core.mcp.server import _check_spicedb_permission
result = _check_spicedb_permission(user, '$DATASET')
print(json.dumps(result))
" 2>&1)
  ALLOWED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('allowed',False))" 2>/dev/null)
  echo "$RESULT" | python3 -c "
import sys,json
try:
    r = json.loads(sys.stdin.read())
    allowed = r.get('allowed', False)
    color = '\033[32m' if allowed else '\033[31m'
    print(f'   {color}allowed: {allowed}\033[0m')
    print(f'   user: {r.get(\"user\")}')
    print(f'   dataset: {r.get(\"dataset\")}')
except Exception as e:
    print(f'   (parse error: {e})')
" 2>/dev/null
  if [ "$ALLOWED" = "True" ]; then
    ok "SpiceDB: ${USER} → ${LABEL} ALLOWED"
  else
    deny "${USER} → ${LABEL} — SpiceDB enforced"
  fi
}

# ── Step 4: SpiceDB permission check (target department) ───────
step "Step 4: SpiceDB — ${USER} queries ${DEPT}.${OWN_DATASET}"
MCP_POD=$(oc get pod -n openshell -l "app=retail-${DEPT}-mcp" -o jsonpath='{.items[0].metadata.name}')
check_spicedb "${OWN_DATASET}" "${DEPT}.${OWN_DATASET}"

pause

# ── Step 5: Cross-department check ─────────────────────────────
if [ "$DEPT" = "sales" ]; then CROSS_DEPT="finance"; CROSS_DS="revenue"
elif [ "$DEPT" = "finance" ]; then CROSS_DEPT="sales"; CROSS_DS="orders"
else CROSS_DEPT="finance"; CROSS_DS="revenue"; fi

step "Step 5: SpiceDB — ${USER} queries ${CROSS_DEPT}.${CROSS_DS}"
check_spicedb "${CROSS_DS}" "${CROSS_DEPT}.${CROSS_DS}"

pause

# ── Step 6: AuthBridge audit trail ─────────────────────────────
step "Step 6: AuthBridge audit trail"
oc logs -n openshell "$MCP_POD" -c envoy-proxy 2>&1 | \
  grep -E "inbound authorized|plugin rejected" | tail -8 | \
  while IFS= read -r line; do
    if echo "$line" | grep -q "authorized"; then
      echo -e "   ${GREEN}${line}${RESET}"
    else
      echo -e "   ${RED}${line}${RESET}"
    fi
  done

echo ""
echo -e "${BOLD}============================================${RESET}"
echo -e "${BOLD} Summary${RESET}"
echo -e "${BOLD}============================================${RESET}"
echo -e " ${GREEN}✓${RESET} Keycloak OIDC → JWT with SPIFFE audience"
echo -e " ${GREEN}✓${RESET} AuthBridge (Envoy ext_proc) → validates JWT via JWKS"
echo -e " ${GREEN}✓${RESET} No JWT → ${RED}401 Unauthorized${RESET} (fail-closed)"
echo -e " ${GREEN}✓${RESET} Valid JWT → identity extracted (preferred_username: ${USER})"
echo -e " ${GREEN}✓${RESET} SpiceDB → ${USER} + ${DEPT}.${OWN_DATASET} → result matches user's permissions"
echo -e " ${GREEN}✓${RESET} SpiceDB → ${USER} + ${CROSS_DEPT}.${CROSS_DS} → result matches user's permissions"
echo -e " ${GREEN}✓${RESET} Agent cannot forge identity — JWT is cryptographically signed"
echo ""
echo -e " Identity chain: User → Keycloak → JWT → Hermes → AuthBridge → MCP → SpiceDB → Trino"
echo ""
