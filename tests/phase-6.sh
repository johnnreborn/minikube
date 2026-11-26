#!/usr/bin/env bash
# Phase 6 acceptance tests (SPEC §6.6). Output: [PASS|FAIL|SKIP] AC-6.n ...; exit 1 if a MUST fails.
# TLS is always verified against the private root CA (never -k). AC-6.10 creates a temporary namespace (removed again).
# AC-6.6 samples 200 requests against a 10% weight: even a correct setup lands outside 10±5% in about 1.5% of runs.
# The East-West L7 LB item (COULD) is skipped on purpose - see the end of this file.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
GW_IP=172.30.250.10
SHOP=shop.boutique.test
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
ac_should AC-6.8
ac_could AC-6.11
REPORT=$(mktemp); on_cleanup "rm -f '$REPORT'"      # measured values, printed also when an AC passes
report() { echo "$*" >>"$REPORT"; }
show_report() { sed 's/^/       /' "$REPORT"; : >"$REPORT"; }

# public certificate of the private root CA only (never the key)
extract_ca cert-manager boutique-root-ca tls.crt || { err "cannot extract the root CA certificate"; exit 2; }

# https <host> <curl args...>  → curl from the probe container, verified with the private CA
https() { local h=$1; shift; probe_curl -sS --max-time 15 --cacert /certs/ca.crt --resolve "$h:443:$GW_IP" "$@" "https://$h/"; }
# many <n> <extra curl args> → n GETs of the shop (one probe container); prints "<code> <x-variant> <x-served-by>"
many() {
  docker run --rm --label ac-test=true --network "$DOCKER_NETWORK" -v "$CACHE_DIR:/certs:ro" --entrypoint sh "$CURL_IMAGE" -c "
    i=0; while [ \$i -lt $1 ]; do i=\$((i+1))
      rm -f /tmp/h
      curl -s -m 15 --cacert /certs/ca.crt --resolve $SHOP:443:$GW_IP $2 -o /dev/null -D /tmp/h https://$SHOP/
      touch /tmp/h
      awk 'NR==1 {c=\$2} tolower(\$1)==\"x-variant:\" {v=\$2} tolower(\$1)==\"x-served-by:\" {s=\$2} END {print (c ? c : \"000\"), (v ? v : \"-\"), (s ? s : \"-\")}' /tmp/h | tr -d '\r'
    done"
}

# AC-6.1 ---------------------------------------------------------------------------------------
check_gateway() {
  local acc prog addr lb
  acc=$(k -n gateway get gateway edge -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')
  prog=$(k -n gateway get gateway edge -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
  addr=$(k -n gateway get gateway edge -o jsonpath='{.status.addresses[*].value}')
  lb=$(k -n gateway get svc cilium-gateway-edge -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Accepted=$acc Programmed=$prog addresses=$addr service=$lb"
  report "Gateway edge: Accepted=$acc Programmed=$prog address=$addr (Service $lb)"
  [[ "$acc" == True && "$prog" == True && "$addr" == "$GW_IP" && "$lb" == "$GW_IP" ]]
}
ac_check AC-6.1 "Gateway edge Accepted and Programmed with address $GW_IP" check_gateway
show_report

# AC-6.2 ---------------------------------------------------------------------------------------
check_routes() {
  local json bad expected
  json=$(k get httproute -A -o json) || return 1
  for expected in gateway/http-redirect gateway/hubble argocd/argocd boutique/shop; do
    jq -e --arg r "$expected" '[.items[] | select(.metadata.namespace + "/" + .metadata.name == $r)] | length == 1' <<<"$json" >/dev/null ||
      { echo "missing HTTPRoute $expected"; return 1; }
  done
  # every parent of every route: Accepted=True and ResolvedRefs=True for the current generation
  bad=$(jq -r '.items[] | .metadata as $m | ($m.namespace + "/" + $m.name) as $r
    | (if (.status.parents // []) | length == 0 then "\($r): no parent status" else empty end),
      (.status.parents[]? | . as $p | ("Accepted", "ResolvedRefs") as $t
        | ([$p.conditions[] | select(.type == $t and .status == "True" and .observedGeneration == $m.generation)] | length) as $n
        | if $n == 1 then empty else "\($r) parent \($p.parentRef.sectionName // "-"): \($t) not True" end)' <<<"$json") ||
    { echo "jq failed"; return 1; }
  echo "$bad"
  report "$(jq '.items | length' <<<"$json") HTTPRoutes; parent conditions not True: $(grep -c . <<<"$bad")"
  [[ -z "$bad" ]]
}
ac_check AC-6.2 "every HTTPRoute parent is Accepted and ResolvedRefs" check_routes
show_report

# AC-6.3 ---------------------------------------------------------------------------------------
check_tls() {
  local out certs rc
  out=$(https "$SHOP" -o /dev/null -w '%{http_code} %{ssl_verify_result}\n') || return 1
  certs=$(https "$SHOP" -o /dev/null -w '%{certs}') || return 1
  echo "$out"; grep -E 'Issuer:|Subject Alternative Name' <<<"$certs" | head -4
  # negative control: without the private CA the same request must fail certificate verification (curl exit 60)
  probe_curl -s --max-time 15 --resolve "$SHOP:443:$GW_IP" -o /dev/null "https://$SHOP/"; rc=$?
  echo "without --cacert: curl exit $rc"
  report "https://$SHOP/ -> HTTP ${out% *}, ssl_verify_result=${out#* }; issuer $(grep -m1 'Issuer:' <<<"$certs" | sed 's/.*CN *= *//'); $(grep -m1 -o 'DNS:[^ ,]*' <<<"$certs"); without CA: curl exit $rc"
  [[ "$out" == "200 0" && $rc -eq 60 ]] &&
    grep -q 'Issuer:.*boutique-root-ca' <<<"$certs" && grep -q 'DNS:\*\.boutique\.test' <<<"$certs"
}
ac_check AC-6.3 "https://$SHOP/ 200, chain verified by the private CA, SAN *.boutique.test" check_tls
show_report

# AC-6.4 ---------------------------------------------------------------------------------------
check_redirect() {
  local out code loc
  out=$(probe_curl -sS --max-time 15 -I --resolve "$SHOP:80:$GW_IP" "http://$SHOP/") || return 1
  code=$(awk 'NR==1 {print $2}' <<<"$out"); loc=$(awk 'tolower($1)=="location:" {print $2}' <<<"$out" | tr -d '\r')
  echo "HTTP $code Location=$loc"; report "http://$SHOP/ -> $code Location: $loc"
  [[ "$code" == 301 && "$loc" == "https://$SHOP"* ]]
}
ac_check AC-6.4 "http://$SHOP/ redirects 301 to https" check_redirect
show_report

# AC-6.5 ---------------------------------------------------------------------------------------
check_hosts() {
  local h code rc=0 line=""
  for h in argocd.boutique.test:200 hubble.boutique.test:200 nope.boutique.test:404; do
    code=$(https "${h%:*}" -o /dev/null -w '%{http_code}') || code="curl-error"
    echo "${h%:*}: $code (want ${h#*:})"; line+="${h%:*}=$code "
    [[ "$code" == "${h#*:}" ]] || rc=1
  done
  report "$line"
  return $rc
}
ac_check AC-6.5 "argocd and hubble hosts return 200, an undefined host 404" check_hosts
show_report

# AC-6.6 ---------------------------------------------------------------------------------------
check_weights() {
  local out total ok stable canary
  out=$(many 200 "") || return 1
  total=$(grep -c . <<<"$out"); ok=$(awk '$1==200' <<<"$out" | wc -l)
  stable=$(awk '$1==200 && $2=="stable"' <<<"$out" | wc -l); canary=$(awk '$1==200 && $2=="canary"' <<<"$out" | wc -l)
  echo "requests=$total 200=$ok stable=$stable canary=$canary"
  report "200 requests without header: $ok x 200, stable=$stable canary=$canary ($(python3 -I -c "print(f'{100*$canary/200:.1f}')")% canary)"
  [[ $total -eq 200 && $ok -eq 200 && $((stable + canary)) -eq 200 && $canary -ge 10 && $canary -le 30 ]]
}
ac_check AC-6.6 "200 requests: canary share 10% ± 5 points" check_weights
show_report

# AC-6.7 ---------------------------------------------------------------------------------------
check_header_route() {
  local out canary
  out=$(many 20 "-H 'x-canary: always'") || return 1
  canary=$(awk '$1==200 && $2=="canary"' <<<"$out" | wc -l)
  echo "$out" | sort | uniq -c
  report "20 requests with x-canary: always: canary=$canary/20"
  [[ $(grep -c . <<<"$out") -eq 20 && $canary -eq 20 ]]
}
ac_check AC-6.7 "x-canary: always routes 100% to the canary (20/20)" check_header_route
show_report

# AC-6.8 ---------------------------------------------------------------------------------------
check_header_timeout() {
  local out served rules with_timeout
  out=$( { many 5 ""; many 5 "-H 'x-canary: always'"; } ) || return 1
  served=$(awk '$1==200 && $3=="gateway-edge"' <<<"$out" | wc -l)
  rules=$(k -n boutique get httproute shop -o json | jq '.spec.rules | length')
  with_timeout=$(k -n boutique get httproute shop -o json | jq '[.spec.rules[] | select(.timeouts.request == "10s")] | length')
  echo "x-served-by: gateway-edge on $served/10; rules with timeouts.request=10s: $with_timeout/$rules"
  report "x-served-by: gateway-edge on $served/10 responses; $with_timeout/$rules shop rules have timeouts.request=10s (setting checked, expiry not exercised)"
  [[ $served -eq 10 && $rules -ge 1 && $with_timeout -eq $rules ]]
}
ac_check AC-6.8 "x-served-by: gateway-edge on responses and a request timeout is configured" check_header_timeout
show_report

# AC-6.9 ---------------------------------------------------------------------------------------
check_ingress_identity() {
  local port flows
  many 10 "" >/dev/null || return 1
  port=$(_pf kube-system hubble-relay 80)
  flows=$(hubble observe --server "localhost:$port" --namespace boutique --to-label app=frontend --since 3m -o jsonpb 2>/dev/null |
    jq -r 'select((.flow.source.labels // []) | index("reserved:ingress"))
      | select(.flow.destination.namespace == "boutique" and (.flow.destination.pod_name | startswith("frontend-")))
      | [.flow.verdict, .flow.source.identity, .flow.destination.pod_name] | @tsv')
  echo "$flows" | head -3
  report "Hubble: $(grep -c . <<<"$flows") flows from reserved:ingress to frontend pods, e.g. $(head -1 <<<"$flows" | tr '\t' ' ')"
  [[ -n "$flows" ]]
}
ac_check AC-6.9 "Gateway -> frontend flows have source identity reserved:ingress" check_ingress_identity
show_report

# AC-6.10 --------------------------------------------------------------------------------------
TMP_NS=ac-test-gw-$RANDOM
on_cleanup "kubectl --context $CTX delete ns $TMP_NS --ignore-not-found --wait=false"
check_not_allowed() {
  local reason status code
  k apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Namespace
metadata: {name: $TMP_NS, labels: {ac-test: "true"}}
---
apiVersion: v1
kind: Service
metadata: {name: ac-test-backend, namespace: $TMP_NS, labels: {ac-test: "true"}}
spec: {selector: {app: none}, ports: [{port: 80}]}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: ac-test-intruder, namespace: $TMP_NS, labels: {ac-test: "true"}}
spec:
  parentRefs: [{name: edge, namespace: gateway, sectionName: https}]
  hostnames: [ac-test-intruder.boutique.test]
  rules: [{backendRefs: [{name: ac-test-backend, port: 80}]}]
EOF
  wait_for 60 bash -c "kubectl --context $CTX -n $TMP_NS get httproute ac-test-intruder -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].status}' | grep -q ." ||
    { echo "no status from the Gateway controller within 60s"; return 1; }
  status=$(k -n "$TMP_NS" get httproute ac-test-intruder -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')
  reason=$(k -n "$TMP_NS" get httproute ac-test-intruder -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}')
  code=$(https ac-test-intruder.boutique.test -o /dev/null -w '%{http_code}') || code=curl-error
  echo "Accepted=$status reason=$reason; request to its host: $code"
  report "route from unlabelled namespace: Accepted=$status reason=$reason; its host answers $code"
  [[ "$status" == False && "$reason" == NotAllowedByListeners && "$code" == 404 ]]
}
ac_check AC-6.10 "a route from an unlabelled namespace is rejected (NotAllowedByListeners)" check_not_allowed
show_report

# AC-6.11 (COULD) ------------------------------------------------------------------------------
# Not run on purpose. East-West L7 LB was enabled and measured once during Phase 6 (docs/PROGRESS.md) and then
# withdrawn: adding/removing the L7 policy that the measurement needs left some clients without responses for minutes.
ac_skip AC-6.11 "East-West L7 LB not adopted (docs/adr/0010-no-east-west-l7-lb.md); one-time measurement in PROGRESS.md"

ac_summary 6
