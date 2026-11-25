#!/usr/bin/env bash
# Version consistency checks (CLAUDE.md "핵심 규칙", NFR-03, AC-0.2).
#   scripts/check-versions.sh            full check (used by `make lint`)
#   scripts/check-versions.sh --env-only only versions.env content checks (used by AC-0.2)
# Fails on: missing keys, `latest`, range versions, kind image without @sha256 digest, and
# drift between versions.env and Application targetRevision / repoURL / kind config / hardcoded versions.
set -uo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/scripts/lib.sh"
cd "$REPO_ROOT"
MODE=${1:-full}

FAILS=0
bad() { err "$*"; FAILS=$((FAILS + 1)); }

# every item of SPEC §5.1 (plus the repo URLs they come from)
REQUIRED_KEYS=(
  KIND_VERSION KUBECTL_VERSION HELM_VERSION KUSTOMIZE_VERSION YQ_VERSION KUBECONFORM_VERSION GITLEAKS_VERSION
  CILIUM_CLI_VERSION HUBBLE_CLI_VERSION
  KIND_NODE_VERSION KIND_NODE_IMAGE
  CILIUM_CHART_REPO CILIUM_CHART_VERSION GATEWAY_API_VERSION GATEWAY_API_CHANNEL
  ARGOCD_CHART_REPO ARGOCD_CHART_VERSION ARGOCD_VERSION
  CERT_MANAGER_CHART_REPO CERT_MANAGER_VERSION
  PROMETHEUS_CHART_REPO PROMETHEUS_OPERATOR_CRDS_CHART_VERSION KUBE_PROMETHEUS_STACK_CHART_VERSION
  GRAFANA_COMMUNITY_CHART_REPO LOKI_CHART_VERSION LOKI_VERSION TEMPO_CHART_VERSION TEMPO_VERSION
  GRAFANA_CHART_REPO ALLOY_CHART_VERSION ALLOY_VERSION
  OTEL_CHART_REPO OTEL_COLLECTOR_CHART_VERSION OTEL_COLLECTOR_IMAGE
  BOUTIQUE_VERSION BOUTIQUE_IMAGE_REGISTRY REDIS_IMAGE CURL_IMAGE NETSHOOT_IMAGE
)

# parse versions.env without sourcing (so a typo cannot execute anything)
declare -A V
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
  if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then V[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  else bad "versions.env: unparsable line: $line"; fi
done < versions.env

for k in "${REQUIRED_KEYS[@]}"; do
  [[ -n "${V[$k]:-}" ]] || bad "versions.env: missing or empty $k"
done

for k in "${!V[@]}"; do
  v=${V[$k]}
  [[ "$v" =~ (^|[:/@=-])latest($|[^a-zA-Z]) ]] && bad "versions.env: $k uses 'latest' ($v)"
  if [[ "$k" == *VERSION* && "$k" != *CHART_REPO* ]]; then
    [[ "$v" == *[~*^]* || "$v" =~ (^|[.-])[xX]($|[.-]) || "$v" == [\>\<=]* ]] && bad "versions.env: $k is a range ($v)"
    [[ "$v" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || bad "versions.env: $k is not an exact x.y.z version ($v)"
  fi
done
for k in KIND_NODE_IMAGE REDIS_IMAGE CURL_IMAGE NETSHOOT_IMAGE OTEL_COLLECTOR_IMAGE; do
  v=${V[$k]:-}; [[ "$v" == *:* ]] || bad "versions.env: $k needs an explicit tag ($v)"
done
[[ "${V[KIND_NODE_IMAGE]:-}" =~ ^kindest/node:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] \
  || bad "versions.env: KIND_NODE_IMAGE must be kindest/node:vX.Y.Z@sha256:<64 hex>"
[[ "${V[KIND_NODE_IMAGE]:-}" == "kindest/node:${V[KIND_NODE_VERSION]:-}@"* ]] \
  || bad "versions.env: KIND_NODE_IMAGE tag does not match KIND_NODE_VERSION"
[[ "${V[GATEWAY_API_CHANNEL]:-}" =~ ^(standard|experimental)$ ]] || bad "versions.env: GATEWAY_API_CHANNEL must be standard|experimental"

if [[ "$MODE" == "--env-only" ]]; then
  (( FAILS == 0 )) && ok "versions.env OK (${#REQUIRED_KEYS[@]} keys)"
  exit $(( FAILS > 0 ))
fi

# ---- repo-wide: floating tags / ranges in manifests ------------------------------------------
shopt -s nullglob globstar
scan_files=()
for f in gitops/**/*.yaml platform/**/*.yaml observability/**/*.yaml apps/**/*.yaml bootstrap/**/*.yaml; do
  [[ "$f" == apps/online-boutique/upstream/* ]] && continue
  scan_files+=("$f")
done
for f in "${scan_files[@]}"; do
  if grep -n -E '^\s*(-\s*)?image:\s*\S+:latest(\s|$)|^\s*(-\s*)?image:\s*[^:@\s]+\s*$' "$f" >/dev/null 2>&1; then
    bad "$f: image without tag or with :latest → $(grep -n -E 'image:' "$f" | head -3 | tr '\n' ' ')"
  fi
  if grep -n -E 'targetRevision:\s*["'\'']?([\^~]|[0-9.]*[xX*]|latest|>|<)' "$f" >/dev/null 2>&1; then
    bad "$f: targetRevision is a range or 'latest'"
  fi
done

# ---- Application targetRevision / repoURL vs versions.env ------------------------------------
declare -A CHART_VER=(
  [cilium]=CILIUM_CHART_VERSION [argo-cd]=ARGOCD_CHART_VERSION [cert-manager]=CERT_MANAGER_VERSION
  [prometheus-operator-crds]=PROMETHEUS_OPERATOR_CRDS_CHART_VERSION [kube-prometheus-stack]=KUBE_PROMETHEUS_STACK_CHART_VERSION
  [loki]=LOKI_CHART_VERSION [tempo]=TEMPO_CHART_VERSION [alloy]=ALLOY_CHART_VERSION
  [opentelemetry-collector]=OTEL_COLLECTOR_CHART_VERSION
)
declare -A CHART_REPO=(
  [cilium]=CILIUM_CHART_REPO [argo-cd]=ARGOCD_CHART_REPO [cert-manager]=CERT_MANAGER_CHART_REPO
  [prometheus-operator-crds]=PROMETHEUS_CHART_REPO [kube-prometheus-stack]=PROMETHEUS_CHART_REPO
  [loki]=GRAFANA_COMMUNITY_CHART_REPO [tempo]=GRAFANA_COMMUNITY_CHART_REPO [alloy]=GRAFANA_CHART_REPO
  [opentelemetry-collector]=OTEL_CHART_REPO
)
if have yq; then
  for f in gitops/**/*.yaml gitops/root.yaml; do
    [[ -f "$f" ]] || continue
    [[ "$(yq '.kind' "$f" 2>/dev/null | head -1)" == "Application" ]] || continue
    while IFS=$'\t' read -r chart rev repo; do
      [[ -n "$chart" && "$chart" != null ]] || continue
      var=${CHART_VER[$chart]:-}; rvar=${CHART_REPO[$chart]:-}
      if [[ -z "$var" ]]; then bad "$f: chart '$chart' has no entry in scripts/check-versions.sh"; continue; fi
      [[ "$rev" == "${V[$var]:-}" ]] || bad "$f: $chart targetRevision '$rev' != versions.env $var '${V[$var]:-}'"
      [[ "$repo" == "${V[$rvar]:-}" ]] || bad "$f: $chart repoURL '$repo' != versions.env $rvar '${V[$rvar]:-}'"
    done < <(yq -r '(.spec.sources // [.spec.source])[] | select(.chart != null) | [.chart, .targetRevision, .repoURL] | @tsv' "$f" 2>/dev/null)
  done
else
  bad "yq not installed: cannot compare Application targetRevision"
fi

# ---- kind config & bootstrap scripts ---------------------------------------------------------
if [[ -f bootstrap/kind/cluster.yaml ]]; then
  while IFS= read -r img; do
    [[ "$img" == "${V[KIND_NODE_IMAGE]:-}" ]] || bad "bootstrap/kind/cluster.yaml: node image '$img' != versions.env KIND_NODE_IMAGE"
  done < <(grep -E '^\s*image:' bootstrap/kind/cluster.yaml | awk '{print $2}')
fi
for f in bootstrap/scripts/*.sh Makefile tests/*.sh; do
  [[ -f "$f" ]] || continue
  # versions must come from versions.env, not be typed into scripts
  if grep -n -E -- '--version[= ]+v?[0-9]+\.[0-9]+\.[0-9]+|kindest/node:v[0-9]|releases/download/v[0-9]+\.[0-9]+' "$f" | grep -v '^\s*#' >/dev/null; then
    bad "$f: hardcoded tool/chart version (use versions.env): $(grep -n -E -- '--version[= ]+v?[0-9]+\.[0-9]+\.[0-9]+|kindest/node:v[0-9]|releases/download/v[0-9]+\.[0-9]+' "$f" | head -2 | tr '\n' ' ')"
  fi
done

if (( FAILS == 0 )); then ok "version consistency OK"; exit 0; fi
err "version consistency: $FAILS problem(s)"; exit 1
