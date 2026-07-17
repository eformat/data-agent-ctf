# Component Versions

Pinned versions for the Retail Zero-Trust CTF platform.

| Component | Version | Image / Chart | Notes |
|-----------|---------|---------------|-------|
| **OpenShell Gateway** | 0.0.85 | `quay.io/eformat/openshell-gateway:0.0.85` | Helm chart `oci://ghcr.io/nvidia/openshell/helm-chart:0.0.85` |
| **OpenShell Supervisor** | 0.0.85 | `quay.io/eformat/openshell-supervisor:v0.0.85` | Custom build with `--unidentified` warm pool support |
| **OpenShell Deployer** | 0.0.85 CLI | `quay.io/eformat/openshell-deployer:latest` | Bundles `openshell` CLI + `oc` 4.21 |
| **AuthBridge Envoy** | v0.6.0-alpha.9 | `ghcr.io/kagenti/kagenti-extensions/authbridge-envoy` | |
| **AuthBridge (full)** | v0.6.0-alpha.9 | `ghcr.io/kagenti/kagenti-extensions/authbridge` | |
| **Proxy Init** | v0.6.0-alpha.9 | `ghcr.io/kagenti/kagenti-extensions/proxy-init` | Uses `iptables-legacy` mode |
| **SPIFFE Helper** | nightly | `ghcr.io/spiffe/spiffe-helper:nightly` | |
| **Hermes Agent** | 0.18.2 (v2026.7.7.2) | `quay.io/eformat/hermes-openshell:latest` | Custom image with `hermes-start.sh` |
| **Retail MCP Server** | latest | `quay.io/eformat/retail-mcp-server:latest` | |
| **Keycloak (RHBK)** | v26 | Operator-managed | Realm: `retail-ctf` |
| **SpiceDB** | operator | `authzed/spicedb-operator` | |
| **Trino** | 480 | Helm chart (community) | Iceberg + Nessie catalogs |
| **MinIO** | latest | Helm chart | S3-compatible lakehouse storage |
| **Nessie** | latest | Helm chart | Iceberg catalog backend |
| **cert-manager** | latest | Operator | |
| **ZTWIM (SPIRE)** | 1.14.7 | Operator-managed | Trust domain: `retail-demo` |
| **Agent Sandbox Operator** | 0.9.0 | OLM `redhat-operators` catalog | Channel: `preview-0.9`, AllNamespaces mode |
| **OpenShift** | 4.21 | | Target cluster version |

## Custom Images

Built from this repo (`scripts/Containerfile.*`):

| Image | Source | Build |
|-------|--------|-------|
| `quay.io/eformat/openshell-gateway:v0.0.85` | `~/git/OpenShell` (v0.0.85) | `cargo build --release -p openshell-server` |
| `quay.io/eformat/openshell-supervisor:v0.0.85` | `~/git/OpenShell` (v0.0.85) | `cargo build --release --target x86_64-unknown-linux-musl -p openshell-sandbox` |
| `quay.io/eformat/openshell-deployer:latest` | `scripts/Containerfile.openshell-deployer` | Bundles openshell CLI + oc + libz3 |
| `quay.io/eformat/hermes-openshell:latest` | `scripts/Containerfile.hermes-sandbox` | hermes-agent + `hermes-start.sh` |
| `quay.io/eformat/retail-mcp-server:latest` | `scripts/Containerfile.retail-mcp-server` | Build context: `~/git/data-agent-template` |
