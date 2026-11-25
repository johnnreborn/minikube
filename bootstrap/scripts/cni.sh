#!/usr/bin/env bash
# Phase 2: Gateway API CRDs -> Cilium (helm), idempotent. `make cni`
#   1. Gateway API CRDs (platform/gateway-api-crds) server-side apply, wait until Established.
#      They must exist BEFORE Cilium starts (ARCHITECTURE §15-3); if Cilium was already running without them,
#      cilium-operator is restarted so it picks them up.
#   2. helm upgrade --install cilium with platform/cilium/values.yaml (same file Argo CD uses from Phase 3).
#      Feature layers (values-monitoring.yaml, Phase 7) are NOT used here: their CRDs do not exist yet.
#   3. cilium status --wait, nodes Ready.
# From Phase 3 on, Argo CD owns Cilium (manual sync). This script then refuses to touch it (CLAUDE.md).
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd kubectl helm kustomize cilium

CONTEXT=kind-boutique
NAMESPACE=kube-system
RELEASE=cilium
CRD_DIR="$REPO_ROOT/platform/gateway-api-crds"
VALUES="$REPO_ROOT/platform/cilium/values.yaml"
k() { kubectl --context "$CONTEXT" "$@"; }

[[ -f "$VALUES" ]] || die "missing $VALUES"
k get nodes >/dev/null 2>&1 || die "cluster context $CONTEXT not reachable (run: make cluster-up)"

# --- guard: Argo CD already manages Cilium ------------------------------------------------------------------
# capture first: `cmd | grep -q` under pipefail can fail with SIGPIPE
crds=$(k get crd -o name 2>/dev/null || true)
if grep -qx 'customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io' <<<"$crds"; then
  if k -n argocd get application cilium >/dev/null 2>&1; then
    ok "Argo CD manages Cilium (Application 'cilium') - nothing to do here. Sync it through Argo CD (CLAUDE.md)."
    exit 0
  fi
fi

# --- 1. Gateway API CRDs ------------------------------------------------------------------------------------
gw_crd_existed=false
grep -qx 'customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io' <<<"$crds" && gw_crd_existed=true

log "Gateway API CRDs ${GATEWAY_API_VERSION} (${GATEWAY_API_CHANNEL})"
kustomize build "$CRD_DIR" | k apply --server-side --field-manager=bootstrap -f - >/dev/null
gw_crds=$(k get crd -o name | grep 'gateway\.networking\.k8s\.io$' || true)
[[ -n "$gw_crds" ]] || die "Gateway API CRDs not found after apply"
# shellcheck disable=SC2086
k wait --for=condition=Established --timeout=60s $gw_crds >/dev/null
ok "Gateway API CRDs established ($(wc -l <<<"$gw_crds") CRDs)"

# --- 2. Cilium ----------------------------------------------------------------------------------------------
release_existed=false
releases=$(helm --kube-context "$CONTEXT" -n "$NAMESPACE" list -q 2>/dev/null || true)
grep -qx "$RELEASE" <<<"$releases" && release_existed=true

log "helm upgrade --install $RELEASE (chart ${CILIUM_CHART_VERSION}, values platform/cilium/values.yaml)"
start=$SECONDS
helm upgrade --install "$RELEASE" cilium \
  --repo "$CILIUM_CHART_REPO" --version "$CILIUM_CHART_VERSION" \
  --kube-context "$CONTEXT" --namespace "$NAMESPACE" \
  -f "$VALUES" --wait --timeout 10m
ok "helm release deployed in $((SECONDS - start))s"

if [[ $release_existed == true && $gw_crd_existed == false ]]; then
  warn "Gateway API CRDs were installed after Cilium -> restarting cilium-operator"
  k -n "$NAMESPACE" rollout restart deploy/cilium-operator
  k -n "$NAMESPACE" rollout status deploy/cilium-operator --timeout=5m
fi

# --- 3. wait for readiness ----------------------------------------------------------------------------------
log "cilium status --wait"
cilium --context "$CONTEXT" -n "$NAMESPACE" status --wait --wait-duration 8m --interactive=false
log "waiting for all nodes Ready"
k wait --for=condition=Ready nodes --all --timeout=5m
ok "Cilium is up; nodes Ready ($((SECONDS - start))s after helm started)"
