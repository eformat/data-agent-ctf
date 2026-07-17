.PHONY: help bootstrap test validate encrypt decrypt clean build-all build-gateway build-deployer build-hermes build-mcp deploy-sandboxes
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

NAMESPACE ?= openshell
OPENSHELL_SRC ?= $(HOME)/git/OpenShell
MCP_SRC ?= $(HOME)/git/data-agent-template
REGISTRY ?= quay.io/eformat

BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)

bootstrap: ## Deploy everything to cluster (one command)
	./scripts/bootstrap.sh --namespace $(NAMESPACE) --branch $(BRANCH)

bootstrap-gpu: ## Deploy with GPU node toleration
	./scripts/bootstrap.sh --namespace $(NAMESPACE) --tolerate-gpu

bootstrap-tenant: ## Deploy with tenant ArgoCD
	./scripts/bootstrap.sh --namespace $(NAMESPACE) --tenant-argocd

test: ## Run end-to-end MCP pipeline tests
	python3 scripts/test-e2e-mcp.py

test-legacy: ## Run legacy CTF validation (bash)
	./scripts/test-ctf.sh --namespace $(NAMESPACE)

validate: ## Validate kustomize builds for all applications
	@for app in applications/*/; do \
		echo "=== $$app ==="; \
		kustomize build "$$app" >/dev/null 2>&1 && echo "  OK" || echo "  FAILED"; \
	done

encrypt: ## Encrypt all secret files with sops
	@for f in $$(find . -name "*.enc.yaml" -not -path "./.git/*"); do \
		sops --encrypt --in-place "$$f" 2>/dev/null && echo "  encrypted $$f" || echo "  skipped $$f"; \
	done

decrypt: ## Decrypt all secret files with sops
	@for f in $$(find . -name "*.enc.yaml" -not -path "./.git/*"); do \
		sops --decrypt --in-place "$$f" 2>/dev/null && echo "  decrypted $$f" || echo "  skipped $$f"; \
	done

clean: ## Delete the namespace and all resources
	oc delete project $(NAMESPACE) --ignore-not-found
	oc delete application -n openshift-gitops -l app.kubernetes.io/part-of=retail-ctf --ignore-not-found

## ── Image Builds ──────────────────────────────────────────────

build-all: build-gateway build-deployer build-hermes build-mcp ## Build and push all images

build-gateway: ## Build + push openshell-gateway (requires $(OPENSHELL_SRC))
	cd $(OPENSHELL_SRC) && cargo build --release -p openshell-server
	cp $(OPENSHELL_SRC)/target/release/openshell-gateway /tmp/openshell-gateway
	cp /lib64/libz3.so.4.15 /tmp/libz3.so.4.15 2>/dev/null || cp /usr/lib64/libz3.so.4.15 /tmp/libz3.so.4.15
	cp /lib64/libgmp.so.10 /tmp/libgmp.so.10 2>/dev/null || cp /usr/lib64/libgmp.so.10 /tmp/libgmp.so.10
	printf 'FROM gcr.io/distroless/cc-debian13:latest\nWORKDIR /app\nCOPY openshell-gateway /usr/local/bin/openshell-gateway\nCOPY libz3.so.4.15 /usr/lib/x86_64-linux-gnu/libz3.so.4.15\nCOPY libgmp.so.10 /usr/lib/x86_64-linux-gnu/libgmp.so.10\nUSER 1000:1000\nEXPOSE 8080\nENTRYPOINT ["/usr/local/bin/openshell-gateway"]\nCMD ["--bind-address", "0.0.0.0:8080"]\n' > /tmp/Containerfile.gateway
	podman build -t $(REGISTRY)/openshell-gateway:v0.0.85 -f /tmp/Containerfile.gateway /tmp/
	podman push $(REGISTRY)/openshell-gateway:v0.0.85

build-deployer: ## Build + push openshell-deployer (requires $(OPENSHELL_SRC))
	cd $(OPENSHELL_SRC) && cargo build --release -p openshell-cli
	cp $(OPENSHELL_SRC)/target/release/openshell /tmp/openshell
	cp /lib64/libz3.so.4.15 /tmp/libz3.so.4.15 2>/dev/null || true
	cp /lib64/libgmp.so.10 /tmp/libgmp.so.10 2>/dev/null || true
	podman build -t $(REGISTRY)/openshell-deployer:latest -t $(REGISTRY)/openshell-deployer:v0.0.85 -f scripts/Containerfile.openshell-deployer /tmp/
	podman push $(REGISTRY)/openshell-deployer:latest
	podman push $(REGISTRY)/openshell-deployer:v0.0.85

build-hermes: ## Build + push hermes-openshell sandbox image
	podman build -t $(REGISTRY)/hermes-openshell:latest -t $(REGISTRY)/hermes-openshell:0.17.0 -f scripts/Containerfile.hermes-sandbox .
	podman push $(REGISTRY)/hermes-openshell:latest
	podman push $(REGISTRY)/hermes-openshell:0.17.0

build-mcp: ## Build + push retail-mcp-server (requires $(MCP_SRC))
	podman build -t $(REGISTRY)/retail-mcp-server:latest -f scripts/Containerfile.retail-mcp-server $(MCP_SRC)
	podman push $(REGISTRY)/retail-mcp-server:latest

GATEWAY ?= prelude2

deploy-sandboxes: ## Delete and recreate all sandboxes
	@for name in retail-finance retail-sales retail-ops; do \
		openshell sandbox delete $$name -g $(GATEWAY) 2>/dev/null || true; \
	done
	@oc get sandbox -n $(NAMESPACE) -o name --no-headers 2>/dev/null | grep -v hermes-agents | xargs -r oc delete -n $(NAMESPACE) 2>/dev/null || true
	@oc delete sandboxclaim --all -n $(NAMESPACE) 2>/dev/null || true
	@oc delete job retail-sandbox-deploy -n $(NAMESPACE) --force --grace-period=0 2>/dev/null || true
	@oc delete pod -n $(NAMESPACE) -l job-name=retail-sandbox-deploy --force --grace-period=0 2>/dev/null || true
	@sleep 3
	@helm template retail-sandboxes applications/retail-sandboxes/ \
		--set appsDomain=$$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}') \
		--set namespace=$(NAMESPACE) \
		--set realmName=retail-ctf \
		--set inference.host=$$(grep 'host:' app-of-apps/values.yaml | head -1 | awk '{print $$2}') \
		--set inference.path=$$(grep 'path:' app-of-apps/values.yaml | head -1 | awk '{print $$2}') \
		--show-only templates/sandbox-job.yaml | oc apply -n $(NAMESPACE) -f -
	@echo "Sandbox deploy triggered — watch with: oc logs -n $(NAMESPACE) -f job/retail-sandbox-deploy"

## ── Cluster Operations ───────────────────────────────────────

status: ## Show deployment status
	@echo "=== ArgoCD Applications ==="
	@oc get applications -n openshift-gitops 2>/dev/null | grep retail-ctf || echo "  none"
	@echo ""
	@echo "=== Pods ==="
	@oc get pods -n $(NAMESPACE) --no-headers 2>/dev/null | head -20 || echo "  none"
	@echo ""
	@echo "=== Sandboxes ==="
	@openshell sandbox list -g $(GATEWAY) 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "  none"
