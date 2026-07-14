# Warm Pool Setup

Pre-provisioned sandbox pods using the Agent Sandbox Operator's `SandboxWarmPool` / `SandboxClaim` CRDs and the upstream [warm-pool-grpc-poc](https://github.com/rhuss/OpenShell/tree/6113-warm-pool-grpc-poc) branch.

## Architecture

```
SandboxTemplate ──► SandboxWarmPool (replicas=3) ──► Pre-warmed pods (--unidentified)
                                                          │
                                              SandboxClaim ──► Operator binds warm pod (~1.4s)
                                                          │
                                              Gateway calls ActivateSandbox gRPC (~0.5s)
                                                          │
                                              Supervisor stores identity, compiles OPA, connects ──► Ready
```

Cold start: ~16s. Warm pool claim + activate: **~1.9s (6x faster)**.

## Source

The `--unidentified` supervisor mode and `ActivateSandbox` gRPC gateway support are on a PoC branch (not yet merged to OpenShell main). Our build merges in the h2 websocket changes from `eformat/OpenShell:h2-ws-support` (required for OpenShift routes).

```bash
# Clone the PoC branch
git clone https://github.com/rhuss/OpenShell.git ~/git/OpenShell-warmpool \
  -b 6113-warm-pool-grpc-poc --depth 1

# Merge h2 websocket support
git -C ~/git/OpenShell-warmpool remote add eformat ~/git/OpenShell
git -C ~/git/OpenShell-warmpool fetch eformat h2-ws-support
git -C ~/git/OpenShell-warmpool cherry-pick 44081985  # 🦩 add h2 websocket support
# Resolve conflict in multiplex.rs: keep both keepalive settings AND enable_connect_protocol()
```

## Custom Images

### 1. Supervisor (openshell-sandbox)

Static musl binary with `--unidentified` mode. Runs in warm pool pods waiting for gRPC activation.

```bash
cd ~/git/OpenShell-warmpool

# Install musl toolchain (Fedora)
sudo dnf install -y musl-gcc musl-devel musl-libc-static
rustup target add x86_64-unknown-linux-musl --toolchain 1.95.0

# Build static binary
cargo +1.95.0 build --release --target x86_64-unknown-linux-musl -p openshell-sandbox

# Stage for container build
mkdir -p deploy/docker/.build/prebuilt-binaries/amd64
cp target/x86_64-unknown-linux-musl/release/openshell-sandbox \
   deploy/docker/.build/prebuilt-binaries/amd64/openshell-sandbox

# Build and push
podman build --platform linux/amd64 \
  -f deploy/docker/Dockerfile.supervisor \
  -t quay.io/eformat/openshell-supervisor:warm-pool-poc .

podman push quay.io/eformat/openshell-supervisor:warm-pool-poc
```

### 2. Gateway (openshell-server)

Gateway binary with warm pool claim + `ActivateSandbox` gRPC client support.

```bash
cd ~/git/OpenShell-warmpool

# Build (GNU-linked, not musl)
cargo +1.95.0 build --release -p openshell-server

# Stage for container build
mkdir -p deploy/docker/.build/prebuilt-binaries/amd64
cp target/release/openshell-gateway \
   deploy/docker/.build/prebuilt-binaries/amd64/openshell-gateway

# Build and push
podman build --platform linux/amd64 \
  -f deploy/docker/Dockerfile.gateway \
  -t quay.io/eformat/openshell-gateway:warm-pool-poc .

podman push quay.io/eformat/openshell-gateway:warm-pool-poc
```

## Deployed CRDs

Managed via ArgoCD (`applications/openshell/crd/`):

| File | Resource | Notes |
|------|----------|-------|
| `sandbox-template.yaml` | `SandboxTemplate/hermes-agent` | Pod template with hermes image + PoC supervisor |
| `sandbox-warmpool.yaml` | `SandboxWarmPool/hermes-agents` | 3 replicas, OnReplenish strategy |

## Key Findings

- **`spec.env` on SandboxClaim triggers a NEW pod** — operator won't adopt a warm pod if env vars differ. Per-department config must be pushed via gRPC `ActivateSandbox`, not claim env injection.
- **Pool name is the sandbox name prefix** — pool `retail-sales` creates sandboxes `retail-sales-xxxxx`.
- **Gateway only lists sandboxes it created** — warm pool sandboxes are invisible to the gateway until activated via `ActivateSandbox` gRPC (which registers them with sandbox ID + routing).
- **`volumeClaimTemplates`** is supported in SandboxTemplate (2Gi workspace PVC per pod).

## Status

| Component | Status |
|-----------|--------|
| Supervisor (`--unidentified`) | Built and deployed (`quay.io/eformat/openshell-supervisor:warm-pool-poc`) |
| Gateway (warm pool support) | Built and pushed (`quay.io/eformat/openshell-gateway:warm-pool-poc`) |
| SandboxTemplate + WarmPool | Deployed, 3 pods READY |
| Per-department pools + claims | Blocked on gateway warm pool support |
| End-to-end claim → activate → route | Blocked on gateway warm pool support |
