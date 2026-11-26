#!/usr/bin/env bash
# Phase 7 acceptance tests (SPEC §6.7). Output: [PASS|FAIL|SKIP] AC-7.n ...; exit 1 if a MUST fails.
#   DESTRUCTIVE=1  also run AC-7.7: pause Argo CD reconciliation of online-boutique (SPEC §7.4), scale paymentservice
#                  to 0, wait for the alerts to fire, restore and wait for them to resolve (up to ~25 min). Restored by
#                  the EXIT trap. SPEC §7.6 requires it for completing the phase; without it AC-7.7 is SKIP.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
NS=observability
GW_IP=172.30.250.10
VIP=http://172.30.250.20
ALERT_TIMEOUT=600          # AC-7.7: both alerts must fire within 10 minutes
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
ac_should AC-7.9
REPORT=$(mktemp); on_cleanup "rm -f '$REPORT'"
report() { echo "$*" >>"$REPORT"; }
show_report() { sed 's/^/       /' "$REPORT"; : >"$REPORT"; }

# long-lived port-forwards (opened here, in the main shell, so every check can use them)
PROM=http://127.0.0.1:$(_pf "$NS" kube-prometheus-stack-prometheus 9090)
LOKI=http://127.0.0.1:$(_pf "$NS" loki 3100)
TEMPO=http://127.0.0.1:$(_pf "$NS" tempo 3200)
pq() { curl -fsS --get --data-urlencode "query=$1" "$PROM/api/v1/query" | jq -c '.data.result'; }
pcount() { pq "$1" | jq 'length'; }

# place_orders <n> [interval-seconds] → one probe container placing n orders through the L4 VIP; prints "ok=<i>/<n>"
ORDER_FN='order() { J=/tmp/j$1; B='"$VIP"'; Y=$(($(date +%Y)+1)); curl -s -m 10 -c $J -b $J -o /dev/null $B/;
  curl -s -m 10 -c $J -b $J -o /dev/null -d product_id=OLJCESPC7Z -d quantity=1 $B/cart;
  curl -s -m 20 -c $J -b $J -o /tmp/o -d email=someone@example.com -d "street_address=1600 Amphitheatre Parkway" \
    -d zip_code=94043 -d "city=Mountain View" -d state=CA -d "country=United States" \
    -d credit_card_number=4432801561520454 -d credit_card_expiration_month=1 -d credit_card_expiration_year=$Y \
    -d credit_card_cvv=672 $B/cart/checkout; grep -q "Your order is complete" /tmp/o; }'
place_orders() {
  docker run --rm --label ac-test=true --network "$DOCKER_NETWORK" --entrypoint sh "$CURL_IMAGE" -c \
    "$ORDER_FN; ok=0; i=0; while [ \$i -lt $1 ]; do i=\$((i+1)); order \$i && ok=\$((ok+1)); sleep ${2:-0}; done; echo ok=\$ok/$1"
}

# AC-7.1 ---------------------------------------------------------------------------------------
check_stack_pods() {
  local rc=0 name phase ready node owner pool n=0
  while IFS=$'\t' read -r name phase ready node owner; do
    n=$((n + 1))
    pool=$(k get node "$node" -o jsonpath='{.metadata.labels.node\.boutique\.io/pool}' 2>/dev/null)
    if [[ "$phase" == Succeeded && "$owner" == Job ]]; then continue; fi
    [[ "$ready" == true ]] || { echo "$name not Ready ($phase)"; rc=1; }
    [[ "$owner" == DaemonSet || "$pool" == infra ]] || { echo "$name ($owner) on $node pool='$pool'"; rc=1; }
  done < <(k -n "$NS" get pods -o json | jq -r '.items[] | [.metadata.name, .status.phase,
    ((.status.conditions // []) | map(select(.type=="Ready"))[0].status == "True" | tostring), .spec.nodeName,
    (.metadata.ownerReferences[0].kind // "-")] | @tsv')
  report "$n pods in $NS; not-Ready or misplaced: $([[ $rc == 0 ]] && echo 0 || echo some)"
  [[ $n -gt 0 && $rc -eq 0 ]]
}
ac_check AC-7.1 "observability pods Ready; non-DaemonSet pods on the infra node" check_stack_pods
show_report

# AC-7.2 ---------------------------------------------------------------------------------------
# required name -> "jq filter on a target" and the minimum number of targets (5 = one per node)
check_targets() {
  local targets down rc=0 spec name filter min n
  targets=$(curl -fsS "$PROM/api/v1/targets?state=active") || return 1
  down=$(jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job) \(.scrapeUrl) \(.lastError[0:120])"' <<<"$targets")
  [[ -z "$down" ]] || { echo "not up:"; echo "$down"; rc=1; }
  for spec in \
    'kubelet|.labels.job=="kubelet" and (.scrapeUrl|test("/metrics$"))|5' \
    'cadvisor|.labels.job=="kubelet" and (.scrapeUrl|test("/metrics/cadvisor$"))|5' \
    'node-exporter|.labels.job=="node-exporter"|5' 'kube-state-metrics|.labels.job=="kube-state-metrics"|1' \
    'apiserver|.labels.job=="apiserver"|1' 'coredns|.labels.job=="coredns"|2' \
    'controller-manager|.labels.job=="kube-controller-manager"|1' 'scheduler|.labels.job=="kube-scheduler"|1' \
    'etcd|.labels.job=="kube-etcd"|1' 'cilium-agent|.labels.job=="cilium-agent"|5' \
    'cilium-operator|.labels.job=="cilium-operator"|1' 'hubble|.labels.job=="hubble-metrics"|5' \
    'cilium-envoy|.labels.job=="cilium-envoy"|5' 'argocd-application-controller|.labels.job=="argocd-application-controller-metrics"|1' \
    'argocd-server|.labels.job=="argocd-server-metrics"|1' 'argocd-repo-server|.labels.job=="argocd-repo-server-metrics"|1' \
    'argocd-applicationset-controller|.labels.job=="argocd-applicationset-controller-metrics"|1' \
    'argocd-redis|.labels.job=="argocd-redis-metrics"|1' 'cert-manager|.labels.job=="cert-manager"|1' \
    'cert-manager-webhook|.labels.job=="webhook"|1' 'cert-manager-cainjector|.labels.job=="cainjector"|1' \
    'loki|.labels.job=="observability/loki"|1' 'tempo|.labels.job=="tempo"|1' 'otel-collector|.labels.job=="otel-collector"|1' \
    'alloy|.labels.job=="alloy"|5'; do
    IFS='|' read -r name rest <<<"$spec"; min=${rest##*|}; filter=${rest%|*}
    n=$(jq "[.data.activeTargets[] | select(.health==\"up\") | select($filter)] | length" <<<"$targets")
    (( n >= min )) || { echo "$name: $n up targets (want >= $min)"; rc=1; }
  done
  report "$(jq '.data.activeTargets|length' <<<"$targets") active targets, $(jq '[.data.activeTargets[]|select(.health=="up")]|length' <<<"$targets") up; required jobs checked: 25"
  return $rc
}
ac_check AC-7.2 "every active target up; all required jobs present" check_targets
show_report

# AC-7.3 ---------------------------------------------------------------------------------------
check_queries() {
  local rc=0 spec name q n
  for spec in 'Hubble flows|sum(hubble_flows_processed_total)' 'Cilium endpoints|sum(cilium_endpoint_state)' \
    'Gateway (Envoy) requests|sum(envoy_http_downstream_rq_total{envoy_http_conn_manager_prefix=~"listener-(secure|insecure)"}) > 0' \
    'argocd_app_info|argocd_app_info' 'boutique kube_pod_info|kube_pod_info{namespace="boutique"}' \
    'spanmetrics calls|sum(traces_span_metrics_calls_total) > 0'; do
    IFS='|' read -r name q <<<"$spec"; n=$(pcount "$q")
    echo "$name: $n series"; report "$name: $n series"
    [[ "$n" -gt 0 ]] || rc=1
  done
  return $rc
}
ac_check AC-7.3 "Hubble, Cilium, Gateway, Argo CD, boutique pod and spanmetrics queries return data" check_queries
show_report

# AC-7.4 ---------------------------------------------------------------------------------------
# an instant metric query counts every stream exactly (a raw log query with a line limit would crowd out quiet pods)
check_logs() {
  local pairs n
  pairs=$(curl -fsS --get --data-urlencode 'query=sum by (app, container) (count_over_time({namespace="boutique"}[5m]))' \
    "$LOKI/loki/api/v1/query" | jq -r '.data.result[] | "\(.metric.app)/\(.metric.container)"' | sort)
  n=$(grep -c . <<<"$pairs"); echo "$pairs"
  report "$n distinct (app, container) pairs with logs in 5m: $(tr '\n' ' ' <<<"$pairs")"
  [[ $n -ge 12 ]]
}
ac_check AC-7.4 "Loki has logs from at least 12 distinct boutique (app, container) pairs in 5 minutes" check_logs
show_report

# AC-7.5 ---------------------------------------------------------------------------------------
# prints, for one trace: which services have spans, whether checkoutservice's server span descends from frontend,
# whether checkoutservice has the PaymentService/Charge client span, and whether paymentservice's span has a parent
analyze_trace() {
  curl -fsS -H 'Accept: application/json' "$TEMPO/api/traces/$1" | python3 -I -c '
import sys, json
d = json.load(sys.stdin); spans = {}
for rs in d.get("batches") or d.get("resourceSpans"):
    svc = [a["value"].get("stringValue") for a in rs["resource"]["attributes"] if a["key"] == "service.name"][0]
    for ss in rs.get("scopeSpans") or rs.get("instrumentationLibrarySpans"):
        for s in ss["spans"]:
            spans[s["spanId"]] = (svc, s["name"], s.get("parentSpanId"), s.get("kind"))
def ancestors(i):
    out = []
    while i in spans and spans[i][2] in spans:
        i = spans[i][2]; out.append(spans[i][0])
    return out
svcs = {v[0] for v in spans.values()}
chain = any(v[0] == "checkoutservice" and v[3] == "SPAN_KIND_SERVER" and "frontend" in ancestors(i) for i, v in spans.items())
charge = any(v[0] == "checkoutservice" and v[1].endswith("PaymentService/Charge") and "frontend" in ancestors(i) for i, v in spans.items())
pay = [i for i, v in spans.items() if v[0] == "paymentservice"]
linked = any("checkoutservice" in ancestors(i) for i in pay)
print(int({"frontend", "checkoutservice", "paymentservice"} <= svcs), int(chain), int(charge), int(linked), len(spans))
'
}
check_trace() {
  local orders q id ids res has chain charge linked n end
  orders=$(place_orders 3) || return 1
  echo "$orders"
  q='{ resource.service.name = "frontend" } && { resource.service.name = "checkoutservice" } && { resource.service.name = "paymentservice" }'
  end=$((SECONDS + 90))
  while (( SECONDS < end )); do
    ids=$(curl -fsS --get --data-urlencode "q=$q" --data-urlencode limit=10 --data-urlencode "start=$(($(date +%s) - 900))" \
      --data-urlencode "end=$(date +%s)" "$TEMPO/api/search" | jq -r '.traces[]?.traceID')
    for id in $ids; do
      res=$(analyze_trace "$id") || continue
      read -r has chain charge linked n <<<"$res"
      if [[ $has == 1 && $chain == 1 && $charge == 1 ]]; then
        echo "trace $id: $n spans, services ok, frontend->checkout parent chain ok, checkout Charge client span ok, payment span linked to parent: $linked"
        report "trace $id ($n spans): frontend, checkoutservice, paymentservice spans; checkout server span and its Charge call descend from frontend"
        report "paymentservice server span linked to its parent: $([[ $linked == 1 ]] && echo yes || echo 'NO (upstream v0.10.7 Node exporter drops parentSpanId; same trace id)')"
        return 0
      fi
    done
    wait_for 5 false || true
  done
  echo "no trace with frontend -> checkoutservice -> paymentservice spans"; return 1
}
ac_check AC-7.5 "Tempo has a trace with frontend, checkoutservice and paymentservice spans (frontend -> checkout chain)" check_trace
show_report

# AC-7.6 ---------------------------------------------------------------------------------------
extract_ca cert-manager boutique-root-ca tls.crt || { err "cannot extract the root CA certificate"; exit 2; }
NETRC=$(mktemp -p "$CACHE_DIR" netrc.XXXXXX); on_cleanup "rm -f '$NETRC'"
{ printf 'machine grafana.boutique.test login admin password '
  k -n "$NS" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo; } >"$NETRC"
chmod 644 "$NETRC"   # readable by the probe container's non-root user; gitignored and removed on exit
grafana() { probe_curl -sS --max-time 20 --cacert /certs/ca.crt --resolve "grafana.boutique.test:443:$GW_IP" --netrc-file "/certs/$(basename "$NETRC")" "$@"; }
check_grafana() {
  local code ds status titles want missing=0 f
  code=$(grafana -o /dev/null -w '%{http_code}' https://grafana.boutique.test/api/health) || return 1
  echo "https://grafana.boutique.test/api/health: $code"; [[ "$code" == 200 ]] || return 1
  for ds in prometheus loki tempo; do
    status=$(grafana "https://grafana.boutique.test/api/datasources/uid/$ds/health" | jq -r .status)
    echo "datasource $ds: $status"; report "datasource $ds: $status"; [[ "$status" == OK ]] || return 1
  done
  titles=$(grafana 'https://grafana.boutique.test/api/search?type=dash-db&limit=500' | jq -r '.[].title')
  while read -r want; do
    grep -qxF "$want" <<<"$titles" || { echo "missing dashboard: $want"; missing=$((missing + 1)); }
  done < <( for f in observability/dashboards/*.json; do jq -r .title "$f"; done
            printf '%s\n' 'Cilium Metrics' 'Cilium Operator' 'Hubble Metrics and Monitoring' 'Hubble / DNS Overview (Namespace)' \
              'Hubble / Network Overview (Namespace)' 'Hubble L7 HTTP Metrics by Workload' \
              'Kubernetes / Compute Resources / Cluster' 'Node Exporter / Nodes' )
  report "Grafana: $(grep -c . <<<"$titles") dashboards, $missing of the required ones missing"
  [[ $missing -eq 0 ]]
}
ac_check AC-7.6 "grafana.boutique.test 200 through the Gateway; 3 datasources healthy; Git dashboards present" check_grafana
show_report

# AC-7.8 ---------------------------------------------------------------------------------------
check_retention() {
  local prom loki lcomp tempo pvcs
  prom=$(curl -fsS "$PROM/api/v1/status/flags" | jq -r '.data["storage.tsdb.retention.time"]')
  loki=$(curl -fsS "$LOKI/config" | yq '.limits_config.retention_period')
  lcomp=$(curl -fsS "$LOKI/config" | yq '.compactor.retention_enabled')
  tempo=$(curl -fsS "$TEMPO/status/config" | grep -E '^\s+block_retention:' | head -1 | awk '{print $2}')
  pvcs=$(k -n "$NS" get pvc -o json | jq -r '.items[] | "\(.metadata.name)=\(.status.phase)"')
  echo "prometheus=$prom loki=$loki (compactor retention $lcomp) tempo=$tempo"; echo "$pvcs"
  report "retention: prometheus $prom, loki $loki (enforced: $lcomp), tempo $tempo; PVCs: $(grep -c '=Bound' <<<"$pvcs")/$(grep -c . <<<"$pvcs") Bound"
  [[ "$prom" == 3d && "$loki" =~ ^(48h0m0s|2d|48h)$ && "$lcomp" == true && "$tempo" =~ ^(24h0m0s|24h|1d)$ &&
     $(grep -c . <<<"$pvcs") -ge 3 && $(grep -vc '=Bound' <<<"$pvcs") -eq 0 ]]
}
ac_check AC-7.8 "retention 3d / 48h / 24h in effect and every PVC Bound" check_retention
show_report

# AC-7.9 (SHOULD) ------------------------------------------------------------------------------
check_correlation() {
  local ex id pod ds logs
  ex=$(curl -fsS --get --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket{service_name="frontend"}' \
    --data-urlencode "start=$(($(date +%s) - 900))" --data-urlencode "end=$(date +%s)" "$PROM/api/v1/query_exemplars")
  id=$(jq -r '[.data[].exemplars[].labels.trace_id] | map(select(. != null)) | last // empty' <<<"$ex")
  [[ -n "$id" ]] || { echo "no exemplar with a trace_id"; return 1; }
  pod=$(curl -fsS -H 'Accept: application/json' "$TEMPO/api/traces/$id" |
    jq -r '[(.batches // .resourceSpans)[].resource.attributes[] | select(.key=="k8s.pod.name") | .value.stringValue] | first // empty')
  [[ -n "$pod" ]] || { echo "exemplar trace $id not found in Tempo or without k8s.pod.name"; return 1; }
  logs=$(curl -fsS --get --data-urlencode "query=sum(count_over_time({namespace=\"boutique\", pod=\"$pod\"}[15m]))" \
    "$LOKI/loki/api/v1/query" | jq -r '.data.result[0].value[1] // "0"')
  ds=$(grafana https://grafana.boutique.test/api/datasources/uid/prometheus | jq -r '.jsonData.exemplarTraceIdDestinations[0].datasourceUid // "-"')
  ds+=" $(grafana https://grafana.boutique.test/api/datasources/uid/tempo | jq -r '.jsonData.tracesToLogsV2.datasourceUid // "-"')"
  echo "exemplar trace $id exists in Tempo (pod $pod); $logs log lines for that pod in 15m; datasource links: $ds"
  report "exemplar -> Tempo trace $id found; trace -> logs: $logs lines for pod $pod; links prometheus->tempo, tempo->loki: $ds (clicking in the UI not exercised)"
  [[ "$ds" == "tempo loki" && "$logs" -gt 0 ]]
}
ac_check AC-7.9 "exemplar -> Tempo and Tempo -> Loki links resolve to real data" check_correlation
show_report

# AC-7.10 --------------------------------------------------------------------------------------
check_cilium() {
  local sync health ds op bds bop late since restarts
  sync=$(k -n argocd get application cilium -o jsonpath='{.status.sync.status}')
  health=$(k -n argocd get application cilium -o jsonpath='{.status.health.status}')
  echo "cilium app: $sync/$health"
  ds=$(k -n kube-system get controllerrevisions -l k8s-app=cilium -o json | jq '[.items[].revision] | max')
  op=$(k -n kube-system get deploy cilium-operator -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
  # the snapshot taken before Phase 7's sync only describes the cluster it was taken on
  local created; created=$(k get ns kube-system -o jsonpath='{.metadata.creationTimestamp}')
  if [[ -s "$CACHE_DIR/phase7-cilium-ds-revision-before" && "$(cat "$CACHE_DIR/phase7-cilium-sync-before")" > "$created" ]]; then
    bds=$(cat "$CACHE_DIR/phase7-cilium-ds-revision-before"); bop=$(cat "$CACHE_DIR/phase7-cilium-operator-revision-before")
    since=$(cat "$CACHE_DIR/phase7-cilium-sync-before")
    late=$(k -n kube-system get pods -l app.kubernetes.io/part-of=cilium -o json | jq --arg t "$since" \
      '[.items[].status.containerStatuses[]?.lastState.terminated | select(. != null and .finishedAt > $t)] | length')
    echo "rollouts since the monitoring layer: agent $((ds - bds)), operator $((op - bop)); container restarts since: $late"
    report "cilium $sync/$health; rollouts for the monitoring layer: agent $((ds - bds)), operator $((op - bop)); container restarts since the sync: $late"
    (( ds - bds <= 1 && op - bop <= 1 && late == 0 )) || return 1
  else
    # rebuilt cluster (SPEC §6.7 AC-7.10 note): the layer is applied by the Argo CD adoption sync, so no container may
    # restart after it. Without an adoption record from this cluster, no restart at all is allowed.
    local adopted total
    adopted=$(sed -n "s/^ADOPTION_FINISHED='\(.*\)'$/\1/p" "$CACHE_DIR/cilium-adoption.env" 2>/dev/null || true)
    total=$(k -n kube-system get pods -l app.kubernetes.io/part-of=cilium -o json | jq '[.items[].status.containerStatuses[]?.restartCount] | add')
    if [[ -n "$adopted" && "$adopted" > "$created" ]]; then
      restarts=$(k -n kube-system get pods -l app.kubernetes.io/part-of=cilium -o json | jq --arg t "$adopted" \
        '[.items[].status.containerStatuses[]?.lastState.terminated | select(. != null and .finishedAt > $t)] | length')
      echo "installed with the layer, adopted at $adopted: agent revision $ds, operator revision $op, restarts after adoption $restarts (since install: $total)"
      report "cilium $sync/$health; installed with the layer: agent revision $ds, operator revision $op; container restarts after the adoption sync ($adopted): $restarts (since install: $total)"
    else
      restarts=$total
      echo "no adoption record from this cluster: agent revision $ds, operator revision $op, restarts $restarts"
      report "cilium $sync/$health; installed with the layer: agent revision $ds, operator revision $op, restarts $restarts"
    fi
    (( ds <= 2 && op <= 2 && restarts == 0 )) || return 1
  fi
  [[ "$sync" == Synced && "$health" == Healthy ]]
}
ac_check AC-7.10 "cilium app Synced with the monitoring layer; at most one planned rollout" check_cilium
show_report

# AC-7.7 (last: disturbs the application) ------------------------------------------------------
FAULT_APP=online-boutique
ALERTS_Q='ALERTS{alertstate="firing", alertname=~"BoutiqueDeploymentUnavailable|BoutiqueCheckoutErrorRateHigh"}'
restore_payment() {    # EXIT trap
  docker rm -f ac-alert-load >/dev/null 2>&1
  k -n boutique scale deploy/paymentservice --replicas=1 >/dev/null 2>&1
  resume_app "$FAULT_APP"
}
check_rules_loaded() {
  local rules want names
  rules=$(curl -fsS "$PROM/api/v1/rules?type=alert") || return 1
  names=$(yq -r '.spec.groups[].rules[].alert' observability/rules/boutique-alerts.yaml)
  while read -r want; do
    jq -e --arg a "$want" '[.data.groups[].rules[] | select(.name==$a and .health=="ok")] | length == 1' <<<"$rules" >/dev/null ||
      { echo "rule $want not loaded or unhealthy"; return 1; }
  done <<<"$names"
  echo "$(grep -c . <<<"$names") custom rules loaded and healthy"
  [[ $(grep -c . <<<"$names") -ge 6 ]]
}
check_alerts() {
  check_rules_loaded || return 1
  report "$(yq -r '.spec.groups[].rules[].alert' observability/rules/boutique-alerts.yaml | grep -c .) custom rules loaded, health ok"
  [[ $(pcount "$ALERTS_Q") -eq 0 ]] || { echo "alerts already firing before the fault:"; pq "$ALERTS_Q"; return 1; }
  # SPEC §7.4: stop reconciliation, otherwise selfHeal restores paymentservice at once
  suspend_app "$FAULT_APP"
  local t0=$SECONDS t_unavail="" t_checkout="" names
  k -n boutique scale deploy/paymentservice --replicas=0 >/dev/null || return 1
  # checkout traffic of our own, so the error ratio has data (loadgenerator alone checks out rarely)
  docker rm -f ac-alert-load >/dev/null 2>&1
  docker run -d --name ac-alert-load --label ac-test=true --network "$DOCKER_NETWORK" --entrypoint sh "$CURL_IMAGE" -c \
    "$ORDER_FN; i=0; while true; do i=\$((i+1)); order \$((i%20)); sleep 3; done" >/dev/null || return 1
  wait_for 60 false || true
  [[ "$(k -n boutique get deploy paymentservice -o jsonpath='{.spec.replicas}')" == 0 ]] ||
    { echo "Argo CD restored paymentservice: skip-reconcile did not hold"; return 1; }
  while (( SECONDS - t0 < ALERT_TIMEOUT )); do
    names=$(pq "$ALERTS_Q" | jq -r '.[] | select(.metric.alertname != "BoutiqueDeploymentUnavailable" or .metric.deployment == "paymentservice") | .metric.alertname')
    [[ -z "$t_unavail" ]] && grep -qx BoutiqueDeploymentUnavailable <<<"$names" && t_unavail=$((SECONDS - t0))
    [[ -z "$t_checkout" ]] && grep -qx BoutiqueCheckoutErrorRateHigh <<<"$names" && t_checkout=$((SECONDS - t0))
    [[ -n "$t_unavail" && -n "$t_checkout" ]] && break
    wait_for 10 false || true
  done
  echo "firing after: BoutiqueDeploymentUnavailable=${t_unavail:-never}s BoutiqueCheckoutErrorRateHigh=${t_checkout:-never}s"
  report "fault: paymentservice scaled to 0 with $FAULT_APP reconciliation paused; firing after BoutiqueDeploymentUnavailable ${t_unavail:-never}s, BoutiqueCheckoutErrorRateHigh ${t_checkout:-never}s (limit ${ALERT_TIMEOUT}s)"
  # restore (the load keeps running so successful checkouts bring the ratio down)
  k -n boutique scale deploy/paymentservice --replicas=1 >/dev/null; resume_app "$FAULT_APP"
  local t1=$SECONDS resolved=""
  while (( SECONDS - t1 < 900 )); do
    [[ $(pcount "$ALERTS_Q") -eq 0 ]] && { resolved=$((SECONDS - t1)); break; }
    wait_for 10 false || true
  done
  docker rm -f ac-alert-load >/dev/null 2>&1
  echo "resolved after restore: ${resolved:-not within 900}s"
  report "after restore: both alerts resolved after ${resolved:-NOT within 900}s"
  wait_for 300 bash -c "[[ \"\$(kubectl --context $CTX -n argocd get application $FAULT_APP -o jsonpath='{.status.sync.status}/{.status.health.status}')\" == Synced/Healthy ]]" ||
    { echo "$FAULT_APP not Synced/Healthy after restore"; return 1; }
  report "$FAULT_APP Synced/Healthy again; skip-reconcile annotation: '$(k -n argocd get application "$FAULT_APP" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}')'"
  [[ -n "$t_unavail" && -n "$t_checkout" && -n "$resolved" ]]
}
if [[ "${DESTRUCTIVE:-0}" == "1" ]]; then
  on_cleanup restore_payment
  ac_check AC-7.7 ">=6 custom rules; paymentservice at 0 fires both alerts within 10 min, resolved after restore" check_alerts
  show_report
else
  echo "       $(check_rules_loaded 2>&1 | tail -1)"
  ac_skip AC-7.7 "alert fault injection not run (set DESTRUCTIVE=1)"
fi

ac_summary 7
