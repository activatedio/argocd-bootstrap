# ---------------------------------------------------------------------------
# argocd-bootstrap — GitOps template for bootstrapping & self-managing Argo CD
#
# Quick start:
#   make install GIT_REPO=https://github.com/you/your-gitops-repo \
#                GIT_TOKEN=ghp_xxx \
#                ARGOCD_VERSION=v3.2.12
#   git commit -am "bootstrap argo-cd" && git push   # publish rendered manifests
# ---------------------------------------------------------------------------

ARGOCD_NS        ?= argocd
GIT_USERNAME     ?= git
ARGOCD_VERSION   ?= v3.2.12
REPO_SECRET_NAME ?= argocd-bootstrap-repo

# Manifest files that carry the __GIT_REPO_URL__ / __ARGOCD_VERSION__ placeholders.
MANIFESTS := bootstrap/argo-cd.yaml bootstrap/root.yaml projects/default.yaml \
             bootstrap/argo-cd/kustomization.yaml

.PHONY: help install manifests repo-secret apply wait-ready bootstrap \
        diff status password port-forward uninstall check-render

help:
	@echo "Targets:"
	@echo "  install       Render manifests + install Argo CD + bootstrap self-management"
	@echo "  manifests     Substitute GIT_REPO / ARGOCD_VERSION into the manifests in place"
	@echo "  bootstrap     Re-apply the install and hand management to Argo CD (idempotent)"
	@echo "  diff          Show what 'make bootstrap' would change"
	@echo "  status        List Applications and ApplicationSets"
	@echo "  password      Print the initial admin password"
	@echo "  port-forward  Forward the Argo CD UI to https://localhost:8080"
	@echo "  uninstall     Remove Applications then the Argo CD install"
	@echo ""
	@echo "Required for install: GIT_REPO, GIT_TOKEN, ARGOCD_VERSION"

# --- Full install ----------------------------------------------------------
# 1. bake the repo URL + version into the manifests
# 2. create the namespace and the repo-access secret
# 3. server-side apply the Argo CD install and wait for it
# 4. apply the bootstrap (root + self-managing argo-cd Applications)
install: manifests repo-secret apply wait-ready bootstrap
	@echo ""
	@echo "✓ Argo CD installed and self-management bootstrapped."
	@echo "  Commit and push the rendered manifests so Argo CD can read them:"
	@echo "      git commit -am 'bootstrap argo-cd' && git push"
	@echo "  Then:  make password   &&   make port-forward"

# --- Render placeholders into the working tree -----------------------------
# Idempotent: once a placeholder is replaced it is gone, so re-running is a no-op.
manifests:
ifndef GIT_REPO
	$(error GIT_REPO is required, e.g. GIT_REPO=https://github.com/you/your-gitops-repo)
endif
	@echo "→ Rendering manifests (repo=$(GIT_REPO), version=$(ARGOCD_VERSION))"
	@perl -pi -e 's{__GIT_REPO_URL__}{$(GIT_REPO)}g; s{__ARGOCD_VERSION__}{$(ARGOCD_VERSION)}g' $(MANIFESTS)
	@$(MAKE) --no-print-directory check-render

# Fail loudly if any placeholder survived (e.g. a new file forgot the substitution).
check-render:
	@if grep -rl '__GIT_REPO_URL__\|__ARGOCD_VERSION__' $(MANIFESTS) >/dev/null 2>&1; then \
		echo "✗ Unrendered placeholders remain:"; \
		grep -rn '__GIT_REPO_URL__\|__ARGOCD_VERSION__' $(MANIFESTS); \
		exit 1; \
	fi

# --- Repo-access secret (so Argo CD can pull a private repo) ----------------
repo-secret:
ifndef GIT_REPO
	$(error GIT_REPO is required)
endif
ifndef GIT_TOKEN
	$(error GIT_TOKEN is required, e.g. GIT_TOKEN=ghp_xxx)
endif
	@kubectl get namespace $(ARGOCD_NS) >/dev/null 2>&1 || kubectl create namespace $(ARGOCD_NS)
	@kubectl -n $(ARGOCD_NS) create secret generic $(REPO_SECRET_NAME) \
		--from-literal=type=git \
		--from-literal=url=$(GIT_REPO) \
		--from-literal=username=$(GIT_USERNAME) \
		--from-literal=password=$(GIT_TOKEN) \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n $(ARGOCD_NS) label secret $(REPO_SECRET_NAME) \
		argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

# --- Phase 1: install Argo CD (CRDs + control plane) ------------------------
# Server-side apply: client-side fails on Argo CD's CRDs because the
# last-applied-configuration annotation exceeds 262144 bytes.
apply:
	kubectl apply -k bootstrap/argo-cd --server-side --force-conflicts

# Wait for the core control-plane components to become ready.
wait-ready:
	kubectl -n $(ARGOCD_NS) wait --for=condition=Available --timeout=300s deployment/argocd-server
	kubectl -n $(ARGOCD_NS) wait --for=condition=Available --timeout=300s deployment/argocd-repo-server
	kubectl -n $(ARGOCD_NS) wait --for=condition=Available --timeout=300s deployment/argocd-applicationset-controller
	kubectl -n $(ARGOCD_NS) rollout status statefulset/argocd-application-controller --timeout=300s

# --- Phase 2: hand management to Argo CD ------------------------------------
# Applies the root Application (manages projects/) and the self-managing
# argo-cd Application. The CRDs they reference exist after `apply` + `wait-ready`.
bootstrap:
	kubectl apply -f bootstrap/argo-cd.yaml -f bootstrap/root.yaml --server-side --force-conflicts

# Show what 'make bootstrap' would change without applying.
diff:
	kubectl diff -f bootstrap/argo-cd.yaml -f bootstrap/root.yaml || true

# --- Day-2 conveniences -----------------------------------------------------
status:
	kubectl -n $(ARGOCD_NS) get applications,applicationsets

password:
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

port-forward:
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server 8080:443

# Tear down everything (Applications first so finalizers run, then the install).
uninstall:
	-kubectl -n $(ARGOCD_NS) delete applicationset --all
	-kubectl -n $(ARGOCD_NS) delete application --all
	-kubectl delete -k bootstrap/argo-cd --ignore-not-found
	-kubectl -n $(ARGOCD_NS) delete secret $(REPO_SECRET_NAME) --ignore-not-found
