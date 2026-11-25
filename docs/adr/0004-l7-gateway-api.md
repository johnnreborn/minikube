# ADR-0004: L7은 Gateway API(Cilium 구현), Ingress 미사용

- 상태: Proposed
- 날짜: 2026-11-14

## 맥락
Host/경로/헤더/가중치 라우팅, TLS 종료, 팀 간 소유권 분리가 필요하다. Kubernetes Ingress는 기능이 제한적이고 구현별 어노테이션에 의존하며, 대표 구현인 ingress-nginx는 은퇴했다.

## 결정
Gateway API v1.6.3(Cilium 1.20.5 문서가 지정한 버전)을 사용한다. 플랫폼 소유 공유 Gateway `edge`(ns `gateway`) + 네임스페이스별 HTTPRoute, `allowedRoutes` 라벨 셀렉터와 ReferenceGrant로 경계를 둔다. 인증서는 cert-manager 사설 CA.

## 대안
- Envoy Gateway: 기능이 풍부한 독립 구현. 단 CNI 정책 identity와 분리되고 구성요소 추가
- Istio Gateway: 메시 도입 시 자연스러우나 범위 초과

## 결과
- (+) 표준 API로 역할 분리(Gateway vs Route), 구현 교체 가능성 유지
- (+) Gateway → 백엔드 트래픽이 `reserved:ingress` identity로 정책에 반영
- (−) 일부 확장 기능(backendRef 필터, 재시도 등)의 지원 여부가 구현에 의존 → 지원 확인 후 사용, 미지원 시 대체 수단 기록
