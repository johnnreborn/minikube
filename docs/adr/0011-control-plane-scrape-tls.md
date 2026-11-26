# ADR-0011: kubelet·controller-manager·scheduler 스크레이프는 인증서 검증을 생략한다 (3개 타깃 한정 예외)

- 상태: Accepted (사용자 승인 2026-11-26)
- 날짜: 2026-11-26

## 맥락
AC-7.2는 kubelet(cadvisor 포함), kube-controller-manager, kube-scheduler 타깃의 수집을 요구한다.
kind(kubeadm) 기본 설정에서 이 세 구성요소의 HTTPS 서빙 인증서는 클러스터 CA가 아니라 **각자 생성한 자체 서명 CA**로 발급된다
(확인: kubelet 발급자 `CN=<node>-ca@…`, controller-manager·scheduler 발급자 `CN=localhost-ca@…`, 클러스터 CA는 `CN=kubernetes`).
검증에 쓸 수 있는 고정 CA가 없어 kube-prometheus-stack 차트의 기본값도 이 세 ServiceMonitor에 `insecureSkipVerify: true`를 쓴다.
CLAUDE.md는 커밋되는 설정에서 TLS 검증을 끄는 것(`--insecure-skip-tls-verify`, `curl -k`)을 금지한다.

## 결정
`kubelet`, `kube-controller-manager`, `kube-scheduler`의 Prometheus 스크레이프에 한해 `insecureSkipVerify: true`를 허용한다.
- values에 명시적으로 적고 이 ADR을 가리킨다(차트 기본값에 숨기지 않는다)
- `make lint`(`scripts/check-tls.sh`)가 이 세 ServiceMonitor 밖에서 `insecureSkipVerify: true`가 렌더되거나, 커밋 파일에
  `--insecure-skip-tls-verify` / `curl -k` / `curl --insecure`가 나타나면 실패한다
- 그 밖의 모든 TLS는 검증한다(apiserver 타깃은 클러스터 CA로 검증)

## 대안
- kubelet `serverTLSBootstrap` + CSR 승인 컨트롤러: kubelet은 제대로 검증할 수 있지만 클러스터 재구축과 구성요소가 추가되고,
  controller-manager·scheduler는 여전히 별도 인증서 발급이 필요하다 → 실습 범위에서 보류(운영 환경 적용 시 권장)
- 타깃 제외: AC-7.2(FR-OBS-01) 위반

## 결과
- (+) 표준 kube-prometheus-stack 구성으로 전 타깃 수집
- (−) 노드 네트워크에 중간자가 있으면 Prometheus의 ServiceAccount 토큰이 가짜 엔드포인트에 전달될 수 있다.
  토큰 권한은 메트릭 조회용 ClusterRole로 제한된다. 실습 클러스터(단일 호스트의 Docker 네트워크)에서 수용
