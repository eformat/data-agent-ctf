.PHONY: bootstrap test validate encrypt decrypt clean

NAMESPACE ?= data-agent-ctf

bootstrap: ## Deploy everything to cluster (one command)
	./scripts/bootstrap.sh --namespace $(NAMESPACE)

bootstrap-gpu: ## Deploy with GPU node toleration
	./scripts/bootstrap.sh --namespace $(NAMESPACE) --tolerate-gpu

bootstrap-tenant: ## Deploy with tenant ArgoCD
	./scripts/bootstrap.sh --namespace $(NAMESPACE) --tenant-argocd

test: ## Run end-to-end CTF validation
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

status: ## Show deployment status
	@echo "=== ArgoCD Applications ==="
	@oc get applications -n openshift-gitops 2>/dev/null | grep retail-ctf || echo "  none"
	@echo ""
	@echo "=== Pods ==="
	@oc get pods -n $(NAMESPACE) --no-headers 2>/dev/null | head -20 || echo "  none"
	@echo ""
	@echo "=== Sandboxes ==="
	@openshell sandbox list -g $${OPENSHELL_GATEWAY:-prelude2-final} 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "  none"
