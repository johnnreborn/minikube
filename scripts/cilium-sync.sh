#!/usr/bin/env bash
# Guarded manual sync of the Argo CD `cilium` Application (SPEC §5.3: Cilium is synced by hand after reviewing the diff).
#   scripts/cilium-sync.sh           show the diff only
#   scripts/cilium-sync.sh --yes     show the diff, then sync (never with prune)
# Refuses to sync while the app has comparison errors or marks any resource for pruning: when repo-server cannot
# render the chart (e.g. a helm pull timeout), Argo CD marks EVERY Cilium resource as requiring pruning and a pruning
# sync would delete the CNI (observed in Phase 7). Waits for the rollout and `cilium status` afterwards.
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/scripts/lib.sh"
load_env
require_cmd kubectl argocd jq cilium

CTX=kind-boutique
APP=cilium
k() { kubectl --context "$CTX" "$@"; }
KCFG=$(mktemp); chmod 600 "$KCFG"; trap 'rm -f "$KCFG"' EXIT
kubectl config view --minify --flatten --context "$CTX" >"$KCFG"
kubectl --kubeconfig "$KCFG" config set-context --current --namespace argocd >/dev/null
acd() { KUBECONFIG="$KCFG" argocd --core "$@"; }

# a fresh comparison without errors and nothing marked for pruning (retry: repo-server may be fetching the chart)
state=$(wait_app_comparable "$CTX" "$APP" 300) || die "cilium app not comparable - do NOT sync"
ok "comparison clean: sync=$state, no conditions, 0 resources marked for pruning"
[[ "$state" == OutOfSync ]] || { ok "nothing to sync"; exit 0; }

log "diff (server-side):"
acd app diff "$APP" --server-side-diff --exit-code=false || die "argocd app diff failed"
[[ "${1:-}" == "--yes" ]] || { log "review the diff above; run again with --yes to sync"; exit 0; }

log "argocd app sync $APP (no prune)"
acd app sync "$APP" --timeout 600 >/dev/null
acd app wait "$APP" --sync --health --timeout 600 >/dev/null
k -n kube-system rollout status ds/cilium --timeout=10m
k -n kube-system rollout status ds/cilium-envoy --timeout=10m
k -n kube-system rollout status deploy/cilium-operator --timeout=10m
cilium --context "$CTX" status --wait --wait-duration 5m --interactive=false >/dev/null
ok "cilium synced and healthy"
