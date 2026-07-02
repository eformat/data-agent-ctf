#!/usr/bin/env python3
"""Patch Hermes for sandboxed/containerized deployments.

Patches applied (all scripted, all automated):

1. Normalize 0.0.0.0/:: to 127.0.0.1 in TUI WebSocket URLs.
   Hermes gated mode binds 0.0.0.0, TUI tries ws://0.0.0.0 which SSRF
   protection blocks.

2. Dashboard Auth Proxy on :8889.
   Holds OIDC tokens in memory (never disk). Passes through caller's
   Authorization header to upstream MCP authbridge. Falls back to stored
   token for MCP discovery before any user logs in.
   PR_SET_DUMPABLE=0 blocks /proc/PID/mem access from sibling processes.

3. OIDC token capture — stores access token per-user in memory.

4. pty_ws — injects user's access token as MCP_AUTH_BEARER in PTY child
   env. Each profile-scoped chat spawns its own gateway subprocess, so
   the env is per-process with no cross-user contamination.

5. mcp_tool.py — httpx request hook reads MCP_AUTH_BEARER from os.environ
   and sets Authorization header on proxy requests. PR_SET_DUMPABLE=0
   protects the env from the agent process.
"""
import re
import sys

# ── Patch 1: Wildcard bind fix ──────────────────────────────────

WILDCARD_PATCH = '''    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"'''

# ── Patch 2: Dashboard Auth Proxy ───────────────────────────────

AUTH_PROXY_PATCH = '''
    import ctypes as _ctypes
    try:
        _ctypes.CDLL("libc.so.6").prctl(4, 0)  # PR_SET_DUMPABLE = 0
    except Exception:
        pass

    import threading, os, http.server, http.client
    import json as _json, base64 as _b64, time as _time
    import urllib.request, urllib.parse, urllib.error
    from urllib.parse import urlparse as _urlparse

    _upstream_url = os.environ.get("MCP_UPSTREAM_URL", "")
    _inference_url = os.environ.get("INFERENCE_UPSTREAM_URL", "")
    _proxy_port = int(os.environ.get("MCP_PROXY_PORT", "8889"))
    _http_proxy = os.environ.get("HTTP_PROXY", os.environ.get(
        "http_proxy", ""))

    def _decode_jwt_username(token):
        try:
            parts = token.split(".")
            payload = parts[1] + "=" * (4 - len(parts[1]) % 4)
            return _json.loads(
                _b64.urlsafe_b64decode(payload)
            ).get("preferred_username")
        except Exception:
            return None

    class _TokenStore:
        user_tokens = {}        # {username: access_token} for pty_ws lookup
        api_key = os.environ.get("OPENAI_API_KEY", "")
        lock = threading.Lock()

    import sys as _sys
    _ts_mod = type(_sys)("_auth_token_store")
    _ts_mod.store = _TokenStore
    _ts_mod.decode_jwt_username = _decode_jwt_username
    _sys.modules["_auth_token_store"] = _ts_mod

    class _ProxyHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):   self._proxy()
        def do_GET(self):    self._proxy()
        def do_PUT(self):    self._proxy()
        def do_DELETE(self): self._proxy()
        def do_PATCH(self):  self._proxy()
        def do_OPTIONS(self): self._proxy()

        def _proxy(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else None
            if self.path.startswith("/mcp"):
                upstream = _upstream_url
                _auth = self.headers.get("Authorization", "")
                if _auth.startswith("Bearer ") and len(_auth) > 30:
                    cred = _auth[7:]
                else:
                    cred = None
                if not upstream:
                    self.send_error(502, "MCP_UPSTREAM_URL not set")
                    return
                if not cred:
                    r = b'{"error":"waiting for login"}'
                    self.send_response(503)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(r)))
                    self.send_header("Retry-After", "5")
                    self.end_headers()
                    self.wfile.write(r)
                    return
            else:
                upstream = _inference_url
                with _TokenStore.lock:
                    cred = _TokenStore.api_key
                if not upstream or not cred:
                    self.send_error(502, "Inference not configured")
                    return
            target_url = upstream.rstrip("/") + self.path
            headers = {}
            for key in self.headers:
                k = key.lower()
                if k in ("host", "authorization", "content-length",
                         "cookie"):
                    continue
                headers[key] = self.headers[key]
            headers["Authorization"] = f"Bearer {cred}"
            if body is not None:
                headers["Content-Length"] = str(len(body))
            try:
                if _http_proxy:
                    pp = _urlparse(_http_proxy)
                    conn = http.client.HTTPConnection(
                        pp.hostname, pp.port or 3128, timeout=300)
                    conn.request(self.command, target_url,
                                 body=body, headers=headers)
                else:
                    up = _urlparse(target_url)
                    path = up.path
                    if up.query:
                        path += "?" + up.query
                    conn = http.client.HTTPConnection(
                        up.hostname, up.port or 80, timeout=300)
                    conn.request(self.command, path,
                                 body=body, headers=headers)
                resp = conn.getresponse()
                resp_headers = resp.getheaders()
                is_sse = any(
                    k.lower() == "content-type"
                    and "text/event-stream" in v
                    for k, v in resp_headers
                )
                if is_sse:
                    self.send_response_only(resp.status)
                    for k, v in resp_headers:
                        kl = k.lower()
                        if kl in ("transfer-encoding",
                                  "content-length", "connection"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Connection", "close")
                    self.end_headers()
                    while True:
                        chunk = resp.read(4096)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    conn.close()
                else:
                    resp_body = resp.read()
                    conn.close()
                    self.send_response_only(resp.status)
                    for k, v in resp_headers:
                        kl = k.lower()
                        if kl in ("transfer-encoding",
                                  "content-length", "connection"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Content-Length",
                                     str(len(resp_body)))
                    self.end_headers()
                    self.wfile.write(resp_body)
                    self.wfile.flush()
            except Exception as _e:
                try:
                    self.send_error(502, str(_e))
                except Exception:
                    pass

        def log_message(self, format, *args):
            pass

    def _start_proxy():
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", _proxy_port), _ProxyHandler
        )
        server.serve_forever()
    threading.Thread(target=_start_proxy, daemon=True).start()

    # MCP discovery is handled by each spawned gateway subprocess
    # using its own MCP_AUTH_BEARER env var — no dashboard-side
    # discovery needed.
'''

# ── Patch 3: OIDC token capture ──────────────────────────────────

OIDC_TOKEN_CAPTURE_PATCH = '''
        _oidc_at = payload.get("access_token")
        _oidc_rt = payload.get("refresh_token")
        try:
            import _auth_token_store
            _uname = _auth_token_store.decode_jwt_username(_oidc_at)
            if _uname and _oidc_at:
                with _auth_token_store.store.lock:
                    _auth_token_store.store.user_tokens[_uname] = _oidc_at
                # Enable MCP discovery in the dashboard process.
                # This sets the bearer cache so /reload-mcp works after login.
                # Actual per-user MCP calls use spawned gateway subprocesses.
                try:
                    import tools.mcp_tool as _mt
                    if hasattr(_mt, "_MCP_BEARER_CACHE") and not _mt._MCP_BEARER_CACHE:
                        _mt._MCP_BEARER_CACHE = _oidc_at
                except Exception:
                    pass
        except Exception:
            pass
'''

# ── Patch 4: pty_ws — inject access token into PTY child env ─────

PTY_WS_USER_PATCH = '''
    try:
        import _auth_token_store as _ats
        for _cn in ("__Host-hermes_session_at",
                     "__Secure-hermes_session_at",
                     "hermes_session_at"):
            _idt = ws.cookies.get(_cn)
            if _idt:
                _un = _ats.decode_jwt_username(_idt)
                _uat = _ats.store.user_tokens.get(_un)
                if _uat:
                    env["MCP_AUTH_BEARER"] = _uat
                    if os.path.exists("/opt/hermes/nodumpable.so"):
                        env["LD_PRELOAD"] = "/opt/hermes/nodumpable.so"
                break
    except Exception:
        pass
'''

# ── Patch 5: mcp_tool.py — httpx hook + PR_SET_DUMPABLE ─────────

MCP_TOOL_DUMPABLE = '''
# Read token from env, store in process memory, then scrub from env
# and block /proc access. The token is only in Python memory after this.
_MCP_BEARER_CACHE = os.environ.pop("MCP_AUTH_BEARER", "")
try:
    import ctypes as _ctypes
    _ctypes.CDLL("libc.so.6").prctl(4, 0)
except Exception:
    pass
'''

MCP_HTTPX_HOOK = '''
            async def _inject_auth_bearer(request):
                if _MCP_BEARER_CACHE and "127.0.0.1" in str(request.url):
                    request.headers["authorization"] = (
                        f"Bearer {_MCP_BEARER_CACHE}")

'''


# ── Patch functions ──────────────────────────────────────────────

def patch_function(source, func_name):
    pattern = rf'(def {func_name}\(.*?\n(?:.*?\n)*?    host = getattr\(app\.state, "bound_host", None\))'
    match = re.search(pattern, source)
    if not match:
        print(f"  WARNING: {func_name} not found", file=sys.stderr)
        return source
    original = match.group(1)
    result = source.replace(original, original + "\n" + WILDCARD_PATCH, 1)
    print(f"  Patched {func_name}", file=sys.stderr)
    return result


def patch_lifespan(source):
    marker = "app.state.event_channels = {}  # dict[str, set]"
    if marker not in source:
        print("  WARNING: _lifespan marker not found", file=sys.stderr)
        return source
    result = source.replace(marker, marker + AUTH_PROXY_PATCH, 1)
    print("  Patched _lifespan (auth proxy)", file=sys.stderr)
    return result


def patch_pty_ws_user(source):
    # Force every chat to spawn its own gateway subprocess by removing
    # the HERMES_TUI_GATEWAY_URL assignment. Without it, the PTY child
    # spawns tui_gateway.entry which inherits MCP_AUTH_BEARER from env.
    gw_marker = ('    if profile_dir is None:\n'
                 '        if gateway_ws_url := _build_gateway_ws_url():\n'
                 '            env["HERMES_TUI_GATEWAY_URL"] = gateway_ws_url')
    if gw_marker in source:
        source = source.replace(gw_marker,
            '    # Per-user token isolation: always spawn a separate gateway\n'
            '    # subprocess so each user gets their own MCP_AUTH_BEARER env.', 1)
        print("  Patched _resolve_chat_argv (force separate gateway)",
              file=sys.stderr)
    else:
        print("  WARNING: gateway_ws_url marker not found", file=sys.stderr)

    marker = "    try:\n        bridge = PtyBridge.spawn(argv, cwd=cwd, env=env)"
    if marker not in source:
        print("  WARNING: PtyBridge.spawn marker not found", file=sys.stderr)
        return source
    result = source.replace(marker, PTY_WS_USER_PATCH + marker, 1)
    print("  Patched pty_ws (MCP_AUTH_BEARER)", file=sys.stderr)
    return result


def patch_mcp_tool(source):
    marker1 = "from urllib.parse import urlparse"
    if marker1 not in source:
        print("  WARNING: urlparse import not found", file=sys.stderr)
        return source
    source = source.replace(marker1, marker1 + "\n" + MCP_TOOL_DUMPABLE, 1)

    fn_marker = "            client_kwargs: dict = {"
    if fn_marker not in source:
        print("  WARNING: client_kwargs not found", file=sys.stderr)
        return source
    source = source.replace(fn_marker, MCP_HTTPX_HOOK + fn_marker, 1)

    hooks_marker = ('"event_hooks": {"response": '
                    '[_strip_auth_on_cross_origin_redirect]},')
    if hooks_marker not in source:
        print("  WARNING: event_hooks not found", file=sys.stderr)
        return source
    source = source.replace(
        hooks_marker,
        '"event_hooks": {"response": '
        '[_strip_auth_on_cross_origin_redirect], '
        '"request": [_inject_auth_bearer]},', 1)

    print("  Patched mcp_tool.py (PR_SET_DUMPABLE + httpx hook)",
          file=sys.stderr)
    return source


def patch_oidc_confidential(source):
    """Add client_secret support to the self-hosted OIDC plugin."""
    # 1. Constructor: add client_secret param
    old_init = ("    def __init__(\n"
                "        self,\n"
                "        *,\n"
                "        issuer: str,\n"
                "        client_id: str,\n"
                "        scopes: str = _DEFAULT_SCOPES,\n"
                "    ) -> None:")
    new_init = ("    def __init__(\n"
                "        self,\n"
                "        *,\n"
                "        issuer: str,\n"
                "        client_id: str,\n"
                "        scopes: str = _DEFAULT_SCOPES,\n"
                "        client_secret: str = \"\",\n"
                "    ) -> None:")
    if old_init not in source:
        print("  WARNING: OIDC __init__ not found", file=sys.stderr)
        return source
    source = source.replace(old_init, new_init, 1)

    # Store client_secret on self
    store_marker = "        self._scopes = scopes.strip() or _DEFAULT_SCOPES"
    if store_marker not in source:
        print("  WARNING: _scopes assignment not found", file=sys.stderr)
        return source
    source = source.replace(
        store_marker,
        store_marker + "\n        self._client_secret = client_secret", 1)

    # 2. complete_login: add client_secret to token exchange
    exchange_marker = ("        # TODO(confidential-client): when client_secret "
                       "support lands, add it")
    if exchange_marker not in source:
        print("  WARNING: complete_login TODO not found", file=sys.stderr)
        return source
    source = source.replace(
        exchange_marker,
        "        if self._client_secret:\n"
        "            data[\"client_secret\"] = self._client_secret\n"
        "        # confidential-client: client_secret added above", 1)

    # 3. refresh_session: add client_secret to refresh
    refresh_marker = ("        # TODO(confidential-client): add client_secret "
                      "here when supported.")
    if refresh_marker not in source:
        print("  WARNING: refresh_session TODO not found", file=sys.stderr)
        return source
    source = source.replace(
        refresh_marker,
        "        if self._client_secret:\n"
        "            data[\"client_secret\"] = self._client_secret\n"
        "        # confidential-client: client_secret added above", 1)

    # 4. register: read env var and pass to constructor
    old_construct = ("        provider = SelfHostedOIDCProvider(\n"
                     "            issuer=issuer, client_id=client_id, "
                     "scopes=scopes\n"
                     "        )")
    new_construct = ("        client_secret = _resolve_setting(\n"
                     "            \"HERMES_DASHBOARD_OIDC_CLIENT_SECRET\",\n"
                     "            oidc_cfg.get(\"client_secret\"))\n"
                     "        provider = SelfHostedOIDCProvider(\n"
                     "            issuer=issuer, client_id=client_id,\n"
                     "            scopes=scopes, client_secret=client_secret\n"
                     "        )")
    if old_construct not in source:
        print("  WARNING: provider construction not found", file=sys.stderr)
        return source
    source = source.replace(old_construct, new_construct, 1)

    print("  Patched OIDC plugin (confidential client_secret)",
          file=sys.stderr)
    return source


def main():
    ws_path = (sys.argv[1] if len(sys.argv) > 1
               else "/opt/hermes/hermes_cli/web_server.py")

    print(f"Patching {ws_path}", file=sys.stderr)
    with open(ws_path, "r") as f:
        source = f.read()
    source = patch_function(source, "_build_gateway_ws_url")
    source = patch_function(source, "_build_sidecar_url")
    source = patch_lifespan(source)
    source = patch_pty_ws_user(source)
    with open(ws_path, "w") as f:
        f.write(source)

    oidc_path = "/opt/hermes/plugins/dashboard_auth/self_hosted/__init__.py"
    print(f"Patching {oidc_path}", file=sys.stderr)
    try:
        with open(oidc_path, "r") as f:
            oidc_source = f.read()
        marker = ('        return self._session_from_tokens(\n'
                  '            id_token=id_token, refresh_token='
                  'refresh_token, claims=claims\n        )')
        if marker in oidc_source:
            oidc_source = oidc_source.replace(
                marker, OIDC_TOKEN_CAPTURE_PATCH + marker, 1)
        else:
            print("  WARNING: OIDC marker not found", file=sys.stderr)
        oidc_source = patch_oidc_confidential(oidc_source)
        with open(oidc_path, "w") as f:
            f.write(oidc_source)
    except FileNotFoundError:
        print("  WARNING: OIDC plugin not found", file=sys.stderr)

    mcp_path = "/opt/hermes/tools/mcp_tool.py"
    print(f"Patching {mcp_path}", file=sys.stderr)
    try:
        with open(mcp_path, "r") as f:
            mcp_source = f.read()
        mcp_source = patch_mcp_tool(mcp_source)
        with open(mcp_path, "w") as f:
            f.write(mcp_source)
    except FileNotFoundError:
        print("  WARNING: mcp_tool.py not found", file=sys.stderr)

    print("Done", file=sys.stderr)


if __name__ == "__main__":
    main()
