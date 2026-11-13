# ADR-0008: 네트워크 정책은 표준 NP 기본 거부 + CNP 허용 + 감사→집행

- 상태: Proposed
- 날짜: 2026-11-14

## 맥락
앱 네임스페이스를 기본 거부로 시작해 최소 허용해야 하며, gRPC 메서드 수준 제어와 DNS 가시성이 필요하다. 잘못된 정책은 즉시 장애로 이어진다.

## 결정
- 기본 거부: Kubernetes `NetworkPolicy`(podSelector `{}`, Ingress+Egress) — 의미가 명확하고 이식 가능
- 허용: `CiliumNetworkPolicy` — 엔티티(`ingress`, `world`, `kube-apiserver`), DNS 규칙, L7 HTTP(gRPC) 규칙
- 간선마다 egress·ingress 양쪽 정의, 포트는 컨테이너 포트
- 적용 순서: `policyAuditMode: true` → 15분 관측 → 수정 → 집행. 집행 후 문제는 정책 revert로 대응(감사 모드 재활성화 금지)
- 정책 리소스는 `platform` AppProject만 관리

## 대안
- 전부 CNP: 표현력은 같지만 기본 거부 의미가 덜 명시적
- Kubernetes ClusterNetworkPolicy(Admin/Baseline 계층, Cilium 1.20 지원): 클러스터 전역 기준선에 적합 — 향후 확장 후보
- 서비스 메시 AuthorizationPolicy: 범위 초과

## 결과
- (+) 감사 모드로 실측 기반 정책 확정, Hubble로 판정 근거 확인
- (−) 정책 수 증가(간선 × 2), 업스트림 호출 변경 시 갱신 필요 → 감사 결과를 SPEC §5.6에 반영하는 절차 유지
