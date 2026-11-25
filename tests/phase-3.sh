#!/usr/bin/env bash
# Phase 3 acceptance tests (SPEC §6.3). Output: [PASS|FAIL|SKIP] AC-3.n ...; exit 1 if a MUST fails.
# Takes 20+ minutes: AC-3.3 observes the cilium app 10 and 20 minutes after its last sync, and AC-3.5 / AC-3.8 push
# commits to origin/<GITOPS_REVISION> and wait for Argo CD to poll Git (about 3 minutes per push).
# AC-3.5 / AC-3.8 need a clean working tree whose HEAD equals the remote branch; every pushed probe commit is reverted
# (also by the EXIT trap if the test is interrupted), so each run adds 2 + 2 commits to the branch.
# Execution order differs from AC order so that AC-3.3's waiting overlaps the Git round trips.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
ARGO_NS=argocd
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
: "${GITOPS_REVISION:?set GITOPS_REVISION in .env}"
CHILD_APPS=(namespaces gateway-api-crds prometheus-operator-crds cilium argocd)
WAVE_M3=(namespaces gateway-api-crds prometheus-operator-crds)
WAVE_M2=(cilium argocd)
SNAP_BEFORE="$CACHE_DIR/cilium-adoption-before.tsv"
SNAP_AFTER="$CACHE_DIR/cilium-adoption-after.tsv"
ADOPTION_RECORD="$CACHE_DIR/cilium-adoption.env"
GIT_STATE="$CACHE_DIR/phase-3-pushed-probes"      # SHAs of pushed probe commits not reverted yet (read by the trap)
epoch() { date -u -d "$1" +%s; }

# argocd CLI in --core mode with a private kubeconfig whose namespace is argocd (the user's kubeconfig is untouched)
ACD_KCFG=$(mktemp); chmod 600 "$ACD_KCFG"; on_cleanup "rm -f '$ACD_KCFG'"
kubectl config view --minify --flatten --context "$CTX" >"$ACD_KCFG"
kubectl --kubeconfig "$ACD_KCFG" config set-context --current --namespace "$ARGO_NS" >/dev/null
acd() { KUBECONFIG="$ACD_KCFG" argocd --core "$@"; }

app_field() { k -n "$ARGO_NS" get application "$1" -o jsonpath="$2" 2>/dev/null; }

# ---- Git probe helpers (AC-3.5, AC-3.8) ----------------------------------------------------------------------
git_ready() {
  git fetch -q origin "$GITOPS_REVISION" || { echo "git fetch failed"; return 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean"; git status --short | head; return 1; }
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$GITOPS_REVISION")" ]] ||
    { echo "HEAD $(git rev-parse --short HEAD) != origin/$GITOPS_REVISION $(git rev-parse --short "origin/$GITOPS_REVISION")"; return 1; }
}
git_push() { git push -q origin "HEAD:refs/heads/$GITOPS_REVISION"; }
# probe_commit <message> <paths...>  (changes already made in the tree) → commits, pushes, records the SHA for the trap
probe_commit() {
  local msg=$1; shift
  git add -- "$@" && git commit -q -m "$msg" -- "$@" || return 1
  echo "$(git rev-parse HEAD)" >>"$GIT_STATE"
  git_push
}
# probe_revert <sha> <message> → revert commit, push, forget the SHA
probe_revert() {
  local sha=$1 msg=$2
  git revert --no-commit "$sha" && git commit -q -m "$msg" -m "This reverts commit $sha." || return 1
  git_push || return 1
  sed -i "/^$sha\$/d" "$GIT_STATE"
}
restore_probes() {   # EXIT trap: revert whatever probe commit is still live, newest first
  [[ -s "$GIT_STATE" ]] || return 0
  local sha
  for sha in $(tac "$GIT_STATE"); do
    git reset -q --hard HEAD   # drop half-made edits of an interrupted step
    probe_revert "$sha" "test(phase-3): restore after interrupted acceptance test" || echo "WARN: could not revert $sha" >&2
  done
}
: >"$GIT_STATE"
on_cleanup restore_probes

# AC-3.1 ---------------------------------------------------------------------------------------
check_argocd_pods() {
  local rc=0 pods comp
  pods=$(k -n "$ARGO_NS" get pods -o json)
  for comp in argocd-application-controller argocd-repo-server argocd-server argocd-redis argocd-applicationset-controller; do
    jq -e --arg c "$comp" '[.items[] | select(.metadata.labels["app.kubernetes.io/name"] == $c)] | length > 0' <<<"$pods" >/dev/null ||
      { echo "$comp: no pod"; rc=1; }
  done
  while IFS=$'\t' read -r name phase ready node; do
    local pool; pool=$(k get node "$node" -o jsonpath='{.metadata.labels.node\.boutique\.io/pool}' 2>/dev/null)
    if [[ "$phase" == Succeeded ]]; then
      [[ "$pool" == infra ]] && echo "$name: Completed on $node (infra)" || { echo "$name: Completed on $node (pool='$pool')"; rc=1; }
    elif [[ "$ready" == true && "$pool" == infra ]]; then echo "$name: Ready on $node (infra)"
    else echo "$name: phase=$phase ready=$ready node=$node pool='$pool'"; rc=1; fi
  done < <(jq -r '.items[] | [.metadata.name, .status.phase,
      ((.status.conditions // []) | map(select(.type == "Ready"))[0].status == "True" | tostring), .spec.nodeName] | @tsv' <<<"$pods")
  return $rc
}
ac_check AC-3.1 "every Argo CD pod Ready and on the infra node" check_argocd_pods

# AC-3.2 ---------------------------------------------------------------------------------------
check_apps_and_adoption() {
  local rc=0 a s h
  for a in root "${CHILD_APPS[@]}"; do
    s=$(app_field "$a" '{.status.sync.status}'); h=$(app_field "$a" '{.status.health.status}')
    if [[ "$s/$h" == Synced/Healthy ]]; then echo "$a: Synced/Healthy"; else echo "$a: ${s:-missing}/${h:-missing}"; rc=1; fi
  done
  # adoption evidence written by gitops-bootstrap.sh: pod snapshots right before and right after the manual sync
  if [[ ! -s "$SNAP_BEFORE" || ! -s "$SNAP_AFTER" || ! -s "$ADOPTION_RECORD" ]]; then
    echo "adoption snapshots missing in $CACHE_DIR (run make gitops-bootstrap)"; return 1
  fi
  # shellcheck disable=SC1090
  source "$ADOPTION_RECORD"   # ADOPTION_STARTED / ADOPTION_FINISHED (RFC3339, from the sync operation)
  local tb ta; tb=$(stat -c %Y "$SNAP_BEFORE"); ta=$(stat -c %Y "$SNAP_AFTER")
  if (( tb <= $(epoch "$ADOPTION_STARTED") && $(epoch "$ADOPTION_FINISHED") <= ta )); then
    echo "snapshots bracket the adoption sync ($ADOPTION_STARTED .. $ADOPTION_FINISHED)"
  else echo "snapshot times do not bracket the adoption sync"; rc=1; fi
  if diff -u "$SNAP_BEFORE" "$SNAP_AFTER"; then echo "cilium pods: $(wc -l <"$SNAP_AFTER") pods, UID and restartCount unchanged"
  else echo "cilium pods changed across the adoption"; rc=1; fi
  return $rc
}
ac_check AC-3.2 "root + all child apps Synced/Healthy; cilium pods unchanged across adoption" check_apps_and_adoption

# AC-3.4 ---------------------------------------------------------------------------------------
# Fault injection on a managed namespace (CLAUDE.md exception); the trap restores the label if selfHeal does not.
SELFHEAL_NS=boutique
on_cleanup "kubectl --context $CTX label ns $SELFHEAL_NS gateway-access=true --overwrite"
check_selfheal() {
  local start=$SECONDS
  k label ns "$SELFHEAL_NS" gateway-access- >/dev/null || return 1
  echo "removed label gateway-access from ns/$SELFHEAL_NS"
  if wait_for 180 bash -c "[[ \"\$(kubectl --context $CTX get ns $SELFHEAL_NS -o jsonpath='{.metadata.labels.gateway-access}')\" == true ]]"; then
    echo "label restored by selfHeal after $((SECONDS - start))s"
  else echo "label not restored within 180s"; return 1; fi
}
ac_check AC-3.4 "selfHeal restores a manually removed namespace label within 3 minutes" check_selfheal

# AC-3.6 ---------------------------------------------------------------------------------------
DENY_APP=ac-test-appproject-deny
on_cleanup "kubectl --context $CTX -n $ARGO_NS delete application $DENY_APP --ignore-not-found --wait=false"
check_project_deny() {
  local repo out msg
  repo=$(yq -r '.spec.source.repoURL' gitops/root.yaml)
  k apply -f - >/dev/null <<EOF || return 1
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $DENY_APP
  namespace: $ARGO_NS
  labels: {ac-test: "true"}
spec:
  project: apps
  source: {repoURL: $repo, targetRevision: $GITOPS_REVISION, path: tests/fixtures/appproject-deny}
  destination: {server: https://kubernetes.default.svc, namespace: l4-test}
EOF
  out=$(acd app sync "$DENY_APP" --timeout 120 2>&1); echo "sync exit=$? (non-zero expected)"
  msg="$out $(app_field "$DENY_APP" '{.status.operationState.message} {.status.conditions[*].message}')"
  echo "$msg" | tr -s ' \n' ' ' | cut -c1-400; echo
  k delete application -n "$ARGO_NS" "$DENY_APP" --ignore-not-found >/dev/null
  if k get clusterrole ac-test-appproject-deny >/dev/null 2>&1; then echo "ClusterRole was created!"; return 1; fi
  grep -Eqi 'not permitted in project|is not permitted|cluster level .* can not be managed' <<<"$msg"
}
ac_check AC-3.6 "AppProject apps rejects syncing a cluster-scoped resource" check_project_deny

# AC-3.7 ---------------------------------------------------------------------------------------
check_secrets() {
  gitleaks git . --no-banner --redact --config .gitleaks.toml &&
    gitleaks dir . --no-banner --redact --config .gitleaks.toml
}
ac_check AC-3.7 "secret scan of the repository (history + working tree): 0 findings" check_secrets

# AC-3.9 ---------------------------------------------------------------------------------------
# The root app creates the wave -2 Application objects only after every wave -3 Application reports Healthy
# (Application health customization in argocd-cm). Evidence: wave -3 apps were Healthy before any wave -2 app existed.
check_waves() {
  local rc=0 a b created healthy
  for b in "${WAVE_M2[@]}"; do
    created=$(app_field "$b" '{.metadata.creationTimestamp}')
    [[ -n "$created" ]] || { echo "$b: missing"; rc=1; continue; }
    for a in "${WAVE_M3[@]}"; do
      healthy=$(app_field "$a" '{.status.health.lastTransitionTime}')
      [[ -n "$healthy" && "$(app_field "$a" '{.status.health.status}')" == Healthy ]] || { echo "$a: not Healthy / no transition time"; rc=1; continue; }
      if (( $(epoch "$healthy") <= $(epoch "$created") )); then echo "$a Healthy at $healthy <= $b created at $created"
      else echo "$a Healthy at $healthy is AFTER $b was created at $created"; rc=1; fi
    done
  done
  return $rc
}
ac_check AC-3.9 "sync waves: CRD/namespace apps (wave -3) Healthy before cilium/argocd (wave -2) existed" check_waves

# AC-3.5 ---------------------------------------------------------------------------------------
PRUNE_FILE=platform/namespaces/ac-prune-probe.yaml
check_prune() {
  local sha start
  git_ready || return 1
  cat >"$PRUNE_FILE" <<EOF
# AC-3.5 probe (tests/phase-3.sh): added and reverted by the acceptance test
apiVersion: v1
kind: ConfigMap
metadata:
  name: ac-prune-probe
  namespace: l4-test
data:
  created-by: tests/phase-3.sh
EOF
  yq -i '.resources += ["ac-prune-probe.yaml"]' platform/namespaces/kustomization.yaml
  probe_commit "test(phase-3): AC-3.5 add prune probe ConfigMap" "$PRUNE_FILE" platform/namespaces/kustomization.yaml || return 1
  sha=$(git rev-parse HEAD); start=$SECONDS
  echo "pushed ${sha:0:7}; waiting for ConfigMap l4-test/ac-prune-probe"
  wait_for 420 k -n l4-test get configmap ac-prune-probe || { echo "ConfigMap not created within 420s"; return 1; }
  echo "created after $((SECONDS - start))s"
  probe_revert "$sha" "test(phase-3): AC-3.5 remove prune probe ConfigMap" || return 1
  start=$SECONDS
  echo "pushed revert $(git rev-parse --short HEAD); waiting for prune"
  wait_for 420 bash -c "! kubectl --context $CTX -n l4-test get configmap ac-prune-probe >/dev/null 2>&1" ||
    { echo "ConfigMap not pruned within 420s"; return 1; }
  echo "pruned after $((SECONDS - start))s"
}
ac_check AC-3.5 "prune: ConfigMap added in Git is created, removed in Git is deleted" check_prune

# AC-3.8 ---------------------------------------------------------------------------------------
check_self_management() {
  local sha start banner
  git_ready || return 1
  banner="AC-3.8 self-management probe $(date -u +%Y%m%dT%H%M%SZ)"
  BANNER="$banner" yq -i '.configs.cm["ui.bannercontent"] = strenv(BANNER)' platform/argocd/values.yaml
  probe_commit "test(phase-3): AC-3.8 set Argo CD banner via Git" platform/argocd/values.yaml || return 1
  sha=$(git rev-parse HEAD); start=$SECONDS
  echo "pushed ${sha:0:7}; waiting for argocd-cm ui.bannercontent"
  wait_for 600 bash -c "[[ \"\$(kubectl --context $CTX -n $ARGO_NS get cm argocd-cm -o jsonpath='{.data.ui\\.bannercontent}')\" == '$banner' ]]" ||
    { echo "argocd-cm not updated within 600s"; return 1; }
  echo "argocd-cm updated after $((SECONDS - start))s"
  probe_revert "$sha" "test(phase-3): AC-3.8 restore Argo CD settings" || return 1
  start=$SECONDS
  wait_for 600 bash -c "[[ -z \"\$(kubectl --context $CTX -n $ARGO_NS get cm argocd-cm -o jsonpath='{.data.ui\\.bannercontent}')\" ]]" ||
    { echo "banner not removed within 600s"; return 1; }
  echo "banner removed after $((SECONDS - start))s"
  wait_for 600 bash -c "[[ \"\$(kubectl --context $CTX -n $ARGO_NS get application argocd -o jsonpath='{.status.sync.status}/{.status.health.status}')\" == Synced/Healthy ]]" ||
    { echo "argocd app not Synced/Healthy after restore"; return 1; }
  echo "argocd app Synced/Healthy again"
}
ac_check AC-3.8 "Argo CD self-management: a Git change of its config is applied, then reverted" check_self_management

# AC-3.3 ---------------------------------------------------------------------------------------
# Two observations of the cilium app, at >= T+10min and >= T+20min after its last sync (T = operationState.finishedAt).
# Each observation waits for a comparison made after its point in time (status.reconciledAt), so a run that starts
# long after T still looks at two fresh, distinct reconciliations.
check_no_drift() {
  local t point last=0 rec s i offs=(600 1200)
  t=$(app_field cilium '{.status.operationState.finishedAt}')
  [[ -n "$t" ]] || { echo "cilium has never been synced"; return 1; }
  t=$(epoch "$t")
  for i in 0 1; do
    point=$(( t + offs[i] )); (( point > last )) || point=$((last + 1))
    while (( $(date +%s) < point )); do sleep 15; done
    wait_for 600 bash -c "(( \$(date -u -d \"\$(kubectl --context $CTX -n $ARGO_NS get application cilium -o jsonpath='{.status.reconciledAt}')\" +%s) >= $point ))" ||
      { echo "no reconciliation after $(date -u -d "@$point" +%FT%TZ)"; return 1; }
    rec=$(app_field cilium '{.status.reconciledAt}'); s=$(app_field cilium '{.status.sync.status}')
    echo "T+$((offs[i] / 60))min check: reconciledAt=$rec sync=$s"
    [[ "$s" != OutOfSync && -n "$s" ]] || return 1
    last=$(epoch "$rec")
  done
}
ac_check AC-3.3 "cilium app not OutOfSync 10 and 20 minutes after its sync (no permanent drift)" check_no_drift

ac_summary 3
