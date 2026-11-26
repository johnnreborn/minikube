# 런북: 클러스터와 UI 접속

kube context는 `kind-boutique`다. 명령은 저장소 루트에서 실행한다.

## 1. 주소

| 용도 | 주소 | 비고 |
|---|---|---|
| 쇼핑몰(L7, TLS) | `https://shop.boutique.test/` | Gateway `172.30.250.10` |
| Argo CD | `https://argocd.boutique.test/` | |
| Grafana | `https://grafana.boutique.test/` | |
| Hubble UI | `https://hubble.boutique.test/` | **인증 없음** — 로컬 실습 한정(ARCHITECTURE §13) |
| 쇼핑몰(L4, 평문) | `http://172.30.250.20/` | `frontend-external` VIP |

`make hosts`가 `/etc/hosts`에 넣을 줄을 출력한다(파일은 직접 고치지 않는다). 호스트의 `/etc/hosts`에 추가하면
Linux와 WSL 안의 셸에서 위 이름이 열린다.

## 2. 사설 CA 신뢰

인증서는 클러스터 안에서 만든 사설 CA가 발급한다. 공개 인증서만 꺼낸다(개인키는 꺼내지 않는다):

```bash
kubectl -n cert-manager get secret boutique-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > boutique-ca.crt
curl --cacert boutique-ca.crt https://shop.boutique.test/ -o /dev/null -w '%{http_code}\n'
```

- 클러스터를 다시 만들면 CA가 바뀐다. 브라우저에 넣었던 옛 CA는 지우고 새로 넣는다.
- `curl -k`는 쓰지 않는다. `boutique-ca.crt`는 커밋하지 않는다.

## 3. 로그인

| UI | 계정 |
|---|---|
| Argo CD | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` (첫 로그인 후 교체 권장) |
| Grafana | `admin` / `.env`의 `GRAFANA_ADMIN_PASSWORD` |

## 4. VIP가 닿지 않는 환경 (macOS, WSL의 Windows 브라우저)

LB VIP는 Docker 네트워크 안에 있다. Linux와 WSL 셸에서는 닿지만 macOS(Docker Desktop)나 WSL 밖의 Windows
브라우저에서는 닿지 않을 수 있다. 이때는 port-forward로 앱에 직접 접속한다(Gateway·TLS를 거치지 않는다).
Cilium Gateway Service는 selector가 없어 port-forward할 수 없다.

```bash
kubectl -n boutique port-forward svc/frontend 8080:80                       # http://localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8081:80                    # http://localhost:8081
kubectl -n observability port-forward svc/grafana 3000:80                   # http://localhost:3000
kubectl -n kube-system port-forward svc/hubble-ui 12000:80                  # http://localhost:12000
```

## 5. 자주 쓰는 확인

```bash
make wait-sync                       # 모든 Argo CD 앱 Synced/Healthy
make verify-phase N=<1..9>           # Phase별 AC
kubectl get pods -A | grep -v Running
```
