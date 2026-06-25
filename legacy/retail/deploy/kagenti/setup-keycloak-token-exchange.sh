#!/bin/bash
# Configure Keycloak for RFC 8693 token exchange (on-behalf-of).
#
# This script creates the Keycloak resources needed for AuthBridge to
# exchange a user's JWT (from hermes-dashboard) for a service-scoped
# token with audience=retail-mcp. The exchanged token preserves
# preferred_username so the MCP server can identify the user.
#
# Prerequisites:
#   - Keycloak with token-exchange feature enabled (KC_FEATURES=token-exchange)
#   - SPIFFE client already registered (via Kagenti client-registration sidecar)
#   - hermes-dashboard client exists
#
# Usage:
#   export KEYCLOAK_ADMIN_PASSWORD="..."
#   ./setup-keycloak-token-exchange.sh

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-keycloak.apps.sno.sandbox1254.opentlc.com}"
REALM="${KEYCLOAK_REALM:-prelude-m6wl4-vs9lb}"
ADMIN_USER="${KEYCLOAK_ADMIN_USERNAME:-temp-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-$(oc get secret authbridge-keycloak-admin -n openshell -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)}"
SPIFFE_CLIENT_ID="spiffe://retail-demo/ns/openshell/sa/default"

echo "Keycloak: ${KEYCLOAK_URL}"
echo "Realm: ${REALM}"

# Get admin token
ADMIN_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=${ADMIN_USER}&password=${ADMIN_PASS}" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
echo "Admin token acquired"

# ── Step 1: Create retail-mcp target client ─────────────────────
echo ""
echo "=== Step 1: retail-mcp target client ==="
EXISTING=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=retail-mcp" | \
  python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [ "$EXISTING" = "0" ]; then
  curl -sk -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
    -d '{
      "clientId": "retail-mcp",
      "name": "Retail MCP Servers",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "publicClient": false,
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "protocol": "openid-connect",
      "attributes": { "standard.token.exchange.enabled": "true" }
    }' -w "  Created (HTTP %{http_code})\n"
else
  echo "  Already exists"
fi

# ── Step 2: Create retail-mcp-aud client scope ──────────────────
echo ""
echo "=== Step 2: retail-mcp-aud audience scope ==="
EXISTING=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | \
  python3 -c "import json,sys; print(sum(1 for s in json.load(sys.stdin) if s['name']=='retail-mcp-aud'))")
if [ "$EXISTING" = "0" ]; then
  curl -sk -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    -d '{
      "name": "retail-mcp-aud",
      "protocol": "openid-connect",
      "attributes": { "include.in.token.scope": "true", "display.on.consent.screen": "false" },
      "protocolMappers": [{
        "name": "retail-mcp-aud",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-audience-mapper",
        "consentRequired": false,
        "config": {
          "included.custom.audience": "retail-mcp",
          "access.token.claim": "true",
          "id.token.claim": "false",
          "userinfo.token.claim": "false"
        }
      }]
    }' -w "  Created (HTTP %{http_code})\n"
else
  echo "  Already exists"
fi

# ── Step 3: Create spiffe-mcp-aud scope ─────────────────────────
# Adds SPIFFE client ID to hermes-dashboard tokens' audience.
# Required so the SPIFFE client passes Keycloak's
# "client is within token audience" check during exchange.
echo ""
echo "=== Step 3: spiffe-mcp-aud audience scope ==="
EXISTING=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | \
  python3 -c "import json,sys; print(sum(1 for s in json.load(sys.stdin) if s['name']=='spiffe-mcp-aud'))")
if [ "$EXISTING" = "0" ]; then
  curl -sk -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    -d "{
      \"name\": \"spiffe-mcp-aud\",
      \"description\": \"Adds SPIFFE MCP client as audience for token exchange\",
      \"protocol\": \"openid-connect\",
      \"attributes\": { \"include.in.token.scope\": \"false\", \"display.on.consent.screen\": \"false\" },
      \"protocolMappers\": [{
        \"name\": \"spiffe-mcp-aud\",
        \"protocol\": \"openid-connect\",
        \"protocolMapper\": \"oidc-audience-mapper\",
        \"consentRequired\": false,
        \"config\": {
          \"included.custom.audience\": \"${SPIFFE_CLIENT_ID}\",
          \"access.token.claim\": \"true\",
          \"id.token.claim\": \"false\",
          \"userinfo.token.claim\": \"false\"
        }
      }]
    }" -w "  Created (HTTP %{http_code})\n"
else
  echo "  Already exists"
fi

# ── Step 4: Enable token exchange on hermes-dashboard ───────────
echo ""
echo "=== Step 4: Enable token exchange on hermes-dashboard ==="
HD_UUID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=hermes-dashboard" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")
curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}" | python3 -c "
import json,sys
c = json.load(sys.stdin)
c.setdefault('attributes',{})['standard.token.exchange.enabled'] = 'true'
json.dump(c, sys.stdout)
" | curl -sk -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}" -d @- -w "  HTTP %{http_code}\n"

# ── Step 5: Assign scopes ──────────────────────────────────────
echo ""
echo "=== Step 5: Assign scopes ==="

# Get scope UUIDs
RETAIL_MCP_AUD_UUID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | \
  python3 -c "import json,sys; [print(s['id']) for s in json.load(sys.stdin) if s['name']=='retail-mcp-aud']")
SPIFFE_MCP_AUD_UUID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | \
  python3 -c "import json,sys; [print(s['id']) for s in json.load(sys.stdin) if s['name']=='spiffe-mcp-aud']")

# Get SPIFFE client UUID
SPIFFE_UUID=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("'"${SPIFFE_CLIENT_ID}"'"))')" | \
  python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")

# retail-mcp-aud → SPIFFE client (so exchanged tokens have aud=retail-mcp)
echo "  retail-mcp-aud → SPIFFE client"
curl -sk -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${SPIFFE_UUID}/default-client-scopes/${RETAIL_MCP_AUD_UUID}" -w "  HTTP %{http_code}\n"

# spiffe-mcp-aud → hermes-dashboard (so user tokens include SPIFFE in audience)
echo "  spiffe-mcp-aud → hermes-dashboard"
curl -sk -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${HD_UUID}/default-client-scopes/${SPIFFE_MCP_AUD_UUID}" -w "  HTTP %{http_code}\n"

echo ""
echo "=== Done ==="
echo "Token exchange is configured. To verify:"
echo "  1. Get a user token from hermes-dashboard (will include SPIFFE in aud)"
echo "  2. Exchange via SPIFFE client with audience=retail-mcp"
echo "  3. Exchanged token preserves preferred_username + sub"
