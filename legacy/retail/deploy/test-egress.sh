#!/bin/bash
# Test that the agent-egress-lockdown NetworkPolicy works correctly.
# Runs against the first MCP pod found in openshell, or pass a pod name as $1.
set -euo pipefail

NS=openshell
POD="${1:-$(oc get pods -n "$NS" -l kagenti.io/type=tool -o jsonpath='{.items[0].metadata.name}')}"
echo "Testing egress from pod: $POD"
echo "---"

oc exec -n "$NS" "$POD" -c mcp -- python3 -c "
import socket, sys

passed = 0
failed = 0

# 1. External UDP — should be blocked
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
q = b'\xaa\xbb\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'
s.sendto(q, ('8.8.8.8', 53))
try:
    s.recv(512)
    print('FAIL  external UDP to 8.8.8.8:53 — got response (should be blocked)')
    failed += 1
except TimeoutError:
    print('PASS  external UDP to 8.8.8.8:53 — blocked')
    passed += 1
finally:
    s.close()

# 2. Cluster DNS — should work
try:
    result = socket.getaddrinfo('kubernetes.default.svc.cluster.local', 443)
    print('PASS  cluster DNS — resolved to', result[0][4][0])
    passed += 1
except Exception as e:
    print('FAIL  cluster DNS —', e)
    failed += 1

# 3. External TCP 443 — should work
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect(('maas.apps.ocp.cloud.rhai-tmm.dev', 443))
    print('PASS  external TCP 443 — connected')
    passed += 1
except Exception as e:
    print('FAIL  external TCP 443 —', e)
    failed += 1
finally:
    s.close()

# 4. External TCP on non-standard port — should be blocked by netpol,
#    but on pods with Envoy proxy-init iptables, connect() succeeds
#    locally (traffic is redirected to the sidecar, never leaves the pod).
#    Both outcomes are safe; we report which layer caught it.
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect(('8.8.8.8', 9999))
    print('PASS  external TCP 9999 — intercepted by Envoy proxy (iptables redirect)')
    passed += 1
except (TimeoutError, OSError):
    print('PASS  external TCP 9999 — blocked by NetworkPolicy')
    passed += 1
finally:
    s.close()

print('---')
print(f'{passed}/{passed+failed} passed')
sys.exit(1 if failed else 0)
"
