#!/usr/bin/env bash
# Shared helpers for bootstrap/scripts/*.sh. Source it; do not execute.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

if [[ -t 2 ]]; then
  _R=$'\033[31m'; _G=$'\033[32m'; _Y=$'\033[33m'; _B=$'\033[34m'; _N=$'\033[0m'
else
  _R=''; _G=''; _Y=''; _B=''; _N=''
fi

log()  { printf '%s[INFO]%s %s\n' "$_B" "$_N" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "$_G" "$_N" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "$_Y" "$_N" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$_R" "$_N" "$*" >&2; }
die()  { err "$*"; exit 1; }

# load_env: versions.env is mandatory; .env is optional (gitignored, see .env.example).
load_env() {
  [[ -f "$REPO_ROOT/versions.env" ]] || die "versions.env not found in $REPO_ROOT"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/versions.env"
  if [[ -f "$REPO_ROOT/.env" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
  fi
  set +a
  : "${DOCKER_SUBNET:=172.30.0.0/16}"
  export DOCKER_SUBNET
}

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local c
  for c in "$@"; do have "$c" || die "required command not found: $c (run bootstrap/scripts/install-tools.sh)"; done
}

# host_arch: normalized to the docker/OCI naming (amd64|arm64)
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) uname -m ;;
  esac
}

# pull_chart <repo-url> <chart> <version> <dest-dir> → prints the .tgz path. Retries: a first-time bootstrap must not
# fail on one dropped chart download (transient network errors were seen repeatedly, PROGRESS deviations).
pull_chart() {
  local repo=$1 chart=$2 version=$3 dir=$4 i
  for i in 1 2 3 4 5; do
    if timeout 180 helm pull "$chart" --repo "$repo" --version "$version" -d "$dir" >&2; then
      echo "$dir/$chart-$version.tgz"; return 0
    fi
    warn "helm pull $chart $version failed (attempt $i/5)"; sleep $((i * 5))
  done
  err "could not download chart $chart $version from $repo"; return 1
}

# wait_app_comparable <kube-context> <app> [timeout-s] → hard refresh, then wait for a comparison without conditions and
# with no resource marked for pruning; prints the sync status (Synced|OutOfSync). When repo-server cannot render a chart
# (helm pull timeout), Argo CD marks EVERY resource for pruning (seen in Phase 7); such a state must never be synced.
wait_app_comparable() {
  local ctx=$1 app=$2 end=$((SECONDS + ${3:-300})) j cond="?" prune="?" state
  kubectl --context "$ctx" -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  while (( SECONDS < end )); do
    sleep 10
    j=$(kubectl --context "$ctx" -n argocd get application "$app" -o json) || continue
    [[ "$(jq -r '.metadata.annotations["argocd.argoproj.io/refresh"] // ""' <<<"$j")" == "" ]] || continue
    cond=$(jq -r '[.status.conditions[]? | .type + ": " + .message] | join("; ")' <<<"$j")
    prune=$(jq '[.status.resources[]? | select(.requiresPruning == true)] | length' <<<"$j")
    state=$(jq -r '.status.sync.status' <<<"$j")
    if [[ -z "$cond" && "$prune" == 0 && "$state" =~ ^(Synced|OutOfSync)$ ]]; then echo "$state"; return 0; fi
  done
  err "$app not comparable (conditions: ${cond:-none}; resources marked for pruning: $prune)"; return 1
}
