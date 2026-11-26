# ADR-0007: Online Boutique 매니페스트 벤더링 + Kustomize overlay

- 상태: Accepted (사용자 승인 2026-11-27, Phase 9 점검)
- 날짜: 2026-11-14

## 맥락
업스트림은 원격 Kustomize base, 릴리스 매니페스트, Helm 차트를 제공한다. 재현성과 리뷰 가능한 diff가 필요하다.

## 결정
고정 태그의 `release/kubernetes-manifests.yaml`을 스크립트로 `apps/online-boutique/upstream/`에 벤더링(체크섬 기록)하고, 모든 변경은 `overlays/lab/`의 패치로 적용한다. 업그레이드는 스크립트 재실행 + diff 리뷰 커밋.

## 대안
- 원격 Kustomize base(`?ref=<tag>`): 간단하지만 repo-server가 원격을 가져오고 렌더 결과 diff가 저장소에 보이지 않음
- 업스트림 Helm 차트: 값으로 제어 가능한 범위를 넘는 패치(분산 제약, 보안 컨텍스트 등)가 필요

## 결과
- (+) 오프라인 렌더링, 업그레이드 diff 가시성, 업스트림과의 차이가 overlay로 명확
- (−) 벤더링 파일 관리 필요, 업스트림 kustomize 컴포넌트(트레이싱 등)를 직접 재현해야 함
