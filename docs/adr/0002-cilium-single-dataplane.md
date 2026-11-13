# ADR-0002: Cilium을 CNI·kube-proxy 대체·L4/L7·관측 단일 스택으로 채택

- 상태: Proposed
- 날짜: 2026-11-14

## 맥락
네트워크 격리, L4/L7 부하분산, 네트워크 관측을 모두 요구한다. 구성요소가 늘어날수록 경계(예: LB 컨트롤러와 CNI, Ingress와 정책)의 상호작용 문제가 커진다.

## 결정
Cilium 1.20을 다음 용도로 사용한다: CNI(eBPF), kube-proxy 완전 대체, LB-IPAM + L2 Announcements(L4), Gateway API(L7, 내장 Envoy), CiliumNetworkPolicy(L3/L4/L7, DNS), Hubble(플로우·메트릭).

## 대안
- Calico + MetalLB + Envoy Gateway: 각 분야의 성숙한 구현이지만 구성요소 3개, L7 정책은 별도 메시 필요
- Calico + MetalLB + Istio(ambient): L7 기능은 풍부하나 학습·자원 비용이 큼

## 결과
- (+) 정책 identity가 L4/L7/Gateway 전 경로에서 일관(`reserved:ingress` 등), Hubble로 정책 판정 직접 관측
- (+) gRPC 메서드 단위 정책과 L7 메트릭을 사이드카 없이 확보
- (−) 단일 구성요소 장애·업그레이드 실수의 영향 범위가 큼 → Argo CD 수동 sync, 태그 기반 롤백
- (−) Envoy L7 리다이렉트에 따른 지연·CPU 증가(실습 규모에서 수용)
