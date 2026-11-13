---
description: 지정 Phase(또는 all)의 AC 검증을 실행하고 결과를 요약
argument-hint: <phase 번호 | all>
---

`$ARGUMENTS`가 `all`이면 `make verify-all`, 숫자면 `make verify-phase N=$ARGUMENTS`를 실행한다.

- 결과를 AC ID별 PASS/FAIL/SKIP 표로 요약한다.
- FAIL은 관련 로그·이벤트·Hubble 플로우를 근거로 원인 가설을 1~3개 제시한다(수정은 사용자 승인 후).
- 파괴적 테스트는 사용자가 명시적으로 요청한 경우에만 `DESTRUCTIVE=1`로 실행한다.
- 클러스터 상태를 변경하지 않는다(테스트 스크립트가 정리하는 임시 리소스 제외).
