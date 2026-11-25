#!/usr/bin/env bash
# Phase 3: GitOps bootstrap (SPEC §6.3, ARCHITECTURE §10.1). Idempotent. `make gitops-bootstrap`
#   0. preconditions: cluster + Cilium up, .env complete, gitops/ manifests point at GITOPS_REPO_URL@GITOPS_REVISION,
#      and the manifests Argo CD will read are pushed (Argo CD reads the remote, not this working tree)
#   1. Argo CD via helm with platform/argocd/values.yaml - first install only; once the `argocd` Application exists,
#      Argo CD manages itself and helm is never run again
#   2. bootstrap exceptions (ARCHITECTURE §10.1): repo Secret, Grafana admin Secret - values from .env, never in Git
#   3. AppProjects (first time only; root manages them afterwards) and the root Application
#   4. wait until root and every child Application are Healthy
#   5. Cilium adoption (SPEC §5.3): pod snapshot -> diff must be tracking metadata only -> manual sync ->
#      pods must be unchanged (same UID, same restart count). Any other diff stops here for human review.
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd kubectl helm argocd jq yq git

CONTEXT=kind-boutique
ARGO_NS=argocd
CACHE_DIR="$REPO_ROOT/tests/.cache"           # gitignored; the Phase 3 test reads the adoption snapshot from here
SNAP_BEFORE="$CACHE_DIR/cilium-adoption-before.tsv"
SNAP_AFTER="$CACHE_DIR/cilium-adoption-after.tsv"
k() { kubectl --context "$CONTEXT" "$@"; }
cd "$REPO_ROOT"

# --- 0. preconditions -----------------------------------------------------------------------------------------
: "${GITOPS_REPO_URL:?set GITOPS_REPO_URL in .env (see .env.example)}"
: "${GITOPS_REVISION:?set GITOPS_REVISION in .env}"
: "${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}"
k get nodes >/dev/null 2>&1 || die "cluster context $CONTEXT not reachable (make cluster-up)"
k -n kube-system get ds cilium >/dev/null 2>&1 || die "Cilium is not installed (make cni)"

root_repo=$(yq -r '.spec.source.repoURL' gitops/root.yaml)
root_rev=$(yq -r '.spec.source.targetRevision' gitops/root.yaml)
[[ "$root_repo" == "$GITOPS_REPO_URL" && "$root_rev" == "$GITOPS_REVISION" ]] ||
  die "gitops/root.yaml points at $root_repo@$root_rev but .env says $GITOPS_REPO_URL@$GITOPS_REVISION (update the manifests: scripts/check-versions.sh keeps all of them consistent)"

git fetch -q origin "$GITOPS_REVISION" || die "git fetch origin $GITOPS_REVISION failed"
if ! git diff --quiet "origin/$GITOPS_REVISION" -- gitops platform observability apps; then
  git diff --stat "origin/$GITOPS_REVISION" -- gitops platform observability apps >&2
  die "manifests differ from origin/$GITOPS_REVISION (committed-but-unpushed or uncommitted). Argo CD reads the remote: commit and push first"
fi

# --- 1. Argo CD -------------------------------------------------------------------------------------------------
if k -n "$ARGO_NS" get application argocd >/dev/null 2>&1; then
  ok "Argo CD manages itself (Application 'argocd') - helm install skipped"
else
  log "helm upgrade --install argocd (chart ${ARGOCD_CHART_VERSION}, values platform/argocd/values.yaml)"
  helm upgrade --install argocd argo-cd \
    --repo "$ARGOCD_CHART_REPO" --version "$ARGOCD_CHART_VERSION" \
    --kube-context "$CONTEXT" --namespace "$ARGO_NS" --create-namespace \
    -f platform/argocd/values.yaml --wait=legacy --timeout 10m   # helm v4 "watcher" waits --timeout per non-Job hook (redis-secret-init: 4 x 10 min)
  ok "Argo CD installed"
fi

# --- 2. bootstrap-exception Secrets (values come from the environment, never from argv) ------------------------
log "repository Secret for $GITOPS_REPO_URL"
jq -n --arg ns "$ARGO_NS" '{
    apiVersion: "v1", kind: "Secret",
    metadata: {name: "repo-gitops", namespace: $ns, labels: {"argocd.argoproj.io/secret-type": "repository"}},
    stringData: ({type: "git", url: env.GITOPS_REPO_URL}
      + (if (env.GITHUB_TOKEN // "") != "" then {username: "git", password: env.GITHUB_TOKEN} else {} end))
  }' | k apply -f - >/dev/null
[[ -n "${GITHUB_TOKEN:-}" ]] && ok "repo Secret with token" || ok "repo Secret without credentials (public repository)"

k get ns observability >/dev/null 2>&1 || k create ns observability >/dev/null   # labels come from the namespaces app
jq -n '{
    apiVersion: "v1", kind: "Secret",
    metadata: {name: "grafana-admin", namespace: "observability"},
    stringData: {"admin-user": "admin", "admin-password": env.GRAFANA_ADMIN_PASSWORD}
  }' | k apply -f - >/dev/null
ok "observability/grafana-admin Secret"

# --- 3. AppProjects + root ----------------------------------------------------------------------------------------
# AppProjects are Git-managed by root after the first sync; re-applying them here would strip Argo CD's tracking
# annotation through the client-side 3-way merge, so they are only created when missing.
for p in platform apps; do
  if k -n "$ARGO_NS" get appproject "$p" >/dev/null 2>&1; then ok "AppProject $p exists (managed by root)"; else
    k apply -f "gitops/projects/$p.yaml" >/dev/null && ok "AppProject $p created"; fi
done
k apply -f gitops/root.yaml >/dev/null
ok "root Application applied"

# --- 4. wait for the tree -------------------------------------------------------------------------------------------
expected_apps=$(for f in gitops/apps/*/*.yaml; do yq -r 'select(.kind == "Application") | .metadata.name' "$f"; done | sort)
all_healthy() {
  local json; json=$(k -n "$ARGO_NS" get applications -o json) || return 1
  local name h s
  [[ "$(jq -r '.items[] | select(.metadata.name=="root") | .status.sync.status + "/" + .status.health.status' <<<"$json")" == "Synced/Healthy" ]] || return 1
  for name in $expected_apps; do
    h=$(jq -r --arg n "$name" '.items[] | select(.metadata.name==$n) | .status.health.status' <<<"$json")
    s=$(jq -r --arg n "$name" '.items[] | select(.metadata.name==$n) | .status.sync.status' <<<"$json")
    [[ "$h" == Healthy ]] || return 1
    [[ "$name" == cilium || "$s" == Synced ]] || return 1    # cilium is manual: OutOfSync until adopted below
  done
}
log "waiting for root and child Applications to become Healthy (up to 15 min)"
end=$((SECONDS + 900))
until all_healthy; do
  (( SECONDS < end )) || { k -n "$ARGO_NS" get applications >&2; die "Applications did not become Healthy in time"; }
  sleep 10
done
ok "root and child Applications Healthy"
k -n "$ARGO_NS" get applications

# --- 5. Cilium adoption -----------------------------------------------------------------------------------------------
cilium_pods() {  # name uid restartCount(sum over containers), sorted
  k -n kube-system get pods -l 'app.kubernetes.io/part-of=cilium' -o json |
    jq -r '.items[] | select(.metadata.ownerReferences[0].kind != "Job") |
      [.metadata.name, .metadata.uid, ([.status.containerStatuses[]?.restartCount] | add // 0)] | @tsv' | sort
}
cilium_status=$(k -n "$ARGO_NS" get application cilium -o jsonpath='{.status.sync.status}')
if [[ "$cilium_status" == Synced ]]; then
  ok "cilium already adopted (Synced) - nothing to do"
else
  mkdir -p "$CACHE_DIR"
  cilium_pods >"$SNAP_BEFORE"
  log "cilium pods before adoption: $(wc -l <"$SNAP_BEFORE") (snapshot $SNAP_BEFORE)"

  # argocd --core uses the namespace of the kube context; use a private copy instead of changing the user's kubeconfig
  KCFG=$(mktemp); chmod 600 "$KCFG"; trap 'rm -f "$KCFG"' EXIT
  kubectl config view --minify --flatten --context "$CONTEXT" >"$KCFG"
  kubectl --kubeconfig "$KCFG" config set-context --current --namespace "$ARGO_NS" >/dev/null
  acd() { KUBECONFIG="$KCFG" argocd --core "$@"; }

  diff_out=$(acd app diff cilium --refresh --exit-code=false 2>&1) || die "argocd app diff failed: $diff_out"
  # allowed: resource headers, diff hunk markers, and added/removed lines that only carry Argo CD tracking metadata
  unexpected=$(grep -E '^[<>]' <<<"$diff_out" | grep -v -E '^[<>][[:space:]]+(annotations:[[:space:]]*(\{\})?|argocd\.argoproj\.io/tracking-id:.*)$' || true)
  if [[ -n "$unexpected" ]]; then
    printf '%s\n' "$diff_out" >&2
    die "cilium diff contains more than tracking metadata - review it and sync by hand (SPEC §5.3)"
  fi
  ok "cilium diff is tracking metadata only ($(grep -c '^=====' <<<"$diff_out" || true) resources)"

  log "argocd app sync cilium (manual sync, server-side apply)"
  acd app sync cilium --timeout 600 >/dev/null
  acd app wait cilium --sync --health --timeout 600 >/dev/null
  cilium_pods >"$SNAP_AFTER"
  {
    printf "ADOPTION_STARTED='%s'\n" "$(k -n "$ARGO_NS" get application cilium -o jsonpath='{.status.operationState.startedAt}')"
    printf "ADOPTION_FINISHED='%s'\n" "$(k -n "$ARGO_NS" get application cilium -o jsonpath='{.status.operationState.finishedAt}')"
  } >"$CACHE_DIR/cilium-adoption.env"
  if ! diff -u "$SNAP_BEFORE" "$SNAP_AFTER" >&2; then
    die "cilium pods changed during adoption (UID or restart count) - see diff above"
  fi
  ok "cilium adopted: Synced/Healthy, pods unchanged (same UID and restart count)"
fi

echo
ok "GitOps bootstrap done. From now on the cluster changes only through commit + push."
log "Argo CD UI: kubectl -n $ARGO_NS port-forward svc/argocd-server 8080:80  (user admin, password: kubectl -n $ARGO_NS get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
