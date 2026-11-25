# PROGRESS

> Claude Code가 매 세션 읽는 진행 상태. Phase 완료(모든 MUST AC PASS) 시에만 상태를 ✅로 바꾼다.
> 상세 기준: `docs/SPEC.md` §6

## 현재 상태

- 현재 Phase: **3 — GitOps 부트스트랩** (⬜ 대기, Phase 2 ✅ 완료 2026-11-26)
- 다음 행동: 사용자 확인 후 Phase 3 착수 (`/phase 3`). 클러스터 `boutique` 5노드 Ready, Cilium 1.20.5(helm 설치, Phase 3에서 Argo CD가 인수) 가동 중
- Phase 3 사전 준비: `.env`가 아직 없음 — `.env.example`을 복사해 `GITHUB_TOKEN`(비공개 저장소면 Contents read-only)·`GRAFANA_ADMIN_PASSWORD` 입력, `origin`으로 push 가능해야 함
- 차단 요소: 없음
- SPEC §10 Q1~Q6: 사용자가 기본값 승인(2026-11-25)

## Phase 현황

| Phase | 이름 | 상태 | MUST | SHOULD | 태그 | 완료일 |
|---|---|---|---|---|---|---|
| 0 | 준비 | ✅ 완료 | 6/6 | – | `phase-0-done` | 2026-11-25 |
| 1 | 멀티노드 클러스터 | ✅ 완료 | 5/5 | 1/1 | `phase-1-done` | 2026-11-25 |
| 2 | CNI (Cilium) | ✅ 완료 | 8/8 | – | `phase-2-done` | 2026-11-26 |
| 3 | GitOps 부트스트랩 | ⬜ | 0/9 | – | | |
| 4 | L4 로드밸런싱 | ⬜ | 0/4 | 0/2 | | |
| 5 | Online Boutique | ⬜ | 0/8 | 0/1 | | |
| 6 | L7 Gateway API | ⬜ | 0/9 | 0/1 | | |
| 7 | 관측 가능성 | ⬜ | 0/9 | 0/1 | | |
| 8 | 네트워크 격리 | ⬜ | 0/6 | 0/4 | | |
| 9 | 복원력·최종 인수 | ⬜ | 0/7 | 0/1 | | |

상태: ⬜ 대기 · 🔄 진행 중 · ✅ 완료 · ⚠️ 차단

## 측정값

| 항목 | 값 | 측정 Phase |
|---|---|---|
| L2 VIP 장애 전환 시간 | | 4 |
| 카나리 실측 비율 (200회) | | 6 |
| East-West L7 LB 전/후 max/min 비율 | | 6 |
| 알림 발화까지 시간 | | 7 |
| 노드 장애 시 서비스 복구 시간 | | 9 |
| 클린 재구축 소요 시간 | | 9 |
| 클러스터 requests 합계 (CPU / Mem) | | 9 |

## 편차 · 결정 로그

| 날짜 | Phase | 내용 | 근거 / 관련 ADR |
|---|---|---|---|
| 2026-11-25 | 0 | Gateway API CRD v1.6.1 → **v1.6.3** (standard 채널, CRD 7종) | Cilium 1.20.5 문서(conf.py)가 v1.6.3을 지정. 같은 마이너 패치, SPEC §5.1 원칙(R3: Cilium 요구 버전 그대로) |
| 2026-11-25 | 0 | Cilium 1.20.5, Argo CD 차트 10.11.7(앱 v3.5.7), cert-manager v1.21.3, kps 93.3.1 + CRDs 33.0.2(operator v0.95.2), Alloy 1.16.0, OTel 차트 0.178.3(collector 0.163.2), Helm v3.22.1 핀 | 각 줄의 출처 URL은 `versions.env`. Argo CD 3.5.9 앱은 있으나 차트가 아직 3.5.7까지(Q5: 3.5.x 유지). Helm은 Argo CD 내장 helm과 같은 v3 |
| 2026-11-25 | 0 | **Loki·Tempo 차트 저장소를 grafana-community로 변경(승인됨, SPEC 반영)**(Loki 21.3.1/3.7.10, Tempo 3.2.1/3.1.1). SPEC §2.3·§5.1 갱신 | `grafana/tempo` deprecated, `grafana/loki`는 GEL 전용(R12). ADR-0009(Accepted) |
| 2026-11-25 | 0 | Online Boutique v0.10.7 이미지는 **linux/amd64 단일 아키텍처**, 레지스트리 `us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo`. arm64 호스트는 AC-0.5 실패 | 업스트림 v0.10.7 `release/kubernetes-manifests.yaml`과 manifest config 확인. 이 호스트는 x86_64라 해당 없음 |
| 2026-11-25 | 0 | 업스트림 `redis:alpine`은 부유 태그 → `REDIS_IMAGE=redis:8.12.0-alpine`로 핀, Phase 5 overlay에서 교체 필요 | CLAUDE.md "latest 금지" |
| 2026-11-25 | 0 | AC-0.3 해석: 디렉터리는 §11 전부, 파일은 Phase 0 소유분만 검사(cluster.yaml, phase-N.sh 등은 해당 Phase가 검사). §11에 없는 추가 파일: `scripts/{lint,check-versions,verify-phase}.sh`, `bootstrap/scripts/install-{system,tools}.sh`, `.yamllint`, `.gitleaks.toml` | 빈 껍데기 파일을 만들어 AC만 통과시키는 것을 피함 |
| 2026-11-25 | 0 | 도구 설치: 바이너리 9종은 체크섬 검증 후 `~/.local/bin`에 설치 완료(kind, kubectl, helm, kustomize, yq, kubeconform, gitleaks, cilium, hubble). docker·make·jq·yamllint·inotify는 사용자가 sudo로 설치 완료(2026-11-25). `install-system.sh`의 pipefail+grep -q SIGPIPE 버그를 수정 후 재실행 | 사용자 결정(제가 스크립트 작성, 사용자가 sudo 실행) |
| 2026-11-25 | 0 | 이 저장소에 git `user.name/email`이 없어 커밋 실패 → 사용자 선택으로 초기 커밋과 같은 작성자를 **저장소 로컬**(`--local`)에만 설정. 전역 설정은 변경하지 않음 | 사용자 결정 |
| 2026-11-25 | 0 | 프로젝트 루프(커밋 → verify)에 맞춰 verify 전에 커밋함: AC-0.6이 clean 작업 트리를 요구 | SPEC §6.0 AC-0.6 |
| 2026-11-25 | 1 | AC-1.2 테스트는 노드 라이프사이클 조건 taint(`node.kubernetes.io/not-ready`, `unreachable`)를 비교에서 제외. 그 외 taint는 ARCHITECTURE §4와 정확히 일치해야 하며 추가 taint는 FAIL(임시 taint로 음성 확인함) | 노드가 NotReady인 동안(CNI 없음) 컨트롤러가 자동 부착하는 조건 taint라 배치 설계 대상이 아님. 첫 실행에서 이 때문에 FAIL → 기준 완화가 아니라 비교 대상 정의를 바로잡음 |
| 2026-11-25 | 1 | 노드 IP는 `.2`부터 순차 할당이 아님(control-plane 172.30.0.4, worker4 .2 …). 노드 IP를 가정하는 코드·매니페스트 금지 | Docker 병렬 컨테이너 생성 순서. LB-IPAM 풀(.250.x)과는 충돌 없음 |
| 2026-11-26 | 2 | **SPEC 변경(승인됨, 반영)**: Gateway API v1.6.1 → v1.6.3(§5.1·§6.2·AC-2.6, ADR-0004 본문), §5.3의 `externalIPs.enabled` 삭제 | 차트 1.20.5에 해당 키가 없음. KPR=true면 externalIPs 항상 활성(AC-2.3에서 노드별 `Enabled` 확인) |
| 2026-11-26 | 2 | **AC-2.4 1차 FAIL → 변경 없이 재검증 PASS**. 1차: 83개 중 2개(`all-ingress-deny`, `client-egress-tls-sni-random-wildcard`) 실패 — Pod → 1.0.0.1:443 HTTP 응답 없음(curl 28, 재시도 포함 4회 연속). 조사: 같은 curl 반복 시 **Docker·Cilium이 없는 WSL 호스트에서도** TCP·TLS 성공 후 10초 무응답 재현(1.0.0.1/1.1.1.1 각 40회: 호스트 1/0, `kind-boutique` 컨테이너 0/0, Pod 1/0, 호스트 추가 200회씩 0/1). Hubble에 남은 1.0.0.1 플로우의 drop은 `POLICY_DENIED`뿐(버퍼가 실패 시점을 포함하는지는 미확인), MTU 1500. 사용자 승인 후 같은 커밋 `a198de5`에서 전체 재실행 → 83/83(776 동작) PASS, skip 55 | 클러스터 밖 외부 경로의 간헐 장애로 **추정**(위치 미특정, 4회 연속 실패는 미설명). 테스트 대상·플래그·기준은 바꾸지 않음. 로그: `phase-2-connectivity-20261125T155739Z.log`(FAIL), `…T162757Z.log`(PASS) |
| 2026-11-26 | 2 | AC-2.7의 `nslookup`은 netshoot(BIND) 이미지로 실행 | curl 이미지의 busybox `nslookup`은 점이 있는 이름(`kubernetes.default`)에 search 도메인을 적용하지 않아 NXDOMAIN. `getent`·BIND는 10.96.0.1로 정상 해석. 기준 동일 |
| 2026-11-26 | 2 | 테스트 하네스 버그 2건 수정: `test_pod`의 JSON merge override가 `--command`를 지움(→ strategic), `_pf`의 port-forward가 서브셸이라 정리되지 않고 남음(→ PID 파일을 EXIT trap이 정리) | Phase 0에서 작성 후 Phase 2에서 처음 실행되며 발견 |
| 2026-11-26 | 2 | 벤더링한 Gateway API CRD 7개는 yamllint 대상에서 제외, 대신 `check-versions.sh`가 CRD 7종 존재와 `bundle-version`·`channel` 어노테이션을 `versions.env`와 비교(음성 사례 확인) | 업스트림 파일은 수정하지 않음(160자 초과 줄, `--strict` lint) |
| 2026-11-26 | 2 | 절차 누락: `feat` 커밋 3건(CRD 벤더링, Cilium values, `cni.sh`)을 커밋 직전 `/verify` 없이 만듦(커밋 전 확인은 `make lint` 등). 이후 커밋된 HEAD에서 `/verify 2` 실행 | 이후 코드·설정 커밋은 직전에 `/verify` 실행 |

## 세션 로그

<!-- 형식: ### YYYY-MM-DD Phase N — 요약 / 실행한 검증 / 결과(PASS x, FAIL y) / 다음 행동 -->

- 2026-11-25 Phase 0 1차 세션: 버전 조사·핀(`versions.env`), 골격, `preflight.sh`, `tests/lib.sh`, `scripts/{lint,check-versions}.sh`, `Makefile`, `tests/phase-0.sh` 작성. `make`가 없어 스크립트를 직접 실행해 검증(lint 통과: 빈 트리 + 임시 사본의 kustomize/helm/kubeconform/드리프트/gitleaks 양·음성 사례). AC 판정은 sudo 설치 후 `make verify-phase N=0`로 수행 예정 — 아직 미판정.
- 2026-11-25 Phase 0 2차 세션: 사용자가 `install-system.sh` 실행(첫 실행은 pipefail+`grep -q` SIGPIPE 버그로 docker 설치 전 종료 → 수정 후 재실행), WSL 메모리 20GB 반영(docker 23.5 GiB), inotify 512. `make preflight` 통과(16 CPU / 23.5 GiB / 951 GB), `make lint` 통과. 6개 논리 커밋 후 `make verify-phase N=0` → **MUST 6/6 PASS** (AC-0.1~0.6, SKIP 0, FAIL 0). 로그: `tests/results/phase-0-20261125T133002Z.log`(gitignored). 남은 리스크: 메모리 23.5 GiB는 권장(32 GiB) 미만 — Phase 7·9에서 requests 합계(AC-9.7)와 OOM 관찰 필요; Tempo 3.x values 키는 Phase 7에서 재검증; arm64 호스트는 Boutique 이미지가 amd64뿐.
- 2026-11-25 Phase 1: `bootstrap/kind/cluster.yaml`, `cluster-up.sh`(멱등), `down.sh`(확인 필수, 실행하지 않음), `tests/phase-1.sh` 작성. `make cluster-up` 최초 실행 약 71초(노드 이미지 pull 포함), 재실행은 모두 "already exists". `make verify-phase N=1` → 첫 실행 AC-1.2 FAIL(NotReady 조건 taint, 위 편차 참조) → 테스트 정의 수정 후 **MUST 5/5, SHOULD 1/1 PASS**. 로그: `tests/results/phase-1-20261125T133543Z.log`. 남은 리스크: 노드는 NotReady로 대기 중이며 Phase 2에서 Cilium이 Ready로 전환해야 함; Cilium 설치 시 `k8sServiceHost: boutique-control-plane`(노드 이름 DNS) 해석을 Phase 2에서 확인.
- 2026-11-26 Phase 2: `platform/gateway-api-crds/`(v1.6.3 standard 7종), `platform/cilium/values.yaml`, `bootstrap/scripts/cni.sh`, `tests/phase-2.sh` 작성. `make cni` 1차 성공(helm 시작 → `cilium status` OK·전 노드 Ready까지 160초), 2차는 멱등(2초, Cilium Pod 이름·재시작 수 불변). `k8sServiceHost: boutique-control-plane` 해석 정상. `make verify-phase N=2`: 1차 MUST 7/8(AC-2.4, 위 편차), 2차 **MUST 8/8 PASS**(FAIL 0, SKIP 0). 로그: `tests/results/phase-2-20261125T162757Z.log`. 남은 리스크: ① 외부 대상 HTTPS 간헐 무응답 — 이후 외부 통신을 쓰는 테스트·이미지 pull에서 같은 증상 가능, ② `cni.sh`의 "Argo CD가 Cilium을 관리하면 건너뜀" 분기와 "CRD 후설치 시 operator 재시작" 분기는 실행된 적 없음(전자는 Phase 3에서 확인), ③ hubble-relay가 설치 직후 1회 재시작(peer 서비스 준비 전), 이후 추가 없음, ④ Cilium 롤백은 클러스터 재생성(`make down`은 사용자 확인 필요). 현재 노드 컨테이너 메모리 합계 약 4.6 GiB / 23.5 GiB.
