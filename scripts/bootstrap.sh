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

NAMESPACE="${NAMESPACE:-openshell}"
TENANT_ARGOCD=false
TOLERATE_GPU=false
GIT_REPO="${GIT_REPO:-https://github.com/eformat/data-agent-ctf.git}"
GIT_BRANCH="${GIT_BRANCH:-$(git -C "$(dirname "$0")/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"    

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

# 4. Configure sops-age-kustomize CMP plugin on ArgoCD repo-server
echo "--- Configuring sops-age-kustomize CMP plugin ---"
oc apply -f "${REPO_DIR}/bootstrap/sops-age-plugin.yaml"

ARGOCD_NAME=$(oc get argocd -n "${ARGOCD_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$ARGOCD_NAME" ]; then
  # Check if sidecar already exists
  if ! oc get argocd "${ARGOCD_NAME}" -n "${ARGOCD_NS}" -o jsonpath='{.spec.repo.sidecarContainers[*].name}' 2>/dev/null | grep -q sops-age-kustomize; then
    echo "  Adding sops-age-kustomize sidecar to ArgoCD ${ARGOCD_NAME}..."
    oc patch argocd "${ARGOCD_NAME}" -n "${ARGOCD_NS}" --type=json -p='[
      {"op":"add","path":"/spec/repo/sidecarContainers/-","value":{
        "name":"sops-age-kustomize",
        "command":["/var/run/argocd/argocd-cmp-server"],
        "image":"quay.io/eformat/argocd-vault-sidecar:2.14.13",
        "imagePullPolicy":"Always",
        "env":[{"name":"SOPS_AGE_KEY_FILE","value":"/sops/age-key.txt"}],
        "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},
        "volumeMounts":[
          {"mountPath":"/var/run/argocd","name":"var-files"},
          {"mountPath":"/home/argocd/cmp-server/config","name":"sops-age-kustomize-config"},
          {"mountPath":"/home/argocd/cmp-server/plugins","name":"plugins"},
          {"mountPath":"/tmp","name":"cmp-tmp-sops"},
          {"mountPath":"/sops","name":"sops-age-key"}
        ]
      }},
      {"op":"add","path":"/spec/repo/volumes/-","value":{"name":"sops-age-kustomize-config","configMap":{"name":"argocd-sops-age-kustomize","items":[{"key":"plugin.yaml","mode":509,"path":"plugin.yaml"}]}}},
      {"op":"add","path":"/spec/repo/volumes/-","value":{"name":"cmp-tmp-sops","emptyDir":{}}},
      {"op":"add","path":"/spec/repo/volumes/-","value":{"name":"sops-age-key","secret":{"secretName":"sops-age-key"}}}
    ]'
    echo "  Waiting for repo-server rollout..."
    oc rollout status deployment/"${ARGOCD_NAME}"-repo-server -n "${ARGOCD_NS}" --timeout=120s 2>/dev/null || true
  else
    echo "  sops-age-kustomize sidecar already configured"
  fi
else
  echo "WARNING: No ArgoCD CR found in ${ARGOCD_NS} — sops plugin not configured"
fi

# 5. Tenant ArgoCD (optional)
#    (Kept separate from sops setup — runs only when --tenant-argocd is passed)
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

# 6. Auto-detect cluster domain and update values
echo "--- Configuring cluster values ---"
APPS_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.example.com")
echo "  APPS_DOMAIN=${APPS_DOMAIN}"
sed -i "s|^appsDomain:.*|appsDomain: ${APPS_DOMAIN}|" "${REPO_DIR}/app-of-apps/values.yaml"
sed -i "s|^namespace:.*|namespace: ${NAMESPACE}|" "${REPO_DIR}/app-of-apps/values.yaml"
sed -i "s|^gitRepo:.*|gitRepo: ${GIT_REPO}|" "${REPO_DIR}/app-of-apps/values.yaml"
sed -i "s|^gitRevision:.*|gitRevision: ${GIT_BRANCH}|" "${REPO_DIR}/app-of-apps/values.yaml"

# 7. Apply app-of-apps
echo "--- Deploying app-of-apps ---"
sed -e "s|namespace: openshift-gitops|namespace: ${ARGOCD_NS}|" \
    -e "s|namespace: openshell|namespace: ${NAMESPACE}|" \
    -e "s|repoURL: .*data-agent-ctf.*|repoURL: ${GIT_REPO}|" \
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
