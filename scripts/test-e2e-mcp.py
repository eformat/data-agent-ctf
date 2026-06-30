#!/usr/bin/env python3
"""
End-to-end test for the Retail CTF MCP pipeline.

Tests the full chain: Keycloak OIDC → JWT audience → AuthBridge → MCP server → Trino.
Run from a machine with KUBECONFIG access to the cluster.

Usage:
    python3 scripts/test-e2e-mcp.py
    KUBECONFIG=~/.kube/config.prelude3 python3 scripts/test-e2e-mcp.py
"""

import base64
import json
import os
import subprocess
import sys
import time

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"
SKIP = "\033[33m⊘\033[0m"

failures = []
passes = []


def oc(*args):
    """Run oc command and return stdout."""
    result = subprocess.run(
        ["oc", *args], capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise RuntimeError(f"oc {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def test(name, fn):
    """Run a test function, print result."""
    try:
        result = fn()
        print(f"  {PASS} {name}")
        if result:
            print(f"      {result}")
        passes.append(name)
        return True
    except Exception as e:
        print(f"  {FAIL} {name}")
        print(f"      {e}")
        failures.append((name, str(e)))
        return False


# ── Discover cluster endpoints ──────────────────────────────────────

def discover():
    """Auto-discover endpoints from the cluster."""
    cfg = {}
    cfg["apps_domain"] = oc("get", "ingresses.config", "cluster", "-o", "jsonpath={.spec.domain}")
    cfg["namespace"] = os.environ.get("NAMESPACE", oc("get", "applications.argoproj.io", "retail-ctf", "-n", "openshift-gitops",
        "-o", "jsonpath={.spec.source.helm.releaseName}").strip() and
        oc("get", "applications.argoproj.io", "retail-ctf", "-n", "openshift-gitops",
           "-o", "jsonpath={.spec.destination.namespace}"))
    cfg["kc_host"] = oc("get", "route", "keycloak", "-n", cfg["namespace"], "-o", "jsonpath={.spec.host}")
    cfg["kc_url"] = f"https://{cfg['kc_host']}"
    cfg["realm"] = "retail-ctf"

    # Get admin credentials from initial-admin secret
    cfg["admin_user"] = base64.b64decode(
        oc("get", "secret", "keycloak-initial-admin", "-n", cfg["namespace"],
           "-o", "jsonpath={.data.username}")
    ).decode()
    cfg["admin_pass"] = base64.b64decode(
        oc("get", "secret", "keycloak-initial-admin", "-n", cfg["namespace"],
           "-o", "jsonpath={.data.password}")
    ).decode()

    # Get CTF user password
    cfg["user_pass"] = base64.b64decode(
        oc("get", "secret", "keycloak-admin-secret", "-n", cfg["namespace"],
           "-o", "jsonpath={.data.CTF_USER_PASSWORD}")
    ).decode()

    return cfg


# ── Tests ───────────────────────────────────────────────────────────

def test_keycloak_reachable(cfg):
    """Keycloak OIDC discovery endpoint responds."""
    def run():
        r = requests.get(
            f"{cfg['kc_url']}/realms/{cfg['realm']}/.well-known/openid-configuration",
            verify=False, timeout=10
        )
        assert r.status_code == 200, f"HTTP {r.status_code}"
        data = r.json()
        assert "token_endpoint" in data
        return f"issuer={data['issuer']}"
    return run


def test_keycloak_admin_login(cfg):
    """Admin can get token from master realm."""
    def run():
        r = requests.post(
            f"{cfg['kc_url']}/realms/master/protocol/openid-connect/token",
            data={"grant_type": "password", "client_id": "admin-cli",
                  "username": cfg["admin_user"], "password": cfg["admin_pass"]},
            verify=False, timeout=10
        )
        assert r.status_code == 200, f"HTTP {r.status_code}: {r.text[:200]}"
        assert "access_token" in r.json()
    return run


def test_user_login(cfg, user="sally"):
    """CTF user can login to retail-ctf realm."""
    def run():
        r = requests.post(
            f"{cfg['kc_url']}/realms/{cfg['realm']}/protocol/openid-connect/token",
            data={"grant_type": "password", "client_id": "hermes-dashboard",
                  "username": user, "password": cfg["user_pass"]},
            verify=False, timeout=10
        )
        assert r.status_code == 200, f"HTTP {r.status_code}: {r.text[:200]}"
        cfg[f"token_{user}"] = r.json()["access_token"]
    return run


def test_jwt_has_spiffe_audience(cfg, user="sally"):
    """User JWT contains SPIFFE audience for MCP authbridge."""
    def run():
        token = cfg.get(f"token_{user}")
        assert token, "no token — login test must pass first"
        payload = token.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        claims = json.loads(base64.b64decode(payload))
        aud = claims.get("aud", "NOT SET")
        assert aud != "NOT SET", "aud claim missing from token"
        if isinstance(aud, list):
            assert any("spiffe://" in a for a in aud), f"no SPIFFE audience in {aud}"
        else:
            assert "spiffe://" in str(aud), f"audience is '{aud}', expected SPIFFE ID"
        return f"aud={aud}"
    return run


def test_mcp_pod_running(cfg, dept="sales"):
    """MCP pod has 4/4 containers ready (mcp + authbridge sidecars)."""
    def run():
        ready = oc("get", "pods", "-n", cfg["namespace"],
                    "-l", f"app=retail-{dept}-mcp",
                    "-o", "jsonpath={.items[0].status.containerStatuses[*].ready}")
        containers = ready.split()
        assert len(containers) == 4, f"expected 4 containers, got {len(containers)}"
        assert all(c == "true" for c in containers), f"not all ready: {containers}"
        name = oc("get", "pods", "-n", cfg["namespace"],
                   "-l", f"app=retail-{dept}-mcp",
                   "-o", "jsonpath={.items[0].metadata.name}")
        return f"pod={name} containers=4/4"
    return run


def _mcp_call_direct(cfg, pod, method, params=None, msg_id=1):
    """MCP call directly to the server (port 8080, no authbridge).
    Returns parsed JSON from SSE response."""
    body = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        body["params"] = params
    if not method.startswith("notifications/"):
        body["id"] = msg_id
    result = subprocess.run(
        ["oc", "exec", "-n", cfg["namespace"], pod, "-c", "mcp", "--",
         "curl", "-s", "--max-time", "10",
         "-H", "Content-Type: application/json",
         "-H", "Accept: application/json, text/event-stream",
         "-X", "POST", "http://127.0.0.1:8080/mcp",
         "-d", json.dumps(body)],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip()[:200])
    raw = result.stdout.strip()
    # Parse SSE: extract JSON from "data: {...}" lines
    for line in raw.splitlines():
        if line.startswith("data: "):
            return line[6:]
    return raw


def test_authbridge_rejects_no_token(cfg, dept="sales"):
    """AuthBridge rejects requests without JWT (envoy port 15124)."""
    def run():
        pod = oc("get", "pods", "-n", cfg["namespace"],
                 "-l", f"app=retail-{dept}-mcp",
                 "-o", "jsonpath={.items[0].metadata.name}")
        result = subprocess.run(
            ["oc", "exec", "-n", cfg["namespace"], pod, "-c", "mcp", "--",
             "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "5", "-X", "POST",
             "http://127.0.0.1:15124/mcp",
             "-H", "Content-Type: application/json",
             "-d", '{"jsonrpc":"2.0","method":"initialize","id":1}'],
            capture_output=True, text=True, timeout=15
        )
        code = result.stdout.strip()
        assert code == "401", f"expected 401, got {code} (authbridge should reject without JWT)"
        return "correctly returns 401 without token"
    return run


def test_mcp_server_responds(cfg, dept="sales"):
    """MCP server responds to initialize (direct port 8080)."""
    def run():
        pod = oc("get", "pods", "-n", cfg["namespace"],
                 "-l", f"app=retail-{dept}-mcp",
                 "-o", "jsonpath={.items[0].metadata.name}")
        result = _mcp_call_direct(cfg, pod, "initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "test", "version": "1.0"}
        }, msg_id=1)
        data = json.loads(result)
        assert "result" in data, f"unexpected: {result[:200]}"
        server = data["result"].get("serverInfo", {}).get("name", "?")
        return f"server={server}"
    return run


def test_sandbox_route(cfg, dept="sales"):
    """Sandbox route returns 200 (login page)."""
    def run():
        url = f"https://retail-{dept}.{cfg['apps_domain']}/login"
        r = requests.get(url, verify=False, timeout=10, allow_redirects=False)
        assert r.status_code == 200, f"HTTP {r.status_code} (expected 200)"
        assert "Sign in" in r.text or "Hermes" in r.text, "not a Hermes login page"
    return run


def test_sandbox_oidc_redirect(cfg, dept="sales"):
    """Sandbox OIDC login redirects to Keycloak."""
    def run():
        url = f"https://retail-{dept}.{cfg['apps_domain']}/auth/login?provider=self-hosted"
        r = requests.get(url, verify=False, timeout=10, allow_redirects=False)
        assert r.status_code == 302, f"HTTP {r.status_code} (expected 302)"
        location = r.headers.get("location", "")
        assert cfg["kc_host"] in location, f"redirect not to keycloak: {location[:100]}"
        assert cfg["realm"] in location, f"wrong realm in redirect: {location[:100]}"
    return run


def test_proxy_bearer_passthrough(cfg, dept="sales"):
    """Proxy passes through per-user Authorization headers correctly.

    Simulates the exploit scenario: get tokens for BOTH users, then send
    MCP requests through the proxy (localhost:8889) with each user's Bearer
    token. The proxy must forward the correct token to the authbridge —
    NOT use a shared global token.

    This is the actual code path: each user's spawned gateway sets
    MCP_AUTH_BEARER in its env, and the httpx hook includes it as
    the Authorization header on proxy requests.
    """
    def run():
        token_url = (f"{cfg['kc_url']}/realms/{cfg['realm']}"
                     "/protocol/openid-connect/token")

        tokens = {}
        for user in ("sally", "fred"):
            resp = requests.post(token_url, data={
                "grant_type": "password", "client_id": "hermes-dashboard",
                "username": user, "password": cfg["user_pass"],
            }, verify=False, timeout=10)
            assert resp.status_code == 200, f"{user} login failed: {resp.status_code}"
            tokens[user] = resp.json()["access_token"]

        sandbox_pod = f"retail-{dept}"
        hermes_pid = subprocess.run(
            ["oc", "exec", "-n", cfg["namespace"], sandbox_pod, "--",
             "bash", "-c", "pgrep -f 'hermes_cli.main.*dashboard' | head -1"],
            capture_output=True, text=True, timeout=15
        ).stdout.strip()
        assert hermes_pid, "hermes dashboard not found in sandbox pod"

        mcp_body = json.dumps({
            "jsonrpc": "2.0", "method": "initialize",
            "params": {"protocolVersion": "2025-03-26",
                       "capabilities": {},
                       "clientInfo": {"name": "test", "version": "1.0"}},
            "id": 1,
        })

        # Send BOTH users' tokens through the proxy (interleaved) and
        # verify each one is forwarded correctly to the authbridge.
        # This catches the shared-token-store bug: if the proxy uses a
        # global token instead of the caller's Authorization header,
        # one of these would fail or return the wrong user.
        for user, token in tokens.items():
            result = subprocess.run(
                ["oc", "exec", "-n", cfg["namespace"], sandbox_pod, "--",
                 "bash", "-c",
                 f"nsenter -t {hermes_pid} -n curl -s --max-time 10 "
                 f"-H 'Content-Type: application/json' "
                 f"-H 'Accept: application/json, text/event-stream' "
                 f"-H 'Authorization: Bearer {token}' "
                 f"-X POST http://127.0.0.1:8889/mcp "
                 f"-d '{mcp_body}'"],
                capture_output=True, text=True, timeout=30
            )
            raw = result.stdout.strip()
            data = None
            for line in raw.splitlines():
                if line.startswith("data: "):
                    data = json.loads(line[6:])
                    break
            if data is None and raw:
                try:
                    data = json.loads(raw)
                except json.JSONDecodeError:
                    pass
            assert data and "result" in data, (
                f"{user}: proxy→authbridge rejected Bearer token "
                f"(response: {raw[:200]})")

        # Verify a forged/empty token is rejected (proxy doesn't fall
        # back to a stored token when Authorization header is present)
        result = subprocess.run(
            ["oc", "exec", "-n", cfg["namespace"], sandbox_pod, "--",
             "bash", "-c",
             f"nsenter -t {hermes_pid} -n curl -s -o /dev/null -w '%{{http_code}}' "
             f"--max-time 5 "
             f"-H 'Content-Type: application/json' "
             f"-H 'Authorization: Bearer forged.token.here' "
             f"-X POST http://127.0.0.1:8889/mcp "
             f"-d '{mcp_body}'"],
            capture_output=True, text=True, timeout=30
        )
        code = result.stdout.strip().strip("'")
        assert code not in ("200",), (
            f"forged token should be rejected, got HTTP {code}")

        return ("proxy passes sally/fred Bearer tokens independently, "
                "rejects forged tokens")
    return run


def test_spire_agent_running(cfg):
    """SPIRE agent is running and ready."""
    def run():
        ready = oc("get", "pods", "-n", "openshift-zero-trust-workload-identity-manager",
                    "-l", "app.kubernetes.io/name=spire-agent",
                    "-o", "jsonpath={.items[0].status.containerStatuses[0].ready}")
        assert ready == "true", f"spire-agent not ready: {ready}"
    return run


def test_spiffe_svid_issued(cfg, dept="sales"):
    """SPIFFE helper has issued JWT SVIDs in MCP pod."""
    def run():
        pod = oc("get", "pods", "-n", cfg["namespace"],
                 "-l", f"app=retail-{dept}-mcp",
                 "-o", "jsonpath={.items[0].metadata.name}")
        logs = oc("logs", "-n", cfg["namespace"], pod, "-c", "spiffe-helper", "--tail=5")
        assert "JWT SVID updated" in logs, f"no SVID updates in spiffe-helper logs"
    return run


# ── Main ────────────────────────────────────────────────────────────

def main():
    print("\n\033[1mRetail CTF E2E Tests\033[0m")
    print("=" * 50)

    print("\n\033[36mDiscovering cluster...\033[0m")
    try:
        cfg = discover()
    except Exception as e:
        print(f"  {FAIL} Cannot reach cluster: {e}")
        sys.exit(1)
    print(f"  domain: {cfg['apps_domain']}")
    print(f"  keycloak: {cfg['kc_host']}")

    print(f"\n\033[36m1. Keycloak / OIDC\033[0m")
    test("Keycloak reachable", test_keycloak_reachable(cfg))
    test("Admin login (master realm)", test_keycloak_admin_login(cfg))
    test("Sally login (retail-ctf realm)", test_user_login(cfg, "sally"))
    test("JWT has SPIFFE audience", test_jwt_has_spiffe_audience(cfg))

    print(f"\n\033[36m2. SPIRE / Zero Trust\033[0m")
    test("SPIRE agent running", test_spire_agent_running(cfg))
    test("SPIFFE SVIDs issued (sales MCP)", test_spiffe_svid_issued(cfg))

    print(f"\n\033[36m3. MCP AuthBridge\033[0m")
    for dept in ["sales", "finance", "ops"]:
        test(f"MCP pod ready ({dept})", test_mcp_pod_running(cfg, dept))
    test("AuthBridge rejects no-token (sales)", test_authbridge_rejects_no_token(cfg))
    test("MCP server responds (sales)", test_mcp_server_responds(cfg))

    print(f"\n\033[36m4. Sandbox Routes\033[0m")
    for dept in ["sales", "finance", "ops"]:
        test(f"Route serves login ({dept})", test_sandbox_route(cfg, dept))
    test("OIDC redirect to Keycloak", test_sandbox_oidc_redirect(cfg))

    print(f"\n\033[36m5. Session Token Isolation\033[0m")
    test("Proxy Bearer passthrough (sales)", test_proxy_bearer_passthrough(cfg))

    # Summary
    print(f"\n{'=' * 50}")
    total = len(passes) + len(failures)
    print(f"\033[1m{len(passes)}/{total} passed\033[0m", end="")
    if failures:
        print(f"  \033[31m{len(failures)} failed:\033[0m")
        for name, err in failures:
            print(f"  {FAIL} {name}: {err[:80]}")
        sys.exit(1)
    else:
        print(f"  \033[32mall green\033[0m")
        sys.exit(0)


if __name__ == "__main__":
    main()
