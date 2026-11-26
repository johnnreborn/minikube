# ADR-0005: GitOps는 Argo CD app-of-apps, 최소 명령형 부트스트랩, Cilium 인수

- 상태: Accepted (사용자 승인 2026-11-27, Phase 9 점검)
- 날짜: 2026-11-14

## 맥락
CNI 없이는 어떤 Pod도 뜨지 않으므로 Argo CD보다 Cilium이 먼저 설치되어야 한다(닭과 달걀). 이후에는 모든 변경이 Git을 거쳐야 한다.

## 결정
- 명령형 부트스트랩: Docker 네트워크 → kind → Gateway API CRD → Cilium(helm) → Argo CD(helm) → repo Secret → AppProjects → root Application
- Argo CD가 동일한 차트 버전·values 파일로 Cilium과 자기 자신을 인수(Cilium은 수동 sync)
- app-of-apps + sync wave, Application health customization으로 웨이브 대기
- AppProject `platform`(클러스터 범위 허용) / `apps`(boutique, l4-test 한정, 정책 리소스 금지)
- 롤백은 `git revert`, Phase 완료 태그로 체크포인트

## 대안
- Flux: 경량·컨트롤러 중심. UI 기반 상태 확인과 AppProject 수준의 권한 분리를 실습 목표로 두어 Argo CD 선택
- ApplicationSet(git directory generator): 앱 수가 적고 앱마다 sync 정책·웨이브가 달라 명시적 Application이 더 명확. 환경이 늘면 전환 검토

## 결과
- (+) 부트스트랩 이후 선언적 상태, 드리프트 자동 교정
- (−) 원격 Git 의존(push 필요), 인수 시 렌더링 차이 관리 필요(ADR-0002 리스크와 연계)

## 개정 (2026-11-27, 구현 반영)
- 부트스트랩 순서에 Prometheus Operator CRD(ADR-0012)와 CoreDNS 분산 패치(ADR-0013)가 추가됐다.
- Git 변경 감지 주기는 60초 + jitter 30초(SPEC §5.8, AC-9.4).
