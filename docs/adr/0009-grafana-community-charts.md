# ADR-0009: Loki·Tempo 차트는 grafana-community 저장소에서 가져온다

- 상태: Accepted (사용자 승인 2026-11-25, SPEC §2.3 / §5.1 반영)
- 날짜: 2026-11-25

## 맥락
SPEC §2.3은 헬름 저장소로 `grafana`(https://grafana.github.io/helm-charts)를 가정한다. Phase 0 버전 조사(R12)에서 다음을 확인했다.

- `grafana/tempo` 차트: 저장소 README에 "migrated to grafana-community/helm-charts, after 2026-01-30 updates are provided in the new repository". 인덱스상 마지막 버전 1.24.4(appVersion 2.9.0)는 `deprecated: true`. `tempo-distributed`도 동일.
- `grafana/loki` 차트: README에 "As of March 16, 2026 the Loki Helm chart for OSS users has moved to grafana-community/helm-charts … maintained for Grafana Enterprise Logs users only". 
- `grafana-community` 인덱스(https://grafana-community.github.io/helm-charts/index.yaml): `loki` 21.x(Loki 3.7), `tempo` 3.x(Tempo 3.1, 단일 바이너리), 둘 다 활성.
- `alloy`는 여전히 `grafana` 저장소에서 발행(deprecated 아님).

## 결정
- Loki와 Tempo는 `grafana-community` 저장소의 차트를 고정 버전으로 사용한다(`versions.env`: `GRAFANA_COMMUNITY_CHART_REPO`, `LOKI_CHART_VERSION`, `TEMPO_CHART_VERSION`).
- Alloy는 `grafana` 저장소를 유지한다.
- `scripts/check-versions.sh`가 차트별 repoURL까지 `versions.env`와 대조한다.

## 대안
- `grafana/loki`(7.x, GEL 전용) 사용: OSS 용도로 지원되지 않아 제외.
- `grafana/tempo` 1.24.4(Tempo 2.9) 고정: deprecated, 보안·버그 수정 중단 → 제외.
- 업스트림 소스에서 직접 차트 벤더링: 관리 비용이 커서 제외.

## 결과
- (+) 유지보수되는 차트와 현행 Loki/Tempo 버전 사용
- (−) Tempo 2.x → 3.x 메이저 전환: 단일 바이너리(monolithic) 모드와 `values` 키는 Phase 7에서 `helm show values`로 재검증해야 함
- (−) 차트 저장소가 하나 더 늘어남(SPEC §2.3 갱신 필요)
