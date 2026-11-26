# PROGRESS

> Claude Code가 매 세션 읽는 진행 상태. Phase 완료(모든 MUST AC PASS) 시에만 상태를 ✅로 바꾼다.
> 상세 기준: `docs/SPEC.md` §6

## 현재 상태

- 현재 Phase: **5 — Online Boutique** (⬜ 대기, Phase 4 ✅ 완료 2026-11-26)
- 다음 행동: 사용자 확인 후 Phase 5 착수 (`/phase 5`). 이제 클러스터 변경은 commit + push로만 반영된다(Argo CD가 `origin/main`을 본다). Cilium은 수동 sync
- 차단 요소: 없음. 알려진 환경 문제: 외부 인터넷 HTTPS 간헐 멈춤(WSL VM 밖, 편차 참조) — AC-2.4처럼 외부 대상에 의존하는 검증이 간헐 실패할 수 있음
- SPEC §10 Q1~Q6: 사용자가 기본값 승인(2026-11-25)

## Phase 현황

| Phase | 이름 | 상태 | MUST | SHOULD | 태그 | 완료일 |
|---|---|---|---|---|---|---|
| 0 | 준비 | ✅ 완료 | 6/6 | – | `phase-0-done` | 2026-11-25 |
| 1 | 멀티노드 클러스터 | ✅ 완료 | 5/5 | 1/1 | `phase-1-done` | 2026-11-25 |
| 2 | CNI (Cilium) | ✅ 완료 | 8/8 | – | `phase-2-done` | 2026-11-26 |
| 3 | GitOps 부트스트랩 | ✅ 완료 | 9/9 | – | `phase-3-done` | 2026-11-26 |
| 4 | L4 로드밸런싱 | ✅ 완료 | 4/4 | 2/2 | `phase-4-done` | 2026-11-26 |
| 5 | Online Boutique | ⬜ | 0/8 | 0/1 | | |
| 6 | L7 Gateway API | ⬜ | 0/9 | 0/1 | | |
| 7 | 관측 가능성 | ⬜ | 0/9 | 0/1 | | |
| 8 | 네트워크 격리 | ⬜ | 0/6 | 0/4 | | |
| 9 | 복원력·최종 인수 | ⬜ | 0/7 | 0/1 | | |

상태: ⬜ 대기 · 🔄 진행 중 · ✅ 완료 · ⚠️ 차단

## 측정값

| 항목 | 값 | 측정 Phase |
|---|---|---|
| L2 VIP 장애 전환 시간 | `docker stop`(정상 종료) 기준: 새 노드 lease 인수 +0.2초, 옛 노드 종료 +0.4초, 그 후 첫 성공 +0.5초, 연속 실패 최장 3.5초. 단 죽은 백엔드 때문에 일부 요청(73회 중 21회)이 노드 NotReady 처리(+45.8초) 직후인 +46.9초까지 실패. **크래시(lease 미반납) 전환은 미측정** | 4 |
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
| 2026-11-26 | 3 | GitOps 저장소는 **공개**(`GITHUB_TOKEN` 비움). SPEC Q1 기본값(비공개 + read-only 토큰)과 다름 → 커밋되는 모든 내용이 공개됨. 시크릿은 Git 밖(`.env` → 부트스트랩 Secret), lint·AC-3.7의 gitleaks로 매번 확인 | 사용자 저장소 설정(공개, `origin`은 SSH). 비공개로 바꾸면 `.env`에 토큰만 넣고 `make gitops-bootstrap` 재실행 |
| 2026-11-26 | 3 | **helm v3.22.1 → v4.2.1**, `versions.env`에 `ARGOCD_BUNDLED_HELM_VERSION` 추가, `check-versions`가 두 값의 일치를 강제. Phase 0 편차 행의 "Argo CD 내장 helm과 같은 v3"는 **틀린 판단이었음**(Argo CD v3.5.7 repo-server의 helm은 v4.2.1, `hack/tool-versions.sh`) | 첫 부트스트랩에서 인수 가드가 멈춤: helm v3은 차트 기본값 `k8s.apiServerURLs: ~`(null)을 유지해 cilium DaemonSet init 컨테이너에 `--k8s-api-server-urls=`를 렌더, helm v4는 null 키를 버림 → 그대로 sync하면 cilium Pod 전부 재시작(AC-3.2 위반). 46개 리소스 중 비메타데이터 차이는 이 한 줄뿐 |
| 2026-11-26 | 3 | **클러스터 재구축**(사용자 승인: `make down` → `make up`). helm v4로 Cilium을 다시 설치한 뒤 인수 → diff는 추적 어노테이션뿐(46개 리소스), cilium Pod 13개의 UID·restartCount 불변 | 값 변경만으로는 기존 클러스터(helm v3 렌더)와 Argo CD 렌더를 같게 만들 수 없음. Phase 1·2 재검증: Phase 1 5/5+1/1 PASS, Phase 2 7/8(AC-2.4, 아래) |
| 2026-11-26 | 3 | 부트스트랩 helm 설치는 `--wait=legacy` | helm v4 기본 `--wait`(watcher)가 hook 리소스마다 `--timeout` 전체를 기다림. Argo CD 차트의 redis-secret-init hook(SA·Role·RoleBinding·Job)으로 설치가 **약 40분** 멈춤(10분 × 4). 임시 차트로 재현: `--timeout 20s`에서 watcher 88초, legacy 4초, hookOnly 3초. **수정 후 전체 부트스트랩은 아직 실행 전**(Phase 9 재구축에서 확인) |
| 2026-11-26 | 3 | Argo CD: dex·notifications 비활성, `resource.exclusions`는 차트 기본값 유지 | SSO 없음, 외부 알림 없음(Q6). 차트 기본값이 이미 CiliumIdentity·CiliumEndpoint·CiliumEndpointSlice를 제외(Cilium 문서 argocd-issues와 일치) — 키를 덮어쓰면 다른 기본 제외가 사라짐 |
| 2026-11-26 | 3 | root가 `gitops/projects/*.yaml`도 관리(AppProject도 Git 소유, FR-GIT-01). 부트스트랩은 AppProject가 없을 때만 생성 | 매번 kubectl apply하면 client-side 3-way merge가 Argo CD의 tracking 어노테이션을 지움 |
| 2026-11-26 | 3 | CRD 앱(gateway-api-crds, prometheus-operator-crds): `ServerSideApply=true`, `automated.prune=false` + CRD마다 `argocd.argoproj.io/sync-options: Prune=false`(kustomize `commonAnnotations` / 차트 `crds.annotations`). `argocd` 앱도 SSA | Argo CD에는 앱 단위 `Prune=false` 옵션이 없음. ApplicationSet CRD 1.4 MB, prometheus-operator CRD 4.6 MB → client-side apply 한도 초과 |
| 2026-11-26 | 3 | 추가 파일: argocd CLI(`install-tools.sh`, `cli_checksums.txt` 검증), `tests/fixtures/appproject-deny/`(§11에 없음, AC-3.6 전용) | SPEC §2.2의 선택 도구(`--core`), Cilium 인수 diff·sync에 사용 |
| 2026-11-26 | 3 | `tests/phase-3.sh`의 AC-3.5·3.8은 `main`에 probe 커밋을 push하고 revert(실행마다 커밋 4개 추가). 작업 트리 clean + HEAD == origin일 때만 실행, 중단 시 EXIT trap이 revert·push. AC-3.3은 cilium 마지막 sync 후 ≥10분·≥20분 시점에 각각 그 이후의 reconciliation 결과를 확인 | SPEC AC-3.5 "커밋 2회 + 확인". 실행 순서는 AC-3.3 대기가 Git 왕복과 겹치도록 조정 |
| 2026-11-26 | 2·3 | **AC-2.4 외부 HTTPS 실패 원인 조사(패킷 캡처)**: Phase 3 커밋 전 회귀(`T173936Z`)와 재구축 후(`T195038Z`)에도 FAIL — 지금까지 4회 중 3회 FAIL, 매번 Cloudflare 대상 동작 1~2건. 노드(worker2)와 WSL 호스트에서 동시 캡처하며 Pod → 1.1.1.1/1.0.0.1 HTTPS 880회 → 7회 실패, 7건 모두 Pod가 보낸 패킷은 전부 WSL eth0 밖으로 나갔고 WSL eth0에 도착한 패킷은 전부 Pod에 도달. 서버의 FIN은 `ack 1543`(ClientHello 이후 바이트 미수신). 실패는 수 초~35초 구간에 몰림 | **손실 위치는 WSL VM 밖**(Windows NAT·보안 소프트웨어·VPN·공유기·ISP·Cloudflare 중 하나, 미특정). Cilium·Docker·kind 구간 손실 0. 사용자 결정: 기록하고 Phase 3 계속. 기준·대상·플래그는 바꾸지 않음. Phase 2의 ✅는 당시 판정 그대로 |
| 2026-11-26 | 3 | 커밋 직전 `/verify`는 Phase 1·2 회귀로 실행 | Phase 3 변경은 push 전에는 클러스터에 반영되지 않아 검증할 수 없음 |
| 2026-11-26 | 3 | `make lint`의 helm template이 `argoproj.github.io` 차트 인덱스 타임아웃으로 1회 실패 → 재실행 통과 | 일시적 외부 네트워크(위 외부 HTTPS 문제와 같은 경로일 수 있음) |
| 2026-11-26 | 4 | **SPEC 변경(승인됨, 반영)**: §5.4·ADR-0003에 L2 Announcements와 `externalTrafficPolicy: Local`의 공식 비호환 주의 추가. `echo-local`은 모든 L2 후보 노드에 Ready 백엔드가 있을 때만 성립하는 실증용, 운영 Service는 `Cluster`만 | Cilium 1.20.5 `l2-announcements.rst` Limitations. AC-4.4는 그대로(10/10 소스 보존) |
| 2026-11-26 | 4 | **AC-4.5의 앞선 PASS 2회는 신뢰할 수 없음 → 테스트 수정 후 3차 결과만 유효**. ① 1차(`T100718Z`): `docker start` 1초 뒤에 회복 확인이 끝남 — 노드가 NotReady 처리되기 전이라 노드·Pod·replica 상태가 중단 전 값(실제로는 직후 worker4의 cilium·echo Pod가 Unknown). 실패 구간도 관측 창 안에서 끝나지 않음. ② 2차(`T101405Z`): 블로킹하는 `docker stop` 이후에 lease를 폴링해 "lease 이동 시간"이 사실은 정지 소요 시간(1차 0.8초, 2차 5.6초)이었고, 옛 노드가 꺼지기 전의 성공(+2.0초)을 VIP 재개로 계산. 수정: NotReady + 연속 20회 성공까지 관측, `docker start` 이후의 Ready 전이만 인정, lease `acquireTime`·컨테이너 `FinishedAt` 기준 판정 | 기준(30초)은 그대로, 판정은 더 엄격해짐. 최종 로그 `phase-4-20261126T101955Z.log` |
| 2026-11-26 | 4 | `docker stop`은 정상 종료라 lease가 `leaseDuration`(3초)보다 빨리(약 0.1~0.2초) 이동 — cilium agent가 반납한 것으로 **추정**. 전원 장애(lease 만료)의 전환 시간은 측정하지 않음. 정지 소요 시간은 실행마다 달랐음(0.4~5.5초) | SPEC AC-4.5가 `docker stop`을 지정. Phase 9 AC-9.2에서 해석 시 주의 |
| 2026-11-26 | 4 | eTP=Cluster VIP는 죽은 노드의 백엔드가 EndpointSlice에서 빠질 때까지(노드 NotReady, 약 46~47초) 일부 새 연결이 실패 → VIP 전환 30초와 **서비스 완전 복구 30초는 다름** | L2 전환과 무관한 Kubernetes 노드 장애 감지 지연. AC-9.2에서 다시 다룸 |
| 2026-11-26 | 4 | `AGNHOST_IMAGE=registry.k8s.io/e2e-test-images/agnhost:2.63.0` 핀(Kubernetes 1.36.4가 쓰는 태그). `check-versions.sh`가 매니페스트 image를 `versions.env`의 `*_IMAGE`와 비교(음성 사례 확인) | CLAUDE.md "이미지 태그 불일치 시 lint 실패" — 이전에는 미검사 |
| 2026-11-26 | 4 | 풀의 첫 주소 `.10`은 할당 가능(임시 Service가 받음). Cilium 문서의 "첫·마지막 IP 요청 금지" 문구는 start/stop 블록에는 해당하지 않음 | Phase 6 Gateway VIP .10에 영향 없음 |
| 2026-11-26 | 4 | 커밋 직전 `/verify`는 Phase 1 회귀(5/5+1/1)로 실행. 테스트 커밋은 `/verify` 대상 아님 | 새 매니페스트는 push 전에 검증 불가 |

## 세션 로그

<!-- 형식: ### YYYY-MM-DD Phase N — 요약 / 실행한 검증 / 결과(PASS x, FAIL y) / 다음 행동 -->

- 2026-11-25 Phase 0 1차 세션: 버전 조사·핀(`versions.env`), 골격, `preflight.sh`, `tests/lib.sh`, `scripts/{lint,check-versions}.sh`, `Makefile`, `tests/phase-0.sh` 작성. `make`가 없어 스크립트를 직접 실행해 검증(lint 통과: 빈 트리 + 임시 사본의 kustomize/helm/kubeconform/드리프트/gitleaks 양·음성 사례). AC 판정은 sudo 설치 후 `make verify-phase N=0`로 수행 예정 — 아직 미판정.
- 2026-11-25 Phase 0 2차 세션: 사용자가 `install-system.sh` 실행(첫 실행은 pipefail+`grep -q` SIGPIPE 버그로 docker 설치 전 종료 → 수정 후 재실행), WSL 메모리 20GB 반영(docker 23.5 GiB), inotify 512. `make preflight` 통과(16 CPU / 23.5 GiB / 951 GB), `make lint` 통과. 6개 논리 커밋 후 `make verify-phase N=0` → **MUST 6/6 PASS** (AC-0.1~0.6, SKIP 0, FAIL 0). 로그: `tests/results/phase-0-20261125T133002Z.log`(gitignored). 남은 리스크: 메모리 23.5 GiB는 권장(32 GiB) 미만 — Phase 7·9에서 requests 합계(AC-9.7)와 OOM 관찰 필요; Tempo 3.x values 키는 Phase 7에서 재검증; arm64 호스트는 Boutique 이미지가 amd64뿐.
- 2026-11-25 Phase 1: `bootstrap/kind/cluster.yaml`, `cluster-up.sh`(멱등), `down.sh`(확인 필수, 실행하지 않음), `tests/phase-1.sh` 작성. `make cluster-up` 최초 실행 약 71초(노드 이미지 pull 포함), 재실행은 모두 "already exists". `make verify-phase N=1` → 첫 실행 AC-1.2 FAIL(NotReady 조건 taint, 위 편차 참조) → 테스트 정의 수정 후 **MUST 5/5, SHOULD 1/1 PASS**. 로그: `tests/results/phase-1-20261125T133543Z.log`. 남은 리스크: 노드는 NotReady로 대기 중이며 Phase 2에서 Cilium이 Ready로 전환해야 함; Cilium 설치 시 `k8sServiceHost: boutique-control-plane`(노드 이름 DNS) 해석을 Phase 2에서 확인.
- 2026-11-26 Phase 2: `platform/gateway-api-crds/`(v1.6.3 standard 7종), `platform/cilium/values.yaml`, `bootstrap/scripts/cni.sh`, `tests/phase-2.sh` 작성. `make cni` 1차 성공(helm 시작 → `cilium status` OK·전 노드 Ready까지 160초), 2차는 멱등(2초, Cilium Pod 이름·재시작 수 불변). `k8sServiceHost: boutique-control-plane` 해석 정상. `make verify-phase N=2`: 1차 MUST 7/8(AC-2.4, 위 편차), 2차 **MUST 8/8 PASS**(FAIL 0, SKIP 0). 로그: `tests/results/phase-2-20261125T162757Z.log`. 남은 리스크: ① 외부 대상 HTTPS 간헐 무응답 — 이후 외부 통신을 쓰는 테스트·이미지 pull에서 같은 증상 가능, ② `cni.sh`의 "Argo CD가 Cilium을 관리하면 건너뜀" 분기와 "CRD 후설치 시 operator 재시작" 분기는 실행된 적 없음(전자는 Phase 3에서 확인), ③ hubble-relay가 설치 직후 1회 재시작(peer 서비스 준비 전), 이후 추가 없음, ④ Cilium 롤백은 클러스터 재생성(`make down`은 사용자 확인 필요). 현재 노드 컨테이너 메모리 합계 약 4.6 GiB / 23.5 GiB.
- 2026-11-26 Phase 3: `platform/argocd/values.yaml`, `platform/namespaces/`, `gitops/{root.yaml,projects/,apps/platform/}`(자식 앱 5개), `bootstrap/scripts/{gitops-bootstrap,wait-sync}.sh`, `tests/phase-3.sh` 작성, argocd CLI 추가. 첫 `make gitops-bootstrap`은 Cilium 인수 가드에서 멈춤(helm v3/v4 렌더 차이, 위 편차) → helm v4.2.1로 핀하고 사용자 승인 후 클러스터 재구축(`make up` 46분, 이 중 약 40분이 helm v4 hook 대기 → `--wait=legacy`로 수정). 재구축 후 인수: diff는 추적 메타데이터뿐, cilium Pod 불변. `make wait-sync` 통과(6개 앱 Synced/Healthy at `690fc7c`). `make verify-phase N=3` → **MUST 9/9 PASS**(FAIL 0, SKIP 0), 로그 `tests/results/phase-3-20261125T201309Z.log`. probe 커밋 4개(`90e141c`..`b4e0d93`)는 모두 revert됨. 남은 리스크: ① 외부 HTTPS 간헐 멈춤(AC-2.4 4회 중 3회 FAIL) — 환경 문제, Phase 9 `verify-all`에도 영향, ② `--wait=legacy` 수정 후의 전체 부트스트랩은 아직 실행 전, ③ 테스트 로그는 PASS인 AC의 세부 출력(선택 시간 등)을 남기지 않음, ④ Argo CD 관리자 초기 비밀번호는 `argocd-initial-admin-secret`(교체 권장, ARCHITECTURE §13), ⑤ Phase 3 검증은 실행마다 `main`에 커밋 4개를 추가함.
- 2026-11-26 Phase 4: `platform/cilium-lb/`(풀 .10~.250, L2 정책), `apps/l4-test/`(agnhost 3 레플리카, `echo-cluster` .30, `echo-local` .31), 앱 `cilium-lb`·`l4-test`, `tests/phase-4.sh` 작성. 배포 후 8개 앱 Synced/Healthy. `DESTRUCTIVE=1 make verify-phase N=4`(사용자 승인) 3회 — 1·2차는 AC-4.5 테스트 결함(위 편차), **3차 MUST 4/4, SHOULD 2/2 PASS**(FAIL 0, SKIP 0). 실측: AC-4.3 30/30 200·백엔드 3개, AC-4.4 10/10 소스 보존, AC-4.6 external(`reserved:world`) → l4-test 플로우 확인. 장애 테스트 후 클러스터 정상(노드 5 Ready, 전 Pod Ready, 앱 8개 Healthy, 노드 IP 불변). 남은 리스크: ① 크래시 시 L2 전환 시간 미측정, ② 노드 장애 후 약 47초간 일부 요청 실패(Phase 9), ③ `echo-local`은 지원되지 않는 조합, ④ 외부 HTTPS 간헐 멈춤(Phase 2·3 편차) 지속, ⑤ `--wait=legacy` 이후 전체 부트스트랩 미실행.
