#!/usr/bin/env bash
# Install the pinned CLI tools from versions.env into $BIN_DIR (default ~/.local/bin). No root needed.
# Every download is checked against a published SHA-256 (upstream .sha256 file or GitHub release asset digest).
# Idempotent: tools already at the pinned version are skipped.   Linux only (macOS: use brew, same versions).
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd curl tar python3 sha256sum

[[ "$(uname -s)" == "Linux" ]] || die "install-tools.sh supports Linux only; on macOS install the versions in versions.env via brew"
ARCH=$(host_arch)
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
mkdir -p "$BIN_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

verify_sha256() { # file expected
  local got; got=$(sha256sum "$1" | awk '{print $1}')
  [[ "$got" == "$2" ]] || die "checksum mismatch for $(basename "$1"): expected $2, got $got"
}

# gh_digest <owner/repo> <tag> <asset-name> → sha256 hex from the GitHub release API
gh_digest() {
  local tag_enc=${2//\//%2F}
  curl -fsS --retry 3 "https://api.github.com/repos/$1/releases/tags/${tag_enc}" |
    python3 -I -c '
import sys, json
name = sys.argv[1]
for a in json.load(sys.stdin)["assets"]:
    if a["name"] == name and (a.get("digest") or "").startswith("sha256:"):
        print(a["digest"].split(":", 1)[1]); break
' "$3"
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

installed_ok() { # name want-substring command...
  local n=$1 want=$2; shift 2
  have "$n" && [[ "$("$@" 2>/dev/null || true)" == *"${want#v}"* ]]
}

place() { install -m 0755 "$1" "$BIN_DIR/$2"; ok "installed $2 → $BIN_DIR/$2"; }

install_kind() {
  installed_ok kind "$KIND_VERSION" kind version && { ok "kind $KIND_VERSION already installed"; return; }
  local u="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  fetch "$u" "$TMP/kind"
  fetch "$u.sha256sum" "$TMP/kind.sha"
  verify_sha256 "$TMP/kind" "$(awk '{print $1}' "$TMP/kind.sha")"
  place "$TMP/kind" kind
}

install_kubectl() {
  installed_ok kubectl "$KUBECTL_VERSION" kubectl version --client && { ok "kubectl $KUBECTL_VERSION already installed"; return; }
  local u="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  fetch "$u" "$TMP/kubectl"
  verify_sha256 "$TMP/kubectl" "$(curl -fsSL "$u.sha256" | awk '{print $1}')"
  place "$TMP/kubectl" kubectl
}

install_helm() {
  installed_ok helm "$HELM_VERSION" helm version --short && { ok "helm $HELM_VERSION already installed"; return; }
  local f="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" u="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  fetch "$u" "$TMP/$f"
  verify_sha256 "$TMP/$f" "$(curl -fsSL "$u.sha256sum" | awk '{print $1}')"
  tar -xzf "$TMP/$f" -C "$TMP" "linux-${ARCH}/helm"
  place "$TMP/linux-${ARCH}/helm" helm
}

# github_tar <name> <version> <owner/repo> <tag> <asset> <member-in-tar> [<installed-name>]
github_tar() {
  local name=$1 want=$2 repo=$3 tag=$4 asset=$5 member=$6
  local d; d=$(gh_digest "$repo" "$tag" "$asset")
  [[ -n "$d" ]] || die "no sha256 digest published for $asset ($repo@$tag)"
  fetch "https://github.com/$repo/releases/download/${tag//\//%2F}/$asset" "$TMP/$asset"
  verify_sha256 "$TMP/$asset" "$d"
  mkdir -p "$TMP/x-$name"
  tar -xzf "$TMP/$asset" -C "$TMP/x-$name"
  place "$TMP/x-$name/$member" "$name"
}

install_kustomize() {
  installed_ok kustomize "$KUSTOMIZE_VERSION" kustomize version && { ok "kustomize $KUSTOMIZE_VERSION already installed"; return; }
  github_tar kustomize "$KUSTOMIZE_VERSION" kubernetes-sigs/kustomize "kustomize/${KUSTOMIZE_VERSION}" \
    "kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" kustomize
}

install_yq() {
  installed_ok yq "$YQ_VERSION" yq --version && { ok "yq $YQ_VERSION already installed"; return; }
  local a="yq_linux_${ARCH}" d; d=$(gh_digest mikefarah/yq "$YQ_VERSION" "$a")
  [[ -n "$d" ]] || die "no sha256 digest published for $a"
  fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/$a" "$TMP/yq"
  verify_sha256 "$TMP/yq" "$d"
  place "$TMP/yq" yq
}

install_kubeconform() {
  installed_ok kubeconform "$KUBECONFORM_VERSION" kubeconform -v && { ok "kubeconform $KUBECONFORM_VERSION already installed"; return; }
  github_tar kubeconform "$KUBECONFORM_VERSION" yannh/kubeconform "$KUBECONFORM_VERSION" \
    "kubeconform-linux-${ARCH}.tar.gz" kubeconform
}

install_gitleaks() {
  installed_ok gitleaks "$GITLEAKS_VERSION" gitleaks version && { ok "gitleaks $GITLEAKS_VERSION already installed"; return; }
  local garch=$ARCH; [[ $ARCH == amd64 ]] && garch=x64
  github_tar gitleaks "$GITLEAKS_VERSION" gitleaks/gitleaks "$GITLEAKS_VERSION" \
    "gitleaks_${GITLEAKS_VERSION#v}_linux_${garch}.tar.gz" gitleaks
}

install_cilium_cli() {
  installed_ok cilium "$CILIUM_CLI_VERSION" cilium version --client && { ok "cilium-cli $CILIUM_CLI_VERSION already installed"; return; }
  github_tar cilium "$CILIUM_CLI_VERSION" cilium/cilium-cli "$CILIUM_CLI_VERSION" "cilium-linux-${ARCH}.tar.gz" cilium
}

install_hubble() {
  installed_ok hubble "$HUBBLE_CLI_VERSION" hubble version && { ok "hubble $HUBBLE_CLI_VERSION already installed"; return; }
  github_tar hubble "$HUBBLE_CLI_VERSION" cilium/hubble "$HUBBLE_CLI_VERSION" "hubble-linux-${ARCH}.tar.gz" hubble
}

# argocd CLI (SPEC §2.2, optional): used in --core mode for the Cilium adoption diff/sync (SPEC §5.3)
install_argocd() {
  installed_ok argocd "$ARGOCD_VERSION" argocd version --client --short && { ok "argocd $ARGOCD_VERSION already installed"; return; }
  local a="argocd-linux-${ARCH}" base="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}"
  local d; d=$(curl -fsSL --retry 3 "$base/cli_checksums.txt" | awk -v a="$a" '$2 == a {print $1}')
  [[ -n "$d" ]] || die "no checksum for $a in cli_checksums.txt"
  fetch "$base/$a" "$TMP/argocd"
  verify_sha256 "$TMP/argocd" "$d"
  place "$TMP/argocd" argocd
}

install_kind; install_kubectl; install_helm; install_kustomize
install_yq; install_kubeconform; install_gitleaks; install_cilium_cli; install_hubble; install_argocd

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
ok "tools ready; next: make preflight"
