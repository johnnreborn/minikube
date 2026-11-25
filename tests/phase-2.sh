#!/usr/bin/env bash
# Phase 2 acceptance tests (SPEC §6.2). Output: [PASS|FAIL|SKIP] AC-2.n ...; exit 1 if a MUST fails.
#   CONNECTIVITY=0  skip the (slow, ~10 min) `cilium connectivity test` for AC-2.4 while iterating. A skipped MUST is
#                   reported as SKIP and does NOT count as a pass, so a phase cannot be completed that way.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
REAL_NODES=5
GW_CRDS=(gatewayclasses gateways httproutes referencegrants grpcroutes backendtlspolicies tlsroutes)
CONNECTIVITY_LOG="$RESULTS_DIR/phase-2-connectivity-$(date -u +%Y%m%dT%H%M%SZ).log"

# AC-2.1 ---------------------------------------------------------------------------------------
check_nodes_ready() {
  local n; n=$(k get nodes --no-headers | wc -l)
  [[ $n -eq $REAL_NODES ]] || { echo "expected $REAL_NODES nodes, found $n"; return 1; }
  k wait --for=condition=Ready nodes --all --timeout=5m
}
ac_check AC-2.1 "all $REAL_NODES nodes Ready within 5 minutes" check_nodes_ready

# AC-2.2 ---------------------------------------------------------------------------------------
# `cilium status --wait` fails on any error/warning; the explicit readiness check makes sure every component
# (agent, envoy, operator, relay, ui) exists at all - status does not complain about a component that was never deployed.
check_components() {
  local rc=0 kind name want ready
  for item in ds/cilium ds/cilium-envoy deploy/cilium-operator deploy/hubble-relay deploy/hubble-ui; do
    kind=${item%%/*}; name=${item##*/}
    if [[ $kind == ds ]]; then
      want=$(k -n kube-system get "$item" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
      ready=$(k -n kube-system get "$item" -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
    else
      want=$(k -n kube-system get "$item" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
      ready=$(k -n kube-system get "$item" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    fi
    if [[ -n "$want" && "$want" -gt 0 && "${ready:-0}" == "$want" ]]; then echo "$name: $ready/$want ready"; else
      echo "$name: NOT ready (ready=${ready:-0} desired=${want:-missing})"; rc=1; fi
  done
  return $rc
}
check_cilium_status() {
  check_components || return 1
  cilium --context "$CTX" status --wait --wait-duration 5m --interactive=false
}
ac_check AC-2.2 "cilium agent/envoy/operator/relay/ui all Ready (cilium status --wait)" check_cilium_status

# AC-2.3 ---------------------------------------------------------------------------------------
check_kpr_maglev() {
  local pods pod out rc=0 count=0
  pods=$(k -n kube-system get pods -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
  while read -r pod node; do
    [[ -n "$pod" ]] || continue
    count=$((count + 1))
    out=$(k -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --verbose 2>&1) || { echo "$node: cilium-dbg status failed"; rc=1; continue; }
    if ! grep -Eq '^KubeProxyReplacement:[[:space:]]+True' <<<"$out"; then echo "$node: KubeProxyReplacement is not True"; rc=1; continue; fi
    if ! grep -Eq 'Backend Selection:[[:space:]]+Maglev' <<<"$out"; then echo "$node: backend selection is not Maglev"; rc=1; continue; fi
    if ! grep -Eq 'externalIPs:[[:space:]]+Enabled' <<<"$out"; then echo "$node: externalIPs not Enabled"; rc=1; continue; fi
    echo "$node: KubeProxyReplacement=True, Backend Selection=Maglev, externalIPs=Enabled"
  done <<<"$pods"
  [[ $count -eq $REAL_NODES ]] || { echo "expected $REAL_NODES cilium agents, found $count"; rc=1; }
  return $rc
}
ac_check AC-2.3 "every agent: KubeProxyReplacement True, service LB algorithm Maglev" check_kpr_maglev

# AC-2.4 ---------------------------------------------------------------------------------------
cleanup_connectivity_ns() {
  local ns
  ns=$(k get ns -o name 2>/dev/null | grep -E '^namespace/cilium-test' || true)
  [[ -n "$ns" ]] || return 0
  # shellcheck disable=SC2086
  k delete $ns --ignore-not-found --wait=true --timeout=3m
}
run_connectivity() {
  local rc
  cleanup_connectivity_ns >/dev/null 2>&1 || true   # leftovers of an earlier aborted run
  timeout 30m cilium --context "$CTX" connectivity test >"$CONNECTIVITY_LOG" 2>&1; rc=$?
  # strip terminal control sequences for the summary lines below
  sed -i 's/\x1b\[[0-9;]*[A-Za-z]//g' "$CONNECTIVITY_LOG"
  echo "full log: $CONNECTIVITY_LOG"
  grep -E -i 'tests? .*(successful|skipped|failed)|^❌|\[FAIL\]|failed' "$CONNECTIVITY_LOG" | tail -8
  (( rc == 0 )) || return 1
  grep -Eq 'All [0-9]+ tests .*successful' "$CONNECTIVITY_LOG"
}
on_cleanup cleanup_connectivity_ns   # registered here: ac_check runs the function in a subshell
if [[ "${CONNECTIVITY:-1}" == "0" ]]; then
  ac_skip AC-2.4 "cilium connectivity test not run (CONNECTIVITY=0) - a skipped MUST is not a pass"
else
  ac_check AC-2.4 "cilium connectivity test: all tests pass" run_connectivity
  # ac_check hides stdout on success; the summary and the skipped tests with cilium-cli's reason go to the result log
  if [[ -f "$CONNECTIVITY_LOG" ]]; then
    printf '       connectivity summary: %s\n' "$(grep -E -i 'All [0-9]+ tests' "$CONNECTIVITY_LOG" | tail -1)"
    printf '       full log: %s\n' "$CONNECTIVITY_LOG"
    echo "       skipped tests (reason as reported by cilium-cli):"
    grep -E -i 'skipping|skipped' "$CONNECTIVITY_LOG" | head -60 | sed 's/^/         /'
  fi
fi

# AC-2.5 ---------------------------------------------------------------------------------------
# `hubble observe --last 50` returns the 50 newest flows. A short burst of DNS lookups from pods on two different
# worker nodes right before the query makes sure more than one node has recent flows.
start_probe_pod() {  # <node> <name>
  local node=$1 name=$2
  k run "$name" --restart=Never --image="$CURL_IMAGE" --labels=ac-test=true \
    --overrides='{"spec":{"nodeName":"'"$node"'","securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$name"'","image":"'"$CURL_IMAGE"'","command":["sleep","300"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    >/dev/null && on_cleanup "kubectl --context $CTX delete pod $name --ignore-not-found --wait=false"
}
check_hubble_multinode() {
  local a=ac-hubble-a-$RANDOM b=ac-hubble-b-$RANDOM port out nodes attempt
  start_probe_pod boutique-worker2 "$a" && start_probe_pod boutique-worker3 "$b" || { echo "could not start probe pods"; return 1; }
  k wait --for=condition=Ready "pod/$a" "pod/$b" --timeout=120s >/dev/null || { echo "probe pods not Ready"; return 1; }
  port=$(_pf kube-system hubble-relay 80)
  hubble status --server "localhost:$port" 2>&1 | grep -E 'Connected Nodes|Flows/s' || true
  for attempt in 1 2 3; do
    for _ in 1 2 3; do
      k exec "$a" -- nslookup kubernetes.default >/dev/null 2>&1 || true
      k exec "$b" -- nslookup kubernetes.default >/dev/null 2>&1 || true
    done
    out=$(hubble observe --server "localhost:$port" --last 50 -o jsonpb 2>/dev/null || true)
    nodes=$(jq -r '.flow.node_name // empty' <<<"$out" 2>/dev/null | sort -u || true)
    echo "attempt $attempt: $(grep -c . <<<"$out") flows from nodes: $(tr '\n' ' ' <<<"$nodes")"
    [[ $(grep -c . <<<"$nodes") -ge 2 ]] && return 0
  done
  return 1
}
ac_check AC-2.5 "hubble observe --last 50 via relay returns flows from multiple nodes" check_hubble_multinode

# AC-2.6 ---------------------------------------------------------------------------------------
check_gateway() {
  local rc=0 accepted crds name bv ch missing=()
  accepted=$(k get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ "$accepted" == "True" ]] && echo "GatewayClass cilium: Accepted=True" || { echo "GatewayClass cilium: Accepted='$accepted'"; rc=1; }
  crds=$(k get crd -o jsonpath='{range .items[?(@.spec.group=="gateway.networking.k8s.io")]}{.metadata.name}{"\n"}{end}')
  for p in "${GW_CRDS[@]}"; do grep -qx "$p.gateway.networking.k8s.io" <<<"$crds" || missing+=("$p"); done
  (( ${#missing[@]} == 0 )) || { echo "missing Gateway API CRDs: ${missing[*]}"; rc=1; }
  while read -r name; do
    [[ -n "$name" ]] || continue
    bv=$(k get crd "$name" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
    ch=$(k get crd "$name" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}')
    if [[ "$bv" == "$GATEWAY_API_VERSION" && "$ch" == "$GATEWAY_API_CHANNEL" ]]; then echo "$name: $bv ($ch)"; else
      echo "$name: bundle-version=$bv channel=$ch (want $GATEWAY_API_VERSION / $GATEWAY_API_CHANNEL)"; rc=1; fi
  done <<<"$crds"
  return $rc
}
ac_check AC-2.6 "GatewayClass cilium Accepted; 7 Gateway API CRDs are $GATEWAY_API_VERSION ($GATEWAY_API_CHANNEL)" check_gateway

# AC-2.7 ---------------------------------------------------------------------------------------
check_dns() {
  local svc_ip out
  k -n kube-system rollout status deploy/coredns --timeout=120s || return 1
  svc_ip=$(k get svc kubernetes -o jsonpath='{.spec.clusterIP}')
  # netshoot (BIND nslookup) applies the pod's search domains; busybox nslookup in the curl image does not do so
  # for dotted names such as kubernetes.default and would report NXDOMAIN although cluster DNS is fine
  out=$(TEST_POD_IMAGE="$NETSHOOT_IMAGE" test_pod default "" "nslookup kubernetes.default" 2>&1) || { echo "$out"; return 1; }
  echo "$out"
  grep -q "$svc_ip" <<<"$out"
}
ac_check AC-2.7 "CoreDNS Ready; test pod resolves kubernetes.default" check_dns

# AC-2.8 ---------------------------------------------------------------------------------------
check_infra_placement() {
  local rc=0 sel pod node pool
  for sel in "io.cilium/app=operator:cilium-operator" "k8s-app=hubble-relay:hubble-relay" "k8s-app=hubble-ui:hubble-ui"; do
    local label=${sel%%:*} name=${sel##*:}
    local pods; pods=$(k -n kube-system get pods -l "$label" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
    [[ -n "$pods" ]] || { echo "$name: no pods found"; rc=1; continue; }
    while read -r pod node; do
      [[ -n "$pod" ]] || continue
      pool=$(k get node "$node" -o jsonpath='{.metadata.labels.node\.boutique\.io/pool}')
      if [[ "$pool" == infra ]]; then echo "$name ($pod) -> $node (pool=infra)"; else echo "$name ($pod) -> $node (pool='$pool', want infra)"; rc=1; fi
    done <<<"$pods"
  done
  return $rc
}
ac_check AC-2.8 "hubble-relay, hubble-ui and cilium-operator run on the infra node" check_infra_placement

ac_summary 2
