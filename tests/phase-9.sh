#!/usr/bin/env bash
# Phase 9 acceptance tests (SPEC §6.9). Output: [PASS|FAIL|SKIP] AC-9.n ...; exit 1 if a MUST fails.
#   AC-9.1 reads tests/.cache/rebuild-last.json, written by scripts/rebuild.sh (the clean rebuild itself).
#   DESTRUCTIVE=1  runs the fault-injection ACs (SPEC §7.6): AC-9.5 deletes a CiliumNetworkPolicy, AC-9.3 deletes 3
#                  random boutique pods, AC-9.4 pushes a broken canary release to origin/<GITOPS_REVISION> and reverts
#                  it (2 commits per run; needs a clean tree equal to the remote), AC-9.2 stops the zone-b worker
#                  container for ~3.5 minutes. The EXIT trap restores all of them. Without it they are SKIP.
# Order: read-only checks first, then the faults from the lightest to the node failure.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
NS=boutique
GW_IP=172.30.250.10
SHOP=shop.boutique.test
UP_TARGET=1800          # AC-9.1 / NFR-04: cold `make up` target (recorded, SPEC says "목표")
RECOVERY_LIMIT=90       # AC-9.2: successful again, and stays so, within this many seconds of the node stop
RESTORE_LIMIT=120       # AC-9.2: 3 frontend replicas again
WINDOW=180              # AC-9.2: observation while the node is down, at 2 requests/s
SPREAD_APPS=(frontend productcatalogservice currencyservice cartservice frontend-canary)
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
: "${GITOPS_REVISION:?set GITOPS_REVISION in .env}"
ac_should AC-9.7
REPORT=$(mktemp); on_cleanup "rm -f '$REPORT'"      # measured values, printed also when an AC passes
report() { echo "$*" >>"$REPORT"; }
show_report() { sed 's/^/       /' "$REPORT"; : >"$REPORT"; }
destructive() {  # <AC-ID> <description> <function>
  if [[ "${DESTRUCTIVE:-0}" == 1 ]]; then ac_check "$1" "$2" "$3"; show_report; else ac_skip "$1" "fault injection not run (set DESTRUCTIVE=1)"; fi
}

uptime_s() { cut -d' ' -f1 /proc/uptime; }                       # monotonic, shared with containers on this kernel
since() { awk -v a="$(uptime_s)" -v b="$1" 'BEGIN { printf "%.1f", a - b }'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
app_state() { k -n argocd get application "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}'; }
app_is() { [[ "$(app_state "$1")" == "$2" ]]; }
all_apps_healthy() {
  k -n argocd get applications -o json |
    jq -e '(.items | length) > 0 and all(.items[]; .status.sync.status == "Synced" and .status.health.status == "Healthy")' >/dev/null
}
# every boutique Deployment has exactly spec.replicas Ready, non-terminating pods (ignoring the pod UIDs in $1)
boutique_converged() {
  local gone=${1:-[]} d p
  d=$(k -n "$NS" get deploy -o json) && p=$(k -n "$NS" get pods -o json) || return 1
  jq -s -e --argjson gone "$gone" '
    .[0] as $d | .[1] as $p
    | ($d.items | length) > 0 and all($d.items[]; . as $dep
        | [$p.items[] | select(.metadata.labels.app == $dep.spec.selector.matchLabels.app
             and .metadata.deletionTimestamp == null
             and (.metadata.uid as $u | $gone | index($u) | not)
             and ((.status.conditions // []) | map(select(.type == "Ready"))[0].status) == "True")]
        | length == $dep.spec.replicas)' <(echo "$d") <(echo "$p") >/dev/null
}
coredns_nodes() {
  k -n kube-system get pods -l k8s-app=kube-dns -o json |
    jq '[.items[] | select(.metadata.deletionTimestamp == null) | .spec.nodeName] | unique | length'
}
git_ready() {
  git fetch -q origin "$GITOPS_REVISION" || { echo "git fetch failed"; return 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean"; git status --short | head; return 1; }
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$GITOPS_REVISION")" ]] ||
    { echo "HEAD $(git rev-parse --short HEAD) != origin/$GITOPS_REVISION"; return 1; }
}
git_push() { git push -q origin "HEAD:refs/heads/$GITOPS_REVISION"; }

# AC-9.1 ---------------------------------------------------------------------------------------
check_rebuild() {
  local f=$CACHE_DIR/rebuild-last.json commit created
  [[ -s "$f" ]] || { echo "no rebuild record ($f): run CONFIRM=yes scripts/rebuild.sh"; return 1; }
  created=$(k get ns kube-system -o jsonpath='{.metadata.creationTimestamp}')
  [[ "$(jq -r .cluster_created "$f")" == "$created" ]] || { echo "the record is for another cluster"; return 1; }
  commit=$(jq -r .commit "$f")
  git merge-base --is-ancestor "$commit" HEAD || { echo "rebuild commit $commit is not an ancestor of HEAD"; return 1; }
  git diff --quiet "$commit" HEAD -- bootstrap platform apps gitops observability scripts tests versions.env Makefile ||
    { echo "cluster code or tests changed since the rebuild:"; git diff --stat "$commit" HEAD -- bootstrap platform apps gitops observability scripts tests versions.env Makefile; return 1; }
  report "$(jq -r '"rebuild of \(.commit[0:7]) started \(.started): down \(.down_seconds)s, make up \(.up_seconds)s (target <= '"$UP_TARGET"'s), wait-sync \(.wait_sync_seconds)s, second make up \(.up_again_seconds)s, phases 1-8 \(.verify_seconds)s"' "$f")"
  report "$(jq -r '.phases | to_entries | map("phase-\(.key): \(.value.summary | sub("SUMMARY phase-[0-9]+: "; ""))") | join("; ")' "$f")"
  jq -e '.up_rc == 0 and .wait_sync_rc == 0 and .up_again_rc == 0 and (.phases | length) == 8 and all(.phases[]; .rc == 0)' "$f" >/dev/null ||
    { jq . "$f"; return 1; }
}
ac_check AC-9.1 "clean rebuild without intervention: make down -> make up -> phases 1-8 pass; durations recorded" check_rebuild
show_report

# AC-9.7 (SHOULD, before any fault) -------------------------------------------------------------
PROM=http://127.0.0.1:$(_pf observability kube-prometheus-stack-prometheus 9090)
pq() { curl -fsS --get --data-urlencode "query=$1" "$PROM/api/v1/query" | jq -c '[.data.result[] | {ns: (.metric.namespace // "total"), v: (.value[1] | tonumber)}]'; }
check_resources() {
  local running='* on(namespace,pod) group_left() max by (namespace,pod) (kube_pod_status_phase{phase="Running"} == 1)'
  local creq mreq cuse muse out table
  creq=$(pq "sum by (namespace) (kube_pod_container_resource_requests{resource=\"cpu\"} $running)") &&
  mreq=$(pq "sum by (namespace) (kube_pod_container_resource_requests{resource=\"memory\"} $running)") &&
  cuse=$(pq 'sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))') &&
  muse=$(pq 'sum by (namespace) (container_memory_working_set_bytes{container!="",container!="POD"})') || return 1
  table=$RESULTS_DIR/phase-9-resources-$(date -u +%Y%m%dT%H%M%SZ).log
  out=$(python3 -I - "$creq" "$mreq" "$cuse" "$muse" <<'PY'
import json, sys
creq, mreq, cuse, muse = ({r["ns"]: r["v"] for r in json.loads(a)} for a in sys.argv[1:5])
gib = 2**30
print(f"{'namespace':20}{'cpu req':>9}{'cpu use(5m)':>13}{'mem req GiB':>13}{'mem ws GiB':>12}")
for ns in sorted(set(creq) | set(mreq) | set(cuse) | set(muse)):
    print(f"{ns:20}{creq.get(ns,0):9.2f}{cuse.get(ns,0):13.2f}{mreq.get(ns,0)/gib:13.2f}{muse.get(ns,0)/gib:12.2f}")
t = (sum(creq.values()), sum(cuse.values()), sum(mreq.values())/gib, sum(muse.values())/gib)
print(f"{'TOTAL':20}{t[0]:9.2f}{t[1]:13.2f}{t[2]:13.2f}{t[3]:12.2f}")
print(f"LIMITS cpu_ok={int(0 < t[0] <= 6)} mem_ok={int(0 < t[2] <= 10)}")
PY
) || return 1
  echo "$out" >"$table"; echo "$out"
  while IFS= read -r line; do report "$line"; done < <(grep -v '^LIMITS' <<<"$out")
  report "table saved to ${table#"$REPO_ROOT"/}"
  grep -qx 'LIMITS cpu_ok=1 mem_ok=1' <<<"$out"
}
ac_check AC-9.7 "per-namespace requests and usage; cluster requests <= 6 vCPU / 10 GiB (NFR-05)" check_resources
show_report

# AC-9.6 ---------------------------------------------------------------------------------------
check_docs() {
  local rc=0 name p lines sections f
  for name in access policy-debug lb-debug argocd-sync-failure rebuild; do
    p=docs/runbooks/$name.md
    [[ -f "$p" ]] || { echo "missing $p"; rc=1; continue; }
    lines=$(grep -c '[^[:space:]]' "$p"); sections=$(grep -c '^## ' "$p")
    (( lines >= 20 && sections >= 2 )) || { echo "$p is too thin ($lines lines, $sections sections)"; rc=1; }
  done
  if [[ -f README.md ]]; then
    for f in 'make up' '.env' 'make verify-all'; do grep -qF -- "$f" README.md || { echo "README.md does not mention '$f'"; rc=1; }; done
  else echo "missing README.md"; rc=1; fi
  for f in docs/adr/*.md; do
    grep -qE '^- 상태: (Accepted|Superseded)' "$f" || { echo "$f: status is not Accepted/Superseded"; rc=1; }
  done
  python3 -I - docs/PROGRESS.md <<'PY' || rc=1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
bad = []
for n in range(9):
    row = re.search(rf"^\| {n} \|.*$", text, re.M)
    if not row or "✅" not in row.group(0): bad.append(f"phase {n} is not marked done")
table = text.split("## 측정값", 1)[1].split("\n##", 1)[0]
rows = [[c.strip() for c in l.strip().strip("|").split("|")] for l in table.splitlines() if l.startswith("|")][2:]
bad += [f"measurement '{r[0]}' is empty" for r in rows if len(r) < 2 or not r[1]]
if not rows: bad.append("no measurement rows")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  report "5 runbooks, README, $(find docs/adr -name '*.md' | wc -l) ADRs, PROGRESS phases 0-8 and measurements checked"
  return $rc
}
ac_check AC-9.6 "5 runbooks, README, every ADR Accepted/Superseded, PROGRESS complete" check_docs
show_report

# AC-9.8 ---------------------------------------------------------------------------------------
check_release_tag() {
  local local_sha remote
  local_sha=$(git rev-parse -q --verify 'v1.0.0^{commit}') || { echo "no local tag v1.0.0"; return 1; }
  git merge-base --is-ancestor "$local_sha" HEAD || { echo "v1.0.0 is not an ancestor of HEAD"; return 1; }
  remote=$(git ls-remote --tags origin 'refs/tags/v1.0.0' 'refs/tags/v1.0.0^{}' | awk '{print $1}' | tail -1)
  [[ "$remote" == "$local_sha" ]] || { echo "origin v1.0.0 (${remote:-missing}) != local $local_sha"; return 1; }
  report "v1.0.0 -> ${local_sha:0:7} (also on origin)"
}
ac_check AC-9.8 "release tag v1.0.0 exists locally and on origin" check_release_tag
show_report

# AC-9.5 ---------------------------------------------------------------------------------------
CNP=adservice           # losing it for a few seconds only hides the ads (the home page tolerates ad failures)
restore_cnp() { k -n "$NS" get cnp "$CNP" >/dev/null 2>&1 || k apply -n "$NS" -f "platform/policies/boutique/$CNP.yaml"; }
check_cnp_selfheal() {
  local uid spec start new_spec
  wait_for 60 app_is policies Synced/Healthy || { echo "precondition: policies $(app_state policies)"; return 1; }
  uid=$(k -n "$NS" get cnp "$CNP" -o jsonpath='{.metadata.uid}') || return 1
  spec=$(k -n "$NS" get cnp "$CNP" -o json | jq -S .spec)
  start=$(uptime_s)
  k -n "$NS" delete cnp "$CNP" >/dev/null || return 1
  wait_for 180 bash -c "u=\$(kubectl --context $CTX -n $NS get cnp $CNP -o jsonpath='{.metadata.uid}' 2>/dev/null); [[ -n \$u && \$u != $uid ]]" ||
    { echo "not recreated within 180s"; return 1; }
  report "CNP $NS/$CNP deleted by hand; Argo CD selfHeal recreated it after $(since "$start")s"
  new_spec=$(k -n "$NS" get cnp "$CNP" -o json | jq -S .spec)
  [[ "$new_spec" == "$spec" ]] || { echo "recreated spec differs"; diff <(echo "$spec") <(echo "$new_spec"); return 1; }
  wait_for 120 app_is policies Synced/Healthy || { echo "policies app $(app_state policies)"; return 1; }
}
[[ "${DESTRUCTIVE:-0}" == 1 ]] && on_cleanup restore_cnp
destructive AC-9.5 "a CiliumNetworkPolicy deleted by hand is recreated by selfHeal within 3 minutes" check_cnp_selfheal

# AC-9.3 ---------------------------------------------------------------------------------------
check_pod_loss() {
  local victims names uids start state drift=0 done_at=""
  wait_for 180 boutique_converged || { echo "precondition: boutique not converged"; k -n "$NS" get pods; return 1; }
  wait_for 60 app_is online-boutique Synced/Healthy || { echo "precondition: online-boutique $(app_state online-boutique)"; return 1; }
  victims=$(k -n "$NS" get pods --field-selector=status.phase=Running -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null and .metadata.labels["ac-test"] == null) | "\(.metadata.name) \(.metadata.uid)"' | shuf -n 3)
  [[ $(grep -c . <<<"$victims") -eq 3 ]] || { echo "could not pick 3 pods"; return 1; }
  names=$(awk '{print $1}' <<<"$victims" | tr '\n' ' ')
  uids=$(awk '{print $2}' <<<"$victims" | jq -R . | jq -cs .)
  start=$(uptime_s)
  # shellcheck disable=SC2086
  k -n "$NS" delete pod $names --wait=false >/dev/null || return 1
  while le "$(since "$start")" 120; do
    state=$(app_state online-boutique)
    [[ "$state" == OutOfSync/* ]] && drift=1
    if boutique_converged "$uids"; then done_at=$(since "$start"); break; fi
    sleep 2
  done
  report "deleted: $names"
  [[ -n "$done_at" ]] || { echo "deployments not converged within 120s"; k -n "$NS" get deploy; return 1; }
  k -n "$NS" wait --for=condition=Available deploy --all --timeout=10s >/dev/null || return 1
  wait_for 90 app_is online-boutique Synced/Healthy || { echo "online-boutique $(app_state online-boutique) after recovery"; return 1; }
  all_apps_healthy || { k -n argocd get applications; return 1; }
  report "every Deployment back to full replicas with new pods after ${done_at}s; online-boutique never OutOfSync: $([[ $drift == 0 ]] && echo yes || echo NO)"
  [[ $drift -eq 0 ]]
}
destructive AC-9.3 "3 random boutique pods deleted: all Deployments Available within 2 minutes, no Argo drift" check_pod_loss

# AC-9.4 ---------------------------------------------------------------------------------------
CANARY_FILE=apps/online-boutique/canary/deployment.yaml
BAD_COMMIT_FILE=$CACHE_DIR/phase-9-bad-commit
revert_bad_release() {    # also the EXIT trap: the broken release must never stay on the branch
  local sha; sha=$(cat "$BAD_COMMIT_FILE" 2>/dev/null || true)
  [[ -n "$sha" ]] || return 0
  git checkout -q -- "$CANARY_FILE"
  git revert --no-commit "$sha" &&
    git commit -q -m "test(phase-9): AC-9.4 revert the broken frontend-canary release" -m "This reverts commit $sha." &&
    git_push && : >"$BAD_COMMIT_FILE"
}
[[ "${DESTRUCTIVE:-0}" == 1 ]] && { : >"$BAD_COMMIT_FILE"; on_cleanup revert_bad_release; }
# prints one line per health change of the app: "+<s>s <sync>/<health> @<revision>"; returns when <want> at <rev>
watch_app() {  # <app> <revision> <Healthy|Degraded> <timeout-s> <t0>
  local app=$1 rev=$2 want=$3 limit=$4 t0=$5 line last=""
  while le "$(since "$t0")" "$limit"; do
    line=$(k -n argocd get application "$app" -o json | jq -r '"\(.status.sync.status)/\(.status.health.status) @\((.status.sync.revision // "")[0:7])"')
    [[ "$line" != "$last" ]] && { echo "+$(since "$t0")s $line"; last=$line; }
    [[ "$line" == "Synced/$want @${rev:0:7}" ]] && return 0
    sleep 5
  done
  return 1
}
check_bad_release() {
  local sha rsha t0 timeline served
  git_ready || return 1
  wait_for 120 app_is online-boutique Synced/Healthy || { echo "precondition: $(app_state online-boutique)"; return 1; }
  sed -i -E 's#^([[:space:]]*image: .*/frontend:v[0-9]+\.[0-9]+\.[0-9]+)$#\1-ac-9-4-missing#' "$CANARY_FILE"
  [[ "$(git diff --numstat -- "$CANARY_FILE" | awk '{print $1 "+" $2}')" == "1+1" ]] ||
    { echo "expected exactly one changed image line"; git diff -- "$CANARY_FILE"; git checkout -q -- "$CANARY_FILE"; return 1; }
  git commit -q -m "test(phase-9): AC-9.4 release a nonexistent frontend-canary image (reverted by the test)" -- "$CANARY_FILE" ||
    { git checkout -q -- "$CANARY_FILE"; return 1; }
  sha=$(git rev-parse HEAD); echo "$sha" >"$BAD_COMMIT_FILE"
  git_push || return 1
  t0=$(uptime_s)
  # progressDeadlineSeconds 180 + the Git poll interval (up to ~3 min) + margin
  if ! timeline=$(watch_app online-boutique "$sha" Degraded 600 "$t0"); then echo "$timeline"; echo "not Degraded within 600s"; return 1; fi
  report "bad release ${sha:0:7} pushed; health: $(tr '\n' ' ' <<<"$timeline")"
  extract_ca cert-manager boutique-root-ca tls.crt || return 1
  served=$(docker run --rm --label ac-test=true --network "$DOCKER_NETWORK" -v "$CACHE_DIR:/certs:ro" --entrypoint sh "$CURL_IMAGE" -c \
    "for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -m 10 -w '%{http_code}\n' --cacert /certs/ca.crt --resolve $SHOP:443:$GW_IP -H 'x-canary: always' https://$SHOP/; done" | grep -c '^200$' || true)
  report "while Degraded, 10 requests forced to the canary: $served x 200 (the old canary pods keep serving)"
  revert_bad_release || { echo "revert/push failed"; return 1; }
  rsha=$(git rev-parse HEAD); t0=$(uptime_s)
  if ! timeline=$(watch_app online-boutique "$rsha" Healthy 300 "$t0"); then echo "$timeline"; echo "not Healthy within 300s of the revert"; return 1; fi
  report "git revert ${rsha:0:7} pushed; health: $(tr '\n' ' ' <<<"$timeline")"
  wait_for 120 boutique_converged || { echo "boutique not converged"; return 1; }
}
destructive AC-9.4 "broken canary release: Degraded is detected; git revert makes the app Healthy within 5 minutes" check_bad_release

# AC-9.2 ---------------------------------------------------------------------------------------
STOPPED_FILE=$(mktemp); on_cleanup "rm -f '$STOPPED_FILE'"
restore_node() {          # EXIT trap: a stopped node is always started again
  local n; n=$(cat "$STOPPED_FILE" 2>/dev/null || true)
  [[ -n "$n" ]] && docker start "$n"
  docker rm -f ac-9-2-probe 2>/dev/null
  true
}
on_cleanup restore_node
node_ready() { k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
node_recovered() {  # <node> <restart-epoch>: the node and every pod on it became Ready AFTER the restart
  local node=$1 t=$2
  k get node "$node" -o json | jq -e --argjson t "$t" \
    '.status.conditions[] | select(.type=="Ready") | .status=="True" and ((.lastTransitionTime|fromdateiso8601) >= $t)' >/dev/null || return 1
  k get pods -A --field-selector "spec.nodeName=$node" -o json | jq -e --argjson t "$t" \
    '[.items[] | select(.status.phase!="Succeeded" and .metadata.deletionTimestamp == null) | (.status.conditions // [] | map(select(.type=="Ready"))[0])]
     | all(.status=="True" and ((.lastTransitionTime|fromdateiso8601) >= $t))' >/dev/null
}
frontend_ready_elsewhere() {  # <dead node> → number of Ready, non-terminating frontend pods on other nodes
  k -n "$NS" get pods -l app=frontend -o json | jq --arg n "$1" '[.items[] | select(.spec.nodeName != $n
    and .metadata.deletionTimestamp == null and ((.status.conditions // []) | map(select(.type=="Ready"))[0].status) == "True")] | length'
}
l2_leases() { k -n kube-system get lease -o json | jq -r '[.items[] | select(.metadata.name | startswith("cilium-l2announce-"))
  | "\(.metadata.name | sub("cilium-l2announce-"; ""))=\(.spec.holderIdentity)"] | join(" ")'; }
check_node_failure() {
  local node on_node t0 notready="" restored="" start_epoch ticks res log
  wait_for 120 bash -c "kubectl --context $CTX wait --for=condition=Ready nodes --all --timeout=5s >/dev/null 2>&1" || { echo "precondition: nodes"; return 1; }
  wait_for 180 boutique_converged || { echo "precondition: boutique not converged"; return 1; }
  [[ $(coredns_nodes) -ge 2 ]] || { echo "precondition: CoreDNS not on 2 nodes"; return 1; }
  node=$(k get nodes -l topology.kubernetes.io/zone=zone-b -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$node" ]] || return 1
  on_node=$(k get pods -A --field-selector "spec.nodeName=$node" -o json |
    jq -r '[.items[] | select(.metadata.namespace == "boutique" or (.metadata.name | startswith("coredns"))) | .metadata.labels.app // .metadata.name] | sort | join(" ")')
  report "zone-b node $node runs: $on_node"
  report "L2 announcements before: $(l2_leases)"
  extract_ca cert-manager boutique-root-ca tls.crt || return 1
  # 2 requests/s, each in the background so a slow answer does not slow the rate; timestamps are /proc/uptime
  ticks=$(( (WINDOW + 40) * 2 ))
  docker rm -f ac-9-2-probe >/dev/null 2>&1
  docker run -d --name ac-9-2-probe --label ac-test=true --network "$DOCKER_NETWORK" -v "$CACHE_DIR:/certs:ro" --entrypoint sh "$CURL_IMAGE" -c \
    "i=0; while [ \$i -lt $ticks ]; do i=\$((i+1)); ( t=\$(cut -d' ' -f1 /proc/uptime); c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert /certs/ca.crt --resolve $SHOP:443:$GW_IP https://$SHOP/); echo \"\$t \$c\" ) & sleep 0.5; done; wait" >/dev/null || return 1
  sleep 15
  [[ "$(docker logs ac-9-2-probe 2>&1 | tail -10 | awk '{print $2}' | sort -u)" == 200 ]] || { echo "shop not healthy before the fault"; docker logs ac-9-2-probe 2>&1 | tail -5; return 1; }
  echo "$node" >"$STOPPED_FILE"
  t0=$(uptime_s)
  docker stop "$node" >/dev/null || return 1
  while le "$(since "$t0")" "$WINDOW"; do
    [[ -z "$notready" && "$(node_ready "$node")" != True ]] && notready=$(since "$t0")
    [[ -z "$restored" && "$(frontend_ready_elsewhere "$node" 2>/dev/null)" == 3 ]] && restored=$(since "$t0")
    sleep 2
  done
  [[ "$(docker inspect -f '{{.State.Running}}' "$node")" == false ]] || { echo "$node was not down during the window"; return 1; }
  report "L2 announcements while down: $(l2_leases)"
  timeout 120 docker wait ac-9-2-probe >/dev/null || { echo "probe did not finish"; return 1; }
  log=$(docker logs ac-9-2-probe 2>&1); docker rm -f ac-9-2-probe >/dev/null
  printf '%s\n' "$log" >"$RESULTS_DIR/phase-9-node-failure-probe-$(date -u +%Y%m%dT%H%M%SZ).log"
  res=$(python3 -I - "$t0" "$log" <<'PY'
import sys, collections
t0 = float(sys.argv[1])
rows = sorted((float(p[0]), p[1]) for p in (l.split() for l in sys.argv[2].splitlines()) if len(p) == 2)
after = [(t - t0, c) for t, c in rows if t >= t0]
fails = [(t, c) for t, c in after if c != "200"]
if fails:
    ok_later = [t for t, c in after if c == "200" and t > fails[-1][0]]
    recover = f"{ok_later[0]:.1f}" if ok_later else "never"
else:
    recover = "0.0"
codes = ",".join(f"{c}x{n}" for c, n in sorted(collections.Counter(c for _, c in fails).items())) or "-"
print(len(after), f"{after[-1][0]:.1f}" if after else "0", len(fails),
      f"{fails[0][0]:.1f}" if fails else "-", f"{fails[-1][0]:.1f}" if fails else "-", recover, codes)
PY
) || return 1
  local n span nf first last recover codes
  read -r n span nf first last recover codes <<<"$res"
  report "probe after 'docker stop' (t=0): $n requests over ${span}s, $nf failed [$codes], first at +${first}s, last at +${last}s"
  report "service recovered (first success after the last failure) at +${recover}s (limit ${RECOVERY_LIMIT}s); node NotReady at +${notready:-?}s; 3 frontend replicas on live nodes at +${restored:-never}s (limit ${RESTORE_LIMIT}s)"

  start_epoch=$(date -u +%s)
  docker start "$node" >/dev/null || return 1
  : >"$STOPPED_FILE"
  wait_for 300 node_recovered "$node" "$start_epoch" || { echo "$node not recovered within 300s"; k get pods -A --field-selector "spec.nodeName=$node"; return 1; }
  wait_for 300 boutique_converged || { echo "boutique not converged after the restart"; return 1; }
  rebalance_zones "$NS" "${SPREAD_APPS[@]}" || return 1
  reset_loadgenerator || { echo "loadgenerator did not restart"; return 1; }
  wait_for 600 all_apps_healthy || { k -n argocd get applications; return 1; }
  report "restore: node and its pods Ready again, zone spread rebalanced, loadgenerator statistics reset, all Applications Synced/Healthy; CoreDNS on $(coredns_nodes) nodes"

  local rc=0
  (( n >= WINDOW * 2 * 9 / 10 )) || { echo "only $n probe requests in the window (expected about $((WINDOW * 2)))"; rc=1; }
  le "$WINDOW" "$span" || { echo "probe ended at +${span}s, before the ${WINDOW}s window"; rc=1; }
  [[ "$recover" != never ]] && le "$recover" "$RECOVERY_LIMIT" || { echo "recovery +${recover}s exceeds ${RECOVERY_LIMIT}s (errors after the recovery point count as not recovered)"; rc=1; }
  [[ -n "$restored" ]] && le "$restored" "$RESTORE_LIMIT" || { echo "frontend not back to 3 replicas within ${RESTORE_LIMIT}s"; rc=1; }
  return $rc
}
destructive AC-9.2 "zone-b worker stopped: https://$SHOP succeeds again within 90s (no later errors), frontend 3/3 within 2 minutes" check_node_failure

ac_summary 9
