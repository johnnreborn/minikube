# 런북: Argo CD 동기화 실패·지연

증상: `make wait-sync` 시간 초과, 앱이 `OutOfSync`/`Degraded`/`Unknown`.

## 1. 상태를 본다

```bash
make wait-sync                      # 어떤 앱이 어떤 리비전에서 멈췄는지 표로 나온다
kubectl -n argocd get applications
kubectl -n argocd get application <app> -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
kubectl -n argocd get application <app> -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
```

`argocd` CLI는 `--core` 모드로 쓴다. kube context의 namespace를 `argocd`로 바꾼 **사본** kubeconfig를 만들면
사용자 설정을 건드리지 않는다(부트스트랩·`scripts/cilium-sync.sh`와 같은 방식):

```bash
KCFG=$(mktemp); chmod 600 "$KCFG"
kubectl config view --minify --flatten --context kind-boutique >"$KCFG"
kubectl --kubeconfig "$KCFG" config set-context --current --namespace argocd >/dev/null
KUBECONFIG="$KCFG" argocd --core app get <app> --refresh
KUBECONFIG="$KCFG" argocd --core app diff <app> --server-side-diff
# 다 쓰면 사본을 지운다: rm -- "$KCFG"
```

## 2. 유형별 대응

| 상태 | 원인 후보 | 대응 |
|---|---|---|
| 새 커밋이 반영 안 됨 | Git 폴링 주기(최대 약 3분), push 누락 | `git log origin/main -1` 확인, 기다리거나 `argocd.argoproj.io/refresh=normal` 어노테이션 |
| `ComparisonError` | repo-server가 차트를 못 가져옴(외부 네트워크), 렌더 오류 | 메시지 확인. 네트워크면 회복을 기다린 뒤 hard refresh. 렌더 오류면 Git을 고친다 |
| `Degraded` | 이미지 pull 실패, Deployment 진행 기한 초과 | `kubectl -n <ns> describe pod`. 잘못된 배포면 `git revert` |
| `OutOfSync`가 계속 | 컨트롤러가 값을 바꿈, 비결정적 렌더(인증서) | diff로 필드를 확인, 필요하면 최소 범위 `ignoreDifferences` |
| 수동 변경이 되돌아감 | selfHeal(정상 동작) | Git을 바꾼다. 장애 주입은 SPEC §7.4 |
| sync wave가 멈춤 | 앞 웨이브 앱이 Healthy가 아님 | 막힌 앱부터 해결 |
| 첫 설치에서 `pki`/`gateway` 실패 | cert-manager webhook 준비 전 | 앱에 sync retry가 있다. 재시도가 끝났으면 앱을 다시 sync |

## 3. Cilium은 특별하다 (CNI)

- `cilium` 앱은 **수동 sync**다. 반드시 `scripts/cilium-sync.sh`(diff만) → 검토 → `scripts/cilium-sync.sh --yes`.
- ⚠️ repo-server가 차트를 렌더하지 못하면(`ComparisonError`) Argo CD는 **모든 Cilium 리소스를 prune 대상**으로
  표시한다. 이때 prune sync를 하면 CNI가 삭제된다. `cilium-sync.sh`는 비교 오류나 prune 표시가 있으면 거부한다.
- Cilium을 `helm`으로 다시 설치·업그레이드하지 않는다.

## 4. 롤백

- `git revert <커밋>` → push → 자동 동기화. Argo CD UI의 Rollback 버튼은 자동 sync와 충돌하므로 쓰지 않는다.
- 특정 시점: `phase-<n>-done` 태그를 참고해 revert할 커밋 범위를 정한다(히스토리 재작성·force push 금지).

## 5. 인프라 노드 중단

Argo CD·관측 스택은 infra 노드 1대에 있다. 이 노드가 죽으면 앱 트래픽은 계속되지만 GitOps와 알림이 멈춘다
(알려진 단일 장애점). 노드를 다시 켜면(`docker start boutique-worker`) 복구된다.
