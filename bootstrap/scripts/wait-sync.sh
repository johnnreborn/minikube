#!/usr/bin/env bash
# `make wait-sync`: wait until every Argo CD Application has compared the commit that is currently on the remote
# branch (Argo CD polls Git, ~2-3 min) and is Synced + Healthy. WAIT_SYNC_TIMEOUT seconds (default 900).
# A manual-sync app (cilium) that is OutOfSync after a Git change makes this time out on purpose: review its diff
# and sync it by hand (SPEC §5.3).
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd kubectl jq git

CONTEXT=kind-boutique
ARGO_NS=argocd
TIMEOUT=${WAIT_SYNC_TIMEOUT:-900}
k() { kubectl --context "$CONTEXT" "$@"; }
: "${GITOPS_REVISION:?set GITOPS_REVISION in .env}"

remote_line=$(git -C "$REPO_ROOT" ls-remote origin "refs/heads/$GITOPS_REVISION") || die "git ls-remote origin failed"
TARGET=$(cut -f1 <<<"$remote_line")
[[ -n "$TARGET" ]] || die "branch $GITOPS_REVISION not found on origin"
log "waiting for all Applications: Synced + Healthy at origin/$GITOPS_REVISION ${TARGET:0:7} (timeout ${TIMEOUT}s)"

# one line per app: name sync health revision-ok ; revision-ok = the app has no Git source or compared TARGET
report() {
  k -n "$ARGO_NS" get applications -o json | jq -r --arg t "$TARGET" '
    .items[] |
    ([(.spec.sources // [.spec.source])[] | select(.chart == null)] | length) as $git |
    ([.status.sync.revision?, (.status.sync.revisions // [])[]] | map(select(. != null))) as $revs |
    [.metadata.name, (.status.sync.status // "-"), (.status.health.status // "-"),
     (if $git == 0 or ($revs | index($t)) != null then "rev-ok" else "rev-old" end)] | @tsv'
}

all_ok() { [[ -n "$1" ]] && awk -F'\t' '$2 != "Synced" || $3 != "Healthy" || $4 != "rev-ok" {bad=1} END {exit bad}' <<<"$1"; }

end=$((SECONDS + TIMEOUT))
while :; do
  out=$(report 2>/dev/null || true)
  if all_ok "$out"; then
    column -t <<<"$out"
    ok "all $(grep -c . <<<"$out") Applications Synced/Healthy at ${TARGET:0:7}"
    exit 0
  fi
  if (( SECONDS >= end )); then
    column -t <<<"$out" >&2
    err "timeout: not every Application is Synced/Healthy at ${TARGET:0:7}"
    awk -F'\t' '$1 == "cilium" && $2 == "OutOfSync" {print "hint: cilium is manual-sync - review the diff, then sync it by hand (SPEC §5.3)"}' <<<"$out" >&2
    exit 1
  fi
  sleep 10
done
