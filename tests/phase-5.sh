#!/usr/bin/env bash
# Phase 5 acceptance tests (SPEC §6.5). Output: [PASS|FAIL|SKIP] AC-5.n ...; exit 1 if a MUST fails.
# Takes a bit over 10 minutes: AC-5.1 observes restarts for OBSERVE_SECONDS (default 600) while the quick checks run.
# AC-5.8 scales deploy/frontend by hand (temporary fault injection; Argo CD selfHeal restores it, the trap too).
# Execution order differs from AC order so that the observation window overlaps the other checks.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
NS=boutique
VIP=http://172.30.250.20
# the 12 upstream workloads (v0.10.7) must exist; later phases may add more (frontend-canary in Phase 6)
UPSTREAM_DEPLOYMENTS=(adservice cartservice checkoutservice currencyservice emailservice frontend loadgenerator
  paymentservice productcatalogservice recommendationservice redis-cart shippingservice)
OBSERVE_SECONDS=${OBSERVE_SECONDS:-600}
# order confirmation page marker: src/frontend/templates/order.html of Online Boutique v0.10.7 (versions.env)
ORDER_MARKER='Your order is complete!'
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
ac_should AC-5.9
REPORT=$(mktemp); on_cleanup "rm -f '$REPORT'"      # measured values, printed also when an AC passes
report() { echo "$*" >>"$REPORT"; }
show_report() { sed 's/^/       /' "$REPORT"; : >"$REPORT"; }

# "pod/container restartCount" for every container of every pod in the namespace
restart_snapshot() {
  k -n "$NS" get pods -o json | jq -r '.items[] | .metadata.name as $p
    | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[] | "\($p)/\(.name) \(.restartCount)"' | sort
}
all_available() {
  local d missing=()
  for d in "${UPSTREAM_DEPLOYMENTS[@]}"; do k -n "$NS" get deploy "$d" >/dev/null 2>&1 || missing+=("$d"); done
  (( ${#missing[@]} == 0 )) || { echo "missing deployments: ${missing[*]}"; return 1; }
  k -n "$NS" wait --for=condition=Available deploy --all --timeout=120s >/dev/null || { k -n "$NS" get deploy; return 1; }
}

OBS_START=$SECONDS
OBS_BEFORE=$(restart_snapshot)
AVAILABLE_AT_START=0; all_available >/dev/null 2>&1 && AVAILABLE_AT_START=1

# AC-5.2 ---------------------------------------------------------------------------------------
check_zones() {
  local app zones rc=0
  for app in frontend productcatalogservice; do
    zones=$(k -n "$NS" get pods -l "app=$app" -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .spec.nodeName' |
      while read -r n; do k get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'; done | sort | tr '\n' ' ')
    echo "$app: $zones"; report "$app zones: $zones"
    [[ "$zones" == "zone-a zone-b zone-c " ]] || rc=1
  done
  return $rc
}
ac_check AC-5.2 "frontend and productcatalogservice have one pod in each of zone-a/b/c" check_zones
show_report

# AC-5.3 ---------------------------------------------------------------------------------------
check_pools() {
  local total=0 bad=0 pod node pool
  while read -r pod node; do
    [[ -n "$pod" ]] || continue
    total=$((total + 1))
    pool=$(k get node "$node" -o jsonpath='{.metadata.labels.node\.boutique\.io/pool}')
    [[ "$pool" == app ]] || { echo "$pod on $node (pool='${pool:-none}')"; bad=$((bad + 1)); }
  done < <(k -n "$NS" get pods -o json | jq -r '.items[] | .metadata.name + " " + .spec.nodeName')
  echo "$total pods, $bad outside the app pool"; report "$total boutique pods, $bad on infra/control-plane nodes"
  [[ $total -gt 0 && $bad -eq 0 ]]
}
ac_check AC-5.3 "no boutique pod on the infra or control-plane nodes" check_pools
show_report

# AC-5.4 ---------------------------------------------------------------------------------------
check_home() {
  local out code n
  out=$(probe_curl -sS --max-time 15 -w '\nHTTP_CODE %{http_code}' "$VIP/") || return 1
  code=$(awk '$1=="HTTP_CODE" {print $2}' <<<"$out"); n=$(grep -o 'href="/product/[A-Z0-9]*"' <<<"$out" | sort -u | wc -l)
  echo "HTTP $code, $n distinct product links"; report "GET $VIP/: HTTP $code, $n distinct /product/ links"
  [[ "$code" == 200 && $n -gt 0 ]]
}
ac_check AC-5.4 "$VIP/ returns 200 with product links (L4 VIP)" check_home
show_report

# AC-5.5 ---------------------------------------------------------------------------------------
# One probe container with a cookie jar: session, add to cart, checkout (test card the UI pre-fills).
ORDER_SCRIPT='
J=/tmp/cookies; B='"$VIP"'
echo "home $(curl -s -m 15 -c $J -b $J -o /tmp/home -w %{http_code} $B/)"
P=$(grep -o "href=\"/product/[A-Z0-9]*\"" /tmp/home | head -1 | sed "s/.*product\///;s/\"//")
echo "product $P"
echo "add $(curl -s -m 15 -c $J -b $J -o /dev/null -w %{http_code} -d product_id=$P -d quantity=2 $B/cart)"
echo "incart $(curl -s -m 15 -c $J -b $J $B/cart | grep -c "/product/$P")"
Y=$(($(date +%Y) + 1))
echo "checkout $(curl -s -m 30 -c $J -b $J -o /tmp/order -w %{http_code} \
  -d email=someone@example.com -d "street_address=1600 Amphitheatre Parkway" -d zip_code=94043 \
  -d "city=Mountain View" -d state=CA -d "country=United States" -d credit_card_number=4432801561520454 \
  -d credit_card_expiration_month=1 -d credit_card_expiration_year=$Y -d credit_card_cvv=672 $B/cart/checkout)"
echo "marker $(grep -c "'"$ORDER_MARKER"'" /tmp/order)"
echo "orderid $(grep -o "[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}" /tmp/order | head -1)"
'
check_order() {
  local out; out=$(docker run --rm --label ac-test=true --network "$DOCKER_NETWORK" --entrypoint sh "$CURL_IMAGE" -c "$ORDER_SCRIPT") || return 1
  echo "$out"
  field() { awk -v f="$1" '$1==f {print $2}' <<<"$out"; }
  report "order: home $(field home), add $(field add), checkout $(field checkout), marker $(field marker), order id $(field orderid)"
  [[ "$(field home)" == 200 && -n "$(field product)" && "$(field add)" == 302 && "$(field incart)" -ge 1 &&
     "$(field checkout)" == 200 && "$(field marker)" -ge 1 && -n "$(field orderid)" ]]
}
ac_check AC-5.5 "add to cart -> checkout -> '$ORDER_MARKER' (cookies kept)" check_order
show_report

# AC-5.7 ---------------------------------------------------------------------------------------
check_pdb_resources() {
  local min missing n
  min=$(k -n "$NS" get pdb frontend -o jsonpath='{.spec.minAvailable}') || return 1
  echo "pdb/frontend minAvailable=$min $(k -n "$NS" get pdb frontend -o jsonpath='healthy={.status.currentHealthy} allowed={.status.disruptionsAllowed}')"
  missing=$(k -n "$NS" get pods -o json | jq -r '.items[] | .metadata.name as $p | ((.spec.initContainers // []) + .spec.containers)[]
    | select((.resources.requests.cpu and .resources.requests.memory and .resources.limits.cpu and .resources.limits.memory) | not)
    | "\($p)/\(.name)"')
  n=$(k -n "$NS" get pods -o json | jq '[.items[] | ((.spec.initContainers // []) + .spec.containers)[]] | length')
  [[ -z "$missing" ]] || { echo "containers without cpu+memory requests and limits:"; echo "$missing"; }
  report "pdb/frontend minAvailable=$min; $n containers (incl. init), $(grep -c . <<<"$missing") without requests+limits"
  [[ "$min" == 2 && -z "$missing" && $n -gt 0 ]]
}
ac_check AC-5.7 "PDB frontend minAvailable 2; every container has cpu+memory requests and limits" check_pdb_resources
show_report

# AC-5.1 ---------------------------------------------------------------------------------------
echo "       observing restarts: waiting until ${OBSERVE_SECONDS}s have passed since the start of the window"
while (( SECONDS - OBS_START < OBSERVE_SECONDS )); do sleep 10; done
check_stable() {
  local after delta
  [[ $AVAILABLE_AT_START == 1 ]] || { echo "not all deployments Available at the start of the window"; return 1; }
  all_available || return 1
  after=$(restart_snapshot)
  # increase per container over the window; a container that appeared during the window counts with all its restarts
  delta=$(awk 'NR==FNR {b[$1]=$2; next} {d=$2-b[$1]; if (d>0) print $1, d}' <(echo "$OBS_BEFORE") <(echo "$after"))
  local sum; sum=$(awk '{s+=$2} END {print s+0}' <<<"$delta")
  echo "restarts during ${OBSERVE_SECONDS}s: $sum"; echo "$delta"
  report "$(k -n "$NS" get deploy --no-headers | wc -l) deployments (incl. ${#UPSTREAM_DEPLOYMENTS[@]} upstream) Available; restarts during ${OBSERVE_SECONDS}s window: $sum (namespace total); restartCount total since pod start: $(awk '{s+=$2} END {print s+0}' <<<"$after")"
  [[ $sum -le 1 ]]
}
ac_check AC-5.1 "all deployments Available; at most 1 restart in the namespace over ${OBSERVE_SECONDS}s" check_stable
show_report

# AC-5.6 ---------------------------------------------------------------------------------------
# Locust (headless) prints cumulative statistics since the loadgenerator started; the last "Aggregated" row counts
# every request, including those made while the other services were still starting.
check_load() {
  local line reqs fails
  line=$(k -n "$NS" logs deploy/loadgenerator -c main --tail=200 | grep -E '^ +Aggregated +[0-9]+ +[0-9]+\(' | tail -1)
  [[ -n "$line" ]] || { echo "no Locust statistics in the log"; return 1; }
  read -r reqs fails < <(sed -E 's/^ +Aggregated +([0-9]+) +([0-9]+)\(.*/\1 \2/' <<<"$line")
  local rate; rate=$(python3 -I -c 'import sys; r,f=int(sys.argv[1]),int(sys.argv[2]); print(f"{100*f/r:.2f}" if r else "100")' "$reqs" "$fails")
  echo "$line"; report "Locust cumulative: $reqs requests, $fails failures ($rate%)"
  # a handful of requests would make "< 1%" meaningless
  [[ $reqs -ge 100 ]] || { echo "too few requests to judge ($reqs)"; return 1; }
  python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 1 else 1)' "$rate"
}
ac_check AC-5.6 "loadgenerator failure rate < 1% (Locust statistics)" check_load
show_report

# AC-5.8 ---------------------------------------------------------------------------------------
on_cleanup "kubectl --context $CTX -n $NS scale deploy/frontend --replicas=3"
check_selfheal() {
  local start=$SECONDS t_spec
  k -n "$NS" scale deploy/frontend --replicas=1 || return 1
  wait_for 180 bash -c "[[ \"\$(kubectl --context $CTX -n $NS get deploy frontend -o jsonpath='{.spec.replicas}')\" == 3 ]]" ||
    { echo "spec.replicas not restored within 180s"; return 1; }
  t_spec=$((SECONDS - start))
  wait_for $((180 - t_spec)) bash -c "[[ \"\$(kubectl --context $CTX -n $NS get deploy frontend -o jsonpath='{.status.readyReplicas}')\" == 3 ]]" ||
    { echo "not 3 ready replicas within 180s"; return 1; }
  echo "spec restored after ${t_spec}s, 3 ready after $((SECONDS - start))s"
  report "scaled to 1 by hand: spec back to 3 after ${t_spec}s, 3 ready after $((SECONDS - start))s"
}
ac_check AC-5.8 "selfHeal: manual scale to 1 is restored to 3 ready replicas within 3 minutes" check_selfheal
show_report

# AC-5.9 ---------------------------------------------------------------------------------------
# server-side dry run: nothing changes. kube-system is the positive control - it must produce warnings, otherwise an
# empty list for boutique would prove nothing.
PSA_LIST="$RESULTS_DIR/phase-5-psa-restricted-$(date -u +%Y%m%dT%H%M%SZ).log"
check_psa_list() {
  local out control n
  control=$(k label --dry-run=server ns kube-system pod-security.kubernetes.io/enforce=restricted --overwrite 2>&1) || return 1
  grep -q '^Warning:' <<<"$control" || { echo "control namespace produced no warnings: dry run does not evaluate pods"; return 1; }
  out=$(k label --dry-run=server ns "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite 2>&1) || return 1
  printf '%s\n' "$out" >"$PSA_LIST"
  n=$(grep -c '^Warning:' <<<"$out")
  echo "$out"
  report "PSA restricted dry run on $NS: $n warning lines (control kube-system: $(grep -c '^Warning:' <<<"$control")); list: ${PSA_LIST#"$REPO_ROOT"/}"
  sed -n 's/^Warning: /  /p' <<<"$out" >>"$REPORT"
}
ac_check AC-5.9 "PSA restricted violation list produced (input for Phase 8)" check_psa_list
show_report

ac_summary 5
