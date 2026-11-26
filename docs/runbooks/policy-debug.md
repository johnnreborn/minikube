# 런북: 네트워크 정책 디버깅

증상 예: 앱 간 호출이 타임아웃(L3/L4 차단) 또는 gRPC `grpc-status: 7 Access denied`(L7 차단),
`HubblePolicyDropsDetected` 알림.

원칙: **정책은 Git에서만 고친다**(`platform/policies/`). `kubectl edit`는 selfHeal이 되돌린다. 문제가 급하면
정책 커밋을 `git revert` 한다. **감사 모드(`policyAuditMode`)를 다시 켜서 문제를 숨기지 않는다**(CLAUDE.md).

## 1. 무엇이 차단됐는지 본다

```bash
kubectl -n kube-system port-forward svc/hubble-relay 18245:80 &
hubble observe --server localhost:18245 --namespace boutique --verdict DROPPED --since 10m -o compact
# L3/L4: drop_reason_desc 가 POLICY_DENIED 인지 확인
hubble observe --server localhost:18245 --namespace boutique --verdict DROPPED --since 10m -o jsonpb |
  jq -r '.flow | [.source.pod_name, .destination.pod_name, .drop_reason_desc, (.l4.TCP.destination_port // "-")] | @tsv'
# L7: 프록시가 거부한 HTTP/gRPC 요청
hubble observe --server localhost:18245 --namespace boutique --protocol http --since 10m -o compact | grep -v FORWARDED
```

- `POLICY_DENIED` 외의 사유(`Stale or unroutable IP` 등)는 정책 문제가 아니다. 롤아웃 직후 이전 Pod IP로 가는
  패킷에서 흔히 보인다.
- Hubble 링버퍼는 짧다. 오래된 일은 Prometheus의 `hubble_policy_verdicts_total{action="dropped"}`로 본다.

## 2. L7 거부의 모양

- gRPC 요청: **HTTP 200 + `grpc-status: 7`, `grpc-message: Access denied`, `server: envoy`**, Hubble L7 `DROPPED`
- 일반 HTTP: 403
- 백엔드가 응답한 gRPC 오류(예: `grpc-status: 13`)는 프록시 거부가 아니다

신원을 보존한 재현(SPEC §7.3, 셸 없는 이미지도 가능):

```bash
kubectl -n boutique debug pod/<checkoutservice-pod> --image=<curl 이미지(versions.env CURL_IMAGE)> \
  --target=server --profile=restricted --container=dbg-$(date +%s) -- \
  curl -s -m 10 -o /dev/null -w '%{http_code}\n' http://cartservice:7070/
```

라벨을 흉내 낸 테스트 Pod는 Service 셀렉터에 잡혀 실제 트래픽을 받을 수 있으니 쓰지 않는다.

## 3. 정책 상태를 확인한다

```bash
kubectl get ciliumnetworkpolicy,networkpolicy -A
# 모든 agent에서 감사 모드가 꺼져 있는지 (false 여야 한다)
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.policy-audit-mode}{"\n"}'
# boutique 엔드포인트가 양방향(both) 집행인지 (agent마다 자기 노드의 엔드포인트만 안다)
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec $p -c cilium-agent -- cilium-dbg endpoint list -o json |
    jq -r '.[] | select((.status.labels["security-relevant"] // []) | index("k8s:io.kubernetes.pod.namespace=boutique"))
           | .status.policy.realized["policy-enabled"]'
done | sort | uniq -c
argocd app get policies --core      # kube context namespace가 argocd인 사본 kubeconfig 필요(argocd-sync-failure.md)
```

## 4. 자주 있는 원인

| 증상 | 확인할 것 |
|---|---|
| 새 연결만 실패 | 포트는 **컨테이너 포트**다(frontend 8080, emailservice 8080 — Service 포트가 아니다) |
| 외부에서 Gateway를 거친 요청이 차단 | 출발 identity는 `reserved:ingress` → `fromEntities: [ingress]` |
| 이름 해석 실패 | `dns.yaml`(kube-dns 53, DNS 프록시 `matchPattern "*"`) |
| L7 정책을 새로 넣은 뒤 일부 호출이 검사를 비켜 감 | 이미 열린 연결은 프록시를 거치지 않는다. 호출자 Pod를 Git 어노테이션(`boutique.test/l7-proxy-epoch`)으로 재시작 |
| 업스트림 버전을 올린 뒤 거부 | 새 gRPC 메서드. 감사 절차(`scripts/policy-audit.sh`)로 관측해 화이트리스트와 SPEC §5.6을 갱신 |
| frontend → `169.254.169.254:80` 차단 | 예상된 차단(`tests/policy-audit-expected.txt`) |

## 5. 정책을 바꿀 때의 절차

1. L7을 새로 넣을 때는 먼저 가시성 규칙(`rules: {http: [{}]}`)으로 배포하고 실제 호출을 관측한다
   (감사 모드는 L3/L4만 감사하고 L7은 집행한다).
2. `platform/policies/<ns>/`를 고치고 `make lint` → commit → push → `make wait-sync`.
3. 음성·양성 확인: `make verify-phase N=8`.
