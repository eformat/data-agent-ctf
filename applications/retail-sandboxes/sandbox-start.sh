#!/bin/bash
# Wait for supervisor network relay before starting Hermes.
# The sandboxed namespace has no testable endpoints until the relay
# bridge is established (~15-30s). A fixed delay is the only reliable
# option inside the OPA-restricted sandbox.
sleep 45
exec /usr/local/bin/hermes-start.sh
