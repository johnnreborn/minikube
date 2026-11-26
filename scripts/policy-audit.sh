#!/usr/bin/env bash
# Network policy audit window (SPEC §6.8 step 3, AC-8.1):  scripts/policy-audit.sh [minutes]   (default 15)
# While Cilium runs in policy audit mode: generates traffic (loadgenerator plus checkout loops through the L4 VIP .20
# and the Gateway, Grafana and Argo CD through the Gateway) and records
#   - every AUDIT verdict (L3/L4 flows the policies would drop)
#   - every L7 HTTP request in boutique (the methods each callee really serves; 403 = an L7 denial, enforced even in
#     audit mode)
# Report: tests/results/phase-8-audit-<UTC>.log; machine-readable summary: tests/.cache/policy-audit-last.json.
# Flows listed in tests/policy-audit-expected.txt (one "src -> dst:port" pattern per line, regex) are expected.
set -euo pipefail
# shellcheck source=bootstrap/scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap/scripts/lib.sh"
load_env
require_cmd kubectl hubble jq docker python3
cd "$REPO_ROOT"

MINUTES=${1:-15}
CTX=kind-boutique
GW_IP=172.30.250.10
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="tests/results/phase-8-audit-$STAMP.log"
SUMMARY=tests/.cache/policy-audit-last.json
EXPECTED=tests/policy-audit-expected.txt
mkdir -p tests/results tests/.cache
k() { kubectl --context "$CTX" "$@"; }
[[ "$(k -n kube-system get cm cilium-config -o jsonpath='{.data.policy-audit-mode}')" == true ]] ||
  die "Cilium is not in policy audit mode - this script is for the audit window only"

TMP=$(mktemp -d)
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  docker rm -f "ac-audit-vip-$$" "ac-audit-gw-$$" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

k -n cert-manager get secret boutique-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d >tests/.cache/ca.crt
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
kubectl --context "$CTX" -n kube-system port-forward svc/hubble-relay "$port:80" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 40); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.5; done

hubble observe --server "localhost:$port" --follow --verdict AUDIT -o jsonpb >"$TMP/audit.json" 2>/dev/null &
PIDS+=($!)
hubble observe --server "localhost:$port" --follow --namespace boutique --protocol http -o jsonpb >"$TMP/l7.json" 2>/dev/null &
PIDS+=($!)

ORDER='order() { B=$1; shift; J=/tmp/j; Y=$(($(date +%Y)+1)); rm -f $J
  curl -s -m 10 "$@" -c $J -b $J -o /dev/null $B/
  curl -s -m 10 "$@" -c $J -b $J -o /dev/null -d product_id=OLJCESPC7Z -d quantity=1 $B/cart
  curl -s -m 20 "$@" -c $J -b $J -o /tmp/o -d email=someone@example.com -d "street_address=1600 Amphitheatre Parkway" \
    -d zip_code=94043 -d "city=Mountain View" -d state=CA -d "country=United States" \
    -d credit_card_number=4432801561520454 -d credit_card_expiration_month=1 -d credit_card_expiration_year=$Y \
    -d credit_card_cvv=672 $B/cart/checkout
  grep -q "Your order is complete" /tmp/o && echo ok || echo fail; }'
docker run -d --name "ac-audit-vip-$$" --label ac-test=true --network kind-boutique --entrypoint sh "$CURL_IMAGE" -c \
  "$ORDER; while true; do order http://172.30.250.20; sleep 5; done" >/dev/null
docker run -d --name "ac-audit-gw-$$" --label ac-test=true --network kind-boutique -v "$REPO_ROOT/tests/.cache:/certs:ro" \
  --entrypoint sh "$CURL_IMAGE" -c "$ORDER; R='--cacert /certs/ca.crt --resolve shop.boutique.test:443:$GW_IP --resolve grafana.boutique.test:443:$GW_IP --resolve argocd.boutique.test:443:$GW_IP'
  while true; do order https://shop.boutique.test \$R
    curl -s -o /dev/null -m 10 \$R https://grafana.boutique.test/api/health
    curl -s -o /dev/null -m 10 \$R https://argocd.boutique.test/healthz
    sleep 5; done" >/dev/null

log "audit window: $MINUTES min (started $(date -u +%FT%TZ))"
start=$(date -u +%FT%TZ)
sleep $((MINUTES * 60))
end=$(date -u +%FT%TZ)
orders_vip=$(docker logs "ac-audit-vip-$$" 2>&1 | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
orders_gw=$(docker logs "ac-audit-gw-$$" 2>&1 | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
PIDS=()
touch "$EXPECTED"

python3 -I - "$TMP/audit.json" "$TMP/l7.json" "$EXPECTED" "$SUMMARY" "$start" "$end" "$MINUTES" "$orders_vip" "$orders_gw" >"$REPORT" <<'PY'
import json, re, sys, collections
audit_f, l7_f, expected_f, summary_f, start, end, minutes, ovip, ogw = sys.argv[1:10]
def ident(ep):
    if not ep: return "?"
    ns = ep.get("namespace")
    if ns:
        w = (ep.get("workloads") or [{}])[0].get("name") or ep.get("pod_name") or "?"
        return f"{ns}/{w}"
    return ",".join(l for l in ep.get("labels", []) if l.startswith("reserved:")) or f"identity:{ep.get('identity')}"
def port(f):
    l4 = f.get("l4", {})
    for p in ("TCP", "UDP"):
        if p in l4: return f"{l4[p].get('destination_port')}/{p}"
    return "?"
expected = [re.compile(l.strip()) for l in open(expected_f) if l.strip() and not l.startswith("#")]
audit = collections.Counter()
for line in open(audit_f):
    try: f = json.loads(line)["flow"]
    except Exception: continue
    audit[f"{ident(f.get('source'))} -> {ident(f.get('destination'))}:{port(f)} ({f.get('traffic_direction','?')})"] += 1
unexpected = {k: v for k, v in audit.items() if not any(p.search(k) for p in expected)}
methods = collections.Counter(); codes = collections.Counter(); denied = collections.Counter()
for line in open(l7_f):
    try: f = json.loads(line)["flow"]
    except Exception: continue
    l7 = f.get("l7") or {}; http = l7.get("http") or {}
    path = re.sub(r"^https?://[^/]+", "", http.get("url", "")); path = re.sub(r"/product/[A-Z0-9]+", "/product/{id}", path)
    callee = ident(f.get("destination")) if l7.get("type") == "REQUEST" else ident(f.get("source"))
    if l7.get("type") == "REQUEST":
        methods[f"{callee} {http.get('method')} {path}"] += 1
    elif l7.get("type") == "RESPONSE":
        codes[f"{callee} {http.get('code')}"] += 1
        if http.get("code") == 403 or f.get("verdict") == "DROPPED":
            denied[f"{ident(f.get('destination'))} -> {callee} {path}"] += 1
print(f"policy audit window {start} .. {end} ({minutes} min)")
print(f"checkout loops: VIP [{ovip.strip()}] Gateway [{ogw.strip()}]")
print(f"\n== AUDIT verdicts (would be dropped): {sum(audit.values())} flows, {len(audit)} distinct, unexpected {len(unexpected)}")
for k, v in audit.most_common(): print(f"{'UNEXPECTED ' if k in unexpected else 'expected   '}{v:6d}  {k}")
print(f"\n== L7 requests per callee (method path): {sum(methods.values())}")
for k, v in sorted(methods.items()): print(f"{v:6d}  {k}")
print("\n== L7 response codes per callee")
for k, v in sorted(codes.items()): print(f"{v:6d}  {k}")
print(f"\n== L7 denials (403): {sum(denied.values())}")
for k, v in denied.most_common(): print(f"{v:6d}  {k}")
json.dump({"start": start, "end": end, "minutes": int(minutes), "audit_flows": sum(audit.values()),
           "unexpected": unexpected, "l7_requests": sum(methods.values()), "l7_denied": sum(denied.values()),
           "methods": sorted(methods)}, open(summary_f, "w"), indent=1)
PY
cat "$REPORT"
ok "report: $REPORT"
