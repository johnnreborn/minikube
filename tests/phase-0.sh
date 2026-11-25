#!/usr/bin/env bash
# Phase 0 acceptance tests (SPEC §6.0). Output: [PASS|FAIL|SKIP] AC-0.n ...; exit 1 if a MUST fails.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

# AC-0.1 ---------------------------------------------------------------------------------------
ac_check AC-0.1 "make preflight exits 0" make --no-print-directory -s preflight

# AC-0.2 ---------------------------------------------------------------------------------------
ac_check AC-0.2 "versions.env has every SPEC §5.1 item; no latest/range; kind node image pinned by @sha256" \
  bash scripts/check-versions.sh --env-only

# AC-0.3 ---------------------------------------------------------------------------------------
# ARCHITECTURE §11: every directory must exist; files are required once their owning Phase has been
# reached (Phase-N files such as cluster.yaml or phase-N.sh are checked by Phase N, not created empty here).
check_structure() {
  local missing=() p
  local dirs=(
    .claude/commands docs docs/adr docs/runbooks
    bootstrap bootstrap/kind bootstrap/scripts
    gitops gitops/projects gitops/apps/platform gitops/apps/observability gitops/apps/apps
    platform platform/namespaces platform/gateway-api-crds platform/cilium-lb platform/pki platform/gateway
    platform/cilium platform/argocd platform/cert-manager
    platform/policies/boutique platform/policies/observability platform/policies/argocd
    observability observability/kube-prometheus-stack observability/loki observability/alloy observability/tempo
    observability/otel-collector observability/dashboards observability/rules
    apps apps/l4-test apps/online-boutique/upstream apps/online-boutique/overlays/lab apps/online-boutique/canary
    apps/online-boutique/routes scripts tests
  )
  local files=(
    CLAUDE.md ARCHITECTURE.md Makefile versions.env .env.example
    .claude/commands/phase.md .claude/commands/verify.md
    docs/SPEC.md docs/PROGRESS.md
    bootstrap/scripts/lib.sh bootstrap/scripts/preflight.sh
    tests/lib.sh tests/phase-0.sh
  )
  for p in "${dirs[@]}";  do [[ -d "$p" ]] || missing+=("dir:$p");  done
  for p in "${files[@]}"; do [[ -f "$p" ]] || missing+=("file:$p"); done
  ls docs/adr/0*.md >/dev/null 2>&1 || missing+=("docs/adr/0*.md")
  if (( ${#missing[@]} )); then printf 'missing: %s\n' "${missing[*]}"; return 1; fi
}
ac_check AC-0.3 "repository layout matches ARCHITECTURE §11 (dirs + Phase-0 files)" check_structure

# AC-0.4 ---------------------------------------------------------------------------------------
ac_check AC-0.4 "make lint passes on the current tree" make --no-print-directory -s lint

# AC-0.5 ---------------------------------------------------------------------------------------
check_images() {
  local arch; arch=$(host_arch)
  local svcs=(adservice cartservice checkoutservice currencyservice emailservice frontend loadgenerator
              paymentservice productcatalogservice recommendationservice shippingservice)
  local bad=() s archs repo tag
  for s in "${svcs[@]}"; do
    archs=$(image_archs "$BOUTIQUE_IMAGE_REGISTRY/$s" "$BOUTIQUE_VERSION" 2>&1) || { bad+=("$s: lookup failed ($archs)"); continue; }
    grep -qx "linux/$arch" <<<"$archs" || bad+=("$s: has [$(tr '\n' ' ' <<<"$archs")] but host needs linux/$arch")
  done
  repo=${REDIS_IMAGE%%:*}; tag=${REDIS_IMAGE#*:}
  archs=$(image_archs "$repo" "$tag" 2>&1) || bad+=("redis: lookup failed ($archs)")
  [[ -n "${archs:-}" ]] && ! grep -qx "linux/$arch" <<<"$archs" && bad+=("redis: has [$(tr '\n' ' ' <<<"$archs")]")
  if (( ${#bad[@]} )); then printf '%s\n' "${bad[@]}"; return 1; fi
}
ac_check AC-0.5 "Online Boutique $BOUTIQUE_VERSION (11 services) + redis images exist for linux/$(host_arch)" check_images

# AC-0.6 ---------------------------------------------------------------------------------------
check_git() {
  local p rc=0
  for p in .env kubeconfig tests/results/x.log tests/.cache/ca.crt ca.key; do
    git check-ignore -q "$p" || { echo "not ignored: $p"; rc=1; }
  done
  git check-ignore -q .env.example && { echo ".env.example must NOT be ignored"; rc=1; }
  local url; url=$(git remote get-url origin 2>/dev/null) || { echo "no 'origin' remote configured"; return 1; }
  [[ -n "$url" ]] || { echo "empty origin url"; rc=1; }
  if [[ -n "$(git status --porcelain)" ]]; then echo "working tree not clean:"; git status --short; rc=1; fi
  return $rc
}
ac_check AC-0.6 ".gitignore covers secret paths, origin remote set, working tree clean" check_git

ac_summary 0
