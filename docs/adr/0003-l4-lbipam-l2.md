# ADR-0003: L4는 Cilium LB-IPAM + L2 Announcements, 고정 Docker 서브넷

- 상태: Proposed
- 날짜: 2026-11-14

## 맥락
kind에는 클라우드 LB가 없다. LoadBalancer Service의 VIP를 할당하고 노드 외부(Docker 네트워크)에서 도달시켜야 한다. Git 매니페스트에 VIP를 고정하려면 서브넷이 결정적이어야 한다.

## 결정
- `CiliumLoadBalancerIPPool`(172.30.250.10–250) + `CiliumL2AnnouncementPolicy`(app 워커 eth0)
- Docker 네트워크 `kind-boutique`를 172.30.0.0/16으로 사전 생성, `KIND_EXPERIMENTAL_DOCKER_NETWORK`로 지정
- Lease 3s/1s/200ms, `k8sClientRateLimit` 상향

## 대안
- MetalLB(L2): 검증된 선택이지만 CNI와 별도 컨트롤러·CRD가 추가되고 정책/관측 identity와 분리됨
- cloud-provider-kind: 호스트 접근성은 좋으나 L2/장애 전환 실습 목적과 맞지 않음
- BGP(Cilium BGP Control Plane + FRR 컨테이너): 운영 현실성은 높으나 범위 확장(향후 후보)

## 결과
- (+) 구성요소 추가 없음, 장애 전환이 Kubernetes Lease로 관측 가능
- (−) L2 모드는 VIP당 단일 응답 노드(수평 확장 없음), ARP 캐시로 인한 전환 지연
- (−) L2 Announcements는 `externalTrafficPolicy: Local`과 공식 비호환(Cilium 1.20 문서 Limitations). l4-test `echo-local`은 모든 L2 후보 노드에 Ready 백엔드가 있을 때만 성립하는 실증용이며, 운영 Service는 `Cluster`만 쓴다. 소스 IP 보존이 운영 요구가 되면 BGP 또는 DSR을 별도 검토한다
- (−) 서브넷 충돌 가능성 → preflight 탐지
