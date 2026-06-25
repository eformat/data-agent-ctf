#!/bin/bash
# Load SpiceDB schema and relationship fixtures for the Acme Retail demo.
#
# Users (prelude2 cluster — Keycloak OIDC):
#   fred    = finance-analyst (Claude agent)
#   sally   = sales-rep       (Hermes agent)
#   alex    = ops-manager     (OpenClaw agent)
#   prelude = org admin       (cross-department access)
#
# Prerequisites:
#   - zed CLI installed (go install github.com/authzed/zed@latest)
#   - SpiceDB running and reachable
#   - ZED_FLAGS set (default: --insecure for dev)
#
# Usage:
#   ./load-fixtures.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZED_FLAGS="${ZED_FLAGS:---insecure}"

echo "=== Loading SpiceDB schema ==="
zed schema write ${ZED_FLAGS} "${SCRIPT_DIR}/schema.zed"

echo "=== Writing organization relationships ==="
zed relationship create ${ZED_FLAGS} organization:acme-retail admin user:prelude
zed relationship create ${ZED_FLAGS} organization:acme-retail member user:fred
zed relationship create ${ZED_FLAGS} organization:acme-retail member user:sally
zed relationship create ${ZED_FLAGS} organization:acme-retail member user:alex

echo "=== Writing department relationships ==="
zed relationship create ${ZED_FLAGS} department:finance organization organization:acme-retail
zed relationship create ${ZED_FLAGS} department:finance member user:fred
zed relationship create ${ZED_FLAGS} department:sales organization organization:acme-retail
zed relationship create ${ZED_FLAGS} department:sales member user:sally
zed relationship create ${ZED_FLAGS} department:ops organization organization:acme-retail
zed relationship create ${ZED_FLAGS} department:ops member user:alex

echo "=== Writing catalog relationships ==="
for catalog in finance sales ops; do
  zed relationship create ${ZED_FLAGS} "catalog:${catalog}" organization organization:acme-retail
  zed relationship create ${ZED_FLAGS} "catalog:${catalog}" department "department:${catalog}"
  zed relationship create ${ZED_FLAGS} "catalog:${catalog}" reader "department:${catalog}#member"
done

echo "=== Writing dataset-catalog bindings ==="
# Finance
for ds in revenue expenses margins forecasts; do
  zed relationship create ${ZED_FLAGS} "dataset:${ds}" catalog catalog:finance
done
# Sales
for ds in orders pipeline customers acquisition_costs; do
  zed relationship create ${ZED_FLAGS} "dataset:${ds}" catalog catalog:sales
done
# Operations
for ds in inventory shipments warehouses returns; do
  zed relationship create ${ZED_FLAGS} "dataset:${ds}" catalog catalog:ops
done

echo ""
echo "=== Verifying demo scenarios ==="
echo "1. fred → revenue (expect: HAS_PERMISSION)"
zed permission check ${ZED_FLAGS} dataset:revenue query user:fred

echo "2. fred → orders (expect: NO_PERMISSION)"
zed permission check ${ZED_FLAGS} dataset:orders query user:fred || true

echo "3. prelude → orders (expect: HAS_PERMISSION)"
zed permission check ${ZED_FLAGS} dataset:orders query user:prelude

echo ""
echo "=== Done. Fixtures loaded. ==="
