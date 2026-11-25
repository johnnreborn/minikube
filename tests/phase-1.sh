#!/usr/bin/env bash
# Phase 1 acceptance tests (SPEC §6.1). Output: [PASS|FAIL|SKIP] AC-1.n ...; exit 1 if a MUST fails.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

CTX=kind-boutique
NETWORK=kind-boutique
k() { kubectl --context "$CTX" "$@"; }
ac_should AC-1.5

# node name -> expected "pool|zone|taint" (ARCHITECTURE §4); zone/taint "-" means absent
declare -A WANT=(
  [boutique-worker]="infra|-|node.boutique.io/dedicated=infra:NoSchedule"
  [boutique-worker2]="app|zone-a|-"
  [boutique-worker3]="app|zone-b|-"
  [boutique-worker4]="app|zone-c|-"
)

# AC-1.1 ---------------------------------------------------------------------------------------
check_nodes() {
  local cp workers total
  total=$(k get nodes --no-headers | wc -l)
  cp=$(k get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
  workers=$((total - cp))
  echo "nodes: total=$total control-plane=$cp workers=$workers"
  [[ $total -eq 5 && $cp -eq 1 && $workers -eq 4 ]]
}
ac_check AC-1.1 "5 nodes registered (1 control-plane, 4 workers)" check_nodes

# AC-1.2 ---------------------------------------------------------------------------------------
# Taints placed by the node lifecycle controller (not-ready/unreachable) are conditions, not placement
# design: they exist on every node while it is NotReady (no CNI until Phase 2) and vanish when Ready.
# Any OTHER taint still has to match ARCHITECTURE §4 exactly.
node_taints() {  # <node> → sorted "key=value:effect" lines without lifecycle condition taints
  k get node "$1" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' |
    grep -v -E '^node\.kubernetes\.io/(not-ready|unreachable)=' | sort
}

check_labels_taints() {
  local rc=0 n want pool zone taint got_pool got_zone got_taints
  # control plane: default taint only
  local cp; cp=$(k get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
  [[ "$cp" == boutique-control-plane ]] || { echo "control-plane node is '$cp', want boutique-control-plane"; rc=1; }
  got_taints=$(node_taints "$cp")
  [[ "$got_taints" == "node-role.kubernetes.io/control-plane=:NoSchedule" ]] || { echo "$cp taints: '$got_taints'"; rc=1; }
  for n in "${!WANT[@]}"; do
    IFS='|' read -r pool zone taint <<<"${WANT[$n]}"
    got_pool=$(k get node "$n" -o jsonpath='{.metadata.labels.node\.boutique\.io/pool}' 2>/dev/null) || { echo "node $n missing"; rc=1; continue; }
    got_zone=$(k get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    got_taints=$(node_taints "$n")
    [[ "$got_pool" == "$pool" ]] || { echo "$n pool='$got_pool' want '$pool'"; rc=1; }
    [[ "${got_zone:--}" == "$zone" ]] || { echo "$n zone='${got_zone:--}' want '$zone'"; rc=1; }
    [[ "${got_taints:--}" == "$taint" ]] || { echo "$n taints='${got_taints:--}' want '$taint'"; rc=1; }
  done
  return $rc
}
ac_check AC-1.2 "labels and taints match ARCHITECTURE §4" check_labels_taints

# AC-1.3 ---------------------------------------------------------------------------------------
check_no_proxy_cni() {
  local ds; ds=$(k -n kube-system get ds -o name)
  echo "daemonsets in kube-system: ${ds:-<none>}"
  ! grep -q -E 'kube-proxy|kindnet' <<<"$ds"
}
ac_check AC-1.3 "no kube-proxy / kindnet DaemonSet" check_no_proxy_cni

# AC-1.4 ---------------------------------------------------------------------------------------
check_network() {
  local rc=0 subnet n ip nets
  subnet=${DOCKER_SUBNET}
  docker network inspect "$NETWORK" >/dev/null 2>&1 || { echo "docker network $NETWORK missing"; return 1; }
  for n in $(k get nodes -o jsonpath='{.items[*].metadata.name}'); do
    nets=$(docker inspect "$n" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null) || { echo "container $n not found"; rc=1; continue; }
    [[ "$nets" == "$NETWORK " ]] || { echo "$n networks: '$nets' (want only $NETWORK)"; rc=1; }
    ip=$(k get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    python3 -I -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$ip" "$subnet" \
      || { echo "$n InternalIP $ip not in $subnet"; rc=1; }
  done
  return $rc
}
ac_check AC-1.4 "all node IPs in $DOCKER_SUBNET on docker network $NETWORK" check_network

# AC-1.5 (SHOULD) ------------------------------------------------------------------------------
# "responds" = the TCP connection was accepted. curl exit 7 (refused) and 28 (timeout) are failures;
# TLS endpoints answer without our CA, so exit 60/35/56 etc. still prove the port is open (no -k needed).
check_cp_metrics() {
  local ip rc=0 spec port scheme code
  ip=$(k get node boutique-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  for spec in "https 10257 controller-manager" "https 10259 scheduler" "http 2381 etcd"; do
    read -r scheme port name <<<"$spec"
    probe_curl -sS -o /dev/null --connect-timeout 5 --max-time 10 "$scheme://$ip:$port/metrics" >/dev/null 2>&1; code=$?
    if [[ $code -eq 7 || $code -eq 28 || $code -eq 6 ]]; then echo "$name $ip:$port not reachable (curl exit $code)"; rc=1; else echo "$name $ip:$port responds (curl exit $code)"; fi
  done
  return $rc
}
ac_check AC-1.5 "controller-manager 10257 / scheduler 10259 / etcd 2381 reachable on the node IP" check_cp_metrics

# AC-1.6 ---------------------------------------------------------------------------------------
check_idempotent() {
  local before after out i
  before=$(docker ps -q --filter "label=io.x-k8s.kind.cluster=boutique" | sort | tr '\n' ' ')
  for i in 1 2; do
    out=$(make --no-print-directory cluster-up 2>&1) || { echo "run $i failed:"; echo "$out" | tail -15; return 1; }
    grep -q 'already exists' <<<"$out" || { echo "run $i: output lacks 'already exists':"; echo "$out" | tail -10; return 1; }
  done
  after=$(docker ps -q --filter "label=io.x-k8s.kind.cluster=boutique" | sort | tr '\n' ' ')
  [[ "$before" == "$after" ]] || { echo "node containers changed: [$before] -> [$after]"; return 1; }
}
ac_check AC-1.6 "make cluster-up twice: no error, 'already exists', containers untouched" check_idempotent

ac_summary 1
