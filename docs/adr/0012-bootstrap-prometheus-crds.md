# ADR-0012: 부트스트랩이 Prometheus Operator CRD를 먼저 적용하고 Cilium을 같은 values 레이어로 설치한다

- 상태: Accepted (사용자 승인 2026-11-26)
- 날짜: 2026-11-26

## 맥락
Phase 7에서 `cilium` Application에 `values-monitoring.yaml`(ServiceMonitor, 대시보드) 레이어를 추가했다. 새 클러스터에서는
`cni.sh`가 CRD가 없어 `values.yaml`만으로 설치하므로, Argo CD 인수 diff에 추적 메타데이터 외의 차이(ServiceMonitor·Service 추가,
Pod 어노테이션 제거)가 생긴다. 인수 가드(SPEC §5.3)가 멈추고 `make up`이 실패한다(NFR-01, AC-9.1). 그대로 sync하면 cilium Pod가 재시작한다(AC-3.2).

## 결정
`cni.sh`가 고정 버전 `prometheus-operator-crds` 차트의 CRD를 server-side apply한 뒤(`Prune=false` 어노테이션 포함),
Application과 **같은 values 파일 목록**으로 Cilium을 설치한다. CRD는 이후 `prometheus-operator-crds` Application이 인수한다
(Argo CD의 server-side apply는 field manager 충돌을 강제로 가져온다). `scripts/check-versions.sh`가 두 목록이 다르면 실패한다.

## 대안
- 인수 가드를 넓혀 monitoring 차이를 허용: 가드가 복잡해지고, 재구축마다 인수 중에 cilium Pod가 재시작한다(AC-3.2 위반)
- 레이어를 부트스트랩 뒤에 따로 sync: 재구축에 수동 단계가 생겨 NFR-01("`.env` 작성 외 수동 개입 없이")에 어긋난다

## 결과
- (+) 부트스트랩과 Argo CD가 같은 파일을 쓴다는 원칙(CLAUDE.md)을 지킨다
- (−) 부트스트랩 예외가 하나 늘었다(ARCHITECTURE §10.1)
- 새 경로(`cni.sh`의 CRD 단계)는 Phase 9 클린 재구축에서 처음 실행된다

## 개정 (2026-11-27, Phase 9 첫 재구축)
같은 원칙을 Argo CD에도 적용한다. 부트스트랩이 `values.yaml`만으로 설치하면 `argocd` Application의 첫 자기 동기화가
`values-monitoring.yaml`(redis exporter 사이드카)을 적용해 **redis를 교체**한다. 컨트롤러의 메모리 캐시는 바뀌지 않는 앱(cilium)의
리소스를 새 redis에 다시 쓰지 않아 `argocd app diff cilium`이 `cache: key is missing`으로 실패하고 인수가 멈췄다.
`gitops-bootstrap.sh`는 Application과 같은 values 목록으로 설치한다(두 레이어 렌더는 Argo CD 렌더와 동일함을 확인, `check-versions`가 강제).
같은 오류가 나면 컨트롤러 Pod를 한 번 다시 띄운다.

