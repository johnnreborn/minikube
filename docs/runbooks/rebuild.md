# 런북: 클러스터 재구축

클러스터를 지우고 처음부터 다시 만든다. **`make down`은 사용자의 명시적 승인 후에만** 실행한다.

## 1. 사라지는 것

- 클러스터와 Docker 네트워크의 모든 상태: Prometheus·Loki·Tempo 데이터(PVC), 장바구니, Hubble 버퍼
- 사설 루트 CA(새로 만들어진다 → 브라우저에 넣은 옛 CA 교체), Argo CD 초기 admin 비밀번호
- 남는 것: Git 저장소, 호스트의 `.env`, 노드 이미지(`kindest/node`)의 Docker 캐시, `tests/.cache/`,
  `tests/results/`

`tests/.cache/`의 옛 클러스터 기록(감사 보고서, Cilium 스냅샷)은 테스트가 클러스터 생성 시각과 비교해 무시한다.

## 2. 사전 점검

```bash
make preflight
git status --short                       # 깨끗해야 한다
git fetch origin && git diff origin/main --stat   # push 안 된 매니페스트가 없어야 한다(부트스트랩이 거부)
```

`.env`: `GITOPS_REPO_URL`, `GITOPS_REVISION`, `GRAFANA_ADMIN_PASSWORD`(비공개 저장소면 `GITHUB_TOKEN`).

## 3. 실행

검증까지 한 번에(AC-9.1, 무개입, 시간 측정, 1~2시간):

```bash
CONFIRM=yes scripts/rebuild.sh   # down → cluster-up·cni → Phase 1·2 → gitops-bootstrap → wait-sync → make up(멱등) → Phase 3~9
```

로그는 `tests/results/rebuild-<UTC>.log`, 기록은 `tests/.cache/rebuild-last.json`. `make up` 시간은 세 단계의 합이다.
Phase 1·2를 Cilium만 있는 상태에서 돌리는 이유: AC-2.4의 연결성 시험은 agent 시작 후 누적된 패킷 드롭·로그·재시작을
모두 검사한다.

검증 없이 다시 만들기만:

```bash
make down                                # 클러스터 이름 'boutique' 입력
make up && make wait-sync
```

## 4. 단계별로 무슨 일이 일어나는가

| 단계 | 내용 |
|---|---|
| `cluster-up` | `kind-boutique` 네트워크, kind 5노드(CNI 없음 → NotReady) |
| `cni` | Gateway API·Prometheus Operator CRD → Cilium(helm) → CoreDNS 2개를 다른 노드로(ADR-0013) |
| `gitops-bootstrap` | Argo CD(helm) → repo·Grafana Secret → AppProject·root → 전 앱 Healthy 대기(최대 25분) → Cilium 인수 |

`make up`은 멱등이다. 중간에 실패하면 원인을 고친 뒤 다시 실행한다(단, AC-9.1의 "무개입 1회"는 처음부터 다시).

## 5. 자주 멈추는 곳

| 증상 | 대응 |
|---|---|
| 차트 다운로드 실패 | 자동 5회 재시도. 계속 실패하면 외부 네트워크 확인 |
| 이미지 pull 지연으로 앱 Healthy 대기 초과 | `kubectl get pods -A \| grep -v Running`, `describe`로 pull 오류 확인 후 `make up` 재실행 |
| `cilium diff contains more than tracking metadata` | 인수 가드. helm 설치와 Argo CD 렌더가 다르다 — values 목록(`cni.sh`)·helm 버전(`versions.env`) 확인. **가드를 끄지 않는다** |
| `cache: key is missing` (인수 diff) | 부트스트랩이 컨트롤러를 한 번 다시 띄우고 재시도한다. Argo CD values 목록(`gitops-bootstrap.sh`)이 Application과 같은지 확인 |
| `cilium app not comparable` | repo-server가 차트를 못 가져옴 → 회복 후 `make gitops-bootstrap` 재실행 |
| AC-2.4(외부 대상 연결성) 실패 | 알려진 환경 문제(WSL 밖 외부 HTTPS 간헐 멈춤, PROGRESS 편차) |

## 6. 소요 시간

측정값은 [PROGRESS.md](../PROGRESS.md)의 "측정값"에 기록한다.
