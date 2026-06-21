#!/bin/bash
# Bootstrap the Retail CTF deployment on a fresh OpenShift cluster.
#
# Usage:
#   ./scripts/bootstrap.sh                          # defaults
#   ./scripts/bootstrap.sh --namespace my-ctf       # custom namespace
#   ./scripts/bootstrap.sh --tenant-argocd          # deploy tenant ArgoCD
#   ./scripts/bootstrap.sh --tolerate-gpu           # schedule on GPU nodes
#
# Prerequisites:
#   - oc CLI logged in as cluster-admin (or namespace-admin for tenant mode)
#   - age-key.txt in repo root (for sops secret decryption)
#   - ArgoCD (openshift-gitops) installed on cluster

set -euo pipefail

NAMESPACE="${NAMESPACE:-data-agent-ctf}"
TENANT_ARGOCD=false
TOLERATE_GPU=false
GIT_REPO="${GIT_REPO:-https://github.com/eformat/data-agent-ctf.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --tenant-argocd) TENANT_ARGOCD=true; shift ;;
    --tolerate-gpu) TOLERATE_GPU=true; shift ;;
    --repo) GIT_REPO="$2"; shift 2 ;;
    --branch) GIT_BRANCH="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Retail CTF Bootstrap ==="
echo "  Namespace:     ${NAMESPACE}"
echo "  Tenant ArgoCD: ${TENANT_ARGOCD}"
echo "  GPU toleration: ${TOLERATE_GPU}"
echo "  Git repo:      ${GIT_REPO}"
echo ""

# 1. Create namespace
echo "--- Creating namespace ---"
oc new-project "${NAMESPACE}" 2>/dev/null || oc project "${NAMESPACE}"

# 2. Label namespace for ArgoCD management
ARGOCD_NS="openshift-gitops"
if $TENANT_ARGOCD; then
  ARGOCD_NS="${NAMESPACE}"
  oc label namespace "${NAMESPACE}" argocd.argoproj.io/managed-by="${NAMESPACE}" --overwrite
else
  oc label namespace "${NAMESPACE}" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
fi

# 3. Create sops-age-key secret (for secret decryption)
if [ -f "${REPO_DIR}/age-key.txt" ]; then
  echo "--- Creating sops-age-key secret ---"
  oc create secret generic sops-age-key \
    -n "${ARGOCD_NS}" \
    --from-file=age-key.txt="${REPO_DIR}/age-key.txt" \
    --dry-run=client -o yaml | oc apply -f -
else
  echo "WARNING: age-key.txt not found — sops secrets won't decrypt"
fi

# 4. Tenant ArgoCD (optional)
if $TENANT_ARGOCD; then
  echo "--- Deploying tenant ArgoCD ---"
  # Ensure OpenShift GitOps operator is installed
  oc get subscription openshift-gitops-operator -n openshift-operators 2>/dev/null || \
    echo "WARNING: OpenShift GitOps operator not installed — install it first"

  # Apply tenant ArgoCD CR
  sed "s/data-agent-ctf/${NAMESPACE}/g" "${REPO_DIR}/bootstrap/tenant-argocd.yaml" | \
    oc apply -n "${NAMESPACE}" -f -

  echo "Waiting for tenant ArgoCD..."
  for i in $(seq 1 60); do
    if oc get pod -n "${NAMESPACE}" -l app.kubernetes.io/name="${NAMESPACE}-server" 2>/dev/null | grep -q Running; then
      echo "  Tenant ArgoCD ready"
      break
    fi
    sleep 5
  done
fi

# 5. Apply app-of-apps
echo "--- Deploying app-of-apps ---"
sed -e "s|namespace: openshift-gitops|namespace: ${ARGOCD_NS}|" \
    -e "s|namespace: data-agent-ctf|namespace: ${NAMESPACE}|" \
    -e "s|repoURL: .*|repoURL: ${GIT_REPO}|" \
    -e "s|targetRevision: .*|targetRevision: ${GIT_BRANCH}|" \
    "${REPO_DIR}/app-of-apps/retail-ctf.yaml" | oc apply -f -

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Monitor progress:"
echo "  oc get applications -n ${ARGOCD_NS}"
echo ""
echo "ArgoCD console:"
if $TENANT_ARGOCD; then
  echo "  $(oc get route ${NAMESPACE}-server -n ${NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo 'pending...')"
else
  echo "  $(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo 'pending...')"
fi
