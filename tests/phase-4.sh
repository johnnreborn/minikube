#!/usr/bin/env bash
# Phase 4 acceptance tests (SPEC §6.4). Output: [PASS|FAIL|SKIP] AC-4.n ...; exit 1 if a MUST fails.
#   DESTRUCTIVE=1  also run AC-4.5: `docker stop` the worker that announces VIP .30 (restarted by the EXIT trap).
#                  SPEC §7.6 requires it for completing the phase; without it AC-4.5 is reported as SKIP.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"
export PATH="$HOME/.local/bin:$PATH"

CTX=kind-boutique
NS=l4-test
VIP_CLUSTER=172.30.250.30
VIP_LOCAL=172.30.250.31
POOL_FIRST=172.30.250.10
POOL_LAST=172.30.250.250
k() { kubectl --context "$CTX" "$@"; }
if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
  err "current kubectl context is not $CTX (tests/lib.sh helpers use the current context)"; exit 2
fi
ac_should AC-4.4 AC-4.5
REPORT=$(mktemp); on_cleanup "rm -f '$REPORT'"      # measured values, printed also when an AC passes
report() { echo "$*" >>"$REPORT"; }
show_report() { sed 's/^/       /' "$REPORT"; : >"$REPORT"; }
in_pool() { python3 -I -c 'import sys,ipaddress as i; a=i.ip_address(sys.argv[1]); sys.exit(0 if i.ip_address(sys.argv[2])<=a<=i.ip_address(sys.argv[3]) else 1)' "$1" "$POOL_FIRST" "$POOL_LAST"; }
probe_sh() { docker run --rm --label ac-test=true --network "$DOCKER_NETWORK" --entrypoint sh "$CURL_IMAGE" -c "$1"; }
svc_ip() { k -n "$NS" get svc "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null; }

# AC-4.1 ---------------------------------------------------------------------------------------
TMP_SVC=ac-test-lb-$RANDOM
on_cleanup "kubectl --context $CTX -n $NS delete svc -l ac-test=true --ignore-not-found --wait=false"
check_pool() {
  local conflict ip start ok_ips=0 bad=0 line
  conflict=$(k get ippools.cilium.io default-pool -o jsonpath='{.status.conditions[?(@.type=="cilium.io/PoolConflict")].status}')
  echo "default-pool PoolConflict=$conflict"; [[ "$conflict" == False ]] || return 1
  start=$SECONDS
  k apply -f - >/dev/null <<EOF || return 1
apiVersion: v1
kind: Service
metadata: {name: $TMP_SVC, namespace: $NS, labels: {ac-test: "true"}}
spec: {type: LoadBalancer, selector: {app: ac-test-no-backend}, ports: [{port: 80}]}
EOF
  wait_for 30 bash -c "[[ -n \"\$(kubectl --context $CTX -n $NS get svc $TMP_SVC -o jsonpath='{.status.loadBalancer.ingress[0].ip}')\" ]]" ||
    { echo "no IP within 30s"; return 1; }
  ip=$(svc_ip "$TMP_SVC"); echo "new LoadBalancer Service got $ip after $((SECONDS - start))s"
  report "new LoadBalancer Service got $ip after $((SECONDS - start))s"
  in_pool "$ip" || { echo "$ip outside $POOL_FIRST-$POOL_LAST"; return 1; }
  k -n "$NS" delete svc "$TMP_SVC" >/dev/null
  while read -r line; do
    [[ -n "$line" ]] || continue
    in_pool "${line##* }" || { echo "outside pool: $line"; bad=1; }
    ok_ips=$((ok_ips + 1))
  done < <(k get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .metadata.name + " " + (.status.loadBalancer.ingress[0].ip // "0.0.0.0")')
  echo "$ok_ips LoadBalancer Services, all in pool=$((1 - bad))"
  return $bad
}
ac_check AC-4.1 "pool has no conflict; a LoadBalancer Service gets a pool IP within 30s" check_pool
show_report

# AC-4.2 ---------------------------------------------------------------------------------------
check_fixed_ips() {
  local a b; a=$(svc_ip echo-cluster); b=$(svc_ip echo-local)
  echo "echo-cluster=$a (want $VIP_CLUSTER), echo-local=$b (want $VIP_LOCAL)"
  [[ "$a" == "$VIP_CLUSTER" && "$b" == "$VIP_LOCAL" ]]
}
ac_check AC-4.2 "fixed VIP annotations applied: echo-cluster .30, echo-local .31" check_fixed_ips

# AC-4.3 ---------------------------------------------------------------------------------------
# 30 separate curl processes = 30 new connections from outside the cluster (Docker network kind-boutique)
check_distribution() {
  local out ok n backends
  out=$(probe_sh "i=0; while [ \$i -lt 30 ]; do i=\$((i+1)); r=\$(curl -s --max-time 5 -w ' %{http_code}' http://$VIP_CLUSTER/hostname); echo \"\$r\"; done")
  n=$(grep -c . <<<"$out"); ok=$(awk '$NF=="200"' <<<"$out" | wc -l)
  backends=$(awk '$NF=="200" {print $1}' <<<"$out" | sort | uniq -c)
  echo "requests=$n ok=$ok"; echo "$backends"
  report "30 requests: $ok x 200; per backend: $(awk '{printf "%s=%s ", $2, $1}' <<<"$backends")"
  [[ $n -eq 30 && $ok -eq 30 && $(grep -c . <<<"$backends") -ge 2 ]]
}
ac_check AC-4.3 "30 new connections to $VIP_CLUSTER/hostname: 100% 200, at least 2 backends" check_distribution
show_report

# AC-4.4 ---------------------------------------------------------------------------------------
check_source_ip() {
  local out me total match
  out=$(probe_sh "me=\$(hostname -i | awk '{print \$1}'); echo ME \$me; i=0; while [ \$i -lt 10 ]; do i=\$((i+1)); echo SEEN \$(curl -s --max-time 5 http://$VIP_LOCAL/clientip); done")
  me=$(awk '$1=="ME" {print $2}' <<<"$out"); total=$(grep -c '^SEEN' <<<"$out")
  match=$(awk -v me="$me" '$1=="SEEN" {split($2,a,":"); if (a[1]==me) c++} END {print c+0}' <<<"$out")
  echo "probe IP=$me; /clientip equal in $match of $total requests"; echo "$out" | tail -3
  report "echo-local: probe $me, backend saw the probe IP in $match/$total requests"
  [[ -n "$me" && $total -eq 10 && $match -eq 10 ]]
}
ac_check AC-4.4 "echo-local /clientip returns the probe container IP (source preserved)" check_source_ip
show_report

# AC-4.6 (before AC-4.5, which disturbs the cluster) -------------------------------------------
check_hubble_external() {
  local port me out found
  port=$(_pf kube-system hubble-relay 80)
  me=$(probe_sh "hostname -i | awk '{print \$1}'; for i in 1 2 3 4 5 6; do curl -s -o /dev/null --max-time 5 http://$VIP_LOCAL/hostname; done")
  me=$(head -1 <<<"$me")
  [[ -n "$me" ]] || { echo "probe failed"; return 1; }
  wait_for 30 bash -c "hubble observe --server localhost:$port --namespace $NS --since 2m -o jsonpb 2>/dev/null | jq -e --arg ip '$me' 'select(.flow.IP.source==\$ip and (.flow.source.labels // [] | index(\"reserved:world\")) and .flow.destination.namespace==\"$NS\")' >/dev/null"
  out=$(hubble observe --server "localhost:$port" --namespace "$NS" --since 2m -o jsonpb 2>/dev/null)
  found=$(jq -r --arg ip "$me" 'select(.flow.IP.source==$ip and (.flow.source.labels // [] | index("reserved:world")) and .flow.destination.namespace=="'"$NS"'") | [.flow.verdict, .flow.destination.pod_name, (.flow.l4.TCP.destination_port|tostring), .flow.node_name] | @tsv' <<<"$out")
  echo "flows reserved:world($me) -> $NS: $(grep -c . <<<"$found")"; head -3 <<<"$found"
  report "Hubble: $(grep -c . <<<"$found") flows reserved:world($me) -> $NS, e.g. $(head -1 <<<"$found" | tr '\t' ' ')"
  [[ -n "$found" ]]
}
ac_check AC-4.6 "Hubble shows external (reserved:world) -> l4-test flows" check_hubble_external
show_report

# AC-4.5 ---------------------------------------------------------------------------------------
LEASE=cilium-l2announce-$NS.echo-cluster
STOPPED_FILE=$(mktemp); on_cleanup "rm -f '$STOPPED_FILE'"
restore_node() {   # EXIT trap: the stopped node is always started again
  local n; n=$(cat "$STOPPED_FILE" 2>/dev/null || true)
  [[ -n "$n" ]] && docker start "$n"
  docker rm -f ac-failover-probe 2>/dev/null
  true
}
on_cleanup restore_node
node_ready() { k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
# Right after `docker start` the API still shows the values from before the stop (the node controller needs ~50s to
# notice a dead node). Only Ready transitions that happened AFTER the restart count as recovery.
node_recovered() {  # <node> <restart-epoch>: node Ready and every pod on it Ready, all with a transition >= restart
  local node=$1 since=$2
  k get node "$node" -o json | jq -e --argjson t "$since" \
    '.status.conditions[] | select(.type=="Ready") | .status=="True" and ((.lastTransitionTime|fromdateiso8601) >= $t)' >/dev/null || return 1
  k get pods -A --field-selector "spec.nodeName=$node" -o json | jq -e --argjson t "$since" \
    '[.items[] | select(.status.phase!="Succeeded") | (.status.conditions // [] | map(select(.type=="Ready"))[0])]
     | length > 0 and all(.status=="True" and ((.lastTransitionTime|fromdateiso8601) >= $t))' >/dev/null
}
probe_ok_streak() { [[ "$(docker logs --tail 20 ac-failover-probe 2>&1 | grep -c '^200$')" == 20 ]]; }
lease_holder() { k -n kube-system get lease "$LEASE" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
check_failover() {
  local old new="" t0 moved="" t_notready="" t_start ip_before log res
  k wait --for=condition=Ready nodes --all --timeout=60s >/dev/null || { echo "precondition: not all nodes Ready"; return 1; }
  old=$(lease_holder); [[ "$old" == boutique-worker[234] ]] || { echo "unexpected lease holder '$old' (must be an app worker)"; return 1; }
  ip_before=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$old")
  docker rm -f ac-failover-probe >/dev/null 2>&1
  # one long-running probe: a new connection roughly every 0.5s; timestamps come from `docker logs --timestamps`
  docker run -d --name ac-failover-probe --label ac-test=true --network "$DOCKER_NETWORK" --entrypoint sh "$CURL_IMAGE" -c \
    "while true; do c=\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 1 http://$VIP_CLUSTER/hostname); echo \"\$c\"; sleep 0.5; done" >/dev/null || return 1
  sleep 5
  [[ "$(docker logs ac-failover-probe 2>&1 | tail -3 | sort -u)" == 200 ]] || { echo "VIP not healthy before the fault"; return 1; }
  echo "$old" >"$STOPPED_FILE"
  t0=$(date +%s.%N)
  echo "stopping lease holder $old"
  docker stop "$old" >/dev/null || return 1
  local end=$((SECONDS + 60))
  while (( SECONDS < end )); do
    new=$(lease_holder)
    if [[ -n "$new" && "$new" != "$old" ]]; then moved=1; break; fi
    sleep 0.5
  done
  [[ -n "$moved" ]] || { echo "lease did not move within 60s"; return 1; }
  # keep probing until the node controller has noticed the dead node (its backend is then removed) and 20 probes in a
  # row succeed: this measures how long connections keep failing, and guarantees the API status is no longer stale
  end=$((SECONDS + 150))
  while (( SECONDS < end )); do
    [[ "$(node_ready "$old")" != True ]] && { t_notready=$(date +%s.%N); break; }
    sleep 1
  done
  [[ -n "$t_notready" ]] || { echo "node was never marked NotReady"; return 1; }
  sleep 10
  wait_for 90 probe_ok_streak || { echo "no 20 consecutive successful probes within 90s after NotReady"; return 1; }
  log=$(docker logs --timestamps ac-failover-probe 2>&1); docker rm -f ac-failover-probe >/dev/null
  # exact times from the sources of truth - the polling above cannot start before the blocking `docker stop` returns
  local t_down t_acq
  t_down=$(date -u -d "$(docker inspect -f '{{.State.FinishedAt}}' "$old")" +%s.%N)
  t_acq=$(date -u -d "$(k -n kube-system get lease "$LEASE" -o jsonpath='{.spec.acquireTime}')" +%s.%N)
  res=$(python3 -I - "$t0" "$t_down" "$t_acq" "$log" <<'PY'
import sys, datetime
t0, down, acq, log = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
rows = []
for line in log.splitlines():
    ts, code = line.split(' ', 1)
    base, _, frac = ts.rstrip('Z').partition('.')
    t = datetime.datetime.fromisoformat(base).replace(tzinfo=datetime.timezone.utc).timestamp() + float('0.' + (frac or '0'))
    rows.append((t - t0, code.strip()))
down, acq = down - t0, acq - t0
if acq < 0:
    print("STALE_LEASE"); sys.exit()
# "VIP answers again" = first success once the old node is completely down AND the new holder owns the lease
resume = next((t for t, c in rows if t > max(down, acq) and c == '200'), None)
if resume is None:
    print("NORESUME"); sys.exit()
after = [(t, c) for t, c in rows if t >= 0]
# longest run of consecutive failed probes = upper bound of a total VIP blackout (one dead backend of 3 gives short runs)
run_start, longest = None, 0.0
for t, c in after:
    if c != '200':
        run_start = t if run_start is None else run_start
    elif run_start is not None:
        longest, run_start = max(longest, t - run_start), None
fails = [t for t, c in after if c != '200']
print(f"{acq:.1f} {down:.1f} {resume:.1f} {longest:.1f} {len(fails)} {len(after)} {max(fails) if fails else 0:.1f}")
PY
)
  echo "analysis: $res"
  [[ "$res" != STALE_LEASE && "$res" != NORESUME ]] || return 1
  local acq down resume longest nf n last
  read -r acq down resume longest nf n last <<<"$res"
  report "L2 failover: holder $old -> $new (times from the 'docker stop' command): lease acquired by $new at +${acq}s, old node fully down at +${down}s, first success afterwards at +${resume}s"
  report "longest run of consecutive failed probes: ${longest}s; failed probes in total: $nf of $n, last at +${last}s; node marked NotReady at +$(python3 -I -c 'import sys; print(f"{float(sys.argv[1])-float(sys.argv[2]):.1f}")' "$t_notready" "$t0")s, then 20 successes in a row"
  # restore and check recovery
  t_start=$(date -u +%s)
  docker start "$old" >/dev/null || return 1
  : >"$STOPPED_FILE"
  wait_for 300 node_recovered "$old" "$t_start" || { echo "$old and its pods did not become Ready again (fresh status) within 300s"; k get pods -A --field-selector "spec.nodeName=$old"; return 1; }
  local t_rec=$(( $(date -u +%s) - t_start ))
  wait_for 240 bash -c "[[ \"\$(kubectl --context $CTX -n $NS get deploy echo -o jsonpath='{.status.readyReplicas}')\" == 3 ]]" || { echo "echo not 3/3 after restart"; return 1; }
  # apps moved off the dead node stay in the other zones: even them out again (later phases check one pod per zone)
  wait_for 240 bash -c "kubectl --context $CTX -n boutique wait --for=condition=Available deploy --all --timeout=5s >/dev/null 2>&1" ||
    { echo "boutique deployments not Available after the node came back"; return 1; }
  rebalance_zones boutique frontend productcatalogservice currencyservice cartservice frontend-canary || return 1
  report "recovery: $old and all its pods Ready ${t_rec}s after 'docker start' (fresh transitions), echo 3/3; node IP before=$ip_before after=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$old")"
  python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= 30 else 1)' "$resume"
}
if [[ "${DESTRUCTIVE:-0}" == "1" ]]; then
  ac_check AC-4.5 "L2 lease holder stopped: VIP answers again within 30s, node returns Ready" check_failover
  show_report
else
  ac_skip AC-4.5 "node failover not run (set DESTRUCTIVE=1)"
fi

ac_summary 4
