#!/usr/bin/env python3
"""Patch Hermes for sandboxed/containerized deployments.

Patches applied (all scripted, all automated):

1. Normalize 0.0.0.0/:: to 127.0.0.1 in TUI WebSocket URLs.
   When the dashboard binds 0.0.0.0 for gated/OAuth mode, the TUI child
   tries to connect to ws://0.0.0.0:<port> which SSRF protection blocks.

2. Dashboard Auth Proxy — per-session token isolation.
   Starts an HTTP proxy on :8889 inside the dashboard process.
   Reads the per-user hermes_session_at cookie (HttpOnly, Secure,
   SameSite=Lax) to select the correct JWT per session. Falls back to
   the global _TokenStore for bootstrap (MCP discovery before login).
   Strips cookies before forwarding to upstream MCP servers.
   Calls PR_SET_DUMPABLE=0 so sibling processes (gateway/agent) cannot
   read the dashboard's /proc/PID/mem, /proc/PID/environ, or /proc/PID/maps.
   Combined with ptrace_scope=1 (default), the gateway process has ZERO
   access to the token. Kagenti-inspired: "Agents never see tokens."

3. OIDC token capture — stores tokens in memory, NOT on disk.
   Patches the self-hosted OIDC plugin to set an in-memory store instead
   of writing to /tmp/hermes-oidc-token. The auth proxy reads from the
   store. No token file ever exists.

4. Session token bridge — Starlette middleware that reads the per-user
   hermes_session_at cookie and stashes it in a contextvars.ContextVar,
   making it available to the MCP tool HTTP client in the same async
   request context.

5. MCP tool cookie forwarding — httpx request event hook that reads the
   contextvar and injects the session cookie into requests to the local
   auth proxy (localhost:8889), ensuring per-session token isolation
   end-to-end.
"""
import re
import sys

# ── Patch 1: Wildcard bind fix ──────────────────────────────────

WILDCARD_PATCH = '''    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"'''

# ── Patch 2: Dashboard Auth Proxy ───────────────────────────────

AUTH_PROXY_PATCH = '''
    # ── Auth Proxy: token never touches disk ──────────────────
    # Kagenti pattern adapted for OpenShell single-container sandboxes.
    # The dashboard holds the token; the agent/gateway never sees it.
    import ctypes as _ctypes
    try:
        _libc = _ctypes.CDLL("libc.so.6")
        _libc.prctl(4, 0)  # PR_SET_DUMPABLE = 0
    except Exception:
        pass

    import threading, os, http.server, http.client, contextvars
    import json as _json, base64 as _b64, time as _time
    import urllib.request, urllib.parse, urllib.error
    from urllib.parse import urlparse as _urlparse

    _upstream_url = os.environ.get("MCP_UPSTREAM_URL", "")
    _inference_url = os.environ.get("INFERENCE_UPSTREAM_URL", "")
    _proxy_port = int(os.environ.get("MCP_PROXY_PORT", "8889"))
    _http_proxy = os.environ.get("HTTP_PROXY", os.environ.get(
        "http_proxy", ""))

    # Per-request session token — set by Starlette middleware, read by
    # MCP tool HTTP client to forward the correct user's JWT to the proxy.
    _current_session_token = contextvars.ContextVar(
        "_current_session_token", default=None)

    # Cookie name variants — hermes uses __Host-/__Secure-/bare depending
    # on HTTPS and reverse-proxy prefix configuration.
    _AT_COOKIE_NAMES = (
        "__Host-hermes_session_at",
        "__Secure-hermes_session_at",
        "hermes_session_at",
    )

    def _extract_at_from_cookies(cookie_header):
        """Extract hermes_session_at value from a Cookie header string."""
        for part in cookie_header.split(";"):
            part = part.strip()
            for name in _AT_COOKIE_NAMES:
                prefix = name + "="
                if part.startswith(prefix):
                    return part[len(prefix):]
        return None

    class _TokenStore:
        token = None
        refresh = None
        api_key = os.environ.get("OPENAI_API_KEY", "")
        lock = threading.Lock()

    # Register as a synthetic module so the OIDC plugin and MCP tool
    # (same process) can import it without touching the filesystem.
    import sys as _sys
    _ts_mod = type(_sys)("_auth_token_store")
    _ts_mod.store = _TokenStore
    _ts_mod.current_session_token = _current_session_token
    _ts_mod.AT_COOKIE_NAMES = _AT_COOKIE_NAMES
    _sys.modules["_auth_token_store"] = _ts_mod

    class _ProxyHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            self._proxy()
        def do_GET(self):
            self._proxy()
        def do_PUT(self):
            self._proxy()
        def do_DELETE(self):
            self._proxy()
        def do_PATCH(self):
            self._proxy()
        def do_OPTIONS(self):
            self._proxy()

        def _proxy(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else None
            if self.path.startswith("/mcp"):
                upstream = _upstream_url
                cred = _extract_at_from_cookies(
                    self.headers.get("Cookie", ""))
                if not cred:
                    with _TokenStore.lock:
                        cred = _TokenStore.token
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

    # Token refresh loop — rotates the access token before Keycloak
    # 5-min TTL expires. Runs entirely in-process, no file I/O.
    def _refresh_loop():
        kc_url = os.environ.get("HERMES_DASHBOARD_OIDC_ISSUER", "")
        client_id = os.environ.get("HERMES_DASHBOARD_OIDC_CLIENT_ID",
                                    "hermes-dashboard")
        if not kc_url:
            return
        token_endpoint = (kc_url.rstrip("/")
                          + "/protocol/openid-connect/token")
        while True:
            _time.sleep(30)
            with _TokenStore.lock:
                tok = _TokenStore.token
                rt = _TokenStore.refresh
            if not tok or not rt:
                continue
            try:
                parts = tok.split(".")
                payload = parts[1] + "=" * (4 - len(parts[1]) % 4)
                claims = _json.loads(_b64.urlsafe_b64decode(payload))
                ttl = claims.get("exp", 0) - _time.time()
                if ttl > 60:
                    _time.sleep(max(10, ttl - 60))
                    continue
            except Exception:
                pass
            try:
                data = urllib.parse.urlencode({
                    "grant_type": "refresh_token",
                    "client_id": client_id,
                    "refresh_token": rt,
                    "scope": "openid profile email",
                }).encode()
                req = urllib.request.Request(
                    token_endpoint, data=data,
                    headers={"Accept": "application/json"})
                resp = urllib.request.urlopen(req, timeout=10)
                body = _json.loads(resp.read())
                new_at = body.get("access_token", "")
                new_rt = body.get("refresh_token", rt)
                with _TokenStore.lock:
                    if new_at:
                        _TokenStore.token = new_at
                    if new_rt:
                        _TokenStore.refresh = new_rt
            except Exception:
                _time.sleep(30)
    threading.Thread(target=_refresh_loop, daemon=True).start()

    # MCP discovery — waits for token to arrive, then discovers tools.
    def _mcp_discover():
        for _ in range(120):
            with _TokenStore.lock:
                if _TokenStore.token:
                    break
            _time.sleep(5)
        else:
            return
        _time.sleep(2)
        try:
            from tools.mcp_tool import discover_mcp_tools
            discover_mcp_tools()
        except Exception:
            pass
    threading.Thread(target=_mcp_discover, daemon=True).start()
'''

# ── Patch 3: OIDC token capture (memory-only) ──────────────────

OIDC_TOKEN_CAPTURE_PATCH = '''
        # Store tokens in the dashboard's in-memory auth proxy store.
        # The token NEVER touches the filesystem. The auth proxy (running
        # in this same process) reads from the store and injects into
        # MCP requests. The gateway/agent process has zero access.
        _oidc_at = payload.get("access_token")
        _oidc_rt = payload.get("refresh_token")
        try:
            import _auth_token_store
            with _auth_token_store.store.lock:
                if _oidc_at:
                    _auth_token_store.store.token = _oidc_at
                if _oidc_rt:
                    _auth_token_store.store.refresh = _oidc_rt
        except Exception:
            pass
'''

# ── Patch 4: Starlette middleware — bridge session cookie → contextvar ──

SESSION_TOKEN_BRIDGE_PATCH = '''

@app.middleware("http")
async def _session_token_bridge(request: Request, call_next):
    """Bridge the per-user session cookie into a contextvar.

    Hermes stores the OIDC access token in the hermes_session_at cookie
    (HttpOnly, Secure, SameSite=Lax). Each browser session has its own
    cookie. This middleware reads it and stashes it in a contextvar so
    the MCP tool HTTP client can forward it to the auth proxy, ensuring
    per-session token isolation.
    """
    at = None
    try:
        import _auth_token_store
        for _name in _auth_token_store.AT_COOKIE_NAMES:
            at = request.cookies.get(_name)
            if at:
                break
        if at:
            _tok = _auth_token_store.current_session_token.set(at)
            try:
                return await call_next(request)
            finally:
                _auth_token_store.current_session_token.reset(_tok)
    except Exception:
        pass
    return await call_next(request)
'''

# ── Patch 5: MCP tool — forward session cookie to auth proxy ──────────

MCP_TOOL_COOKIE_PATCH = '''
            # Per-session cookie forwarding: when the MCP server is the local
            # auth proxy, inject the hermes_session_at cookie from the current
            # request's contextvar so each user's MCP call uses their own JWT.
            def _inject_session_cookie(request):
                try:
                    import _auth_token_store as _ats
                    if "127.0.0.1" in str(request.url):
                        tok = _ats.current_session_token.get(None)
                        if tok:
                            request.headers["cookie"] = (
                                f"{_ats.AT_COOKIE_NAMES[0]}={tok}")
                except Exception:
                    pass
'''


def patch_function(source: str, func_name: str) -> str:
    pattern = rf'(def {func_name}\(.*?\n(?:.*?\n)*?    host = getattr\(app\.state, "bound_host", None\))'
    match = re.search(pattern, source)
    if not match:
        print(f"  WARNING: could not find {func_name}", file=sys.stderr)
        return source
    original = match.group(1)
    patched = original + "\n" + WILDCARD_PATCH
    result = source.replace(original, patched, 1)
    print(f"  Patched {func_name}", file=sys.stderr)
    return result


def patch_lifespan_auth_proxy(source: str) -> str:
    marker = "app.state.event_channels = {}  # dict[str, set]"
    if marker not in source:
        print("  WARNING: could not find _lifespan marker", file=sys.stderr)
        return source
    result = source.replace(marker, marker + AUTH_PROXY_PATCH, 1)
    print("  Patched _lifespan (auth proxy + token refresh + MCP discovery)",
          file=sys.stderr)
    return result


def patch_session_token_bridge(source: str) -> str:
    """Add middleware to bridge session cookie into contextvar."""
    marker = ("@app.middleware(\"http\")\n"
              "async def auth_middleware(request: Request, call_next):")
    if marker not in source:
        print("  WARNING: could not find auth_middleware marker",
              file=sys.stderr)
        return source
    result = source.replace(
        marker, SESSION_TOKEN_BRIDGE_PATCH + "\n" + marker, 1)
    print("  Patched web_server.py (session token bridge middleware)",
          file=sys.stderr)
    return result


def patch_mcp_tool_cookie(source: str) -> str:
    """Patch MCP tool to forward session cookie to auth proxy.

    Injects a request event hook into the httpx.AsyncClient that hermes
    creates for Streamable HTTP MCP connections. The hook reads the
    contextvar set by the Starlette middleware and forwards the session
    cookie to the auth proxy on localhost.
    """
    marker = ('"event_hooks": {"response": '
              '[_strip_auth_on_cross_origin_redirect]},')
    if marker not in source:
        print("  WARNING: could not find mcp_tool event_hooks marker",
              file=sys.stderr)
        return source
    replacement = (
        MCP_TOOL_COOKIE_PATCH
        + '            "event_hooks": {"response": '
        '[_strip_auth_on_cross_origin_redirect], '
        '"request": [_inject_session_cookie]},'
    )
    result = source.replace(marker, replacement, 1)
    print("  Patched mcp_tool.py (session cookie forwarding)",
          file=sys.stderr)
    return result


def main():
    ws_path = (sys.argv[1] if len(sys.argv) > 1
               else "/opt/hermes/hermes_cli/web_server.py")

    print(f"Patching {ws_path}", file=sys.stderr)
    with open(ws_path, "r") as f:
        source = f.read()
    source = patch_function(source, "_build_gateway_ws_url")
    source = patch_function(source, "_build_sidecar_url")
    source = patch_lifespan_auth_proxy(source)
    source = patch_session_token_bridge(source)
    with open(ws_path, "w") as f:
        f.write(source)

    # Patch self-hosted OIDC plugin to capture tokens in memory.
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
            with open(oidc_path, "w") as f:
                f.write(oidc_source)
            print("  Patched OIDC plugin (in-memory token capture)",
                  file=sys.stderr)
        else:
            print("  WARNING: could not find OIDC token marker",
                  file=sys.stderr)
    except FileNotFoundError:
        print("  WARNING: self-hosted OIDC plugin not found",
              file=sys.stderr)

    # Patch MCP tool to forward session cookie to proxy.
    mcp_path = "/opt/hermes/tools/mcp_tool.py"
    print(f"Patching {mcp_path}", file=sys.stderr)
    try:
        with open(mcp_path, "r") as f:
            mcp_source = f.read()
        mcp_source = patch_mcp_tool_cookie(mcp_source)
        with open(mcp_path, "w") as f:
            f.write(mcp_source)
    except FileNotFoundError:
        print("  WARNING: mcp_tool.py not found", file=sys.stderr)

    print("Done", file=sys.stderr)


if __name__ == "__main__":
    main()
