# SPEC.md — Online Boutique Platform Lab 인프라 명세서

| 항목 | 값 |
|---|---|
| 문서 버전 | 1.0 (Draft — 사용자 승인 전) |
| 작성일 | 2026-11-14 |
| 상태 | Phase 0 착수 전 |
| 판정 규칙 | MUST AC 전부 PASS = Phase 완료. SHOULD 미충족은 PROGRESS.md에 사유 기록 후 진행 가능. COULD는 선택 |

---

## 1. 목적과 범위

### 1.1 목적

Google Online Boutique(11개 마이크로서비스 + Redis + 부하 발생기)를 다음 다섯 계층이 갖춰진 로컬 Kubernetes 환경에 배포하고,
각 계층이 **자동화된 검증으로 증명**되는 상태를 만든다.

1. 멀티 노드 (존 시뮬레이션, 워크로드 격리 노드 풀)
2. 네트워크 격리 (eBPF CNI, 기본 거부, L3/L4/L7 정책)
3. L4/L7 로드밸런싱 (LoadBalancer VIP, Gateway API)
4. 관측 가능성 (메트릭, 로그, 트레이스, 네트워크 플로우, 알림)
5. GitOps (선언적 배포, 드리프트 교정, Git 기반 롤백)

### 1.2 범위 안 (In Scope)

- kind 기반 단일 호스트 멀티노드 클러스터, 고정 Docker 서브넷
- Cilium: CNI, kube-proxy 대체, LB-IPAM, L2 Announcements, Gateway API, 네트워크 정책, Hubble
- cert-manager 사설 CA 기반 TLS
- Argo CD app-of-apps, AppProject 권한 분리, self-management
- kube-prometheus-stack, Loki + Alloy, Tempo + OpenTelemetry Collector, Grafana 대시보드·알림 as code
- Online Boutique 고정 버전 배포 + 운영 보강(분산, PDB, 리소스, PSA, 트레이싱)
- Phase별 검증 스크립트, 런북, 클린 재구축 검증

### 1.3 범위 밖 (Out of Scope) / 향후 확장

| 항목 | 사유 / 확장 경로 |
|---|---|
| 클라우드 관리형 클러스터(EKS/GKE), HA 컨트롤 플레인, 멀티 클러스터 | 로컬 재현성 우선. 디렉터리 구조는 overlay 추가로 확장 가능 |
| 이미지 빌드 CI, 이미지 자동 업데이트 | 업스트림 이미지 사용 |
| 외부 시크릿 저장소(SOPS/Sealed Secrets/ESO) | 부트스트랩 Secret으로 대체. 확장 후보 1순위 |
| 서비스 메시 mTLS (Cilium ztunnel 등) | 확장 후보. WireGuard 노드 간 암호화는 COULD |
| Argo Rollouts 기반 자동 점진 배포 | 수동 가중치 카나리까지만 |
| shoppingassistantservice | 외부 LLM 의존 |
| 장기 데이터 보존, 백업/DR | 실습 환경 |

## 2. 전제와 환경

### 2.1 호스트 요구사항

| 항목 | 최소 | 권장 | 비고 |
|---|---|---|---|
| OS | Linux (커널 5.10+, cgroup v2) / macOS + Docker Desktop | Linux | macOS는 VIP 호스트 직접 접근 불가(ARCHITECTURE §15-6) |
| CPU (Docker 할당) | 8 vCPU | 12 vCPU | |
| 메모리 (Docker 할당) | 16 GiB | 32 GiB | |
| 디스크 여유 | 40 GB | 80 GB | 이미지 + PVC |
| 네트워크 | 인터넷(이미지/차트/GitHub) | | 오프라인은 범위 밖 |
| inotify (Linux) | `max_user_watches ≥ 524288`, `max_user_instances ≥ 512` | | |

### 2.2 필요 도구

docker, kind, kubectl, helm(v3.18+ 또는 v4), cilium-cli, hubble, kustomize, jq, yq(v4), git, make,
yamllint, kubeconform, gitleaks(권장), argocd CLI(선택, `--core` 모드).

### 2.3 외부 의존

- **GitOps 저장소**: 사용자의 GitHub 저장소(`GITOPS_REPO_URL`, 기본 브랜치 `main`). 비공개면 `GITHUB_TOKEN`(read 권한) 필요.
- 헬름 저장소/레지스트리: cilium, argo, jetstack, prometheus-community, grafana(Alloy), **grafana-community(Loki, Tempo — ADR-0009)**, open-telemetry.
- 이미지: Online Boutique(Artifact Registry), redis(Docker Hub), 기타 차트 이미지.

### 2.4 설정 파일

- `.env` (gitignored, `.env.example` 제공): `GITOPS_REPO_URL`, `GITOPS_REVISION`, `GITHUB_TOKEN`, `GRAFANA_ADMIN_PASSWORD`, `DOCKER_SUBNET`(기본 172.30.0.0/16)
- `versions.env` (커밋): 모든 도구·차트·이미지 버전

## 3. 용어

| 용어 | 정의 |
|---|---|
| AC | Acceptance Criteria. `AC-<phase>.<n>` 형식, 자동 검증 스크립트가 판정 |
| VIP | LB-IPAM이 할당한 LoadBalancer 외부 IP |
| probe 컨테이너 | `kind-boutique` Docker 네트워크에 붙어 클러스터 "외부"에서 요청을 보내는 검증용 컨테이너 |
| identity | Cilium이 라벨 집합으로 부여하는 보안 주체 ID |
| 인수(adoption) | 명령형으로 설치된 리소스를 Argo CD가 동일 매니페스트로 관리 시작하는 것 |
| 골든 시그널 | 요청률, 오류율, 지연(p50/p95/p99), 포화도 |

---

## 4. 요구사항

우선순위: **MUST**(Phase 완료 필수) / **SHOULD**(강력 권장, 미충족 시 사유 기록) / **COULD**(선택·확장).

### 4.1 기능 요구사항 (FR)

#### 클러스터 (CL)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-CL-01 | kind로 컨트롤 플레인 1 + 워커 4(인프라 1, 앱 3) 클러스터를 생성한다 | MUST |
| FR-CL-02 | 앱 워커는 `topology.kubernetes.io/zone` = zone-a/b/c, 인프라 워커는 전용 taint를 가진다 | MUST |
| FR-CL-03 | 기본 CNI(kindnet)와 kube-proxy를 설치하지 않는다 | MUST |
| FR-CL-04 | 노드는 고정 서브넷 Docker 네트워크 `kind-boutique`에 연결된다 | MUST |
| FR-CL-05 | controller-manager, scheduler, etcd 메트릭이 클러스터 내부에서 수집 가능하다 | SHOULD |

#### CNI·데이터플레인 (NET)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-NET-01 | Cilium이 CNI이며 kube-proxy를 완전 대체한다 | MUST |
| FR-NET-02 | Hubble relay/UI로 클러스터 전체 플로우를 조회할 수 있다 | MUST |
| FR-NET-03 | `cilium connectivity test`가 통과한다 | MUST |
| FR-NET-04 | Service LB 알고리즘은 Maglev | SHOULD |
| FR-NET-05 | WireGuard 노드 간 투명 암호화 | COULD |

#### L4 로드밸런싱 (L4)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-L4-01 | `type: LoadBalancer` Service에 풀에서 VIP가 자동 할당된다 | MUST |
| FR-L4-02 | VIP는 L2 Announcement로 Docker 네트워크에서 도달 가능하다 | MUST |
| FR-L4-03 | 특정 Service에 고정 VIP를 지정할 수 있다(Gateway .10, frontend-external .20) | MUST |
| FR-L4-04 | VIP 응답 노드 장애 시 30초 이내 다른 노드로 전환된다 | SHOULD |
| FR-L4-05 | `externalTrafficPolicy: Local`에서 클라이언트 소스 IP가 보존된다 | SHOULD |

#### L7 로드밸런싱 (L7)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-L7-01 | Gateway API(GatewayClass `cilium`)로 공유 Gateway `edge` 하나를 운영한다 | MUST |
| FR-L7-02 | Host 기반 라우팅: shop / grafana / argocd / hubble `.boutique.test` | MUST |
| FR-L7-03 | 사설 CA 와일드카드 인증서로 TLS 종료, HTTP→HTTPS 리다이렉트 | MUST |
| FR-L7-04 | 가중치 카나리(frontend 90 / frontend-canary 10)와 헤더 `x-canary: always` 강제 라우팅 | MUST |
| FR-L7-05 | 요청 타임아웃, 응답 헤더 추가(`x-served-by`) | SHOULD |
| FR-L7-06 | Route 소유권 분리(`allowedRoutes` 네임스페이스 라벨, ReferenceGrant) | MUST |
| FR-L7-07 | East-West gRPC 요청 단위 L7 LB 비교 실험 | COULD |
| FR-L7-08 | GRPCRoute로 gRPC 서비스 외부 노출 | COULD |

#### 네트워크 격리 (ISO)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-ISO-01 | `boutique` 네임스페이스는 Ingress/Egress 기본 거부 | MUST |
| FR-ISO-02 | 호출 그래프(§5.6) 간선만 컨테이너 포트 단위로 허용 | MUST |
| FR-ISO-03 | Egress는 kube-dns(53)와 명시 목적지만 허용, DNS 질의 가시성 확보 | MUST |
| FR-ISO-04 | paymentservice, cartservice, emailservice는 gRPC 메서드 단위 L7 허용 | MUST |
| FR-ISO-05 | 나머지 gRPC 백엔드도 L7 규칙 적용(→ 전 서비스 L7 가시성) | SHOULD |
| FR-ISO-06 | `observability`, `argocd`는 Ingress 기본 거부 + 필요한 출발지만 허용 | MUST |
| FR-ISO-07 | 감사 모드 → 집행 모드 단계 적용 | SHOULD |
| FR-ISO-08 | `boutique`에서 인터넷·kube-apiserver egress 차단 | MUST |
| FR-ISO-09 | `boutique` PSA `restricted` enforce | SHOULD |
| FR-ISO-10 | 정책 리소스는 `platform` 프로젝트만 관리(앱 프로젝트에서 차단) | MUST |
| FR-ISO-11 | argocd egress를 FQDN 기반으로 제한(`toFQDNs`) | COULD |

#### 관측성 (OBS)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-OBS-01 | 노드·K8s·컨트롤 플레인·Cilium·Hubble·Envoy·Argo CD·cert-manager 메트릭 수집, 정의된 타깃 100% up | MUST |
| FR-OBS-02 | 모든 Pod 로그가 namespace/pod/container 라벨로 Loki에 저장 | MUST |
| FR-OBS-03 | 트레이싱 지원 서비스의 OTLP 트레이스가 Tempo에 저장, 체크아웃 트레이스가 end-to-end로 연결 | MUST |
| FR-OBS-04 | Grafana 데이터소스·대시보드가 Git에서 프로비저닝 | MUST |
| FR-OBS-05 | Online Boutique 서비스별 골든 시그널 대시보드 | MUST |
| FR-OBS-06 | 사용자 정의 알림 규칙 ≥ 5개, 장애 주입으로 발화 확인 | MUST |
| FR-OBS-07 | exemplar→트레이스, 트레이스→로그 상관 이동 | SHOULD |
| FR-OBS-08 | Hubble에서 정책 판정(FORWARDED/DROPPED/AUDIT)과 DNS가 보인다 | MUST |

#### GitOps (GIT)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-GIT-01 | 부트스트랩 예외 목록(ARCHITECTURE §10.1) 외 모든 리소스는 Git으로 관리 | MUST |
| FR-GIT-02 | app-of-apps + sync wave로 의존 순서 보장 | MUST |
| FR-GIT-03 | 자동 sync + selfHeal + prune (Cilium은 수동, CRD는 prune 금지) | MUST |
| FR-GIT-04 | AppProject `platform`/`apps` 최소 권한 분리 | MUST |
| FR-GIT-05 | Argo CD self-management | MUST |
| FR-GIT-06 | 롤백 = `git revert` | MUST |
| FR-GIT-07 | Phase 완료 태그 | SHOULD |
| FR-GIT-08 | Git에 시크릿 없음(스캔으로 증명) | MUST |

#### 애플리케이션 (APP)
| ID | 요구사항 | 우선순위 |
|---|---|---|
| FR-APP-01 | Online Boutique 고정 버전의 전 서비스(+redis, loadgenerator) 정상 동작 | MUST |
| FR-APP-02 | 업스트림 매니페스트 벤더링 + Kustomize overlay | MUST |
| FR-APP-03 | frontend 3 레플리카 존 분산 + PDB(minAvailable 2) | MUST |
| FR-APP-04 | 모든 컨테이너 requests/limits 지정 | MUST |
| FR-APP-05 | 트레이싱 활성화(업스트림이 지원하는 서비스) | MUST |
| FR-APP-06 | frontend-canary 변형 배포 | MUST |

### 4.2 비기능 요구사항 (NFR)

| ID | 범주 | 요구사항 | 측정 |
|---|---|---|---|
| NFR-01 | 재현성 | 깨끗한 호스트에서 `.env` 작성 외 수동 개입 없이 `make up` → `make verify-all` 통과 | AC-9.1 |
| NFR-02 | 멱등성 | `make up` 재실행 시 오류·변경 없음 | AC-1.7, AC-9.1 |
| NFR-03 | 버전 고정 | `latest`·범위 버전 0건, 버전 단일 기록 일치 | `make lint` |
| NFR-04 | 소요 시간 | 콜드 스타트 `make up` ≤ 30분(권장 사양, 양호한 네트워크), 이미지 캐시 시 ≤ 15분 | AC-9.1 기록 |
| NFR-05 | 자원 | 클러스터 전체 requests ≤ 6 vCPU / 10 GiB | AC-9.7 |
| NFR-06 | 보안 | Git 시크릿 0건, 앱 Pod 비특권, PSA 적용 | AC-3.7, AC-8.6 |
| NFR-07 | 자기 관측 | 플랫폼 구성요소 메트릭 미수집 0건 | AC-7.2 |
| NFR-08 | 문서화 | 모든 설계 결정 ADR, 런북 5종 | AC-9.6 |
| NFR-09 | 이식성 | Linux amd64/arm64, macOS(Apple Silicon)에서 검증 스크립트 동일 동작 | probe 컨테이너 사용 |
| NFR-10 | 정적 검증 | push 전 `make lint` 통과(kustomize/helm 렌더 + kubeconform + yamllint + gitleaks) | 각 Phase |

---

## 5. 기술 설계 상세

### 5.1 버전 매트릭스

작성 시점(2026-11-14)에 확인한 기준값이다. **Phase 0에서 각 항목의 최신 패치와 상호 호환성을 재확인해 `versions.env`에 핀**한다.
원칙: 마이너는 아래 기준을 따르고 패치는 최신. 새 마이너(예: Kubernetes 1.37)는 Cilium 호환 매트릭스가 지원을 명시할 때만 채택.

| 구성요소 | 기준 | 근거·비고 |
|---|---|---|
| kind | v0.33.0 | 기본 노드 이미지는 1.37.0이지만 아래 1.36을 명시 사용 |
| Kubernetes (kindest/node) | v1.36.4 `@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed` | kind 릴리스 노트의 digest로 재확인. Cilium 1.20 지원 범위 확인 필수 |
| Cilium (chart/image) | 1.20.x 최신 패치 | 1.20.0 GA 2026-07-29 |
| cilium-cli, hubble CLI | Cilium 1.20 호환 최신 | |
| Gateway API CRDs | v1.6.3 | Cilium 1.20.5 문서(`conf.py`의 `gateway_api_version`) 기준. 필요한 채널(standard/experimental)과 CRD 목록은 Cilium 1.20 문서의 prerequisites를 따름 |
| Argo CD | 3.5.x 최신 패치 (argo/argo-cd 차트 대응 버전) | 3.5 GA 2026-08. 3.6 GA 시 채택 여부는 Phase 0 판단 |
| cert-manager | 최신 stable v1.x | |
| kube-prometheus-stack / prometheus-operator-crds | 최신 stable (서로 호환되는 조합) | CRD는 별도 차트로 관리 |
| Loki | 3.x 최신 (SingleBinary) | 차트는 `grafana-community` 저장소(OSS). `grafana/loki`는 GEL 전용 (ADR-0009) |
| Tempo | 최신 stable (monolithic) | 차트는 `grafana-community` 저장소. `grafana/tempo`는 2026-01-30 이후 deprecated (ADR-0009). Tempo 3.x는 Phase 7에서 values 키 재검증 |
| Grafana Alloy | 최신 stable | Promtail 사용 금지(EOL) |
| OpenTelemetry Collector | contrib 배포판 최신 stable | spanmetrics connector 포함 |
| Online Boutique | v0.10.x 최신 (작성 시점 v0.10.4 확인) | |
| probe/디버그 이미지 | curlimages/curl, nicolaka/netshoot 고정 태그 | |

### 5.2 클러스터 사양 (`bootstrap/kind/cluster.yaml`)

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: boutique
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
    image: kindest/node:v1.36.4@sha256:<versions.env 값>
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiVersion: kubeadm.k8s.io/v1beta4
        controllerManager:
          extraArgs:
            - name: bind-address
              value: "0.0.0.0"
        scheduler:
          extraArgs:
            - name: bind-address
              value: "0.0.0.0"
        etcd:
          local:
            extraArgs:
              - name: listen-metrics-urls
                value: "http://0.0.0.0:2381"
  - role: worker                       # boutique-worker  (infra)
    image: kindest/node:v1.36.4@sha256:<…>
    labels:
      node.boutique.io/pool: infra
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          taints:
            - key: node.boutique.io/dedicated
              value: infra
              effect: NoSchedule
  - role: worker                       # boutique-worker2 (zone-a)
    image: kindest/node:v1.36.4@sha256:<…>
    labels:
      node.boutique.io/pool: app
      topology.kubernetes.io/zone: zone-a
  # worker3 = zone-b, worker4 = zone-c (동일 형식)
```

생성 절차(`bootstrap/scripts/cluster-up.sh`, 멱등):
1. `docker network inspect kind-boutique` 없으면 `docker network create --driver bridge --subnet 172.30.0.0/16 --gateway 172.30.0.1 kind-boutique`. 있으면 서브넷 일치 확인(불일치 시 중단).
2. `KIND_EXPERIMENTAL_DOCKER_NETWORK=kind-boutique kind create cluster --config …` (클러스터가 이미 있으면 건너뜀).
3. kubeconfig 컨텍스트 `kind-boutique` 확인.

### 5.3 Cilium 사양

`platform/cilium/values.yaml` (부트스트랩과 Argo CD 공용, 키는 고정 버전의 `helm show values`로 검증):

```yaml
kubeProxyReplacement: true
k8sServiceHost: boutique-control-plane
k8sServicePort: 6443
ipam:
  mode: kubernetes
routingMode: tunnel
tunnelProtocol: vxlan
loadBalancer:
  algorithm: maglev
l2announcements:
  enabled: true
  leaseDuration: 3s
  leaseRenewDeadline: 1s
  leaseRetryPeriod: 200ms
k8sClientRateLimit:          # L2 lease 갱신으로 API 호출 증가 → 상향
  qps: 50
  burst: 100
gatewayAPI:
  enabled: true
envoy:
  enabled: true
policyAuditMode: false       # Phase 8 감사 기간에만 true
operator:
  replicas: 1
  nodeSelector: { node.boutique.io/pool: infra }   # toleration 포함
hubble:
  enabled: true
  relay: { enabled: true }   # infra 노드 배치
  ui: { enabled: true }      # infra 노드 배치
  tls:
    auto:
      method: cronJob        # Argo CD 영구 drift 방지
  metrics:
    enableOpenMetrics: true
    # 컨텍스트 옵션 문법은 Cilium 1.20 Hubble metrics 문서로 확인 후 확정
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp
      - "policy:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity"
      - "httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
prometheus:
  enabled: true
```

`platform/cilium/values-monitoring.yaml` (Phase 7에서 Application의 valueFiles에 추가):
ServiceMonitor 활성화 — agent(`prometheus.serviceMonitor`), operator, hubble metrics, envoy. 필요 시 Cilium 차트의 Grafana 대시보드 ConfigMap 활성화.

부트스트랩(`cni.sh`)은 monitoring 레이어가 만드는 ServiceMonitor를 위해 Prometheus Operator CRD를 먼저 server-side apply한 뒤, Application과 **같은 values 파일 목록**으로 설치한다(ADR-0012, `make lint`가 목록 일치를 검사).

Argo CD 인수 규칙:
- Application `cilium`: `releaseName: cilium`, `namespace: kube-system`, 자동 sync 없음, `ServerSideApply=true`.
- 인수 전 `argocd app diff`(또는 `--core`)로 차이가 메타데이터(추적 어노테이션)뿐임을 확인 후 sync.
- 인수 후 cilium Pod 재시작 횟수 불변이어야 한다(AC-3.2).
- 해결 불가한 동적 필드(인증서 Secret data 등)만 `ignoreDifferences`에 등록하고 근거를 주석으로 남긴다.

### 5.4 L4 사양

```yaml
apiVersion: cilium.io/v2   # 1.20의 API 버전 확인
kind: CiliumLoadBalancerIPPool
metadata: { name: default-pool }
spec:
  blocks:
    - start: "172.30.250.10"
      stop: "172.30.250.250"
---
apiVersion: cilium.io/v2alpha1   # 1.20의 API 버전 확인
kind: CiliumL2AnnouncementPolicy
metadata: { name: app-workers }
spec:
  nodeSelector:
    matchLabels: { node.boutique.io/pool: app }
  interfaces: ["^eth0$"]
  loadBalancerIPs: true
  externalIPs: true
```

l4-test (`apps/l4-test`, ns `l4-test`): agnhost `netexec` 3 레플리카(존 분산), Service 2개
— `echo-cluster`(eTP=Cluster, VIP .30), `echo-local`(eTP=Local, VIP .31). `/hostname`, `/clientip` 엔드포인트로 분산과 소스 IP 보존을 판정.

> **주의:** Cilium 1.20 문서(`network/l2-announcements.rst`, Limitations)는 L2 Announcements가 `externalTrafficPolicy: Local`과 **호환되지 않는다**고 명시한다. L2 리더 선출이 로컬 백엔드 유무를 보지 않아, 백엔드 없는 노드가 VIP에 응답하면 트래픽이 drop된다.
> `echo-local`은 **모든 L2 후보 노드(app 풀 3대)에 Ready 백엔드가 있을 때만 성립하는 실증용**이다(존 분산 `DoNotSchedule`). 한 노드의 백엔드가 Ready가 아닌 동안에는 `.31`이 끊길 수 있다.
> 운영 대상 Service(Gateway `edge`, `frontend-external`)는 `Cluster`만 사용한다.

### 5.5 L7 사양

| 리소스 | 네임스페이스 | 핵심 설정 |
|---|---|---|
| ClusterIssuer `selfsigned` → Certificate `boutique-root-ca`(isCA) → ClusterIssuer `boutique-ca` | cert-manager | 루트 CA 10년, ECDSA P-256 |
| Certificate `wildcard-boutique-test` | gateway | `*.boutique.test`, Secret `wildcard-tls` |
| Gateway `edge` | gateway | `gatewayClassName: cilium`, VIP 172.30.250.10 고정(Cilium이 생성하는 LB Service에 LB-IPAM 어노테이션 전달 — `spec.addresses` 또는 `spec.infrastructure.annotations` 중 1.20 지원 방식), 리스너 http:80 / https:443(`*.boutique.test`, TLS Terminate), `allowedRoutes.namespaces.from: Selector` (`gateway-access: "true"`) |
| HTTPRoute `http-redirect` | gateway | :80 전체 → `RequestRedirect` scheme https, 301 |
| HTTPRoute `shop` | boutique | host `shop.boutique.test`; 규칙1: 헤더 `x-canary: always` → frontend-canary 100%; 규칙2: frontend 90 / frontend-canary 10; `timeouts.request: 10s`; `ResponseHeaderModifier` `x-served-by: gateway-edge` |
| HTTPRoute `argocd` | argocd | host `argocd.boutique.test` → argocd-server:80 (`server.insecure: true`) |
| HTTPRoute `grafana` | observability | host `grafana.boutique.test` → grafana:80 (Phase 7) |
| HTTPRoute `hubble` + ReferenceGrant | gateway / kube-system | host `hubble.boutique.test` → kube-system/hubble-ui:80 |

카나리 식별: 1순위 backendRef 수준 `ResponseHeaderModifier`로 `x-variant: stable|canary`(Cilium 지원 확인), 미지원 시 frontend-canary의 배너 문자열(업스트림 frontend가 지원하는 env로 설정)로 판정.

(COULD) East-West L7 LB: Cilium values `loadBalancer.l7.backend: envoy` + productcatalogservice Service 어노테이션 `service.cilium.io/lb-l7: enabled`. 활성 전/후 레플리카별 요청 비율을 Hubble L7 플로우로 비교(HTTP 요청 단위 데이터는 L7 가시성이 필요하므로, **측정하는 동안만** productcatalogservice 인그레스에 전부 허용 L7 CiliumNetworkPolicy를 스크립트가 적용하고 종료 시 제거).

### 5.6 네트워크 정책 매트릭스 (boutique)

정책 포트 = 컨테이너 포트. L7 규칙은 `method: POST`, `path: /hipstershop.<Svc>/<Method>`.

| # | 출발지 | 목적지 | 포트 | L7 허용 | 우선순위 |
|---|---|---|---|---|---|
| 1 | `reserved:ingress` (Gateway) | frontend, frontend-canary | 8080/TCP | HTTP 전체 메서드·경로 | MUST |
| 2 | L4 VIP 진입 identity(`world` 또는 `remote-node`, 감사 모드로 확정) | frontend | 8080/TCP | — | MUST |
| 3 | loadgenerator | frontend | 8080/TCP | HTTP 전체 | MUST |
| 4 | frontend(+canary) | adservice | 9555 | `AdService/GetAds` | SHOULD(L7) |
| 5 | frontend(+canary) | cartservice | 7070 | `CartService/GetCart`, `AddItem`, `EmptyCart` | MUST |
| 6 | frontend(+canary) | checkoutservice | 5050 | `CheckoutService/PlaceOrder` | SHOULD(L7) |
| 7 | frontend(+canary) | currencyservice | 7000 | `CurrencyService/GetSupportedCurrencies`, `Convert` | SHOULD(L7) |
| 8 | frontend(+canary) | productcatalogservice | 3550 | `ProductCatalogService/ListProducts`, `GetProduct` | SHOULD(L7) |
| 9 | frontend(+canary) | recommendationservice | 8080 | `RecommendationService/ListRecommendations` | SHOULD(L7) |
| 10 | frontend(+canary) | shippingservice | 50051 | `ShippingService/GetQuote` | SHOULD(L7) |
| 11 | checkoutservice | cartservice | 7070 | `CartService/GetCart`, `EmptyCart` | MUST |
| 12 | checkoutservice | productcatalogservice | 3550 | `ProductCatalogService/GetProduct` | SHOULD(L7) |
| 13 | checkoutservice | currencyservice | 7000 | `CurrencyService/Convert` | SHOULD(L7) |
| 14 | checkoutservice | shippingservice | 50051 | `ShippingService/GetQuote`, `ShipOrder` | SHOULD(L7) |
| 15 | checkoutservice | paymentservice | 50051 | `PaymentService/Charge` | MUST |
| 16 | checkoutservice | emailservice | 8080 | `EmailService/SendOrderConfirmation` | MUST |
| 17 | recommendationservice | productcatalogservice | 3550 | `ProductCatalogService/ListProducts` | SHOULD(L7) |
| 18 | cartservice | redis-cart | 6379 | — (L4) | MUST |
| 19 | boutique 전체 | kube-system/kube-dns | 53/UDP·TCP | `dns.matchPattern: "*"` | MUST |
| 20 | 트레이싱 서비스 | observability/otel-collector | 4317/TCP | — | MUST |
| — | host(kubelet 프로브) | 전체 | 프로브 포트 | Cilium 기본 허용 | — |

- frontend-canary는 frontend와 같은 정책을 받도록 셀렉터를 `app in (frontend, frontend-canary)`로 작성.
- L7 메서드 목록은 감사 모드 관측으로 최종 확정(업스트림 버전에 따라 추가 호출이 있을 수 있음). 확정된 목록을 이 표에 반영한다.
- 각 간선은 egress(호출자)와 ingress(피호출자) 양쪽 규칙이 모두 필요하다.

플랫폼 네임스페이스 Ingress 허용(FR-ISO-06):

| 네임스페이스 | 허용 출발지 → 대상 |
|---|---|
| observability | 동일 NS 전체; `reserved:ingress` → grafana:3000; boutique 트레이싱 서비스 → otel-collector:4317; host/remote-node → (kubelet 프로브) |
| argocd | 동일 NS 전체; `reserved:ingress` → argocd-server:8080; observability/prometheus → 각 컴포넌트 메트릭 포트 |

### 5.7 관측성 사양

| 구성요소 | 배치 | 핵심 설정 |
|---|---|---|
| prometheus-operator-crds | (CRD) | Phase 3 설치, kube-prometheus-stack은 `crds.enabled: false` |
| kube-prometheus-stack | infra 노드 | Prometheus 보존 3d, PVC 10Gi(`standard`), `enableFeatures: [exemplar-storage]`, 셀렉터 `*NilUsesHelmValues: false`(모든 NS의 SM/PM/Rule 수집), `kubeProxy.enabled: false`, etcd 2381 스크레이프, Grafana 사이드카(`grafana_dashboard: "1"`, 전체 NS), `admin.existingSecret` |
| Loki | infra | SingleBinary, filesystem, 보존 48h, PVC 10Gi, 인증 비활성(단일 테넌트) |
| Alloy | DaemonSet (모든 노드) | `/var/log/pods` tail, `namespace`/`pod`/`container`/`app` 라벨, Loki push |
| Tempo | infra | monolithic, local 스토리지, 보존 24h, OTLP gRPC 수신 |
| OTel Collector | infra, Deployment | receivers: otlp(4317/4318); processors: memory_limiter, k8sattributes, batch; connectors: spanmetrics(서비스·span 이름·상태 코드, 지연 히스토그램); exporters: otlp→Tempo, prometheus(스크레이프용) |
| Grafana | infra | 데이터소스: Prometheus(exemplar→Tempo), Loki, Tempo(tracesToLogs→Loki, 서비스맵→Prometheus) |

대시보드(Git, `observability/dashboards/`): Kubernetes 클러스터/노드(차트 기본), Cilium agent/operator, Hubble(드롭·정책·DNS·HTTP), Gateway(Envoy), Argo CD, **Boutique Golden Signals**(서비스별 RPS·오류율·p95/p99 — spanmetrics 기반, Phase 8에 Hubble L7 패널 추가).

알림 규칙(`observability/rules/`, PrometheusRule):

| 이름 | 조건(요지) | for | 도입 |
|---|---|---|---|
| BoutiqueDeploymentUnavailable | boutique Deployment 가용 레플리카 < 의도 | 2m | 7 |
| BoutiqueCheckoutErrorRateHigh | checkoutservice span 오류 비율 > 10% | 2m | 7 |
| BoutiqueFrontendLatencyP95High | frontend p95 > 1s | 10m | 7 |
| GatewayHigh5xxRate | Gateway 응답 5xx 비율 > 5% | 5m | 7 |
| CiliumAgentUnhealthy | agent 비가용 또는 unreachable 노드 존재 | 5m | 7 |
| ArgoAppNotHealthy | Application OutOfSync 또는 Degraded | 10m | 7 |
| HubblePolicyDropsDetected | boutique 정책 거부 드롭 증가 | 2m | 8 |

Alertmanager: 실습용 `null` 수신자 기본 + (선택) 로컬 웹훅. 판정은 Prometheus `ALERTS{alertstate="firing"}`로 한다.

메트릭 이름은 고정 버전에서 실제 노출되는 이름으로 확정하고 규칙 파일에 주석으로 원천을 기록한다.

**스크레이프 TLS 예외(ADR-0011)**: kubelet·kube-controller-manager·kube-scheduler는 서빙 인증서가 각자의 자체 서명 CA라 검증할 CA가 없다. 이 세 타깃에 한해 `insecureSkipVerify: true`를 허용하며, `make lint`가 그 밖의 TLS 검증 생략을 거부한다.

### 5.8 GitOps 사양

- Argo CD 차트 values(`platform/argocd/values.yaml`): 모든 컴포넌트 infra 노드 배치, `configs.params."server.insecure": true`, `configs.cm`에 Application health customization, `resource.exclusions`에 Cilium 동적 리소스 추가(기본값 유지), 기본 tracking 방식(annotation) 유지.
- `values-monitoring.yaml`: 각 컴포넌트 ServiceMonitor (Phase 7).
- root Application: `gitops/apps` 재귀, `automated: {prune: true, selfHeal: true}`.
- 공통 syncOptions: `CreateNamespace=false`(네임스페이스는 `namespaces` 앱이 소유), `PruneLast=true`, CRD 앱은 `ServerSideApply=true`, `Prune=false`.
- repo 자격증명: `gitops-bootstrap.sh`가 `.env`로 `argocd.argoproj.io/secret-type: repository` Secret 생성(Git 미포함).
- 버전 일관성: `make lint`의 `check-versions` 단계가 `versions.env` ↔ Application `targetRevision` ↔ 부트스트랩 스크립트 사용 버전을 비교.

### 5.9 애플리케이션 사양 (overlay 패치)

| 대상 | 변경 |
|---|---|
| 전체 | `namespace: boutique`, 공통 라벨 `app.kubernetes.io/part-of: online-boutique`, requests/limits 확인·보강 |
| frontend | replicas 3, zone `topologySpreadConstraints`, PDB minAvailable 2, unreachable/not-ready toleration 30s |
| productcatalogservice | replicas 3, zone 분산(L7 LB 실험 대상) |
| frontend-external | `lbipam.cilium.io/ips: 172.30.250.20` (L4 경로로 유지) |
| 트레이싱 | 업스트림이 트레이싱을 지원하는 서비스에 `ENABLE_TRACING=1`, `COLLECTOR_SERVICE_ADDR=otel-collector.observability.svc.cluster.local:4317` — 실제 env 이름과 지원 서비스 목록은 고정 버전 소스(업스트림 kustomize 트레이싱 컴포넌트)에서 확인 |
| loadgenerator | 사용자 수·속도를 낮게 조정(env 이름은 고정 버전에서 확인), 대상은 내부 frontend Service |
| 보안 컨텍스트 | PSA restricted 위반 항목(예: `seccompProfile`)만 패치로 보강 |
| frontend-canary | `apps/online-boutique/canary/`: frontend와 동일 이미지 1 레플리카, 식별 가능한 env(배너), Service `frontend-canary` |

### 5.10 설정·시크릿 관리

| 항목 | 위치 | 생성 주체 |
|---|---|---|
| repo 자격증명 | argocd/Secret | `gitops-bootstrap.sh` (`.env`) |
| Grafana 관리자 | observability/Secret `grafana-admin` | `gitops-bootstrap.sh` (`.env`) |
| Argo CD 초기 관리자 | argocd/Secret `argocd-initial-admin-secret` | Argo CD 자동 생성 |
| 루트 CA 키 | cert-manager/Secret | cert-manager 자동 생성 (클러스터 수명과 동일) |
| 테스트용 CA 공개 인증서 | `tests/.cache/ca.crt` (gitignored) | 테스트 스크립트가 추출 |

---

## 6. 단계별 구현 계획과 완료 기준

공통 규칙
- 각 Phase는 `tests/phase-<n>.sh`를 가진다. 출력: `[PASS|FAIL|SKIP] AC-<n>.<m> <설명>`, 마지막 줄 요약, MUST 실패 시 exit 1.
- "검증 방법"의 명령은 의도를 보여주는 예시다. 스크립트는 같은 판정을 재현 가능하게 구현한다(타임아웃·재시도 포함).
- Phase N 완료 후에도 이전 Phase의 AC는 계속 유지되어야 한다(`make verify-all`이 회귀를 잡는다).

```mermaid
flowchart LR
  P0[0 준비] --> P1[1 클러스터] --> P2[2 Cilium] --> P3[3 GitOps]
  P3 --> P4[4 L4] --> P5[5 앱] --> P6[6 L7] --> P7[7 관측성] --> P8[8 격리] --> P9[9 복원력·인수]
```

### 6.0 Phase 0 — 준비 (Preflight & Scaffolding)

**목표**: 저장소 골격, 버전 핀, 호스트 점검, 테스트 하네스를 갖춘다.

**작업**
1. ARCHITECTURE §11 디렉터리 골격, `.gitignore`(.env, kubeconfig, `tests/results/`, `tests/.cache/`, `*.key`), `.env.example`
2. `versions.env` 작성: §5.1의 모든 항목을 공식 릴리스 페이지에서 확인해 핀(각 줄에 확인 출처 URL 주석)
3. `bootstrap/scripts/preflight.sh`: 도구·버전, Docker 동작, cgroup v2, Docker 할당 CPU/메모리, 디스크, inotify(Linux), 서브넷 충돌(호스트 라우트·기존 Docker 네트워크) 점검
4. `tests/lib.sh`: `ac_pass/ac_fail/ac_skip`, `wait_for <timeout> <cmd>`, `probe_curl`(kind-boutique 네트워크의 curl 컨테이너, CA 마운트), `debug_curl <ns> <pod> <args>`(ephemeral 컨테이너), `prom_query`, `loki_query`, `tempo_search`(port-forward + trap 정리)
5. `Makefile` 타깃 골격, `make lint`(yamllint, kustomize build, helm template, kubeconform with CRD 스키마, check-versions, gitleaks)
6. Online Boutique 고정 버전 이미지의 아키텍처 지원 확인(`docker manifest inspect`)
7. `.claude/commands/` 커스텀 커맨드 확인, PROGRESS.md 갱신

**산출물**: 디렉터리 골격, `Makefile`, `versions.env`, `.env.example`, `bootstrap/scripts/preflight.sh`, `tests/lib.sh`, `tests/phase-0.sh`

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-0.1 | MUST | `make preflight` exit 0 (최소 사양 미달 시 명확한 메시지와 함께 실패) | `make preflight` |
| AC-0.2 | MUST | `versions.env`에 §5.1 전 항목 존재, `latest`/범위 버전 0건, kind 노드 이미지 digest 포함 | grep 기반 검사 |
| AC-0.3 | MUST | 저장소 구조가 ARCHITECTURE §11과 일치 | 경로 존재 검사 |
| AC-0.4 | MUST | `make lint` 실행 가능(현재 매니페스트 기준 통과) | `make lint` |
| AC-0.5 | MUST | 호스트 아키텍처용 Online Boutique 이미지 존재 확인 | manifest inspect |
| AC-0.6 | MUST | `.gitignore`가 시크릿 경로 포함, 원격 저장소 설정, 작업 트리 clean | `git check-ignore`, `git status` |

**롤백**: 해당 없음(파일만 생성).

### 6.1 Phase 1 — 멀티노드 클러스터

**목표**: CNI 없는 5노드 kind 클러스터를 고정 네트워크 위에 멱등적으로 생성한다.

**작업**
1. `bootstrap/kind/cluster.yaml` (§5.2)
2. `bootstrap/scripts/cluster-up.sh` (네트워크 생성/검증 → 클러스터 생성, 멱등)
3. `make cluster-up`, `tests/phase-1.sh`

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-1.1 | MUST | 노드 5개(control-plane 1, worker 4) 등록 | `kubectl get nodes` |
| AC-1.2 | MUST | 라벨·taint가 ARCHITECTURE §4와 일치 | `kubectl get nodes -L …`, taint jsonpath |
| AC-1.3 | MUST | `kube-proxy`, `kindnet` DaemonSet 부재 | `kubectl -n kube-system get ds` |
| AC-1.4 | MUST | 모든 노드 IP ∈ 172.30.0.0/16, 네트워크 `kind-boutique` | `docker network inspect` |
| AC-1.5 | SHOULD | controller-manager(10257)/scheduler(10259)/etcd(2381) 포트가 노드 IP에서 응답(연결 거부 아님) | probe 컨테이너에서 접속 시도 |
| AC-1.6 | MUST | `make cluster-up` 재실행 시 오류 없이 "already exists" 처리 | 2회 실행 |

**롤백**: `make down`(사용자 확인 후).

### 6.2 Phase 2 — CNI (Cilium + Hubble)

**목표**: Cilium으로 노드를 Ready로 만들고 kube-proxy 대체·Gateway API·L2·Hubble 기반 기능을 활성화한다.

**작업**
1. Gateway API CRD(v1.6.3 standard, Cilium 1.20 요구 목록 7종)를 `platform/gateway-api-crds/`에 벤더링하고 `kubectl apply --server-side`
2. `platform/cilium/values.yaml`(§5.3) 작성, `bootstrap/scripts/cni.sh`로 `helm upgrade --install` (버전은 `versions.env`)
3. `cilium status --wait`, `cilium connectivity test`(완료 후 테스트 네임스페이스 정리)
4. `tests/phase-2.sh`

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-2.1 | MUST | 설치 후 5분 내 모든 노드 Ready | `kubectl wait --for=condition=Ready nodes --all --timeout=5m` |
| AC-2.2 | MUST | cilium agent/operator/envoy/relay/ui 전부 Ready | `cilium status --wait` |
| AC-2.3 | MUST | 모든 agent에서 KubeProxyReplacement True, Service LB 알고리즘 Maglev | `kubectl -n kube-system exec ds/cilium -- cilium-dbg status`를 노드별로 |
| AC-2.4 | MUST | `cilium connectivity test` 전 항목 통과(skip 항목은 사유 기록) | 실행 로그 |
| AC-2.5 | MUST | `hubble observe --last 50`이 relay를 통해 여러 노드의 플로우 반환 | hubble CLI(port-forward) |
| AC-2.6 | MUST | GatewayClass `cilium` Accepted=True, CRD 7종의 `bundle-version` 어노테이션 = `versions.env`의 `GATEWAY_API_VERSION`(v1.6.3), `channel` = standard | `kubectl get gatewayclass`, CRD 어노테이션 |
| AC-2.7 | MUST | CoreDNS Ready, 테스트 Pod에서 `kubernetes.default` 해석 성공 | 임시 Pod nslookup |
| AC-2.8 | MUST | hubble-relay/ui, cilium-operator가 infra 노드에 배치 | Pod nodeName |

**롤백**: `helm uninstall cilium`은 클러스터 네트워크를 끊는다 → 클러스터 재생성이 기본 롤백.

### 6.3 Phase 3 — GitOps 부트스트랩 (Argo CD)

**목표**: Argo CD를 설치하고, 이후 모든 변경이 Git을 통해서만 반영되는 구조로 전환한다. Cilium과 Argo CD 자신을 인수한다.

**작업**
1. `platform/argocd/values.yaml`(§5.8), `bootstrap/scripts/gitops-bootstrap.sh`: helm 설치 → repo Secret·Grafana Secret 생성(.env) → `gitops/projects/*` → `gitops/root.yaml` apply
2. 자식 앱: `namespaces`(argocd, cert-manager, gateway, observability, boutique, l4-test + PSA/`gateway-access` 라벨), `gateway-api-crds`, `prometheus-operator-crds`, `cilium`(수동), `argocd`(self)
3. Cilium 인수 절차(§5.3): diff 확인 → 수동 sync → Pod 재시작 없음 확인 → 10분 후 diff 재확인
4. `make wait-sync`, `tests/phase-3.sh`
5. 이 Phase 이후 모든 매니페스트 변경은 commit/push로만

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-3.1 | MUST | Argo CD 전 Pod Ready, infra 노드 배치 | Pod 상태·nodeName |
| AC-3.2 | MUST | root 및 모든 자식 앱 Synced/Healthy. cilium 인수 전후 cilium Pod restartCount·UID 불변 | Application status, 인수 전후 스냅샷 비교 |
| AC-3.3 | MUST | cilium 앱 sync 10분 후, 20분 후 두 번 모두 OutOfSync 아님(영구 drift 없음) | Application status 반복 조회 |
| AC-3.4 | MUST | selfHeal: 관리 중인 네임스페이스 라벨을 수동 삭제 → 3분 내 원복 | kubectl 변경 후 wait_for |
| AC-3.5 | MUST | prune: Git에 테스트 ConfigMap 추가 → 생성 확인 → Git에서 삭제 → 클러스터에서 삭제 | 커밋 2회 + 확인 |
| AC-3.6 | MUST | `apps` 프로젝트에서 클러스터 범위 리소스 동기화가 거부됨 | 임시 Application(정리 포함)의 sync 오류 메시지 |
| AC-3.7 | MUST | 저장소 전체 시크릿 스캔 0건 | `gitleaks detect` |
| AC-3.8 | MUST | argocd self-management: Git에서 Argo CD 설정값 변경 → 반영 확인 → 원복 | argocd-cm 값 비교 |
| AC-3.9 | MUST | 웨이브 순서 준수: CRD 앱이 cilium/argocd 앱보다 먼저 Healthy | Application 상태 이력/이벤트 |

**롤백**: `git revert` 또는 `phase-2-done` 시점으로 돌아가 Argo CD 제거(`helm uninstall argocd`, 관리 리소스 유지 확인).

### 6.4 Phase 4 — L4 로드밸런싱

**목표**: LoadBalancer Service가 VIP를 받아 클러스터 외부(Docker 네트워크)에서 도달 가능하고, 노드 장애 시 전환되는 것을 증명한다.

**작업**
1. `platform/cilium-lb/`: IP 풀, L2 Announcement 정책(§5.4) → 앱 `cilium-lb`
2. `apps/l4-test/`: agnhost netexec 3 레플리카, `echo-cluster`(.30), `echo-local`(.31) → 앱 `l4-test`
3. `tests/phase-4.sh` (장애 전환 테스트는 trap으로 노드 재시작 보장)

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-4.1 | MUST | IP 풀 conflict 없음, LB Service가 30초 내 풀 범위 IP 획득 | Pool status, Service status |
| AC-4.2 | MUST | 고정 IP 어노테이션 반영(.30, .31) | Service `status.loadBalancer` |
| AC-4.3 | MUST | probe에서 `http://172.30.250.30/hostname` 30회 새 연결 → 200 100%, 서로 다른 백엔드 ≥ 2 | probe_curl 루프 |
| AC-4.4 | SHOULD | `echo-local`의 `/clientip`가 probe 컨테이너 IP 반환(소스 보존) | probe_curl |
| AC-4.5 | SHOULD | `.30`의 L2 Lease 보유 노드를 `docker stop` → 30초 내 VIP 응답 재개 → 노드 재시작 후 Ready | Lease `holderIdentity`, 타이머 |
| AC-4.6 | MUST | Hubble에서 외부 → l4-test 플로우 확인 | `hubble observe -n l4-test` |

**롤백**: `cilium-lb`, `l4-test` 앱 커밋 revert.

### 6.5 Phase 5 — Online Boutique 배포

**목표**: 고정 버전 Online Boutique를 GitOps로 배포하고 운영 보강을 적용한다. L4 VIP로 정상 동작을 증명한다.

**작업**
1. `scripts/vendor-boutique.sh <tag>`: 릴리스 매니페스트 다운로드 → `apps/online-boutique/upstream/` + 체크섬
2. `overlays/lab/` 패치(§5.9, 트레이싱·카나리 제외 — 각각 Phase 7·6)
3. 앱 `online-boutique`(apps 프로젝트)
4. 체크아웃 완료 페이지 마커 문자열을 고정 버전 템플릿에서 찾아 테스트에 상수로 기록
5. `tests/phase-5.sh`

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-5.1 | MUST | 전 Deployment Available, 10분 관찰 동안 재시작 ≤ 1 | `kubectl -n boutique get deploy`, restartCount |
| AC-5.2 | MUST | frontend·productcatalogservice Pod가 zone-a/b/c에 1개씩 | Pod nodeName → 노드 zone 라벨 |
| AC-5.3 | MUST | boutique Pod가 infra/control-plane 노드에 0개 | nodeName |
| AC-5.4 | MUST | `http://172.30.250.20/` 200, 상품 링크(`/product/`) 포함 | probe_curl |
| AC-5.5 | MUST | probe로 장바구니 담기 → 체크아웃 → 주문 완료 마커 확인(쿠키 유지) | probe 스크립트 |
| AC-5.6 | MUST | loadgenerator 실패율 < 1% (Locust 통계 로그) | `kubectl logs` 파싱 |
| AC-5.7 | MUST | PDB `frontend` minAvailable 2, 모든 컨테이너 requests/limits 존재 | jsonpath 검사 |
| AC-5.8 | MUST | selfHeal: `kubectl scale deploy/frontend --replicas=1` → 3분 내 3으로 복구 | wait_for |
| AC-5.9 | SHOULD | PSA restricted 위반 목록 산출(Phase 8 입력) | `kubectl label --dry-run=server ns boutique pod-security.kubernetes.io/enforce=restricted --overwrite` 경고 |

**롤백**: 앱 커밋 revert(Argo prune).

### 6.6 Phase 6 — L7 로드밸런싱 (Gateway API)

**목표**: 공유 Gateway로 TLS·Host 라우팅·카나리·헤더 라우팅을 제공하고 Route 소유권을 분리한다.

**작업**
1. 앱 `cert-manager`(차트), `pki`(CA 체인, §5.5)
2. 앱 `gateway`: Gateway `edge`, 와일드카드 인증서, http→https 리다이렉트, hubble Route + ReferenceGrant
3. frontend-canary(`apps/online-boutique/canary/`) 및 앱 `boutique-routes`(shop HTTPRoute), argocd HTTPRoute
4. `tests/phase-6.sh`: CA 추출 → probe에서 `--cacert` + `--resolve`
5. (COULD) East-West L7 LB 실험(§5.5) — 결과를 PROGRESS에 표로 기록

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-6.1 | MUST | Gateway `edge` Accepted·Programmed=True, 주소 172.30.250.10 | Gateway status |
| AC-6.2 | MUST | 모든 HTTPRoute의 parent 조건 Accepted=True, ResolvedRefs=True | HTTPRoute status |
| AC-6.3 | MUST | `https://shop.boutique.test/` 200, 인증서 체인이 사설 CA로 검증(`-k` 없이), SAN 일치 | `probe_curl --cacert ca.crt --resolve shop.boutique.test:443:172.30.250.10` |
| AC-6.4 | MUST | `http://shop.boutique.test/` → 301, `Location: https://…` | probe_curl -I |
| AC-6.5 | MUST | argocd·hubble 호스트 200, 미정의 호스트(`nope.boutique.test`) 404 | probe_curl |
| AC-6.6 | MUST | 헤더 없는 요청 200회 중 canary 비율 10% ± 5%p | x-variant 헤더 또는 배너 집계 |
| AC-6.7 | MUST | `x-canary: always` 20회 → canary 100% | 동일 |
| AC-6.8 | SHOULD | 응답에 `x-served-by: gateway-edge`, 타임아웃 설정 존재 | 헤더·리소스 검사 |
| AC-6.9 | MUST | Hubble에서 Gateway → frontend 플로우 출발 identity가 `reserved:ingress` | `hubble observe --to-pod boutique/frontend… -o json` |
| AC-6.10 | MUST | `boutique` 외 라벨 없는 NS의 HTTPRoute는 Gateway에 붙지 않음(NotAllowedByListeners) | 임시 NS·Route(정리 포함) |
| AC-6.11 | COULD | L7 LB 활성 시 productcatalogservice 레플리카별 요청 비율 max/min ≤ 1.5 (비활성 시 측정값도 기록) | Hubble L7 플로우(`hubble observe --protocol http`), 측정 중 임시 L7 가시성 정책 |

**롤백**: Route/카나리 커밋 revert. Gateway 장애 시 L4 경로(.20)는 독립적으로 유지된다.

### 6.7 Phase 7 — 관측 가능성

**목표**: 메트릭·로그·트레이스·플로우를 수집·상관하고, 대시보드와 알림을 코드로 관리한다.

**작업**
1. 앱 `kube-prometheus-stack`, `loki`, `alloy`, `tempo`, `otel-collector`, `dashboards`(ConfigMap), `rules`(PrometheusRule)
2. cilium·argocd·cert-manager Application에 `values-monitoring.yaml` 레이어 추가(cilium은 diff 검토 후 수동 sync)
3. Online Boutique overlay에 트레이싱 env 패치(§5.9)
4. HTTPRoute `grafana`, Grafana 데이터소스 상관 설정
5. Boutique Golden Signals 대시보드(spanmetrics), 알림 규칙(§5.7)
6. `tests/phase-7.sh` — 장애 주입은 §7.4 절차

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-7.1 | MUST | 관측 스택 Pod Ready, 비-DaemonSet은 infra 노드 | Pod 상태·nodeName |
| AC-7.2 | MUST | Prometheus 활성 타깃 health=up 100%. 대상 잡: kubelet, cadvisor, node-exporter, kube-state-metrics, apiserver, coredns, controller-manager, scheduler, etcd, cilium-agent, cilium-operator, hubble, cilium-envoy, argocd 각 컴포넌트, cert-manager, loki, tempo, otel-collector, alloy | `/api/v1/targets` |
| AC-7.3 | MUST | 다음 쿼리가 비어있지 않음: Hubble 플로우, Cilium 엔드포인트, Gateway(Envoy) 요청, `argocd_app_info`, boutique `kube_pod_info`, spanmetrics 호출 수 | `prom_query` |
| AC-7.4 | MUST | Loki `{namespace="boutique"}` 최근 5분에 서로 다른 `(app, container)` 조합 ≥ 12종 로그 | `loki_query` |
| AC-7.5 | MUST | Tempo에 frontend → checkoutservice → paymentservice span을 포함한 트레이스 존재 | `tempo_search` + 트레이스 조회 |
| AC-7.6 | MUST | `https://grafana.boutique.test` 200, 데이터소스 3종 health OK, Git 정의 대시보드 전부 존재 | Grafana API |
| AC-7.7 | MUST | 사용자 정의 알림 규칙 ≥ 6개 로드, 장애 주입(paymentservice 0 레플리카) 10분 내 `BoutiqueDeploymentUnavailable`·`BoutiqueCheckoutErrorRateHigh` firing → 복구 후 resolved | `ALERTS` 시계열 |
| AC-7.8 | MUST | 보존 기간 설정(3d/48h/24h)과 PVC Bound | 설정·PVC 상태 |
| AC-7.9 | SHOULD | exemplar → Tempo, Tempo → Loki 링크 동작 | 데이터소스 설정 + 수동 확인 기록 |
| AC-7.10 | MUST | Cilium 앱이 monitoring 레이어 적용 후에도 Synced, Pod 재시작은 계획된 롤링 1회 이내 | Application status, restartCount |

> **AC-7.5 주석**: Online Boutique v0.10.7의 Node.js 서비스(paymentservice, currencyservice)는 OTel JS SDK 2.x에 옛 exporter(`exporter-otlp-grpc` 0.26.0)를 섞어 써 `parentSpanId`가 빠진 채 전송한다(trace id는 유지). 판정은 같은 트레이스에 세 서비스의 span이 있고 frontend → checkoutservice(결제 호출 span 포함)가 부모 관계로 이어지는지로 한다. 업스트림 이미지 결함이라 overlay로 고치지 않는다.

**롤백**: 관측 앱 커밋 revert. 관측 스택 장애는 앱 동작에 영향 없음.

### 6.8 Phase 8 — 네트워크 격리

**목표**: 기본 거부 + 최소 허용 + L7 gRPC 정책을 감사 모드로 검증한 뒤 집행하고, 음성 테스트로 차단을 증명한다.

**작업**
1. Cilium values `policyAuditMode: true` 커밋 → 수동 sync
2. `platform/policies/boutique/`: 기본 거부 NP, DNS, 간선별 CNP(§5.6), `platform/policies/{observability,argocd}/`: Ingress 격리, `platform/policies/l4-test/`: 기본 거부 + VIP 진입만 허용(ARCHITECTURE §8.1) → 앱 `policies`
3. 감사: 부하 상태(loadgenerator + probe 체크아웃 루프)로 15분 → `hubble observe --verdict AUDIT` 분석 → 예상 외 플로우는 정책 수정(또는 SPEC 매트릭스 갱신). **감사 모드는 L3/L4만 감사하고 L7 규칙은 그대로 집행한다(Cilium 1.20 문서)** → 감사 단계의 L7 규칙은 전부 허용(`http: [{}]`, 가시성 전용)으로 두고 Hubble L7 플로우로 실제 메서드를 수집한 뒤, 확정한 화이트리스트로 바꾸고 Hubble에 403(L7 거부)이 없음을 확인한다
4. `policyAuditMode: false` 커밋 → 수동 sync
5. PSA restricted enforce(필요 패치 포함), `apps` AppProject에 정책 리소스 금지 추가
6. Golden Signals에 Hubble L7 패널 추가, `HubblePolicyDropsDetected` 규칙 추가
7. `tests/phase-8.sh`: 회귀 + 음성 테스트(ephemeral 컨테이너로 실제 워크로드 identity 사용)

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-8.1 | SHOULD | 감사 모드 마지막 15분 동안 예상 외 AUDIT 판정 0건(예상 목록은 문서화) | `hubble observe --verdict AUDIT --since 15m` |
| AC-8.2 | MUST | `policyAuditMode=false`, boutique 엔드포인트 전부 ingress·egress enforcement 활성 | `cilium-dbg endpoint list`(노드별) |
| AC-8.3 | MUST | 회귀: AC-5.4, 5.5, 5.6, 6.3, 6.6, 7.4, 7.5 재통과 | 해당 함수 재실행 |
| AC-8.4 | MUST | 음성 테스트 전부 차단 + Hubble `DROPPED (Policy denied)` 증거: ① frontend→paymentservice:50051 ② loadgenerator→cartservice:7070 ③ boutique Pod→외부 IP:443 ④ boutique Pod→kube-apiserver ⑤ 다른 NS Pod→frontend:8080 ⑥ boutique Pod→grafana:3000 ⑦ boutique Pod→argocd-server:8080 | debug_curl + hubble |
| AC-8.5 | MUST | L7 음성: checkoutservice identity로 `CartService/AddItem` → HTTP 403, `CartService/GetCart` → HTTP 200(프록시 통과) | `debug_curl … --http2-prior-knowledge -X POST -H 'content-type: application/grpc'` |
| AC-8.6 | MUST | 양성: 트레이싱 서비스→otel-collector:4317 허용, DNS 질의가 Hubble에 이름과 함께 표시 | hubble DNS 플로우 |
| AC-8.7 | SHOULD | Hubble HTTP 메트릭에 boutique gRPC 서비스별 시계열 존재(대시보드 패널 채워짐) | `prom_query` |
| AC-8.8 | SHOULD | boutique PSA enforce=restricted, 위반 0, 전 Pod Running | NS 라벨, 이벤트 |
| AC-8.9 | MUST | `apps` 프로젝트로 boutique에 NetworkPolicy/CNP 동기화 시 거부 | 임시 Application(정리 포함) |
| AC-8.10 | SHOULD | 음성 테스트 실행 후 `HubblePolicyDropsDetected` firing | `ALERTS` |

**롤백**: 정상 트래픽 차단 발생 시 `policies` 앱 커밋 revert(감사 모드 재활성화로 우회하지 않는다). 원인 분석은 runbook `policy-debug.md`.

### 6.9 Phase 9 — 복원력 검증과 최종 인수

**목표**: 처음부터 재구축해도 전 AC가 통과하고, 장애·드리프트·잘못된 배포에서 복구됨을 증명한다. 문서를 완성한다.

**작업**
1. `tests/phase-9.sh`: 노드 장애, Pod 장애, GitOps 롤백, 드리프트 시나리오
2. 클린 재구축: `make down && make up && make verify-all` (시간 측정)
3. `docs/runbooks/`: `access.md`, `policy-debug.md`, `lb-debug.md`, `argocd-sync-failure.md`, `rebuild.md`
4. `README.md` 빠른 시작, ADR 상태 갱신, 자원 사용 보고

**완료 기준**
| AC | 우선 | 기준 | 검증 방법 |
|---|---|---|---|
| AC-9.1 | MUST | 클린 재구축 무개입 1회 통과, 소요 시간 기록(목표 ≤ 30분) | 실행 로그 |
| AC-9.2 | MUST | zone-b 워커 중단 중 `https://shop…`에 2 req/s 3분 → 연속 성공 재개까지 ≤ 90초, 이후 오류 0, frontend 3 레플리카 2분 내 복원 | probe 루프 + 타임라인 |
| AC-9.3 | MUST | boutique 무작위 Pod 3개 삭제 → 2분 내 전 Deployment Available, Argo 드리프트 없음 | wait_for |
| AC-9.4 | MUST | frontend-canary 이미지 태그를 존재하지 않는 값으로 커밋 → Degraded 감지 → `git revert` → 5분 내 Healthy | Application health 타임라인 |
| AC-9.5 | MUST | CNP 하나를 수동 삭제 → 3분 내 selfHeal로 재생성 | wait_for |
| AC-9.6 | MUST | 런북 5종, README, ADR 전부 Accepted/Superseded 상태, PROGRESS 완료 | 파일 검사 |
| AC-9.7 | SHOULD | 네임스페이스별 requests/실사용 보고, NFR-05 충족 | Prometheus 쿼리 결과 표 |
| AC-9.8 | MUST | `v1.0.0` 태그 | `git tag` |

**롤백**: 해당 없음(검증 Phase).

---

## 7. 검증 전략

### 7.1 테스트 하네스 (`tests/lib.sh`)

| 함수 | 역할 |
|---|---|
| `ac_pass/ac_fail/ac_skip <AC-ID> <msg>` | 결과 출력·집계. MUST 실패가 있으면 종료 코드 1 |
| `wait_for <timeout> <cmd…>` | 조건 충족까지 폴링(지수 백오프 없이 2초 간격) |
| `probe_curl <curl args…>` | `docker run --rm --network kind-boutique -v tests/.cache:/certs <curl 이미지> …` — 클러스터 외부 관점 |
| `debug_curl <ns> <pod> <container> <curl args…>` | ephemeral 컨테이너로 해당 Pod의 네트워크 네임스페이스(=identity)에서 요청 |
| `test_pod <ns> <labels> <cmd>` | 임시 Pod 실행 후 삭제(PSA 준수 securityContext 포함) |
| `prom_query / loki_query / tempo_search` | 백그라운드 port-forward + trap 정리 |
| `hubble_expect <filter> <verdict>` | 최근 N초 플로우에서 기대 판정 존재 여부 |
| `suspend_app / resume_app <app>` | §7.4 장애 주입용 일시 정지/복원 |

모든 임시 리소스는 `ac-test=true` 라벨을 붙이고 `trap`에서 정리한다.

### 7.2 외부 관점 검증 (probe 컨테이너)

```bash
probe_curl -sS --cacert /certs/ca.crt \
  --resolve shop.boutique.test:443:172.30.250.10 \
  -o /dev/null -w '%{http_code}' https://shop.boutique.test/
```

호스트 OS와 무관하게 동일하게 동작하며, VIP에 대한 ARP·L2 경로까지 포함해 검증한다.

### 7.3 identity 보존 검증 (ephemeral 컨테이너)

```bash
kubectl -n boutique debug pod/<checkoutservice-pod> \
  --image=<curl 이미지> --target=server --profile=restricted \
  --container=ac-8-5-$(date +%s) -- \
  curl -s -o /dev/null -w '%{http_code}' --http2-prior-knowledge \
  -X POST -H 'content-type: application/grpc' \
  http://cartservice:7070/hipstershop.CartService/AddItem
# 결과는 kubectl logs <pod> -c <container>로 수집
```

- 셸 없는 이미지에서도 실제 워크로드의 Cilium identity로 요청을 보낸다. 라벨을 흉내 낸 테스트 Pod를 쓰지 않는다(Service 셀렉터에 잡혀 실제 트래픽을 받을 위험).
- 프록시가 거부하면 HTTP 403, 통과하면 백엔드가 gRPC 오류 상태를 담은 HTTP 200을 반환한다 → HTTP 상태로 L7 판정이 가능하다.
- ephemeral 컨테이너는 Pod에서 제거되지 않는다. 테스트 후 Pod를 재생성할 필요는 없지만 반복 실행 시 개수가 늘어나므로 컨테이너 이름에 타임스탬프를 붙인다.

### 7.4 장애 주입과 selfHeal의 공존

selfHeal은 수동 장애 주입을 즉시 되돌린다. app-of-apps에서는 자식 Application의 syncPolicy를 직접 바꿔도 root가 되돌린다. 따라서:

1. 우선: 대상 Application에 `argocd.argoproj.io/skip-reconcile: "true"` 어노테이션을 추가해 조정을 멈춘 뒤 주입(고정 버전에서 지원 확인).
2. 미지원 시: Git 커밋으로 장애를 주입하고 `git revert`로 복구(AC-9.4와 같은 방식).
3. 어떤 방식이든 `trap`으로 복원을 보장하고, 종료 시 Application이 Synced/Healthy로 돌아왔는지 확인한다.

### 7.5 결과 기록

- 실행 로그: `tests/results/phase-<n>-<UTC timestamp>.log` (gitignored)
- PROGRESS.md: Phase별 MUST/SHOULD 통과 수, 실패·SKIP 사유, 편차, 측정값(장애 전환 시간, 카나리 비율, 재구축 시간)

### 7.6 회귀

`make verify-all`은 Phase 1부터 순서대로 실행한다. 파괴적 테스트(노드 중단, 장애 주입)는 `DESTRUCTIVE=1`일 때만 실행하고, Phase 완료 판정과 AC-9.1에서는 켠다.

---

## 8. 추적성 매트릭스 (FR → AC)

| FR | AC |
|---|---|
| FR-CL-01 | AC-1.1 |
| FR-CL-02 | AC-1.2, AC-5.2, AC-5.3 |
| FR-CL-03 | AC-1.3 |
| FR-CL-04 | AC-1.4 |
| FR-CL-05 | AC-1.5, AC-7.2 |
| FR-NET-01 | AC-2.1, AC-2.3 |
| FR-NET-02 | AC-2.5 |
| FR-NET-03 | AC-2.4 |
| FR-NET-04 | AC-2.3 |
| FR-L4-01 | AC-4.1 |
| FR-L4-02 | AC-4.3 |
| FR-L4-03 | AC-4.2, AC-5.4, AC-6.1 |
| FR-L4-04 | AC-4.5, AC-9.2 |
| FR-L4-05 | AC-4.4 |
| FR-L7-01 | AC-6.1 |
| FR-L7-02 | AC-6.3, AC-6.5, AC-7.6 |
| FR-L7-03 | AC-6.3, AC-6.4 |
| FR-L7-04 | AC-6.6, AC-6.7 |
| FR-L7-05 | AC-6.8 |
| FR-L7-06 | AC-6.2, AC-6.5, AC-6.10 |
| FR-L7-07 | AC-6.11 |
| FR-ISO-01 | AC-8.2, AC-8.4 |
| FR-ISO-02 | AC-8.3, AC-8.4 |
| FR-ISO-03 | AC-8.4③, AC-8.6 |
| FR-ISO-04 | AC-8.5 |
| FR-ISO-05 | AC-8.7 |
| FR-ISO-06 | AC-8.4⑥⑦ |
| FR-ISO-07 | AC-8.1 |
| FR-ISO-08 | AC-8.4③④ |
| FR-ISO-09 | AC-8.8 |
| FR-ISO-10 | AC-8.9 |
| FR-OBS-01 | AC-7.2, AC-7.3 |
| FR-OBS-02 | AC-7.4 |
| FR-OBS-03 | AC-7.5 |
| FR-OBS-04 | AC-7.6 |
| FR-OBS-05 | AC-7.3, AC-7.6, AC-8.7 |
| FR-OBS-06 | AC-7.7, AC-8.10 |
| FR-OBS-07 | AC-7.9 |
| FR-OBS-08 | AC-2.5, AC-8.4, AC-8.6 |
| FR-GIT-01 | AC-3.2, AC-9.1 |
| FR-GIT-02 | AC-3.9 |
| FR-GIT-03 | AC-3.4, AC-3.5, AC-5.8, AC-9.5 |
| FR-GIT-04 | AC-3.6, AC-8.9 |
| FR-GIT-05 | AC-3.8 |
| FR-GIT-06 | AC-9.4 |
| FR-GIT-07 | AC-9.8 (+ Phase별 태그) |
| FR-GIT-08 | AC-3.7 |
| FR-APP-01 | AC-5.1, AC-5.4, AC-5.5, AC-5.6 |
| FR-APP-02 | AC-0.3, AC-5.1 |
| FR-APP-03 | AC-5.2, AC-5.7, AC-9.2 |
| FR-APP-04 | AC-5.7 |
| FR-APP-05 | AC-7.5 |
| FR-APP-06 | AC-6.6 |

COULD 항목 중 FR-NET-05, FR-L7-08, FR-ISO-11은 채택 시 AC를 추가한다.

---

## 9. 리스크와 대응

| ID | 리스크 | 영향 | 대응 |
|---|---|---|---|
| R1 | macOS에서 VIP가 호스트로 라우팅되지 않음 | 수동 확인 불편 | 검증은 probe 컨테이너, 브라우저는 port-forward. Linux 권장 |
| R2 | 자원 부족(OOMKilled, Pending) | 단계 지연 | preflight 하한, "축소 프로파일"(productcatalog 1, Prometheus 보존 1d) 옵션, 사용 시 기록 |
| R3 | Kubernetes/Cilium/Gateway API 버전 비호환 | 설치 실패, 기능 누락 | Cilium 호환 매트릭스 기준 N-1 Kubernetes, CRD는 Cilium 요구 버전 그대로 |
| R4 | Argo CD의 Cilium 인수 중 재시작·네트워크 중단 | 클러스터 단절 | 수동 sync, 사전 diff, Pod UID 스냅샷 비교, `phase-2-done` 태그 |
| R5 | 비결정적 렌더링(인증서)로 영구 OutOfSync | 노이즈, 잘못된 sync | Hubble TLS cronJob, 최소 범위 ignoreDifferences |
| R6 | L2 장애 전환 지연(ARP 캐시) | 수십 초 단절 | Lease 튜닝, 기준 30초, 측정값 기록 |
| R7 | L7 정책이 헬스체크·미파악 호출 차단 | 서비스 장애 | 감사 모드 선행, 헬스 경로 허용, Hubble 기반 확정 |
| R8 | 업스트림 버전별 env/템플릿 차이(트레이싱 env, 완료 페이지 문구) | 테스트 오판 | 고정 버전 소스에서 확인 후 상수화, 출처 주석 |
| R9 | Docker 서브넷 충돌(VPN·사내망) | 라우팅 장애 | preflight 탐지, `.env`로 변경 가능 |
| R10 | 이미지 pull 실패·속도 제한(Docker Hub) | 배포 지연 | 사전 pull + `kind load docker-image`, 재시도 |
| R11 | GitHub 의존(오프라인, 토큰 만료) | GitOps 정지 | 토큰 만료일 기록. 오프라인 요구 시 클러스터 내 Gitea로 ADR 개정 |
| R12 | 차트 폐기·저장소 이동 | 설치 불가 | Phase 0에서 유지보수 상태 확인, 대체 시 ADR |
| R13 | kubeadm v1beta4 패치 형식 오류 | 클러스터 생성 실패/메트릭 미노출 | §5.2 형식 준수, AC-1.5 |
| R14 | selfHeal과 장애 주입 충돌 | 테스트 불안정 | §7.4 절차 |
| R15 | 라벨 기반 identity 위장 | 정책 우회 | AppProject·RBAC로 Pod 생성 주체 통제(ARCHITECTURE §8.3), 운영 적용 시 Admission 정책 추가 |

## 10. 미결 사항 (기본값으로 진행, 사용자 확인 필요)

| ID | 질문 | 기본값 |
|---|---|---|
| Q1 | GitOps 저장소: GitHub 공개/비공개? | 비공개 + read-only fine-grained token |
| Q2 | 호스트 OS·Docker 할당 자원 | Linux, 12 vCPU / 32 GiB |
| Q3 | 172.30.0.0/16 사용 가능 여부 | 사용 가능으로 가정(preflight로 확인) |
| Q4 | COULD 항목 포함 범위(WireGuard, East-West L7 LB, GRPCRoute, FQDN egress) | East-West L7 LB만 포함 |
| Q5 | Argo CD 3.6 GA 시 채택 여부 | 3.5.x 유지 |
| Q6 | 알림 외부 통보(Slack 등) | 없음(Prometheus ALERTS로 판정) |

## 11. 변경 이력

| 버전 | 날짜 | 내용 |
|---|---|---|
| 1.0-draft | 2026-11-14 | 최초 작성 |
| 1.0-draft+1 | 2026-11-25 | §2.3·§5.1: Loki/Tempo 차트 저장소를 grafana-community로 변경(사용자 승인, ADR-0009) |
| 1.0-draft+2 | 2026-11-26 | §5.1·§6.2(AC-2.6): Gateway API CRD v1.6.1 → v1.6.3(Cilium 1.20.5 문서 기준, Phase 0 편차 반영). §5.3: 차트 1.20.5에 없는 `externalIPs.enabled` 삭제(KPR=true면 externalIPs 항상 활성) — 사용자 승인 |
| 1.0-draft+3 | 2026-11-26 | §5.4: L2 Announcements와 `externalTrafficPolicy: Local`의 공식 비호환 주의 문구 추가(`echo-local`은 실증용, 운영 Service는 Cluster) — 사용자 승인. ADR-0003 결과에 같은 내용 반영 |
| 1.0-draft+4 | 2026-11-26 | §5.5·§6.6(AC-6.11): 측정을 Hubble 메트릭 → Hubble L7 플로우(측정 중 임시 L7 가시성 정책)로 변경. `httpV2` 메트릭에 `destination_pod`가 없고 L7 데이터는 가시성 정책이 필요 — 사용자 승인 |
| 1.0-draft+5 | 2026-11-26 | §5.7: kubelet·controller-manager·scheduler 스크레이프 TLS 예외(ADR-0011). AC-7.4: "컨테이너 ≥ 12종" → 서로 다른 `(app, container)` 조합 ≥ 12(업스트림 컨테이너 이름은 3종뿐) — 사용자 승인 |
| 1.0-draft+6 | 2026-11-26 | §5.3: 부트스트랩이 Prometheus Operator CRD를 먼저 적용하고 Argo CD와 같은 Cilium values 레이어로 설치(재구축 시 인수 diff를 추적 메타데이터로 유지, ADR-0012) — 사용자 승인 |
| 1.0-draft+7 | 2026-11-26 | §6.7: AC-7.5 판정 주석(업스트림 Node 서비스의 parentSpanId 누락) — 사용자 승인 |
| 1.0-draft+8 | 2026-11-26 | §6.8: L7은 감사 모드에서도 집행되므로 2단계 L7(가시성 → 화이트리스트) 절차 명시, l4-test 기본 거부 추가 — 사용자 승인 |
