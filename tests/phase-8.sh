#!/usr/bin/env bash
# Phase 8 acceptance tests (SPEC §6.8). Output: [PASS|FAIL|SKIP] AC-8.n ...; exit 1 if a MUST fails.
# Negative tests send traffic with the REAL workload identity from ephemeral containers (SPEC §7.3; the containers stay
# in the pods, named with a timestamp) and from throwaway pods in the unprotected `default` namespace.
# AC-8.3 re-runs selected ACs of phases 5-7 (AC_ONLY); AC-8.1 reads the report of scripts/policy-audit.sh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
NS=boutique
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
ac_should AC-8.1 AC-8.7 AC-8.8 AC-8.10
REPORT=$(mktemp); on_cleanup "rm -f '$REPORT'"
report() { echo "$*" >>"$REPORT"; }
show_report() { sed 's/^/       /' "$REPORT"; : >"$REPORT"; }
BOUTIQUE_WORKLOADS='frontend|frontend-canary|loadgenerator|adservice|cartservice|checkoutservice|currencyservice|emailservice|paymentservice|productcatalogservice|recommendationservice|shippingservice|redis-cart'

HUBBLE="localhost:$(_pf kube-system hubble-relay 80)"
PROM=http://127.0.0.1:$(_pf observability kube-prometheus-stack-prometheus 9090)
pod_of() { k -n "${2:-$NS}" get pods -l "app=$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }

# AC-8.1 (SHOULD) ------------------------------------------------------------------------------
check_audit_report() {
  local f=$CACHE_DIR/policy-audit-last.json
  [[ -s "$f" ]] || { echo "no audit report ($f): run scripts/policy-audit.sh during the audit window"; return 1; }
  jq -c '{start, end, minutes, audit_flows, unexpected, l7_requests, l7_denied}' "$f"
  report "audit window $(jq -r '.start + " .. " + .end' "$f") ($(jq .minutes "$f") min): $(jq .audit_flows "$f") AUDIT flows, $(jq '.unexpected|length' "$f") unexpected; $(jq .l7_requests "$f") L7 requests, $(jq .l7_denied "$f") L7 denials"
  [[ $(jq .minutes "$f") -ge 15 && $(jq '.unexpected|length' "$f") -eq 0 && $(jq .l7_denied "$f") -eq 0 && $(jq .l7_requests "$f") -gt 0 ]]
}
ac_check AC-8.1 "audit window of 15 min: no unexpected AUDIT verdict, no L7 denial (expected list documented)" check_audit_report
show_report

# AC-8.2 ---------------------------------------------------------------------------------------
check_enforcement() {
  local cm agents p eps total=0 bad=0
  cm=$(k -n kube-system get cm cilium-config -o jsonpath='{.data.policy-audit-mode}')
  [[ "$cm" == false ]] || { echo "cilium-config policy-audit-mode=$cm"; return 1; }
  for p in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
    k -n kube-system exec "$p" -c cilium-agent -- cilium-dbg config -a 2>/dev/null | grep -Eq 'PolicyAuditMode +: +(false|Disabled)' ||
      { echo "$p: policy audit mode still on"; bad=$((bad + 1)); }
    eps=$(k -n kube-system exec "$p" -c cilium-agent -- cilium-dbg endpoint list -o json 2>/dev/null | jq -r '.[] |
      select([.status.labels["security-relevant"][]?] | any(. == "k8s:io.kubernetes.pod.namespace=boutique")) |
      "\(.id) \([.status.labels["security-relevant"][] | select(startswith("k8s:app="))][0]) \(.status.policy.realized["policy-enabled"])"')
    while read -r id app mode; do
      [[ -n "$id" ]] || continue
      total=$((total + 1))
      [[ "$mode" == both ]] || { echo "$p endpoint $id $app: policy-enabled=$mode"; bad=$((bad + 1)); }
    done <<<"$eps"
  done
  local pods; pods=$(k -n "$NS" get pods --field-selector=status.phase=Running --no-headers | wc -l)
  echo "boutique endpoints: $total (running pods $pods), not fully enforced: $bad"
  report "policy-audit-mode=false on all agents; boutique endpoints with ingress+egress enforcement: $((total - bad))/$total (running pods: $pods)"
  [[ $bad -eq 0 && $total -eq $pods && $total -gt 0 ]]
}
ac_check AC-8.2 "audit mode off; every boutique endpoint enforces ingress and egress" check_enforcement
show_report

# AC-8.3 ---------------------------------------------------------------------------------------
check_regression() {
  local out rc=0 phase only
  for spec in "5:AC-5.4,AC-5.5,AC-5.6" "6:AC-6.3,AC-6.6" "7:AC-7.4,AC-7.5"; do
    phase=${spec%%:*}; only=${spec#*:}
    out=$(AC_ONLY="$only" OBSERVE_SECONDS=0 bash "tests/phase-$phase.sh" 2>&1)
    echo "$out" | grep -E '^\[(PASS|FAIL|SKIP)\]|^ {7}' | head -12
    for id in ${only//,/ }; do
      grep -q "^\[PASS\] $id " <<<"$out" || { echo "$id did not pass"; rc=1; }
    done
    report "$(grep -E '^\[(PASS|FAIL|SKIP)\]' <<<"$out" | cut -c1-90 | tr '\n' ';')"
  done
  return $rc
}
ac_check AC-8.3 "regression: AC-5.4 5.5 5.6 6.3 6.6 7.4 7.5 pass again" check_regression
show_report

# AC-8.4 ---------------------------------------------------------------------------------------
# blocked <label> <curl exit code> → a refused/timed-out connection, never an HTTP or TLS answer
blocked() { [[ "$2" == 28 || "$2" == 7 ]]; }
# drop_seen <hubble filter...> → a DROPPED flow with drop reason POLICY_DENIED in the last 3 minutes
drop_seen() {
  hubble observe --server "$HUBBLE" --verdict DROPPED --since 3m -o jsonpb "$@" 2>/dev/null |
    jq -e -s 'map(select(.flow.drop_reason_desc == "POLICY_DENIED")) | length > 0' >/dev/null
}
DEFAULT_PROBE=ac-test-np-$RANDOM
on_cleanup "kubectl --context $CTX -n default delete pod $DEFAULT_PROBE --ignore-not-found --wait=false"
check_negative() {
  local fe lg ck rc=0 r ip
  fe=$(pod_of frontend); lg=$(pod_of loadgenerator); ck=$(pod_of checkoutservice)
  # a pod in the unprotected default namespace, as "another namespace"
  k -n default run "$DEFAULT_PROBE" --restart=Never --image="$CURL_IMAGE" --labels=ac-test=true --override-type=strategic \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$DEFAULT_PROBE"'","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    --command -- sleep 600 >/dev/null || return 1
  k -n default wait --for=condition=Ready "pod/$DEFAULT_PROBE" --timeout=120s >/dev/null || return 1
  dflt() { k -n default exec "$DEFAULT_PROBE" -- curl -s -o /dev/null -m 5 "$@"; echo $?; }
  one() {  # <n> <description> <exit code> <hubble filter...>
    local n=$1 d=$2 code=$3; shift 3
    local ok=no ev=no
    blocked "$d" "$code" && ok=yes
    sleep 3; drop_seen "$@" && ev=yes
    echo "$n $d: curl exit $code (blocked=$ok), Hubble DROPPED/POLICY_DENIED: $ev"
    report "$n $d: blocked=$ok (curl $code), Hubble policy drop: $ev"
    [[ $ok == yes && $ev == yes ]] || rc=1
  }
  r=$(debug_curl_rc "$NS" "$fe" server -o /dev/null -m 5 http://paymentservice:50051/) || r="err"
  one ① "frontend -> paymentservice:50051" "${r%% *}" --from-pod "$NS/$fe" --to-port 50051
  r=$(debug_curl_rc "$NS" "$lg" main -o /dev/null -m 5 http://cartservice:7070/) || r="err"
  one ② "loadgenerator -> cartservice:7070" "${r%% *}" --from-pod "$NS/$lg" --to-port 7070
  r=$(debug_curl_rc "$NS" "$ck" server -o /dev/null -m 5 https://1.1.1.1/) || r="err"
  one ③ "checkoutservice -> 1.1.1.1:443 (internet)" "${r%% *}" --from-pod "$NS/$ck" --to-ip 1.1.1.1
  r=$(debug_curl_rc "$NS" "$ck" server -o /dev/null -m 5 https://kubernetes.default.svc/) || r="err"
  one ④ "checkoutservice -> kube-apiserver" "${r%% *}" --from-pod "$NS/$ck" --to-port 6443
  ip=$(k -n "$NS" get pod "$fe" -o jsonpath='{.status.podIP}')
  one ⑤ "default-namespace pod -> frontend:8080" "$(dflt "http://$ip:8080/")" --from-pod "default/$DEFAULT_PROBE" --to-port 8080
  r=$(debug_curl_rc "$NS" "$fe" server -o /dev/null -m 5 http://grafana.observability.svc/) || r="err"
  one ⑥ "frontend -> grafana:3000" "${r%% *}" --from-pod "$NS/$fe" --to-port 3000
  one ⑥b "default-namespace pod -> grafana:3000 (observability ingress isolation)" \
    "$(dflt "http://$(k -n observability get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.podIP}'):3000/")" \
    --from-pod "default/$DEFAULT_PROBE" --to-port 3000
  r=$(debug_curl_rc "$NS" "$fe" server -o /dev/null -m 5 http://argocd-server.argocd.svc/) || r="err"
  one ⑦ "frontend -> argocd-server:8080" "${r%% *}" --from-pod "$NS/$fe" --to-port 8080 --to-namespace argocd
  one ⑦b "default-namespace pod -> argocd-server:8080 (argocd ingress isolation)" \
    "$(dflt "http://$(k -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.podIP}'):8080/")" \
    --from-pod "default/$DEFAULT_PROBE" --to-namespace argocd
  return $rc
}
ac_check AC-8.4 "7 negative paths (+2 ingress-isolation checks) blocked with Hubble DROPPED (Policy denied)" check_negative
show_report

# AC-8.5 ---------------------------------------------------------------------------------------
GRPC=(-o /dev/null -w '%{http_code}' -m 10 --http2-prior-knowledge -X POST -H 'content-type: application/grpc')
check_l7() {
  local ck add get
  ck=$(pod_of checkoutservice)
  add=$(debug_curl_rc "$NS" "$ck" server "${GRPC[@]}" http://cartservice:7070/hipstershop.CartService/AddItem) || return 1
  get=$(debug_curl_rc "$NS" "$ck" server "${GRPC[@]}" http://cartservice:7070/hipstershop.CartService/GetCart) || return 1
  echo "AddItem: exit/code '$add'  GetCart: exit/code '$get'"
  report "checkoutservice identity: CartService/AddItem -> HTTP ${add#* }, CartService/GetCart -> HTTP ${get#* } (passes the proxy; gRPC status in trailers)"
  [[ "${add#* }" == "403 " && "${get#* }" == "200 " ]]
}
ac_check AC-8.5 "L7: checkoutservice -> CartService/AddItem 403, GetCart 200" check_l7
show_report

# AC-8.6 ---------------------------------------------------------------------------------------
check_positive() {
  local otel dns
  otel=$(hubble observe --server "$HUBBLE" --namespace "$NS" --to-namespace observability --to-port 4317 --verdict FORWARDED \
    --since 5m -o jsonpb 2>/dev/null | jq -r '.flow.source.workloads[0].name // empty' | sort -u | tr '\n' ' ')
  dns=$(hubble observe --server "$HUBBLE" --namespace "$NS" --protocol dns --since 5m -o jsonpb 2>/dev/null |
    jq -r '.flow.l7.dns.query // empty' | sort | uniq -c | sort -rn | head -5 | awk '{print $2}' | tr '\n' ' ')
  echo "OTLP 4317 FORWARDED from: $otel"; echo "DNS queries seen: $dns"
  report "OTLP to otel-collector:4317 forwarded from: $otel"
  report "DNS queries with names in Hubble: $dns"
  [[ $(wc -w <<<"$otel") -ge 5 && "$dns" == *svc.cluster.local* ]]
}
ac_check AC-8.6 "tracing services reach otel-collector:4317; DNS queries visible with names" check_positive
show_report

# AC-8.7 (SHOULD) ------------------------------------------------------------------------------
check_hubble_http() {
  local w
  w=$(curl -fsS --get --data-urlencode 'query=sum by (destination_workload) (rate(hubble_http_requests_total{destination_namespace="boutique"}[5m])) > 0' \
    "$PROM/api/v1/query" | jq -r '.data.result[].metric.destination_workload' | sort | tr '\n' ' ')
  echo "$w"; report "Hubble HTTP request series for: $w"
  local s n=0
  for s in adservice cartservice checkoutservice currencyservice emailservice paymentservice productcatalogservice recommendationservice shippingservice; do
    [[ " $w " == *" $s "* ]] && n=$((n + 1))
  done
  [[ $n -eq 9 ]]
}
ac_check AC-8.7 "Hubble HTTP metrics have series for all 9 boutique gRPC services" check_hubble_http
show_report

# AC-8.8 (SHOULD) ------------------------------------------------------------------------------
check_psa() {
  local level warn notrun events
  level=$(k get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
  warn=$(k label --dry-run=server ns "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite 2>&1 | grep -c '^Warning:')
  notrun=$(k -n "$NS" get pods --no-headers | awk '$3 != "Running"' | wc -l)
  events=$(k -n "$NS" get events --field-selector reason=FailedCreate -o json | jq '[.items[] | select(.message | test("PodSecurity"))] | length')
  echo "enforce=$level warnings=$warn non-Running=$notrun PodSecurity FailedCreate events=$events"
  report "boutique PSA enforce=$level, restricted violations=$warn, non-Running pods=$notrun, PodSecurity FailedCreate events=$events"
  [[ "$level" == restricted && $warn -eq 0 && $notrun -eq 0 && $events -eq 0 ]]
}
ac_check AC-8.8 "boutique PSA enforce=restricted, no violation, every pod Running" check_psa
show_report

# AC-8.9 ---------------------------------------------------------------------------------------
DENY_APP=ac-test-apps-policy-deny
on_cleanup "kubectl --context $CTX -n argocd delete application $DENY_APP --ignore-not-found --wait=false"
check_apps_project() {
  local repo kcfg out msg
  repo=$(yq -r '.spec.source.repoURL' gitops/root.yaml)
  k apply -f - >/dev/null <<EOF || return 1
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $DENY_APP
  namespace: argocd
  labels: {ac-test: "true"}
spec:
  project: apps
  source: {repoURL: $repo, targetRevision: $GITOPS_REVISION, path: tests/fixtures/apps-policy-deny}
  destination: {server: https://kubernetes.default.svc, namespace: $NS}
EOF
  kcfg=$(mktemp); chmod 600 "$kcfg"
  kubectl config view --minify --flatten --context "$CTX" >"$kcfg"
  kubectl --kubeconfig "$kcfg" config set-context --current --namespace argocd >/dev/null
  out=$(KUBECONFIG="$kcfg" argocd --core app sync "$DENY_APP" --timeout 120 2>&1); rm -f "$kcfg"
  msg="$out $(k -n argocd get application "$DENY_APP" -o jsonpath='{.status.operationState.message} {.status.conditions[*].message}')"
  k -n argocd delete application "$DENY_APP" --ignore-not-found >/dev/null
  echo "$msg" | tr -s ' \n' ' ' | cut -c1-400; echo
  if k -n "$NS" get networkpolicy,ciliumnetworkpolicy ac-test-apps-policy-deny >/dev/null 2>&1; then echo "a policy object was created!"; return 1; fi
  report "apps project sync of a NetworkPolicy + CNP into boutique: $(grep -oE '[^ ]*(NetworkPolicy|CiliumNetworkPolicy)[^.]*not permitted[^.]*' <<<"$msg" | head -2 | tr '\n' ';')"
  grep -Eqi 'NetworkPolicy.*not permitted|not permitted.*NetworkPolicy' <<<"$msg"
}
ac_check AC-8.9 "apps project refuses to sync NetworkPolicy / CiliumNetworkPolicy into boutique" check_apps_project
show_report

# AC-8.10 (SHOULD) -----------------------------------------------------------------------------
check_drop_alert() {
  local t0=$SECONDS
  # AC-8.4 produced the drops; the rule needs its `for: 2m`
  wait_for 420 bash -c "curl -fsS --get --data-urlencode 'query=ALERTS{alertname=\"HubblePolicyDropsDetected\",alertstate=\"firing\"}' '$PROM/api/v1/query' | jq -e '.data.result | length > 0' >/dev/null" ||
    { echo "HubblePolicyDropsDetected not firing within 420s"; return 1; }
  echo "firing after $((SECONDS - t0))s of waiting"
  report "HubblePolicyDropsDetected firing $((SECONDS - t0))s after the negative tests finished"
}
ac_check AC-8.10 "HubblePolicyDropsDetected fires after the negative tests" check_drop_alert
show_report

ac_summary 8
