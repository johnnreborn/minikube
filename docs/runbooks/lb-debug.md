# 런북: L4 VIP · Gateway(L7) 디버깅

VIP는 Cilium LB-IPAM(풀 `172.30.250.10–250`) + L2 Announcements다. 고정 VIP: Gateway `.10`,
`frontend-external` `.20`, l4-test `.30`/`.31`. VIP 하나는 한 번에 **노드 1대**가 ARP에 응답한다(Kubernetes Lease).

## 1. 할당과 광고 상태

```bash
kubectl get svc -A | grep LoadBalancer                 # EXTERNAL-IP 가 <pending>이면 LB-IPAM 문제
kubectl get ciliumloadbalancerippools.cilium.io default-pool -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl get ciliuml2announcementpolicies.cilium.io
kubectl -n kube-system get lease | grep l2announce      # HOLDER = ARP에 응답하는 노드
```

- `PoolConflict=True`: 풀이 겹친다. Lease가 없으면: 광고 정책의 `nodeSelector`(app 풀)와 Cilium values의
  `l2announcements.enabled`를 확인한다.

## 2. 클러스터 밖에서 확인

호스트(Linux/WSL)에서는 VIP로 바로 접속할 수 있다. macOS(Docker Desktop)는 닿지 않으므로 같은 Docker 네트워크에서
확인한다(테스트와 같은 방식, `versions.env`의 이미지 사용):

```bash
source versions.env
docker run --rm --network kind-boutique "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}\n' http://172.30.250.20/
docker run --rm --network kind-boutique "$NETSHOOT_IMAGE" arping -c 3 -I eth0 172.30.250.10   # 응답 MAC = holder 노드
docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' $(docker ps -q --filter name=boutique-)
```

## 3. 데이터플레인(eBPF)

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A3 '172.30.250.30'
# 백엔드가 (active) 상태로 여러 개 보여야 한다
kubectl -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>
```

`externalTrafficPolicy: Local`은 L2 Announcements와 공식 비호환이다(ADR-0003). 운영 Service는 `Cluster`만 쓴다.

## 4. Gateway API (L7)

```bash
kubectl -n gateway get gateway edge -o jsonpath='{.status.addresses[*].value} {range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl get httproute -A
kubectl -n <ns> get httproute <name> -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}'
kubectl -n gateway get certificate
```

| 증상 | 원인 후보 |
|---|---|
| `Accepted=False (NotAllowedByListeners)` | Route 네임스페이스에 `gateway-access: "true"` 라벨이 없다 |
| 404 | `hostnames` 불일치, 또는 Route가 `https` 리스너가 아닌 곳에 붙음 |
| 503 `no healthy upstream` | 백엔드 Ready Pod 없음(특히 `frontend-canary`, 10% 요청) |
| TLS 검증 실패 | 클러스터를 다시 만들면 CA가 바뀐다 → `docs/runbooks/access.md`로 CA를 다시 추출 (`curl -k` 금지) |

## 5. 노드 장애 때

- VIP holder가 죽으면 다른 app 노드가 Lease를 가져간다(정상 종료 약 1초, Phase 4 측정).
- 그러나 죽은 노드의 **백엔드**는 노드가 NotReady로 표시될 때까지(약 40~50초) 남아 일부 새 연결이 실패한다.
- 노드가 돌아오면 Pod는 자동으로 존 균형을 맞추지 않는다(ADR-0013). 한 존에 몰린 앱은 Pod를 지워 재배치한다.
