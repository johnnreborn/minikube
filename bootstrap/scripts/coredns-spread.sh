#!/usr/bin/env bash
# CoreDNS placement (ADR-0013), part of `make cni`. Idempotent.
# kubeadm only PREFERS to spread the two replicas, and while the cluster is created only one node is Ready, so both can
# land on the same node: losing that node stops all cluster DNS. This is a bootstrap exception (ARCHITECTURE §10.1):
# CoreDNS is managed by kubeadm, not by Argo CD.
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd kubectl jq

CONTEXT=kind-boutique
k() { kubectl --context "$CONTEXT" -n kube-system "$@"; }

PATCH='{"spec":{"template":{"spec":{"topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname",
  "whenUnsatisfiable":"DoNotSchedule","nodeTaintsPolicy":"Honor",
  "labelSelector":{"matchLabels":{"k8s-app":"kube-dns"}},"matchLabelKeys":["pod-template-hash"]}]}}}}'
k patch deployment coredns --type=strategic -p "$PATCH"
k rollout status deployment/coredns --timeout=5m

pods=$(k get pods -l k8s-app=kube-dns -o json)
nodes=$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running") | .spec.nodeName] | unique | length' <<<"$pods")
[[ "$nodes" -ge 2 ]] || die "CoreDNS replicas run on $nodes node(s); expected 2 different nodes"
ok "CoreDNS replicas run on $nodes different nodes"
