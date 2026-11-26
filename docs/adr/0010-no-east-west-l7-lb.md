# ADR-0010: East-West L7 로드밸런싱(Cilium lb-l7)은 채택하지 않는다

- 상태: Accepted (사용자 승인 2026-11-26)
- 날짜: 2026-11-26

## 맥락
SPEC §5.5의 COULD 항목(AC-6.11, Q4에서 포함 결정)은 gRPC의 장수명 HTTP/2 연결 때문에 생기는 productcatalogservice 레플리카 간 쏠림을
Cilium의 Envoy 기반 L7 LB(`loadBalancer.l7.backend: envoy` + Service 어노테이션 `service.cilium.io/lb-l7: enabled`, Cilium 1.20에서 **beta**)로
해소하는 실험이다. 요청 단위 데이터를 얻으려면 L7 가시성이 필요해, 측정 중에만 전부 허용 L7 CiliumNetworkPolicy를 적용했다(SPEC 변경, 사용자 승인).

Phase 6에서 Git으로 켜고 측정했다(Hubble L7 플로우, 목적지 측 `INGRESS REQUEST`, 부하: 상품 페이지 150회 + loadgenerator).

| 상태 | 실행 | 레플리카별 요청 수 | max/min |
|---|---|---|---|
| L7 LB 끔 | 1 | 338 / 158 / 612 | 3.87 |
| L7 LB 끔 | 2 | 161 / 0 / 970 | ∞ |
| L7 LB 켬 | 1 | 377 / 377 / 378 | 1.00 |
| L7 LB 켬 | 2 | 364 / 365 / 364 | 1.00 |

분산 효과는 확인됐다. 그러나 이후 같은 정책을 다시 적용하자(11:24:38~11:35:33 UTC) 일부 frontend Pod의 상품 페이지 요청 대부분이 응답 없이 멈췄다.

- 정책이 적용된 동안 계속됐고, 제거 후 약 2분 뒤(11:37:49) 스스로 회복했다. recommendationservice 1회 재시작(liveness 실패)
- 클라이언트 측 L7 플로우에서 frontend 2개 Pod의 요청 다수가 응답 없음, Envoy `upstream_cx_destroy_remote_with_active_rq=15`
- loadgenerator 실패는 정책 적용·제거 시간대에 몰렸다. L7 LB를 켜기 전의 측정 시간대에도 소수(약 6건) 있었다(당시 agent 로그는 재시작으로 사라져 정책 적용 시각은 실행 순서 기준 추정)
- 정책 없이 L7 LB만 켠 상태에서는 새 실패를 보지 못했지만, 관찰 시간이 1분 남짓(Gateway 요청 200건 전부 200 포함)이라 근거로는 약하다
- **근본 원인은 확정하지 못했다.** L7 정책이 상시 적용된 상태에서 L7 LB가 안정적인지도 확인하지 않았다

## 결정
East-West L7 LB를 채택하지 않는다. 관련 커밋을 `git revert`로 되돌렸다(`dec3a6f`, `4394754`, `6826279`). AC-6.11 테스트는 사유를 남긴 SKIP이다.
측정 스크립트는 Git 이력(`9a22c85`)에 남아 있다.

## 대안
- 유지하고 Phase 8에서 검증: Phase 8은 같은 서비스에 L7 정책을 상시 적용하므로, 원인을 모르는 장애 요인을 안고 보안 정책을 검증하게 된다
- 상시 정책 상태를 먼저 실험: 판단 근거는 늘지만 앱 장애를 다시 일으킬 수 있다
- 서비스 메시(Istio 등) 또는 클라이언트 측 LB(headless Service + gRPC round_robin): 범위 밖(향후 후보). 후자는 업스트림 앱 설정 변경이 필요하다

## 결과
- (+) Phase 8의 L7 정책 검증이 L7 LB 상호작용 없이 진행된다
- (−) productcatalogservice의 요청 쏠림은 남는다(Phase 7 대시보드에서 관찰 대상)
- (−) 함께 되돌린 `rollOutCiliumPods`가 없으면 Cilium ConfigMap만 바뀌는 변경은 수동 sync 후에도 agent에 적용되지 않는다. Phase 8의 `policyAuditMode` 전환 전에 해결해야 한다
- 다시 검토할 조건: Cilium에서 lb-l7이 stable이 되거나, 격리 환경에서 L7 정책 상시 적용 상태의 안정성을 재현·확인했을 때
