#!/usr/bin/env bash
# East-West request distribution over the productcatalogservice replicas (AC-6.11).
#   scripts/measure-lb-ratio.sh [pages]     (default 150 product pages of extra load through the L4 VIP)
# Per-request data needs L7 visibility, so for the duration of the measurement only, an allow-all L7
# CiliumNetworkPolicy is applied to productcatalogservice ingress (temporary, label ac-test, removed by the EXIT trap).
# Counted: Hubble L7 HTTP REQUEST flows on the destination side whose path is a ProductCatalogService method (gRPC
# health checks excluded), per destination pod. Prints "<pod> <requests>" per replica and a final line
# "TOTAL <n> MAX_MIN <ratio>". Exit 1 if nothing was counted.
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/scripts/lib.sh"
load_env
require_cmd kubectl hubble jq docker python3

PAGES=${1:-150}
CTX=kind-boutique
NS=boutique
POLICY=ac-test-l7-visibility
k() { kubectl --context "$CTX" "$@"; }
TMP=$(mktemp -d)
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  k -n "$NS" delete ciliumnetworkpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

replicas=$(k -n "$NS" get pods -l app=productcatalogservice -o json |
  jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' | sort)
[[ $(grep -c . <<<"$replicas") -ge 2 ]] || die "fewer than 2 productcatalogservice replicas"

log "applying temporary L7 visibility policy $NS/$POLICY"
k apply -f - >/dev/null <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: $POLICY
  namespace: $NS
  labels: {ac-test: "true"}
spec:
  description: temporary allow-all L7 visibility for scripts/measure-lb-ratio.sh
  endpointSelector:
    matchLabels: {app: productcatalogservice}
  ingress:
    - fromEntities: [all]
      toPorts:
        - ports: [{port: "3550", protocol: TCP}]
          rules:
            http:
              - {}
EOF
sleep 15   # let the agents regenerate the endpoints; clients reconnect through the visibility proxy

port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
# kubectl directly, not through k(): $! must be kubectl itself or the cleanup would only kill a wrapper subshell
kubectl --context "$CTX" -n kube-system port-forward svc/hubble-relay "$port:80" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 40); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.5; done

# stream (not the ring buffer, which could overflow) for as long as the load runs
hubble observe --server "localhost:$port" --follow --protocol http --to-label app=productcatalogservice \
  -o jsonpb >"$TMP/flows.json" 2>"$TMP/hubble.err" &
HUBBLE_PID=$!
PIDS+=("$HUBBLE_PID")
sleep 3

log "load: $PAGES product pages through http://172.30.250.20/ (plus the loadgenerator's own traffic)"
docker run --rm --label ac-test=true --network kind-boutique --entrypoint sh "$CURL_IMAGE" -c "
  ids='0PUK6V6EV0 1YMWWN1N4O 2ZYFJ3GM2N 66VCHSJNUP 6E92ZMYYFZ 9SIQT8TOJO L9ECAV7KIM LS4PSXUNUM OLJCESPC7Z'
  ok=0; i=0
  while [ \$i -lt $PAGES ]; do
    for id in \$ids; do
      [ \$i -lt $PAGES ] || break
      i=\$((i+1))
      c=\$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://172.30.250.20/product/\$id)
      [ \"\$c\" = 200 ] && ok=\$((ok+1))
    done
  done
  echo \"pages ok: \$ok/\$i\"" >&2
sleep 5
kill "$HUBBLE_PID" 2>/dev/null || true

jq -r 'select(.flow.l7.type == "REQUEST" and .flow.traffic_direction == "INGRESS")
       | select((.flow.l7.http.url // "") | test("/hipstershop\\.ProductCatalogService/"))
       | .flow.destination.pod_name' "$TMP/flows.json" 2>/dev/null | sort | uniq -c >"$TMP/counts" || true

python3 -I - "$TMP/counts" "$replicas" <<'PY'
import sys
counts = {}
for line in open(sys.argv[1]):
    n, pod = line.split()
    counts[pod] = int(n)
pods = sys.argv[2].split()
total = sum(counts.get(p, 0) for p in pods)
for p in pods:
    print(p, counts.get(p, 0))
if total == 0:
    print("TOTAL 0 MAX_MIN n/a"); sys.exit(1)
lo = min(counts.get(p, 0) for p in pods); hi = max(counts.get(p, 0) for p in pods)
print(f"TOTAL {total} MAX_MIN {'inf' if lo == 0 else f'{hi / lo:.2f}'}")
PY
