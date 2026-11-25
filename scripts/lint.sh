#!/usr/bin/env bash
# `make lint` (NFR-10, AC-0.4): yamllint → kustomize build → helm template → kubeconform → versions → secret scan.
# Runs every step even if an earlier one fails, then reports. Exit 1 if any step failed or a tool is missing.
# Works on an (almost) empty repo: steps with nothing to check report "nothing to check" and pass.
set -uo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/scripts/lib.sh"
cd "$REPO_ROOT"
load_env
shopt -s nullglob globstar

STEPS_FAILED=()
step_fail() { STEPS_FAILED+=("$1"); err "step failed: $1"; }

MISSING=()
for t in yamllint kustomize helm kubeconform yq gitleaks; do have "$t" || MISSING+=("$t"); done
if (( ${#MISSING[@]} )); then
  err "lint tools missing: ${MISSING[*]} (see bootstrap/scripts/install-system.sh / install-tools.sh)"
  exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
K8S_VER=${KIND_NODE_VERSION#v}
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
KUBECONFORM=(kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "$K8S_VER"
  -schema-location default -schema-location "$CRD_CATALOG")

# 1. yamllint ---------------------------------------------------------------------------------
log "== yamllint =="
if yamllint --strict -c .yamllint . ; then ok "yamllint"; else step_fail yamllint; fi

# 2. kustomize build + 4. kubeconform ----------------------------------------------------------
log "== kustomize build =="
kdirs=()
while IFS= read -r k; do
  d=$(dirname "$k")
  [[ "$d" == apps/online-boutique/upstream* ]] && continue
  kdirs+=("$d")
done < <(find . -name kustomization.yaml -not -path './.git/*' -not -path './tests/*' | sed 's|^\./||' | sort)
if (( ${#kdirs[@]} == 0 )); then log "no kustomization.yaml yet — nothing to build"; fi
for d in "${kdirs[@]}"; do
  if kustomize build "$d" >"$TMP/k.yaml" 2>"$TMP/k.err"; then
    if "${KUBECONFORM[@]}" <"$TMP/k.yaml" >"$TMP/kc.out" 2>&1; then ok "kustomize+kubeconform: $d"; else
      cat "$TMP/kc.out" >&2; step_fail "kubeconform(kustomize:$d)"; fi
  else
    cat "$TMP/k.err" >&2; step_fail "kustomize build $d"
  fi
done

# 3. helm template ----------------------------------------------------------------------------
log "== helm template =="
# name|repo var|chart|version var|namespace|values dir
HELM_COMPONENTS=(
  "cilium|CILIUM_CHART_REPO|cilium|CILIUM_CHART_VERSION|kube-system|platform/cilium"
  "argocd|ARGOCD_CHART_REPO|argo-cd|ARGOCD_CHART_VERSION|argocd|platform/argocd"
  "cert-manager|CERT_MANAGER_CHART_REPO|cert-manager|CERT_MANAGER_VERSION|cert-manager|platform/cert-manager"
  "kube-prometheus-stack|PROMETHEUS_CHART_REPO|kube-prometheus-stack|KUBE_PROMETHEUS_STACK_CHART_VERSION|observability|observability/kube-prometheus-stack"
  "loki|GRAFANA_COMMUNITY_CHART_REPO|loki|LOKI_CHART_VERSION|observability|observability/loki"
  "tempo|GRAFANA_COMMUNITY_CHART_REPO|tempo|TEMPO_CHART_VERSION|observability|observability/tempo"
  "alloy|GRAFANA_CHART_REPO|alloy|ALLOY_CHART_VERSION|observability|observability/alloy"
  "otel-collector|OTEL_CHART_REPO|opentelemetry-collector|OTEL_COLLECTOR_CHART_VERSION|observability|observability/otel-collector"
)
helm_rendered=0
for row in "${HELM_COMPONENTS[@]}"; do
  IFS='|' read -r name rvar chart vvar ns dir <<<"$row"
  [[ -f "$dir/values.yaml" ]] || continue
  helm_rendered=$((helm_rendered + 1))
  repo=${!rvar}; ver=${!vvar}
  # base alone, then base + every layer (values-*.yaml), like bootstrap and Argo CD do
  layers=("$dir"/values-*.yaml)
  for variant in base all; do
    args=(-f "$dir/values.yaml")
    [[ $variant == all ]] && { (( ${#layers[@]} )) || continue; for l in "${layers[@]}"; do args+=(-f "$l"); done; }
    if helm template "$name" "$chart" --repo "$repo" --version "$ver" --namespace "$ns" \
         --kube-version "$K8S_VER" "${args[@]}" >"$TMP/h.yaml" 2>"$TMP/h.err"; then
      if "${KUBECONFORM[@]}" <"$TMP/h.yaml" >"$TMP/hc.out" 2>&1; then ok "helm template+kubeconform: $name ($variant)"; else
        cat "$TMP/hc.out" >&2; step_fail "kubeconform(helm:$name:$variant)"; fi
    else
      cat "$TMP/h.err" >&2; step_fail "helm template $name ($variant)"
    fi
  done
done
(( helm_rendered == 0 )) && log "no helm values files yet — nothing to render"

# plain Application / policy manifests that are not part of a kustomization
log "== kubeconform (plain manifests) =="
plain=()
for f in gitops/**/*.yaml; do plain+=("$f"); done
if (( ${#plain[@]} )); then
  if "${KUBECONFORM[@]}" "${plain[@]}" >"$TMP/p.out" 2>&1; then ok "kubeconform: gitops/ (${#plain[@]} files)"; else
    cat "$TMP/p.out" >&2; step_fail "kubeconform(gitops)"; fi
else
  log "no gitops manifests yet — nothing to validate"
fi

# 5. version consistency ----------------------------------------------------------------------
log "== check-versions =="
if bash scripts/check-versions.sh; then :; else step_fail check-versions; fi

# 6. secret scan ------------------------------------------------------------------------------
log "== gitleaks =="
if gitleaks dir . --no-banner --redact --config .gitleaks.toml >"$TMP/g.out" 2>&1; then ok "gitleaks (working tree)"; else
  cat "$TMP/g.out" >&2; step_fail "gitleaks(dir)"; fi
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  if gitleaks git . --no-banner --redact --config .gitleaks.toml >"$TMP/gh.out" 2>&1; then ok "gitleaks (git history)"; else
    cat "$TMP/gh.out" >&2; step_fail "gitleaks(git)"; fi
fi

echo >&2
if (( ${#STEPS_FAILED[@]} )); then
  err "lint FAILED: ${STEPS_FAILED[*]}"
  exit 1
fi
ok "lint passed"
