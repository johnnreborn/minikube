# ADR-0013: 앱 워커 1대 장애를 견디도록 요청 경로를 이중화하고 CoreDNS를 분산한다

- 상태: Accepted (사용자 승인 2026-11-27)
- 날짜: 2026-11-27

## 맥락
AC-9.2는 zone-b 워커를 끈 상태에서 `https://shop.boutique.test/`가 90초 안에 회복되고 frontend 3 레플리카가 2분 안에 복원되기를
요구한다. Phase 9 착수 점검에서 Phase 8까지의 구성은 이를 만족할 수 없거나, 만족 여부가 Pod 배치에 달려 있었다.

1. **존 분산 제약**: frontend·productcatalogservice의 `DoNotSchedule`은 `nodeTaintsPolicy` 기본값(`Ignore`)이라 죽은 노드의 존도
   분산 계산에 남는다. 남은 두 존에 1개씩 있으면 대체 Pod는 어디에도 놓일 수 없어 Pending이 된다.
2. **CoreDNS**: kubeadm의 anti-affinity는 `preferred`뿐이고, 클러스터 생성 시 Ready 노드가 하나뿐이라 2개가 같은 노드(관측: zone-b
   워커)에 몰렸다. 그 노드가 죽으면 새 DNS 조회가 모두 실패한다.
3. **단일 레플리카**: 기본 toleration(300초)이라, 홈 화면 요청 경로(currency, cart → redis)나 카나리(shop 요청의 10%)가 죽은 노드에
   있으면 약 6분 동안 오류가 난다. 배치는 재구축할 때마다 달라진다.

## 결정
- `currencyservice`, `cartservice`, `frontend-canary`: 2 레플리카, zone 분산(`DoNotSchedule`, `nodeTaintsPolicy: Honor`,
  `matchLabelKeys: [pod-template-hash]`)
- `frontend`, `productcatalogservice`: 분산 제약에 `nodeTaintsPolicy: Honor`
- `redis-cart`: 단일 레플리카 유지(상태 저장, emptyDir), unreachable/not-ready toleration 10초(처음 결정은 30초, 아래 개정)
- boutique 전 Pod: `dnsConfig.options` `timeout: 1`, `attempts: 3`(아래 개정)
- CoreDNS: 부트스트랩이 hostname 분산(`DoNotSchedule`, `nodeTaintsPolicy: Honor`) 패치를 적용(kubeadm 관리 리소스라 Argo CD 대상 아님)

## 대안
- 전 Deployment에 toleration 30초만: 자원은 늘지 않지만 cartservice는 readiness `initialDelaySeconds: 15` 때문에 NotReady(약 46초) +
  30초 + 15초 > 90초가 될 것으로 예상된다
- 단일 서비스는 그대로: 합격 여부가 Pod 배치(운)에 달린다
- redis 복제(Sentinel 등): 상태 저장 구성은 이 실습 범위를 넘는다
- zone-b를 피하는 nodeAffinity: 테스트를 맞추기 위한 배치일 뿐 장애 내성이 아니다

## 결과
- (+) 앱 워커 1대가 죽어도 홈 화면 요청 경로의 모든 서비스에 살아 있는 백엔드가 있거나(redis 제외) 곧 다시 뜬다
- (−) requests가 약 +0.4 vCPU / +0.2 GiB (NFR-05 한도 안)
- (−) redis-cart가 죽은 노드에 있으면 장바구니가 사라지고, 새 Pod가 뜰 때까지 홈 화면이 실패한다(toleration 30초일 때 실측 약 85초)
- (−) **보호 범위는 홈 화면(`/`)이다**(v0.10.7 `homeHandler`: currency, productcatalog, cart, ad — ad는 실패해도 표시). 상품·장바구니·결제
  경로의 단일 레플리카(checkout, payment, email, shipping, recommendation, ad)는 죽은 노드에 있으면 약 6분 동안 해당 기능이 실패한다
- (−) 노드가 복구돼도 Pod는 자동으로 재균형되지 않는다(테스트가 복구 후 재분산)
- (−) 부트스트랩 예외가 하나 늘었다(ARCHITECTURE §10.1)

## 개정 (2026-11-27, 두 번째 공식 재구축의 AC-9.2 실패, 사용자 승인)

**측정**(시각은 `docker stop` 기준, redis-cart가 중단한 zone-b 워커에 있던 첫 측정):
- 연속 실패 +0.5초 ~ +84.7초. NotReady +51.8초, 30초 뒤 redis-cart 퇴거, 첫 성공 +85.2초. 한도 90초까지 여유 약 5초
- 약 111초 동안 모두 200이다가 +196.9초에 1건 실패 → 판정상 복구 시점 +197.4초(FAIL)

**마지막 1건의 원인**
- 죽은 노드의 CoreDNS는 NotReady 때 EndpointSlice에서 `ready=false`가 됐는데, 약 144초 뒤 frontend의 DNS 질의 1건이 그 Pod IP로
  전달돼 응답이 없었다(Cilium DNS 프록시 로그 `Timeout waiting for response to forwarded proxied DNS lookup`)
- v0.10.7 `homeHandler`는 홈 요청마다 `net.LookupHost("metadata.google.internal.")`를 실행한다
- 그 요청은 5015ms 만에 200으로 끝났다(트레이스: gRPC 호출은 처음 12ms 안에 끝나고 `ENV_PLATFORM` 로그 전 약 5초가 비어 있음).
  리졸버 기본 타임아웃 5초 뒤의 재시도로 판단. 프로브의 요청 제한은 5초
- **확인하지 못한 것**: EndpointSlice에서 빠진 백엔드로 Cilium 데이터패스가 질의를 보낸 이유

**결정**
- boutique 전 Pod의 DNS를 `timeout: 1`, `attempts: 3`으로: 질의가 유실되는 이유와 무관하게 한 번의 유실 비용을 약 1초로 줄인다.
  CoreDNS의 업스트림 응답이 1초를 넘으면 재시도가 늘 수 있다(이 클러스터 75분 동안 업스트림 전달 약 1100건 중 1.024초 초과 약 1건)
- redis-cart toleration 10초: NotReady 감지(실측 44~52초) 뒤 대기를 줄여 여유를 확보한다. 대가: 노드가 약 1분 응답이 없으면
  redis-cart가 옮겨지고 장바구니가 사라진다(30초일 때 약 80초)
- AC-9.2는 redis-cart를 중단할 노드에 두고 시작한다(SPEC §6.9 주석)

**대안**: `hostAliases`로 `metadata.google.internal` 고정 — 조회가 성공해 frontend가 플랫폼을 GCP로 표시한다. 요청 제한이나
90초 기준을 늘리기 — 기준 하향이라 채택하지 않는다
