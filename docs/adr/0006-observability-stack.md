# ADR-0006: 관측 스택은 kube-prometheus-stack + Loki/Alloy + Tempo/OTel Collector + Hubble

- 상태: Accepted (사용자 승인 2026-11-27, Phase 9 점검)
- 날짜: 2026-11-14

## 맥락
메트릭·로그·트레이스·네트워크 플로우를 수집하고 상관해야 한다. Online Boutique 서비스 대부분은 Prometheus 메트릭을 노출하지 않지만 일부 서비스는 OTLP 트레이스를 지원한다.

## 결정
- 메트릭: kube-prometheus-stack(CRD는 별도 차트), ServiceMonitor 기반
- 로그: Loki SingleBinary + Grafana Alloy DaemonSet (Promtail은 EOL이라 제외)
- 트레이스: OTel Collector(게이트웨이) → Tempo monolithic. spanmetrics connector로 트레이스 기반 RED 메트릭 생성
- 네트워크: Hubble 메트릭(드롭, 정책, DNS, HTTP) + relay/UI
- 대시보드·알림은 Git(ConfigMap/PrometheusRule)

## 대안
- 단일 에이전트(Alloy)로 OTLP·로그 모두 처리: 구성요소는 줄지만 벤더 중립 OTel Collector 실습 가치를 우선
- Elastic/OpenSearch 로그: 자원 비용 큼

## 결과
- (+) 앱 코드 수정 없이 골든 시그널 확보(트레이스 + Hubble L7 두 경로)
- (−) 인프라 노드 1대에 집중 → 단일 장애점(실습 범위에서 수용)
- (−) Hubble L7 메트릭은 L7 정책 적용 후(Phase 8)에야 완전해짐

## 개정 (2026-11-27, 구현 반영)
- Loki·Tempo 차트는 grafana-community 저장소(ADR-0009), kubelet·controller-manager·scheduler 스크레이프는 TLS 검증 예외(ADR-0011).
