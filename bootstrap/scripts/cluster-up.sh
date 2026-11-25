#!/usr/bin/env bash
# Phase 1: fixed Docker network + 5-node kind cluster. Idempotent (SPEC §5.2 "생성 절차").
#   1. docker network kind-boutique (create if absent; if present its subnet must match DOCKER_SUBNET)
#   2. kind create cluster (skipped if the cluster already exists)
#   3. kubeconfig context kind-boutique
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd docker kind kubectl python3

NETWORK=kind-boutique
CLUSTER=boutique
CONTEXT=kind-boutique
CONFIG="$REPO_ROOT/bootstrap/kind/cluster.yaml"
EXPECTED_NODES=5

docker info >/dev/null 2>&1 || die "docker daemon not reachable"
[[ -f "$CONFIG" ]] || die "missing $CONFIG"

# the config must use the digest-pinned image from versions.env
while read -r img; do
  [[ "$img" == "$KIND_NODE_IMAGE" ]] || die "cluster.yaml node image '$img' != versions.env KIND_NODE_IMAGE '$KIND_NODE_IMAGE'"
done < <(awk '/^[[:space:]]*image:/ {print $2}' "$CONFIG")

# gateway = first host address of the subnet (172.30.0.0/16 -> 172.30.0.1)
GATEWAY=$(python3 -I -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1],strict=False); print(n.network_address+1)' "$DOCKER_SUBNET")

# 1. network ------------------------------------------------------------------------------------
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  have_subnets=$(docker network inspect "$NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
  if [[ " $have_subnets " == *" $DOCKER_SUBNET "* ]]; then
    ok "docker network $NETWORK already exists ($DOCKER_SUBNET)"
  else
    die "docker network $NETWORK exists with subnet(s) '${have_subnets% }', expected $DOCKER_SUBNET — refusing to continue (remove the network or fix DOCKER_SUBNET)"
  fi
else
  log "creating docker network $NETWORK ($DOCKER_SUBNET, gw $GATEWAY)"
  docker network create --driver bridge --subnet "$DOCKER_SUBNET" --gateway "$GATEWAY" "$NETWORK" >/dev/null
  ok "docker network $NETWORK created"
fi

# 2. cluster ------------------------------------------------------------------------------------
# capture first: `cmd | grep -q` under pipefail can fail with SIGPIPE
clusters=$(kind get clusters 2>/dev/null || true)
if grep -qx "$CLUSTER" <<<"$clusters"; then
  ok "kind cluster '$CLUSTER' already exists — skipping creation"
else
  log "creating kind cluster '$CLUSTER' (first run pulls the node image, ~1 GB)"
  KIND_EXPERIMENTAL_DOCKER_NETWORK="$NETWORK" kind create cluster --config "$CONFIG"
  ok "kind cluster '$CLUSTER' created"
fi

# 3. kubeconfig context -------------------------------------------------------------------------
contexts=$(kubectl config get-contexts -o name 2>/dev/null || true)
if ! grep -qx "$CONTEXT" <<<"$contexts"; then
  log "context $CONTEXT missing — exporting kubeconfig"
  kind export kubeconfig --name "$CLUSTER"
fi
kubectl config use-context "$CONTEXT" >/dev/null
kubectl --context "$CONTEXT" cluster-info >/dev/null || die "cannot reach the API server via context $CONTEXT"

nodes=$(kubectl --context "$CONTEXT" get nodes --no-headers 2>/dev/null | wc -l)
if (( nodes == EXPECTED_NODES )); then
  ok "context $CONTEXT active, $nodes nodes registered (NotReady until Cilium is installed in Phase 2)"
else
  die "expected $EXPECTED_NODES nodes, found $nodes — cluster '$CLUSTER' is inconsistent; ask before deleting it"
fi
