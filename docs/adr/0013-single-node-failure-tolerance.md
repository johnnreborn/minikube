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
- `redis-cart`: 단일 레플리카 유지(상태 저장, emptyDir), unreachable/not-ready toleration 30초
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
- (−) redis-cart가 죽은 노드에 있으면 장바구니가 사라지고, 새 Pod가 뜰 때까지(약 80초 예상) 홈 화면이 실패한다
- (−) 노드가 복구돼도 Pod는 자동으로 재균형되지 않는다(테스트가 복구 후 재분산)
- (−) 부트스트랩 예외가 하나 늘었다(ARCHITECTURE §10.1)
