#!/usr/bin/env bash
# Delete the kind cluster and the kind-boutique docker network. DESTRUCTIVE — only on explicit user request.
# Requires confirmation: type the cluster name on a TTY, or pass CONFIRM=yes for a user-approved non-interactive run.
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmd docker kind

CLUSTER=boutique
NETWORK=kind-boutique

if [[ "${CONFIRM:-}" != "yes" ]]; then
  [[ -t 0 ]] || die "refusing to delete without confirmation (run on a terminal, or CONFIRM=yes make down after the user approved)"
  read -r -p "This deletes kind cluster '$CLUSTER' and docker network '$NETWORK'. Type '$CLUSTER' to continue: " answer
  [[ "$answer" == "$CLUSTER" ]] || die "aborted"
fi

clusters=$(kind get clusters 2>/dev/null || true)
if grep -qx "$CLUSTER" <<<"$clusters"; then
  kind delete cluster --name "$CLUSTER"
else
  log "kind cluster '$CLUSTER' not found"
fi
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  docker network rm "$NETWORK" >/dev/null && ok "docker network $NETWORK removed"
else
  log "docker network $NETWORK not found"
fi
