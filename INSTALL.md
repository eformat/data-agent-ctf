# data-agent-ctf

ArgoCD-driven deployment for the Retail Zero-Trust CTF — a Dune-themed security challenge
demonstrating SpiceDB authorization, SPIFFE identity, AuthBridge JWT validation, and
agent credential isolation on OpenShift.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/eformat/data-agent-ctf.git
cd data-agent-ctf

# 2. Bootstrap (one command)
./scripts/bootstrap.sh

# 3. Wait for ArgoCD to sync all apps (~10 min)
oc get applications -n openshift-gitops | grep retail-ctf
```

## Deployment Modes

```bash
# Default: single namespace, use cluster ArgoCD
./scripts/bootstrap.sh

# Custom namespace
./scripts/bootstrap.sh --namespace my-ctf

# Tenant ArgoCD (namespace-scoped, multi-tenant safe)
./scripts/bootstrap.sh --tenant-argocd --namespace team1-ctf

# GPU node scheduling (for CPU-constrained clusters)
./scripts/bootstrap.sh --tolerate-gpu
```

## Architecture

```
ArgoCD App-of-Apps
├── cert-manager (operator)
├── keycloak (operator + instance + realm/users/clients Job)
├── spicedb (operator + instance + schema/fixtures Job)
├── minio (S3 storage)
├── trino (Nessie + query engine + tables/data Job)
├── kagenti (ZTWIM + operator)
├── openshell (gateway + routes)
├── retail-mcp (3x MCP servers + AuthBridge sidecars)
└── retail-sandboxes (3x Hermes agent sandboxes)
```

## Secrets

Encrypted with [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

```bash
# Generate key (once)
age-keygen > age-key.txt  # Keep safe, gitignored

# Encrypt a secret
sops --encrypt --in-place applications/keycloak/config/realm-secret.enc.yaml

# Decrypt (for editing)
sops --decrypt applications/keycloak/config/realm-secret.enc.yaml
```

## Values

Edit `values.yaml` to configure:

| Key | Default | Description |
|-----|---------|-------------|
| `namespace` | `data-agent-ctf` | Target namespace |
| `singleNamespace` | `true` | All components in one namespace |
| `tenantArgoCD.enabled` | `false` | Deploy namespace-scoped ArgoCD |
| `tolerateGPU` | `false` | Schedule on GPU nodes |
| `inference.url` | MaaS endpoint | LLM inference URL |
| `inference.model` | `qwen36-27b` | Model name |
