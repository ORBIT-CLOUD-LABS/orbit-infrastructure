# lgtm 메트릭 스택 (Prometheus, Alertmanager, Grafana)

구현: [#43](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/43). k3s 노드와 클러스터 지표는 [#44](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/44)에서 붙인다.
`lgtm` VM은 이름과 달리 Prometheus, Alertmanager, Grafana만 운영한다. 로그는 `efk`를 쓴다.
이 문서에는 이름과 절차만 기록한다. 비밀번호 값은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다. 값은 Vault에만 있다.

## 구성

| 항목 | 값 |
| --- | --- |
| 위치 | `lgtm` VM (`10.0.0.206`). 측정 대상의 자원을 쓰지 않도록 k3s 밖에 둠 |
| Prometheus | Ubuntu 패키지 `prometheus`. 9090. 설정 `/etc/prometheus/prometheus.yml`, 실행 인자 `/etc/default/prometheus` |
| Alertmanager | Ubuntu 패키지 `prometheus-alertmanager`. 9093. Prometheus와 연결만 함. 알림 채널과 룰은 아직 없음 |
| Grafana | Grafana apt 저장소 `grafana` (버전은 `roles/lgtm/defaults/main.yml`의 `lgtm_grafana_version`). 3000 |
| node-exporter | Ubuntu 패키지 `prometheus-node-exporter`. astra, efk, lgtm, wazuh의 내부망 주소 9100. astra는 `prometheus-node-exporter-collectors`도 둠 (아래 수집 대상) |
| 버전 고정 | 네 패키지 모두 `apt-mark hold`. Ubuntu 패키지는 설치된 버전에서 멈춤 |
| 보관 | 60일 또는 40GB 중 먼저 닿는 쪽 (`lgtm_metrics_retention`, `lgtm_metrics_retention_size`). 로그(7일)와 따로 둠 |
| 수집 간격 | 30초 |

## 접속

- Grafana: `https://grafana.orbit-labs.space` (Tailscale을 켠 팀원. astra 내부 리버스 프록시 경유, [docs/reverse-proxy.md](reverse-proxy.md))
- 로그인: `admin`. 비밀번호는 Vault `secret/orbit/infra/lgtm`의 `grafana_admin_password`. 로그인 없이는 볼 수 없다. 팀원별 계정은 아직 없다.
- Prometheus(9090)와 Alertmanager(9093) 화면은 서비스 이름으로 열지 않는다. 관리자는 Tailscale에서 `http://10.0.0.206:9090`으로 볼 수 있다.

## 수집 대상

| job | 대상 | 내용 |
| --- | --- | --- |
| `node` | astra, efk, lgtm, wazuh의 `:9100` | 호스트 CPU, 메모리, 디스크, 네트워크. astra는 추가로 `smartmon_*`(SMART), `nvme_*`(NVMe 수명·오류), `apt_*`(대기 업데이트, 재부팅 필요) |
| `prometheus`, `alertmanager`, `grafana` | lgtm 자신 | 스택 자체 상태 |

astra의 추가 지표는 `prometheus-node-exporter-collectors` 패키지의 타이머(`prometheus-node-exporter-{apt,nvme,smartmon}.timer`, 15분마다)가 `/var/lib/prometheus/node-exporter/*.prom`에 쓰고, node-exporter가 읽어 함께 내놓는다. 이 패키지가 함께 설치하는 `smartmontools`는 호스트 Fluent Bit이 로그를 수집하므로 지우지 않는다(`apt autoremove` 주의).

대상을 추가할 때는 `roles/lgtm/templates/prometheus.yml.j2`에 job을 더한다. node-exporter를 둘 호스트는 `lgtm_node_exporter_hosts`로 정한다.

## 데이터 소스와 대시보드

화면에서 고치지 않고 `roles/lgtm`에서 고친다 (provisioning).

| 이름 | 종류 | 내용 |
| --- | --- | --- |
| Prometheus | prometheus | 기본 데이터 소스 |
| efk-host | elasticsearch | 호스트 로그 `orbit-host-*`. 조회 계정 `grafana_viewer`, efk CA로 검증 ([docs/efk.md](efk.md#grafana-lgtm에-필요한-값)) |
| efk-k8s | elasticsearch | k3s Pod 로그 `orbit-k8s-*` |

대시보드는 Node Exporter Full(grafana.com 1860) 하나다. `lgtm_dashboards`에 받을 주소와 checksum을 적는다.

## 방화벽

체인 `ORBIT-METRICS`가 아래 포트를 허용한 출발지에서만 받고 나머지는 버린다. 다른 포트는 건드리지 않는다. 연결은 INPUT 맨 뒤에 붙인다(astra의 `ORBIT-VAULT`, efk의 `ORBIT-EFK`는 맨 앞).

| 호스트 | 포트 | 허용 |
| --- | --- | --- |
| lgtm | 3000, 9090, 9093 | astra, 자기 자신 |
| astra, efk, lgtm, wazuh | 9100 | lgtm, 자기 자신 |

- 팀원은 Tailscale 정책에서 443이 astra 하나만 열려 있어 이 포트들에 직접 닿지 않는다.
- astra는 Tailscale이 넣는 `ts-input` 규칙이 이 체인보다 앞에 있어, Tailscale 관리자 기기에서 오는 접속은 astra의 9100에 닿는다.

## 플레이북

astra 개인 계정으로 실행한다 ([개인 계정 문서](personal-accounts.md#ansible-실행)).

```bash
cd ~/orbit-infrastructure/ansible
../scripts/orbit-ssh-cert.sh                      # SSH 인증서와 Vault 토큰 (8시간)
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)
ansible-playbook playbooks/lgtm.yml -K --check --diff   # 미리보기
ansible-playbook playbooks/lgtm.yml -K --diff           # 적용. 다시 실행하면 changed=0
unset VAULT_TOKEN
```

- 먼저 `efk.yml`과 `fluent-bit.yml`이 적용돼 있어야 한다 (조회 계정, lgtm의 `/etc/fluent-bit/efk-ca.crt`).
- node-exporter와 방화벽은 astra, efk, lgtm, wazuh 4대에 적용된다.
- 마지막에 수집 대상이 모두 up인지, 관리자 로그인, 데이터 소스 연결, 방화벽을 확인한다.

## 관리자 비밀번호 바꾸기

Grafana는 설정의 관리자 비밀번호를 처음 시작할 때 한 번만 읽는다. Vault 값을 바꾼 뒤에는 lgtm에서 직접 맞춘다. 값이 화면과 history에 남지 않게 한다.

```bash
sudo grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password "$(sudo cat /etc/grafana/orbit/admin-password)"
```

## 확인

```bash
systemctl is-active prometheus prometheus-alertmanager grafana-server prometheus-node-exporter   # lgtm
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' | grep -o '"health":"[a-z]*"' | sort | uniq -c   # 전부 up이어야 함
sudo iptables -S ORBIT-METRICS
df -h /var/lib/prometheus          # 지표 디스크 사용량
```

## 기록

| 날짜 | 작업 | 결과 |
| --- | --- | --- |
| 2026-11-?? | 적용 | (미리보기, 적용, 재실행 `changed=0`, target 수, 재부팅 뒤 확인 결과를 적음) |
