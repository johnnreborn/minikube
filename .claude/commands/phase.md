---
description: SPEC의 지정 Phase를 계획→구현→검증 루프로 진행
argument-hint: <phase 번호>
---

Phase $ARGUMENTS 를 진행한다.

1. `docs/PROGRESS.md`에서 선행 Phase가 모두 완료(✅)인지 확인한다. 아니면 멈추고 보고한다.
2. `docs/SPEC.md` §6.$ARGUMENTS 와 그 Phase가 참조하는 §5 설계 절, 관련 ADR을 읽는다.
3. 구현 계획을 제시한다: 생성/변경 파일, 커밋 단위, 위험, 사용할 검증. 고정 버전에서 확인이 필요한 항목(차트 값 키, env 이름, API 버전)을 목록으로 뽑아 먼저 확인한다.
4. 구현 → `make lint` → 커밋/푸시(Phase 3 이후) → `make wait-sync` → `make verify-phase N=$ARGUMENTS`.
5. 실패한 AC는 원인을 분석해 수정한다. AC 기준을 낮추거나 정책을 완화해 통과시키지 않는다. SPEC이 틀렸다면 변경안을 제시하고 멈춘다.
6. MUST 전부 PASS면 PROGRESS.md(현황 표, 측정값, 편차, 세션 로그)를 갱신하고 `phase-$ARGUMENTS-done` 태그를 만든다.
7. 결과 요약을 보고하고 다음 Phase 진행 여부를 사용자에게 묻는다.
