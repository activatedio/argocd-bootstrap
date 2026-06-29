# ---------------------------------------------------------------------------
# argocd-bootstrap — GitOps template for bootstrapping & self-managing Argo CD
#
# Quick start (render first, push, THEN install — so Argo CD comes up in sync):
#   make init    GIT_REPO=https://github.com/you/your-gitops-repo ARGOCD_VERSION=v3.2.12
#   git commit -am "init gitops repo" && git push    # publish the rendered manifests
#   make install GIT_REPO=https://github.com/you/your-gitops-repo GIT_TOKEN=ghp_xxx
# ---------------------------------------------------------------------------

ARGOCD_NS        ?= argocd
GIT_USERNAME     ?= git
ARGOCD_VERSION   ?= v3.2.12
REPO_SECRET_NAME ?= argocd-bootstrap-repo

# Directories scanned for the __GIT_REPO_URL__ / __ARGOCD_VERSION__ placeholders.
# Rendering scans the whole tree, so files you add later (a new project or app)
# are picked up by re-running `make init`.
RENDER_DIRS := bootstrap projects roots cluster-resources
PLACEHOLDER := __GIT_REPO_URL__\|__ARGOCD_VERSION__

.PHONY: help init install manifests require-rendered repo-secret apply \
        wait-ready bootstrap diff status password port-forward uninstall check-render

help:
	@echo "Targets:"
	@echo "  init          Render GIT_REPO / ARGOCD_VERSION into the manifests (then commit & push)"
	@echo "  install       Install Argo CD + bootstrap self-management from the already-rendered repo"
	@echo "  manifests     Low-level render used by 'init': substitute the placeholders in place"
	@echo "  bootstrap     Re-apply the install and hand management to Argo CD (idempotent)"
	@echo "  diff          Show what 'make bootstrap' would change"
	@echo "  status        List Applications and ApplicationSets"
	@echo "  password      Print the initial admin password"
	@echo "  port-forward  Forward the Argo CD UI to https://localhost:8080"
	@echo "  uninstall     Remove Applications then the Argo CD install"
	@echo ""
	@echo "Workflow:"
	@echo "  make init    GIT_REPO=... ARGOCD_VERSION=...   # render the templates"
	@echo "  git commit -am 'init gitops repo' && git push  # publish them"
	@echo "  make install GIT_REPO=... GIT_TOKEN=...         # apply to the cluster"

# --- Step 1: render the templates into the working tree --------------------
# `init` only edits files — it touches nothing in the cluster. Commit and push
# the result BEFORE `make install`, so Argo CD reads back exactly what you
# applied and the very first reconcile is already in sync.
init: manifests
	@echo ""
	@echo "✓ Templates rendered (repo=$(GIT_REPO), version=$(ARGOCD_VERSION))."
	@echo "  Commit and push, THEN install:"
	@echo "      git commit -am 'init gitops repo' && git push"
	@echo "      make install GIT_REPO=$(GIT_REPO) GIT_TOKEN=ghp_xxx"

# --- Step 2: install Argo CD from the already-rendered, pushed repo ---------
# Assumes `make init` has run and the rendered manifests are committed & pushed.
# This phase only creates the repo secret and applies resources to the cluster
# — it does not modify your working tree.
# 1. create the namespace and the repo-access secret
# 2. server-side apply the Argo CD install and wait for it
# 3. apply the bootstrap (root + self-managing argo-cd Applications)
install: require-rendered repo-secret apply wait-ready bootstrap
	@echo ""
	@echo "✓ Argo CD installed and self-management bootstrapped."
	@echo "  The repo was rendered and pushed first, so Argo CD comes up already in sync."
	@echo "  Next:  make password   &&   make port-forward"

# Refuse to install if the manifests still carry placeholders — that means
# `make init` (and the commit + push) hasn't happened yet.
require-rendered:
	@if grep -rl '$(PLACEHOLDER)' $(RENDER_DIRS) >/dev/null 2>&1; then \
		echo "✗ Manifests still contain placeholders — run 'make init' (then commit & push) first."; \
		grep -rn '$(PLACEHOLDER)' $(RENDER_DIRS); \
		exit 1; \
	fi

# --- Render placeholders into the working tree -----------------------------
# Scans the whole tree and substitutes in place. Idempotent: once a placeholder
# is replaced it is gone, so re-running (e.g. after adding a project or app) only
# renders the new files.
manifests:
ifndef GIT_REPO
	$(error GIT_REPO is required, e.g. GIT_REPO=https://github.com/you/your-gitops-repo)
endif
	@echo "→ Rendering manifests (repo=$(GIT_REPO), version=$(ARGOCD_VERSION))"
	@files=$$(grep -rl '$(PLACEHOLDER)' $(RENDER_DIRS) 2>/dev/null); \
	for f in $$files; do \
		perl -pi -e 's{__GIT_REPO_URL__}{$(GIT_REPO)}g; s{__ARGOCD_VERSION__}{$(ARGOCD_VERSION)}g' "$$f"; \
	done
	@$(MAKE) --no-print-directory check-render

# Fail loudly if any placeholder survived (e.g. a new file forgot the substitution).
check-render:
	@if grep -rl '$(PLACEHOLDER)' $(RENDER_DIRS) >/dev/null 2>&1; then \
		echo "✗ Unrendered placeholders remain:"; \
		grep -rn '$(PLACEHOLDER)' $(RENDER_DIRS); \
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
# Applies the self-managing argo-cd Application, the root Application (manages
# projects/), and the cluster-resources ApplicationSet. The CRDs they reference
# exist after `apply` + `wait-ready`.
BOOTSTRAP_MANIFESTS := -f bootstrap/argo-cd.yaml -f bootstrap/root.yaml -f bootstrap/cluster-resources.yaml

bootstrap:
	kubectl apply $(BOOTSTRAP_MANIFESTS) --server-side --force-conflicts

# Show what 'make bootstrap' would change without applying.
diff:
	kubectl diff $(BOOTSTRAP_MANIFESTS) || true

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
