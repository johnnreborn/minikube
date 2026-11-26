# Online Boutique Platform Lab — see CLAUDE.md for the workflow, docs/SPEC.md for acceptance criteria.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
export PATH := $(HOME)/.local/bin:$(PATH)

include versions.env
-include .env

.PHONY: help preflight cluster-up cni gitops-bootstrap up wait-sync verify-phase verify-all lint hosts down

help: ## list targets
	@grep -h -E '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

preflight: ## host/tool/resource checks (Phase 0)
	@bash bootstrap/scripts/preflight.sh

cluster-up: ## docker network + kind cluster (Phase 1)
	@test -x bootstrap/scripts/cluster-up.sh || { echo "cluster-up: not implemented before Phase 1" >&2; exit 1; }
	@bash bootstrap/scripts/cluster-up.sh

cni: ## Gateway API CRDs -> Cilium bootstrap (Phase 2)
	@test -x bootstrap/scripts/cni.sh || { echo "cni: not implemented before Phase 2" >&2; exit 1; }
	@bash bootstrap/scripts/cni.sh
	@bash bootstrap/scripts/coredns-spread.sh

gitops-bootstrap: ## Argo CD + repo secret + root app (Phase 3)
	@test -x bootstrap/scripts/gitops-bootstrap.sh || { echo "gitops-bootstrap: not implemented before Phase 3" >&2; exit 1; }
	@bash bootstrap/scripts/gitops-bootstrap.sh

up: cluster-up cni gitops-bootstrap ## all bootstrap stages in order (idempotent)

wait-sync: ## wait until every Argo CD Application is Synced/Healthy (Phase 3)
	@test -x bootstrap/scripts/wait-sync.sh || { echo "wait-sync: not implemented before Phase 3" >&2; exit 1; }
	@bash bootstrap/scripts/wait-sync.sh

verify-phase: ## run AC checks for one phase: make verify-phase N=5
	@test -n "$(N)" || { echo "usage: make verify-phase N=<phase>" >&2; exit 2; }
	@bash scripts/verify-phase.sh "$(N)"

verify-all: ## AC checks for phases 1..9 in order (DESTRUCTIVE=1 enables fault-injection tests)
	@fail=0; for n in 1 2 3 4 5 6 7 8 9; do \
	  echo "=== phase $$n ==="; bash scripts/verify-phase.sh $$n || fail=1; \
	done; exit $$fail

lint: ## yamllint, kustomize, helm template, kubeconform, version consistency, secret scan
	@bash scripts/lint.sh

hosts: ## print /etc/hosts lines (does not modify the file)
	@echo "172.30.250.10 shop.boutique.test argocd.boutique.test grafana.boutique.test hubble.boutique.test"

down: ## delete cluster + docker network (only on explicit user request)
	@test -x bootstrap/scripts/down.sh || { echo "down: not implemented before Phase 1" >&2; exit 1; }
	@bash bootstrap/scripts/down.sh
