#!/usr/bin/env bash
# TLS verification must not be switched off (CLAUDE.md). The only exception is ADR-0011: the Prometheus scrapes of
# kubelet, kube-controller-manager and kube-scheduler (self-signed serving certificates).
#   scripts/check-tls.sh files              committed files: no curl -k/--insecure, no --insecure-skip-tls-verify
#   scripts/check-tls.sh render <yaml>...   rendered manifests: skip-verify only in the three allowed ServiceMonitors
# Exit 1 on any violation. Called by scripts/lint.sh.
set -uo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/scripts/lib.sh"
cd "$REPO_ROOT"
MODE=${1:?usage: check-tls.sh files | render <yaml>...}
shift
FAILS=0

case "$MODE" in
files)
  # docs describe the rule and the vendored upstream trees are not ours
  while IFS= read -r f; do
    case "$f" in docs/*|*.md|apps/online-boutique/upstream/*|platform/gateway-api-crds/*|scripts/check-tls.sh) continue ;; esac
    hits=$(grep -n -E -- '--insecure-skip-tls-verify|(^|[^A-Za-z])curl([[:space:]][^#|;]*)?[[:space:]](-[A-Za-z]*k[A-Za-z]*|--insecure)([[:space:]"'\'']|$)' "$f" 2>/dev/null)
    if [[ -n "$hits" ]]; then err "$f: TLS verification disabled:"; echo "$hits" >&2; FAILS=$((FAILS + 1)); fi
  done < <(git ls-files; git ls-files --others --exclude-standard)
  ;;
render)
  for f in "$@"; do
    bad=$(yq -o=json -I=0 '.' "$f" | jq -r '
      select(. != null)
      | select(([.. | objects | (.insecureSkipVerify == true) or (.tlsSkipVerify == true) or (.insecure_skip_verify == true)] | any)
               or ([.. | strings | test("(insecure_skip_verify|tlsSkipVerify|insecureSkipVerify): *true|--kubelet-insecure-tls|--insecure-skip-tls-verify")] | any))
      | select((.kind == "ServiceMonitor" and (.metadata.name | test("-(kubelet|kube-controller-manager|kube-scheduler)$"))) | not)
      | "\(.kind)/\(.metadata.name)"') || { err "$f: cannot parse"; FAILS=$((FAILS + 1)); continue; }
    if [[ -n "$bad" ]]; then err "TLS verification disabled outside the ADR-0011 exception: $(tr '\n' ' ' <<<"$bad")"; FAILS=$((FAILS + 1)); fi
  done
  ;;
*) die "unknown mode $MODE" ;;
esac
(( FAILS == 0 ))
