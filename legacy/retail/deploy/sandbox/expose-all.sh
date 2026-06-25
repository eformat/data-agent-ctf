#!/bin/bash
# Expose all retail sandbox services. Idempotent — safe to run repeatedly.
GATEWAY="${OPENSHELL_GATEWAY:-prelude2-final}"
for name in retail-finance retail-sales retail-ops; do
  openshell service expose "$name" 9119 -g "$GATEWAY" 2>&1
done
