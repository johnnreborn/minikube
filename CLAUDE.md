# CLAUDE.md

Online Boutique Platform Lab — kind 멀티노드 클러스터 위에 Cilium(CNI·L4·L7·Hubble), Argo CD(GitOps),
Prometheus/Loki/Tempo(관측성)를 구성하고 Google Online Boutique를 운영 수준으로 배포하는 저장소다.

## 문서 지도 (Source of Truth 우선순위: SPEC > ARCHITECTURE > ADR)

- 현재 진행 상태: @docs/PROGRESS.md
- 요구사항 · Phase별 작업 · 완료 기준(AC): `docs/SPEC.md` — 작업 중인 Phase 섹션(§6.x)과 관련 설계 절만 읽는다
- 구조 · 트래픽/관측/GitOps 흐름 · IP 계획: `ARCHITECTURE.md`
- 설계 결정 근거: `docs/adr/`
- 문서가 틀렸다고 판단되면 구현으로 우회하지 말고, SPEC 변경안을 먼저 제시하고 승인받는다.

## 작업 루프 (반드시 Phase 단위)

1. PROGRESS.md에서 현재 Phase 확인 → SPEC §6의 해당 Phase "작업"과 "완료 기준" 읽기
2. 구현 전 짧은 계획 제시: 변경/생성 파일, 위험, 검증 방법
3. 구현 → `make lint` 통과
4. 커밋 → push. Phase 3 이후에는 **push해야 클러스터에 반영된다** (Argo CD가 원격 Git을 본다)
5. 동기화 대기(`make wait-sync`) → `make verify-phase N=<n>`
6. MUST AC가 전부 PASS일 때만 PROGRESS.md 갱신, `git tag phase-<n>-done`
7. 결과 요약(PASS/FAIL, 편차, 남은 리스크)을 보고하고 사용자 확인 후 다음 Phase로 진행

## 명령어

```bash
make preflight              # 호스트/도구/자원 점검 (Phase 0)
make cluster-up             # docker network(kind-boutique) + kind 클러스터 (Phase 1)
make cni                    # Gateway API CRDs → Cilium 부트스트랩 (Phase 2)
make gitops-bootstrap       # Argo CD + repo secret + root app (Phase 3)
make up                     # 위 단계를 순서대로 실행, 멱등
make wait-sync              # 모든 Argo CD Application이 Synced/Healthy 될 때까지 대기
make verify-phase N=5       # Phase별 AC 검증, 결과는 tests/results/ (gitignored)
make verify-all             # Phase 1~9 전체 검증
make lint                   # yamllint, kustomize build, helm template, kubeconform, 버전 일관성, 시크릿 스캔
make hosts                  # /etc/hosts용 줄 출력 (파일 직접 수정은 하지 않음)
make down                   # 클러스터+네트워크 삭제 — 사용자 명시 요청 시에만
```

## 핵심 규칙

- **Phase 3 이후 Git이 유일한 진실 원천.** Argo CD 관리 리소스에 `kubectl apply/edit/patch/delete` 금지.
  예외: `bootstrap/` 스크립트, 읽기 전용 디버깅, 테스트 스크립트의 일시적 장애 주입(trap으로 반드시 원복).
- 긴급 수동 변경을 했다면 즉시 Git에 반영하고 PROGRESS.md "편차" 칸에 기록한다.
- 버전은 `versions.env`에 단일 기록. Application의 `targetRevision`, 차트 버전, 이미지 태그와 불일치하면 `make lint`가 실패해야 한다.
- 이미지/차트에 `latest`, 범위 버전(`^`, `~`, `x`) 사용 금지. kind 노드 이미지는 `@sha256` digest까지 핀.
- 업스트림 Online Boutique 매니페스트(`apps/online-boutique/upstream/`)는 직접 수정 금지 — `overlays/`의 Kustomize 패치로만 변경.
- Helm values는 컴포넌트별 `values.yaml` + 기능별 레이어(`values-monitoring.yaml` 등)로 분리. 부트스트랩과 Argo CD는 같은 파일을 쓴다.
- 차트 값 키가 불확실하면 추측하지 말고 `helm show values <chart> --version <pinned>`와 해당 버전 공식 문서로 확인한다.
- 설계 결정을 바꾸거나 새로 하면 `docs/adr/`에 ADR을 추가한다.
- 테스트 스크립트는 AC ID(`AC-5.4` 등)로 `[PASS]/[FAIL]`을 출력하고 실패 시 non-zero exit.

## 절대 하지 말 것

- 시크릿, `.env`, kubeconfig, 개인키, CA 키를 커밋
- `git push --force`, 공유 브랜치 히스토리 재작성
- 사용자 확인 없이 `make down` / `kind delete cluster` / docker network 삭제
- 테스트를 통과시키려고 네트워크 정책 완화, `policyAuditMode` 재활성화, AC 기준 하향, 검증 단계 생략
- 커밋되는 설정에 `--insecure-skip-tls-verify` / `curl -k` 사용 (사설 CA 파일을 쓴다)
- ingress-nginx(은퇴), Promtail(EOL) 도입
- Cilium을 helm CLI로 재설치/업그레이드 (Phase 3 이후에는 Argo CD `cilium` 앱만 사용, 수동 sync)

## 알려진 함정 (상세는 ARCHITECTURE.md §15)

- Kubernetes 1.36+ kind 노드는 kubeadm `v1beta4` 설정을 쓴다: `extraArgs`는 `- name: / value:` 리스트 형식
- Gateway API CRD는 Cilium보다 **먼저** 설치. 나중에 설치했다면 cilium-operator 재시작 필요
- ServiceMonitor를 켜는 values는 Prometheus Operator CRD가 설치된 뒤에만 적용(`values-monitoring.yaml`로 분리)
- Hubble TLS는 `cronJob` 방식. helm 방식은 렌더링마다 인증서가 바뀌어 Argo CD가 영구 OutOfSync
- 네트워크 정책 포트는 Service 포트가 아니라 **컨테이너 포트** (frontend 80→8080, emailservice 5000→8080)
- Cilium Gateway를 거친 트래픽의 출발 identity는 `reserved:ingress` → `fromEntities: [ingress]`
- frontend/checkoutservice/productcatalogservice 이미지는 셸이 없다 → `kubectl debug --profile=restricted --target=server`
- macOS(Docker Desktop)에서는 LB VIP가 호스트에서 직접 닿지 않는다 → 검증은 항상 `tests/lib.sh`의 probe 컨테이너로
- app-of-apps에서 sync wave가 자식 앱 Health를 기다리려면 argocd-cm에 `argoproj.io/Application` health customization 필요
- selfHeal 때문에 kubectl로 바꾼 상태는 되돌아간다. 장애 주입 테스트는 SPEC §7.4의 절차를 따른다

## 커밋 규칙

`<type>(phase-<n>): <요약>` — type: feat, fix, docs, test, chore, refactor
예: `feat(phase-6): add canary HTTPRoute with 90/10 weights`
한 커밋은 하나의 논리적 변경. 생성된 파일(렌더링 결과)은 커밋하지 않는다(벤더링된 upstream 제외).
