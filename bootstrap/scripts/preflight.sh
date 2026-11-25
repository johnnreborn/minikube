#!/usr/bin/env bash
# Phase 0 host preflight (SPEC §2.1, §6.0, AC-0.1). Exit 0 only if every hard requirement is met.
# Hard requirements are the SPEC minimums; they are never relaxed to make the check pass.
set -uo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env

MIN_CPU=8
MIN_MEM_GIB=16
MIN_DISK_GB=40
MIN_INOTIFY_WATCHES=524288
MIN_INOTIFY_INSTANCES=512

FAILS=0
WARNS=0
fail() { err "$*"; FAILS=$((FAILS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }

# ---- tools -------------------------------------------------------------------------------------
# name:expected-version:command that prints the installed version
check_tool() {
  local name=$1 want=$2 got=$3
  if ! have "$name"; then
    fail "tool missing: $name (want $want) — run bootstrap/scripts/install-tools.sh"
    return
  fi
  if [[ -z "$want" ]]; then ok "$name present"; return; fi
  if [[ "$got" == *"${want#v}"* ]]; then
    ok "$name $want"
  else
    note "$name version drift: want $want, got '${got}'"
  fi
}

log "== tools =="
check_tool docker "" ""
check_tool kind "$KIND_VERSION" "$(kind version 2>/dev/null)"
check_tool kubectl "$KUBECTL_VERSION" "$(kubectl version --client 2>/dev/null | head -1)"
check_tool helm "$HELM_VERSION" "$(helm version --short 2>/dev/null)"
check_tool kustomize "$KUSTOMIZE_VERSION" "$(kustomize version 2>/dev/null)"
check_tool cilium "$CILIUM_CLI_VERSION" "$(cilium version --client 2>/dev/null | head -1)"
check_tool hubble "$HUBBLE_CLI_VERSION" "$(hubble version 2>/dev/null | head -1)"
check_tool yq "$YQ_VERSION" "$(yq --version 2>/dev/null)"
check_tool kubeconform "$KUBECONFORM_VERSION" "$(kubeconform -v 2>/dev/null)"
check_tool gitleaks "$GITLEAKS_VERSION" "$(gitleaks version 2>/dev/null)"
for t in jq git make yamllint python3 curl; do check_tool "$t" "" ""; done
have argocd || log "argocd CLI not installed (optional, --core mode)"

# helm v3.18+ or v4 (SPEC §2.2); this repo pins v3, but a v4 install is acceptable for the CLI
if have helm; then
  hv=$(helm version --short 2>/dev/null | sed -E 's/^v([0-9]+)\.([0-9]+).*/\1 \2/')
  read -r hmaj hmin <<<"$hv"
  if [[ -n "${hmaj:-}" ]] && { (( hmaj >= 4 )) || (( hmaj == 3 && hmin >= 18 )); }; then :; else
    fail "helm must be v3.18+ or v4 (found: $(helm version --short 2>/dev/null))"
  fi
fi

# ---- docker daemon & resources ---------------------------------------------------------------
log "== docker & resources =="
DOCKER_OK=0
if have docker && docker info >/dev/null 2>&1; then
  DOCKER_OK=1
  ok "docker daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
else
  fail "docker daemon not reachable (is it running? is your user in the docker group?)"
fi

if (( DOCKER_OK )); then
  cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  mem_gib=$(awk -v b="$mem_bytes" 'BEGIN{printf "%.1f", b/1024/1024/1024}')
  if (( cpus >= MIN_CPU )); then ok "docker CPUs: $cpus (min $MIN_CPU)"; else
    fail "docker CPUs: $cpus < $MIN_CPU (raise the Docker/WSL allocation)"; fi
  if (( mem_bytes >= MIN_MEM_GIB * 1024 * 1024 * 1024 )); then ok "docker memory: ${mem_gib} GiB (min $MIN_MEM_GIB)"; else
    fail "docker memory: ${mem_gib} GiB < ${MIN_MEM_GIB} GiB (WSL: set memory in .wslconfig, then 'wsl --shutdown')"; fi
  cg=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo "")
  if [[ "$cg" == "2" ]]; then ok "cgroup v2 (docker)"; else fail "cgroup v2 required (docker reports: '${cg:-unknown}')"; fi

  droot=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)
  probe_dir=$droot; [[ -d "$probe_dir" ]] || probe_dir=/
  free_gb=$(df -Pk "$probe_dir" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')
  if [[ -z "$free_gb" ]]; then free_gb=$(df -Pk "$REPO_ROOT" | awk 'NR==2{printf "%d", $4/1024/1024}'); fi
  if (( free_gb >= MIN_DISK_GB )); then ok "disk free: ${free_gb} GB (min $MIN_DISK_GB)"; else
    fail "disk free: ${free_gb} GB < ${MIN_DISK_GB} GB"; fi
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]]; then ok "cgroup v2 (host)"; else
    fail "host cgroup is not v2 (Kubernetes >= 1.35 requires cgroup v2)"; fi
  w=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  i=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
  if (( w >= MIN_INOTIFY_WATCHES )); then ok "inotify max_user_watches=$w"; else
    fail "inotify max_user_watches=$w < $MIN_INOTIFY_WATCHES (sudo sysctl -w fs.inotify.max_user_watches=$MIN_INOTIFY_WATCHES)"; fi
  if (( i >= MIN_INOTIFY_INSTANCES )); then ok "inotify max_user_instances=$i"; else
    fail "inotify max_user_instances=$i < $MIN_INOTIFY_INSTANCES (sudo sysctl -w fs.inotify.max_user_instances=$MIN_INOTIFY_INSTANCES)"; fi
else
  log "non-Linux host: skipping host cgroup/inotify checks (Docker Desktop VM is checked via docker info)"
  note "macOS/Docker Desktop: VIPs are not reachable from the host; verification uses probe containers (ARCHITECTURE §15-6)"
fi

# ---- subnet collisions -----------------------------------------------------------------------
log "== subnet ${DOCKER_SUBNET} =="
overlap_check() { # args: subnet, then "label cidr" lines on stdin → prints colliding labels
  python3 -I - "$1" <<'PY'
import ipaddress, sys
mine = ipaddress.ip_network(sys.argv[1], strict=False)
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 2:
        continue
    label, cidr = parts[0], parts[1]
    try:
        other = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        continue
    if other.version == mine.version and other.prefixlen > 0 and mine.overlaps(other):
        print(f"{label}={cidr}")
PY
}

host_routes=""
if have ip; then
  host_routes=$(ip -4 route show 2>/dev/null | awk '$1 ~ /\// {dev=""; for(i=1;i<=NF;i++) if($i=="dev") dev=$(i+1); print "route:" dev, $1}')
elif have netstat; then
  host_routes=$(netstat -rn -f inet 2>/dev/null | awk '$1 ~ /\// {print "route:" $NF, $1}')
fi
collide=$(printf '%s\n' "$host_routes" | grep -v ' default' | overlap_check "$DOCKER_SUBNET" || true)
# a route that kind-boutique's own bridge created is expected once the network exists
collide=$(printf '%s\n' "$collide" | grep -v -E '^route:br-' || true)
if [[ -n "$collide" ]]; then
  fail "host routes overlap $DOCKER_SUBNET: $(echo "$collide" | tr '\n' ' ') — change DOCKER_SUBNET in .env (and the VIPs in manifests)"
else
  ok "no host route overlaps $DOCKER_SUBNET"
fi

if (( DOCKER_OK )); then
  nets=""
  while read -r n; do
    [[ -z "$n" || "$n" == "kind-boutique" ]] && continue
    for c in $(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null); do
      nets+="docker:$n $c"$'\n'
    done
  done < <(docker network ls --format '{{.Name}}')
  collide=$(printf '%s' "$nets" | overlap_check "$DOCKER_SUBNET" || true)
  if [[ -n "$collide" ]]; then
    fail "docker networks overlap $DOCKER_SUBNET: $(echo "$collide" | tr '\n' ' ')"
  else
    ok "no other docker network overlaps $DOCKER_SUBNET"
  fi
  if docker network inspect kind-boutique >/dev/null 2>&1; then
    have_sub=$(docker network inspect kind-boutique --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
    if [[ "$have_sub" == *"$DOCKER_SUBNET"* ]]; then ok "docker network kind-boutique exists with $DOCKER_SUBNET"; else
      fail "docker network kind-boutique exists with subnet '${have_sub}', expected $DOCKER_SUBNET"; fi
  fi
fi

# ---- summary ---------------------------------------------------------------------------------
echo >&2
if (( FAILS > 0 )); then
  err "preflight FAILED: $FAILS problem(s), $WARNS warning(s)"
  exit 1
fi
ok "preflight passed ($WARNS warning(s))"
