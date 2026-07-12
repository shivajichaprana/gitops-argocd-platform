# Makefile for the GitOps control plane.
#
# Convenience wrappers around the bootstrap, validation, and diff workflows.
# Run `make help` for the target list. Bootstrap and diff talk to whatever
# cluster the current kubeconfig context points at, so confirm your context
# before running them.

# ---- Configuration (override on the command line, e.g. `make diff NS=argocd`) --
ARGOCD_NS       ?= argocd
BOOTSTRAP_DIR   ?= bootstrap/argocd
ROOT_APP        ?= bootstrap/app-of-apps.yaml
KUBE_VERSION    ?= 1.30.0
ROLLOUT_TIMEOUT ?= 300s

# Directories containing a kustomization for build-based validation.
KUSTOMIZE_DIRS  := $(BOOTSTRAP_DIR) $(shell find apps tenants -name kustomization.yaml -exec dirname {} \; 2>/dev/null | sort -u)

# YAML files linted directly (Go-template placeholders excluded by .yamllint if present).
YAML_FILES      := $(shell find . -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path './.git/*' | sort)

.DEFAULT_GOAL := help

## help: Show this help.
.PHONY: help
help:
	@echo "gitops-argocd-platform — available targets:"
	@grep -E '^## [a-zA-Z0-9_-]+:' $(MAKEFILE_LIST) \
		| sed -E 's/^## ([a-zA-Z0-9_-]+): (.*)/  \1|\2/' \
		| awk -F'|' '{ printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }'

## tools: Verify required CLIs are installed.
.PHONY: tools
tools:
	@for t in kubectl kustomize kubeconform yamllint python3; do \
		command -v $$t >/dev/null 2>&1 && echo "  ok   $$t" || echo "  MISS $$t"; \
	done

## bootstrap: Install Argo CD and hand the cluster over to GitOps (one-time).
.PHONY: bootstrap
bootstrap:
	kubectl apply -k $(BOOTSTRAP_DIR)
	kubectl -n $(ARGOCD_NS) rollout status deployment/argocd-server --timeout=$(ROLLOUT_TIMEOUT)
	kubectl apply -f $(ROOT_APP)
	@echo "Bootstrap complete — Argo CD now reconciles appsets/ from Git."

## yamllint: Lint all YAML manifests.
.PHONY: yamllint
yamllint:
	yamllint $(YAML_FILES)

## build: Render every kustomize overlay (no cluster access needed).
.PHONY: build
build:
	@set -e; for d in $(KUSTOMIZE_DIRS); do \
		echo "==> kustomize build $$d"; \
		kustomize build "$$d" >/dev/null; \
	done
	@echo "All overlays build cleanly."

## kubeconform: Validate rendered manifests against Kubernetes schemas.
.PHONY: kubeconform
kubeconform:
	@set -e; for d in $(KUSTOMIZE_DIRS); do \
		echo "==> kubeconform $$d"; \
		kustomize build "$$d" | kubeconform -strict -ignore-missing-schemas -kubernetes-version $(KUBE_VERSION); \
	done

## policy: Run policy checks (sync waves + resource limits).
.PHONY: policy
policy:
	bash tests/policy-checks.sh

## validate: Full local validation (yamllint + build + kubeconform + policy).
.PHONY: validate
validate: yamllint build kubeconform policy
	@echo "Validation passed."

## diff: Server-side diff of the bootstrap overlay against the cluster.
.PHONY: diff
diff:
	kubectl diff -k $(BOOTSTRAP_DIR) || true

## admin-password: Print the initial Argo CD admin password (rotate after use).
.PHONY: admin-password
admin-password:
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

## clean: Remove local render artifacts.
.PHONY: clean
clean:
	@find . -name '*.rendered.yaml' -delete 2>/dev/null || true
	@echo "Clean."
