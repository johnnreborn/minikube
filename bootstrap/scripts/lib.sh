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
