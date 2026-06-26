# data-agent-ctf

ArgoCD-driven deployment for the Retail Zero-Trust CTF — a Dune-themed security challenge
demonstrating SpiceDB authorization, SPIFFE identity, AuthBridge JWT validation, and
agent credential isolation on OpenShift.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/eformat/data-agent-ctf.git
cd data-agent-ctf

# 2. Configure for your cluster (edit ONE file)
vi app-of-apps/values.yaml

# 3. Bootstrap (pass --branch if not on main)
./scripts/bootstrap.sh --branch $(git branch --show-current)

# 4. Wait for ArgoCD to sync all apps (~10 min)
oc get applications -n openshift-gitops | grep retail-ctf

# 5. Deploy sandboxes
make deploy-sandboxes

# 6. Run tests
make test
```

## Cluster Configuration

All cluster-specific values live in **one file**: `app-of-apps/values.yaml`

```yaml
appsDomain: apps.my-cluster.example.com    # oc get ingresses.config cluster -o jsonpath='{.spec.domain}'
namespace: openshell
realmName: retail-ctf
inference:
  host: maas.apps.ocp.cloud.rhai-tmm.dev   # your LLM inference endpoint
  path: /prelude-maas/qwen36-27b
gitRepo: https://github.com/eformat/data-agent-ctf.git
gitRevision: main
```

The bootstrap script auto-detects `appsDomain` from the cluster if not already configured.

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
ArgoCD App-of-Apps (Helm chart — app-of-apps/)
├── cert-manager (operator)
├── keycloak (operator + instance + realm/users/clients Job)
├── spicedb (operator + instance + schema/fixtures Job)
├── minio (S3 storage)
├── trino (Nessie + query engine + tables/data Job)
├── kagenti (ZTWIM + operator)
├── openshell (gateway + routes)
├── console-plugin (SpiceDB authz UI)
├── retail-mcp (3x MCP servers + AuthBridge sidecars)
└── retail-sandboxes (3x Hermes agent sandboxes + deploy Job)
```

## Secrets

Encrypted with [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

```bash
# Decrypt
SOPS_AGE_KEY_FILE=age-key.txt sops -d applications/secrets/secrets.enc.yaml

# Edit + re-encrypt
cp secrets-dec.yaml secrets-dec.enc.yaml  # filename must match .enc.yaml
SOPS_AGE_KEY_FILE=age-key.txt sops -e --age <AGE_PUBLIC_KEY> secrets-dec.enc.yaml > applications/secrets/secrets.enc.yaml
```

## Deploying to a New Cluster

Each cluster gets its own git branch with cluster-specific `values.yaml`.

```bash
# 1. Create a branch for the new cluster
git checkout -b new-cluster

# 2. Configure for the cluster
vi app-of-apps/values.yaml   # update appsDomain + inference

# 3. Update sops secrets if needed (keycloak admin password, API keys)
SOPS_AGE_KEY_FILE=age-key.txt sops -d applications/secrets/secrets.enc.yaml > /tmp/secrets-dec.enc.yaml
vi /tmp/secrets-dec.enc.yaml
SOPS_AGE_KEY_FILE=age-key.txt sops -e --age <AGE_PUBLIC_KEY> /tmp/secrets-dec.enc.yaml > applications/secrets/secrets.enc.yaml

# 4. Commit, push, deploy
git commit -am "Configure for new-cluster"
git push -u origin new-cluster
make bootstrap

# 5. Wait for sync (~10 min), then deploy sandboxes and test
make deploy-sandboxes
make test
```

To merge code changes from `main`:
```bash
git checkout new-cluster
git merge main
git push
```

## Makefile Targets

```bash
make bootstrap        # Deploy everything
make test             # Run E2E MCP pipeline tests (15 checks)
make deploy-sandboxes # Recreate Hermes sandboxes
make build-all        # Build and push all container images
make build-hermes     # Build hermes-openshell image
make build-gateway    # Build openshell-gateway image
make build-deployer   # Build openshell-deployer image
make build-mcp        # Build retail-mcp-server image
make validate         # Validate kustomize builds
make status           # Show deployment status
```

## Versions

See [VERSIONS.md](VERSIONS.md) for all component versions and image sources.
