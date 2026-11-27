# Online Boutique Platform Lab

kind 멀티노드 클러스터에 Cilium(CNI·kube-proxy 대체·L4/L7·Hubble), Argo CD(GitOps), Prometheus·Loki·Tempo(관측성)를
구성하고 Google Online Boutique를 네트워크 정책까지 적용해 배포하는 실습 저장소다. 설계는
[ARCHITECTURE.md](ARCHITECTURE.md), 요구사항·완료 기준은 [docs/SPEC.md](docs/SPEC.md), 결정 근거는
[docs/adr/](docs/adr/), 진행 상태와 편차는 [docs/PROGRESS.md](docs/PROGRESS.md)에 있다.

## 필요한 것

- Linux(amd64) 또는 WSL2. Online Boutique 이미지는 amd64만 있다.
- Docker에 할당된 자원 8 vCPU / 16 GiB 이상(권장 12 vCPU / 32 GiB), 디스크 40 GB
- 네트워크 `172.30.0.0/16`이 비어 있을 것
- 외부 인터넷(이미지·차트 다운로드), GitOps용 Git 저장소

## 빠른 시작

```bash
sudo bash bootstrap/scripts/install-system.sh   # make, jq, yamllint, docker, inotify 한도 (Ubuntu/Debian)
bash bootstrap/scripts/install-tools.sh         # 고정 버전 CLI를 ~/.local/bin에 (체크섬 검증)
cp .env.example .env                            # GITOPS_REPO_URL, GRAFANA_ADMIN_PASSWORD 등을 채운다
make preflight                                  # 호스트·도구·자원 점검
make up                                         # 클러스터 → Cilium → Argo CD → 전체 동기화 (멱등)
make wait-sync
DESTRUCTIVE=1 make verify-all                   # 모든 AC (노드 중단·장애 주입 포함, 1~2시간)
```

- Argo CD는 **원격 Git**을 본다. 저장소를 포크했다면 `.env`와 `gitops/`의 저장소 URL을 함께 바꾼다
  (`make lint`가 불일치를 잡는다). 이후 변경은 commit + push로만 반영된다.
- `DESTRUCTIVE=1` 없이 실행하면 장애 주입 AC는 SKIP이다. 일부 테스트는 시험용 커밋을 `main`에 push하고
  revert한다(작업 트리가 깨끗해야 한다).
- Phase 9의 AC-9.1(클린 재구축)은 `scripts/rebuild.sh`가 남긴 기록으로 판정하므로, 재구축 없이 돌린
  `make verify-all`에서는 AC-9.1이 FAIL이다.
- Phase 2의 AC-2.4(Cilium 연결성 시험)는 Cilium만 있는 상태를 전제로 한다. GitOps까지 올라간 클러스터의 `verify-all`에서는
  실패할 수 있다(사전 실행에서 실패). 릴리스 판정은 `scripts/rebuild.sh`의 순서로 했다(SPEC §6.9 AC-9.1 주석).
- 접속 방법과 계정: [docs/runbooks/access.md](docs/runbooks/access.md)
- 지우기: `make down`(클러스터와 Docker 네트워크 삭제, 확인 필요)

## 명령

| 명령 | 내용 |
|---|---|
| `make up` | `cluster-up` → `cni` → `gitops-bootstrap` |
| `make wait-sync` | 모든 Argo CD 앱이 최신 커밋에서 Synced/Healthy |
| `make verify-phase N=5` | Phase별 AC (결과는 `tests/results/`) |
| `make verify-all` | Phase 1~9 |
| `make lint` | yamllint, kustomize/helm 렌더, kubeconform, 버전 일관성, 시크릿 스캔 |
| `make hosts` | `/etc/hosts`에 넣을 줄 출력 |
| `CONFIRM=yes scripts/rebuild.sh` | 클러스터를 지우고 다시 만들어 전체 검증 (AC-9.1, 1~2시간) |

## 런북

- [접속](docs/runbooks/access.md)
- [네트워크 정책 디버깅](docs/runbooks/policy-debug.md)
- [L4 VIP·Gateway 디버깅](docs/runbooks/lb-debug.md)
- [Argo CD 동기화 실패](docs/runbooks/argocd-sync-failure.md)
- [재구축](docs/runbooks/rebuild.md)

## 알려진 제약 (실습 범위)

- 관측 스택·Argo CD는 infra 노드 1대에 있다(단일 장애점).
- 앱 워커 1대 장애 내성은 **홈 화면 경로**까지다(ADR-0013). 상품·장바구니·결제 경로의 단일 레플리카 서비스는
  죽은 노드에 있으면 약 6분 동안 해당 기능이 실패한다. redis-cart가 옮겨지면 장바구니가 사라진다.
- Hubble UI는 인증이 없다. 시크릿은 `.env` → 클러스터 Secret이며 Git에 두지 않는다.
- L2 Announcements는 VIP당 응답 노드가 1대다(ADR-0003).
