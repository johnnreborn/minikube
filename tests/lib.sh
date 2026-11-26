#!/usr/bin/env bash
# Test harness (SPEC §7.1). Source from tests/phase-<n>.sh; do not execute.
#   ac_pass/ac_fail/ac_skip <AC-ID> <msg>   output "[PASS|FAIL|SKIP] AC-x.y msg" and count it
#   ac_should <AC-ID>...                    mark ACs as SHOULD (default is MUST); ac_could for COULD
#   ac_summary <phase>                      last line + exit code (1 if any MUST failed)
#   AC_ONLY=AC-5.4,AC-5.5 bash tests/phase-5.sh   run only the listed ACs (others are neither run nor counted)
#   wait_for <timeout-s> <cmd...>           poll every 2s until cmd succeeds
#   probe_curl <curl args...>               curl from a container on the kind-boutique network (outside view)
#   debug_curl <ns> <pod> <container> <curl args...>   curl from an ephemeral container in the pod's netns (identity-preserving)
#   debug_curl_rc <ns> <pod> <container> <curl args...> same, prints "<curl exit code> <stdout>"
#   test_pod <ns> <labels> <cmd...>         throwaway PSA-restricted pod running `sh -c cmd` (image: TEST_POD_IMAGE)
#   prom_query / loki_query / tempo_search  query via a temporary port-forward
#   hubble_expect <hubble-observe-filter> <VERDICT> [window]   assert a recent flow with that verdict exists
#   suspend_app / resume_app <app>          freeze Argo CD reconciliation for fault injection (§7.4); restored by trap
#   rebalance_zones <ns> <app...>           after a node-failure test, move pods back so every zone-spread app is even
#   reset_loadgenerator                     after a node-failure test, restart loadgenerator so AC-5.6 starts over
# Every temporary resource carries ac-test=true and is removed by the EXIT trap.
# shellcheck shell=bash

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export TESTS_DIR REPO_ROOT
# shellcheck source=bootstrap/scripts/lib.sh
source "$REPO_ROOT/bootstrap/scripts/lib.sh"
load_env

CACHE_DIR="$TESTS_DIR/.cache"
RESULTS_DIR="$TESTS_DIR/results"
DOCKER_NETWORK=${DOCKER_NETWORK:-kind-boutique}
mkdir -p "$CACHE_DIR" "$RESULTS_DIR"

# ---- AC accounting ---------------------------------------------------------------------------
declare -A AC_LEVEL=()
AC_MUST_TOTAL=0; AC_MUST_PASS=0; AC_MUST_FAIL=0
AC_SHOULD_TOTAL=0; AC_SHOULD_PASS=0
AC_FAIL_TOTAL=0; AC_SKIP_TOTAL=0

ac_should() { local a; for a in "$@"; do AC_LEVEL[$a]=SHOULD; done; }
ac_could()  { local a; for a in "$@"; do AC_LEVEL[$a]=COULD; done; }
_ac_level() { echo "${AC_LEVEL[$1]:-MUST}"; }

_ac_count() { # id outcome
  local lvl; lvl=$(_ac_level "$1")
  case "$lvl" in
    MUST)   AC_MUST_TOTAL=$((AC_MUST_TOTAL + 1)); [[ $2 == pass ]] && AC_MUST_PASS=$((AC_MUST_PASS + 1)); [[ $2 == fail ]] && AC_MUST_FAIL=$((AC_MUST_FAIL + 1)) ;;
    SHOULD) AC_SHOULD_TOTAL=$((AC_SHOULD_TOTAL + 1)); [[ $2 == pass ]] && AC_SHOULD_PASS=$((AC_SHOULD_PASS + 1)) ;;
  esac
  [[ $2 == fail ]] && AC_FAIL_TOTAL=$((AC_FAIL_TOTAL + 1))
  [[ $2 == skip ]] && AC_SKIP_TOTAL=$((AC_SKIP_TOTAL + 1))
  return 0
}
_ac_selected() { [[ -z "${AC_ONLY:-}" || ",$AC_ONLY," == *",$1,"* ]]; }
ac_pass() { _ac_selected "$1" || return 0; printf '[PASS] %s %s\n' "$1" "${*:2}"; _ac_count "$1" pass; }
ac_fail() { _ac_selected "$1" || return 0; printf '[FAIL] %s %s\n' "$1" "${*:2}"; _ac_count "$1" fail; }
ac_skip() { _ac_selected "$1" || return 0; printf '[SKIP] %s %s\n' "$1" "${*:2}"; _ac_count "$1" skip; }

# ac_check <AC-ID> <description> <cmd...>   PASS if cmd exits 0, else FAIL (cmd output shown indented on failure)
ac_check() {
  local id=$1 desc=$2; shift 2
  _ac_selected "$id" || return 0
  local out rc
  out=$("$@" 2>&1); rc=$?
  if (( rc == 0 )); then ac_pass "$id" "$desc"; else
    ac_fail "$id" "$desc"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/        /' | tail -20
  fi
  return 0
}

ac_summary() {
  local phase=${1:?phase}
  printf 'SUMMARY phase-%s: MUST %d/%d pass, SHOULD %d/%d pass, FAIL %d, SKIP %d\n' \
    "$phase" "$AC_MUST_PASS" "$AC_MUST_TOTAL" "$AC_SHOULD_PASS" "$AC_SHOULD_TOTAL" "$AC_FAIL_TOTAL" "$AC_SKIP_TOTAL"
  # a MUST that was skipped is not a pass
  if (( AC_MUST_FAIL > 0 || AC_MUST_PASS < AC_MUST_TOTAL )); then return 1; fi
  return 0
}

# ---- cleanup ---------------------------------------------------------------------------------
declare -a AC_CLEANUPS=()
PF_PIDS_FILE=$(mktemp "${TMPDIR:-/tmp}/ac-pf.XXXXXX")
on_cleanup() { AC_CLEANUPS+=("$*"); }   # run in reverse order on exit
_ac_cleanup() {
  local rc=$? i
  # port-forwards started by _pf (it runs in a $(...) subshell, so it cannot register on_cleanup itself)
  if [[ -s "$PF_PIDS_FILE" ]]; then xargs -r kill <"$PF_PIDS_FILE" >/dev/null 2>&1 || true; fi
  rm -f "$PF_PIDS_FILE"
  for (( i=${#AC_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${AC_CLEANUPS[$i]}" >/dev/null 2>&1 || true; done
  if have docker; then
    docker ps -aq --filter label=ac-test=true 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  fi
  if have kubectl && kubectl cluster-info >/dev/null 2>&1; then
    kubectl delete pod -A -l ac-test=true --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  return $rc
}
trap _ac_cleanup EXIT

# ---- generic helpers -------------------------------------------------------------------------
wait_for() {
  local timeout=$1; shift
  local end=$(( SECONDS + timeout ))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= end )) && return 1
    sleep 2
  done
}

# Outside view: same Docker network as the kind nodes, so ARP/L2 paths to VIPs are exercised.
probe_curl() {
  mkdir -p "$CACHE_DIR"
  docker run --rm --label ac-test=true --network "$DOCKER_NETWORK" \
    -v "$CACHE_DIR:/certs:ro" "$CURL_IMAGE" "$@"
}

# extract_ca <ns> <secret> [key]  → tests/.cache/ca.crt (public cert only)
extract_ca() {
  local ns=$1 secret=$2 key=${3:-ca.crt}
  mkdir -p "$CACHE_DIR"
  kubectl -n "$ns" get secret "$secret" -o jsonpath="{.data['${key//./\\.}']}" | base64 -d >"$CACHE_DIR/ca.crt"
}

# debug_curl <ns> <pod> <target-container> <curl args...> → prints curl stdout
# The ephemeral container shares the pod's network namespace, so Cilium sees the real workload identity.
debug_curl() {
  local ns=$1 pod=$2 target=$3; shift 3
  local name; name="ac-dbg-$(date +%s)-$RANDOM"
  kubectl -n "$ns" debug "pod/$pod" --image="$CURL_IMAGE" --target="$target" --profile=restricted \
    --container="$name" -q -- curl -s --max-time 10 "$@" >/dev/null 2>&1 || return 1
  wait_for 60 bash -c "kubectl -n '$ns' get pod '$pod' -o jsonpath='{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.terminated.exitCode}' | grep -q ." || return 1
  kubectl -n "$ns" logs "$pod" -c "$name"
}

# debug_curl_rc <ns> <pod> <target-container> <curl args...> → "<exit code> <stdout>" (curl output on one line)
debug_curl_rc() {
  local ns=$1 pod=$2 target=$3; shift 3
  local name rc; name="ac-dbg-$(date +%s)-$RANDOM"
  kubectl -n "$ns" debug "pod/$pod" --image="$CURL_IMAGE" --target="$target" --profile=restricted \
    --container="$name" -q -- curl -s "$@" >/dev/null 2>&1 || return 1
  wait_for 90 bash -c "kubectl -n '$ns' get pod '$pod' -o jsonpath='{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.terminated.exitCode}' | grep -q ." || return 1
  rc=$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.terminated.exitCode}")
  echo "$rc $(kubectl -n "$ns" logs "$pod" -c "$name" | tr '\n' ' ')"
}

# test_pod <ns> <labels k=v,k=v> <shell command>  → command stdout; pod is removed afterwards
test_pod() {   # image: TEST_POD_IMAGE (default CURL_IMAGE)
  local ns=$1 labels=$2 cmd=$3 image=${TEST_POD_IMAGE:-$CURL_IMAGE}
  local name; name="ac-test-$(date +%s)-$RANDOM"
  # strategic override: a (default) JSON merge would replace the container list and drop --command
  kubectl -n "$ns" run "$name" --restart=Never --rm -i --quiet --image="$image" \
    --labels="ac-test=true${labels:+,$labels}" --override-type=strategic \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"'"$name"'","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
    --command -- sh -c "$cmd"
}

# ---- port-forward based queries --------------------------------------------------------------
# _pf <ns> <svc> <remote-port> → echoes local port, forward is torn down by the EXIT trap (pid list in $PF_PIDS_FILE)
_pf() {
  local ns=$1 svc=$2 rport=$3 port
  port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  kubectl -n "$ns" port-forward "svc/$svc" "$port:$rport" >/dev/null 2>&1 &
  echo "$!" >>"$PF_PIDS_FILE"
  # plain TCP connect: works for HTTP and gRPC (hubble-relay) endpoints alike
  wait_for 20 bash -c "(exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null" || true
  echo "$port"
}

# Service names depend on the chart release names fixed in Phase 7; override via env if they change.
PROM_NS=${PROM_NS:-observability};  PROM_SVC=${PROM_SVC:-kube-prometheus-stack-prometheus}; PROM_PORT=${PROM_PORT:-9090}
LOKI_NS=${LOKI_NS:-observability};  LOKI_SVC=${LOKI_SVC:-loki};                            LOKI_PORT=${LOKI_PORT:-3100}
TEMPO_NS=${TEMPO_NS:-observability}; TEMPO_SVC=${TEMPO_SVC:-tempo};                        TEMPO_PORT=${TEMPO_PORT:-3200}

prom_query() {  # <promql> → raw JSON
  local p; p=$(_pf "$PROM_NS" "$PROM_SVC" "$PROM_PORT")
  curl -fsS --get --data-urlencode "query=$1" "http://127.0.0.1:$p/api/v1/query"
}

loki_query() {  # <logql> [since, default 15m] [limit, default 100] → raw JSON
  local p; p=$(_pf "$LOKI_NS" "$LOKI_SVC" "$LOKI_PORT")
  curl -fsS --get --data-urlencode "query=$1" --data-urlencode "since=${2:-15m}" --data-urlencode "limit=${3:-100}" \
    "http://127.0.0.1:$p/loki/api/v1/query_range"
}

tempo_search() {  # <traceql> [limit] → raw JSON
  local p; p=$(_pf "$TEMPO_NS" "$TEMPO_SVC" "$TEMPO_PORT")
  curl -fsS --get --data-urlencode "q=$1" --data-urlencode "limit=${2:-20}" "http://127.0.0.1:$p/api/search"
}

# hubble_expect <hubble observe args, e.g. "--to-label app=cartservice"> <FORWARDED|DROPPED|AUDIT|REDIRECTED> [window=60s]
hubble_expect() {
  local filter=$1 verdict=$2 window=${3:-60s}
  local p; p=$(_pf kube-system hubble-relay 80)
  # shellcheck disable=SC2086
  local out
  # capture first: `cmd | grep -q` under pipefail can fail at random (SIGPIPE when grep exits before the writer)
  out=$(hubble observe --server "localhost:$p" --since "$window" --verdict "$verdict" $filter -o jsonpb --last 1 2>/dev/null) || true
  [[ -n "$out" ]]
}

# ---- Argo CD fault injection (SPEC §7.4) -----------------------------------------------------
suspend_app() {
  kubectl -n argocd annotate application "$1" argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
  on_cleanup "resume_app $1"
}
resume_app() {
  kubectl -n argocd annotate application "$1" argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
}

# ---- node-failure cleanup ----------------------------------------------------------------------
# Spread constraints are only applied when a pod is scheduled: after a node failure the replacement pods stay in the
# surviving zones (ADR-0013). Delete the newest pod of the fullest zone until every zone differs by at most one, waiting
# for each replacement to be Ready. Test cleanup only.
rebalance_zones() {
  local ns=$1 app victim i; shift
  for app in "$@"; do
    for i in 1 2 3; do
      victim=$(_surplus_pod "$ns" "$app") || return 1
      [[ -n "$victim" ]] || break
      echo "rebalance: deleting $ns/$victim ($app is unevenly spread over the zones)"
      kubectl -n "$ns" delete pod "$victim" --wait=true >/dev/null || return 1
      kubectl -n "$ns" rollout status "deploy/$app" --timeout=180s >/dev/null || return 1
    done
    [[ -z "$(_surplus_pod "$ns" "$app")" ]] || { echo "$app still unevenly spread after rebalancing"; return 1; }
  done
}
_surplus_pod() {  # <ns> <app> → name of one pod to move, empty if the zones are even
  local zones pods
  zones=$(kubectl get nodes -l topology.kubernetes.io/zone -o json |
    jq -c '[.items[] | {key: .metadata.name, value: .metadata.labels["topology.kubernetes.io/zone"]}] | from_entries') || return 1
  pods=$(kubectl -n "$1" get pods -l "app=$2" -o json) || return 1
  jq -r --argjson zones "$zones" '
    [.items[] | select(.metadata.deletionTimestamp == null and (.spec.nodeName // "") != "" and $zones[.spec.nodeName])
     | {zone: $zones[.spec.nodeName], name: .metadata.name, at: .metadata.creationTimestamp}] as $p
    | [$zones[]] | unique | map(. as $z | [$p[] | select(.zone == $z)]) | sort_by(length)
    | if (.[-1] | length) - (.[0] | length) > 1 then (.[-1] | sort_by(.at) | .[-1].name) else empty end' <<<"$pods"
}

# AC-5.6 reads Locust's cumulative failure rate, which a deliberate node failure would dominate: restart the pod so the
# statistics describe normal operation again (SPEC §6.5 AC-5.6 note). Test cleanup only.
reset_loadgenerator() {
  kubectl -n boutique get deploy loadgenerator >/dev/null 2>&1 || return 0
  kubectl -n boutique delete pod -l app=loadgenerator --wait=true >/dev/null &&
    kubectl -n boutique rollout status deploy/loadgenerator --timeout=300s >/dev/null &&
    echo "loadgenerator restarted: its statistics start over after the deliberate node failure"
}

# ---- images ----------------------------------------------------------------------------------
# image_archs <registry/repo> <tag> → one "os/arch" per line, for manifest lists and single-arch images.
# Uses the registry HTTP API (anonymous), so it needs no docker daemon.
image_archs() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys, urllib.request, urllib.error, re
repo, tag = sys.argv[1], sys.argv[2]
host, _, path = repo.partition("/")
if "." not in host and ":" not in host:           # docker hub shorthand
    host, path = "registry-1.docker.io", repo if "/" in repo else "library/" + repo
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])
token = None
def get(url, accept=None):
    global token
    for attempt in range(2):
        req = urllib.request.Request(url)
        if accept: req.add_header("Accept", accept)
        if token: req.add_header("Authorization", "Bearer " + token)
        try:
            return json.load(urllib.request.urlopen(req, timeout=30))
        except urllib.error.HTTPError as e:
            if e.code == 401 and attempt == 0:
                m = re.search(r'realm="([^"]+)",service="([^"]*)"', e.headers.get("WWW-Authenticate", ""))
                if not m: raise
                t = json.load(urllib.request.urlopen(f"{m.group(1)}?service={m.group(2)}&scope=repository:{path}:pull", timeout=30))
                token = t.get("token") or t.get("access_token")
                continue
            raise
base = f"https://{host}/v2/{path}"
m = get(f"{base}/manifests/{tag}", ACCEPT)
out = set()
if "manifests" in m:
    for d in m["manifests"]:
        p = d.get("platform", {})
        if p.get("os") not in (None, "unknown"): out.add(f'{p["os"]}/{p["architecture"]}')
else:
    cfg = get(f'{base}/blobs/{m["config"]["digest"]}')
    out.add(f'{cfg["os"]}/{cfg["architecture"]}')
print("\n".join(sorted(out)))
PY
}
