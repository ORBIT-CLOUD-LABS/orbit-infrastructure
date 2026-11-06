# efk 로그 저장소 (Elasticsearch, Kibana, 호스트 Fluent Bit)

구현: [#21](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/21). k3s 쪽 수집은 [orbit-gitops#46](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/46).
이 문서에는 이름과 절차만 기록한다. 비밀번호, 토큰, Kibana 암호화 키 값은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다. 값은 Vault에만 있다.

## 구성

| 항목 | 값 |
| --- | --- |
| 위치 | `efk` VM `10.0.0.205` (astra 안, 4 vCPU, 20GB, 디스크 100GB). 클러스터 장애를 조사할 수 있도록 k3s 밖에 둠 |
| 버전 | Elasticsearch·Kibana 9.5.6, 호스트 Fluent Bit 5.1.5. 모두 apt hold로 고정 |
| Elasticsearch | 단일 노드 `orbit-efk`, 힙 4g. HTTPS `9200`은 `127.0.0.1`과 `10.0.0.205`, 노드 간 `9300`은 `127.0.0.1`만 |
| Kibana | `https://10.0.0.205:5601`. 공개 경로 `kibana.orbit-labs.space`(Cloudflare 프록시 → astra nginx)는 이후 진행. Elasticsearch에는 `127.0.0.1`로 `kibana_system` 계정으로 접속 |
| 데이터·로그 | `/var/lib/elasticsearch`, `/var/log/elasticsearch` (서버 로그 `orbit-efk_server.json`), `/var/log/kibana/kibana.log` |
| TLS | 자체 CA `ORBIT EFK CA` (`/etc/elasticsearch/tls/efk-ca.crt`, 10년). Elasticsearch·Kibana 서버 인증서는 825일, SAN `efk`, `localhost`, `127.0.0.1`, `10.0.0.205`. SAN이 바뀌면 다시 발급 |
| 비밀값 | Vault KV. 인프라 구역 `secret/orbit/infra/efk`, k3s 구역 `secret/orbit/k3s/fluent-bit` ([Vault 문서](vault.md#비밀값-경로와-권한)) |
| 송신기 | k3s 노드 4대(DaemonSet, orbit-gitops#46), astra·VM 3대(호스트 Fluent Bit, 이 저장소) |

## 플레이북

astra 개인 계정으로 실행한다([개인 계정 문서](personal-accounts.md#ansible-실행)). 비밀번호를 Vault에서 읽으므로 토큰이 필요하다.

```bash
cd ~/orbit-infrastructure/ansible
../scripts/orbit-ssh-cert.sh                       # SSH 인증서와 Vault 토큰 (8시간)
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)

ansible-playbook playbooks/efk.yml -K --check --diff         # 미리보기
ansible-playbook playbooks/efk.yml -K --diff                 # 적용. 다시 실행하면 changed=0
ansible-playbook playbooks/fluent-bit.yml -K --check --diff  # 호스트 Fluent Bit (efk 다음)
ansible-playbook playbooks/fluent-bit.yml -K --diff
unset VAULT_TOKEN
```

| 플레이북 | 대상 | 하는 일 |
| --- | --- | --- |
| `efk.yml` | efk, astra | efk 방화벽, Vault 비밀값, Elasticsearch·Kibana 설치·TLS·설정, 기본 계정, 수집·조회 역할과 계정, ILM·인덱스 템플릿, Kibana 데이터 뷰. astra의 tailnet → efk 통과 제한. 마지막에 상태·권한·템플릿·방화벽 확인 |
| `fluent-bit.yml` | astra, efk, lgtm, wazuh | 호스트 Fluent Bit 설치·설정. 마지막에 상태와 호스트별 수신 확인 |

- 처음 실행할 때 Vault에 없는 비밀번호·키는 무작위 값(영문·숫자 40자)으로 만들어 Vault에 먼저 저장한 뒤 쓴다. 있는 값은 바꾸지 않는다. 미리보기에서는 저장하지 않으므로 계정 단계를 건너뛴다.
- 설정·버전·인증서가 바뀌면 Elasticsearch와 Kibana가 재시작된다. 그동안 로그는 송신기 버퍼에 쌓였다가 다시 보내진다.
- 역할·ILM·템플릿·데이터 뷰는 서버의 실제 값과 비교해 다를 때만 다시 쓴다. Kibana나 API로 직접 바꾼 값은 다음 실행에서 되돌아간다. 바꾸려면 `roles/efk/defaults/main.yml`을 고친다.

## 계정

모든 비밀번호는 Vault에 있다. 일상 조회는 `elastic` 관리자 대신 조회 계정을 쓴다. 팀원별 계정은 아직 없다.

| 계정 | 역할 | 권한 | Vault (경로 / 키) |
| --- | --- | --- | --- |
| `elastic` | 기본 관리자 | 전체. Ansible과 장애 대응에만 | `orbit/infra/efk` / `elastic_password` |
| `kibana_system` | Kibana 내부 | Kibana가 Elasticsearch에 접속 | `orbit/infra/efk` / `kibana_system_password` |
| `fluentbit_k8s` | `orbit_k8s_writer` | `orbit-k8s-*`, `orbit-host-*` 문서 생성만 (Pod 로그, 노드 journald) | `orbit/k3s/fluent-bit` / `password` |
| `fluentbit_host` | `orbit_host_writer` | `orbit-host-*` 문서 생성만 | `orbit/infra/efk` / `fluentbit_host_password` |
| `kibana_viewer` | `orbit_log_viewer` | 두 인덱스 읽기, Kibana default 공간 읽기 | `orbit/infra/efk` / `kibana_viewer_password` |
| `grafana_viewer` | `orbit_grafana_viewer` | 두 인덱스 읽기, 클러스터 상태(`monitor`) | `orbit/infra/efk` / `grafana_viewer_password` |

- 쓰기 계정은 문서 생성(`create_doc`)만 할 수 있다. 덮어쓰기·삭제·템플릿·ILM 관리 권한은 없다. 템플릿과 ILM은 Ansible이 `elastic`으로 관리한다.
- Kibana 암호화 키 3개(`kibana_security_key`, `kibana_saved_objects_key`, `kibana_reporting_key`)도 `orbit/infra/efk`에 있다. 바꾸면 Kibana 로그인 세션과 암호화된 저장 객체를 다시 만들어야 하므로 바꾸지 않는다.
- 비밀번호를 바꾸려면 Vault 값을 바꾼 뒤 `efk.yml`을 실행한다. 로그인이 안 되는 계정은 Vault 값으로 다시 맞춘다. `fluentbit_host`를 바꾸면 `fluent-bit.yml`도 실행한다. `fluentbit_k8s`는 ESO가 k3s Secret을 갱신한 뒤 DaemonSet을 재시작해야 한다. `elastic`은 자동으로 맞추지 않는다(플레이북이 멈추고 방법을 알려 줌).

### Vault 준비

이 문서의 Vault 조회 예제는 모두 astra 개인 계정에서, 아래를 먼저 실행한 셸에서 한다. 인증서 스크립트는 토큰을 `~/.orbit/vault-token` 파일에만 저장하므로 셸마다 `VAULT_TOKEN`으로 내보내야 Vault CLI가 쓴다. 플레이북 예제 끝의 `unset VAULT_TOKEN` 뒤나 새 셸에서도 다시 한다.

```bash
~/orbit-infrastructure/scripts/orbit-ssh-cert.sh          # 토큰이 10분 넘게 남았으면 그대로 씀. 만료됐으면 GitHub PAT를 물음
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)
export VAULT_ADDR=https://10.0.0.201:8200 VAULT_CACERT=/opt/vault/tls/vault-ca.crt
vault token lookup -format=json | jq '.data.ttl'          # 남은 초. 숫자가 나오면 준비됨
```

끝나면 `unset VAULT_TOKEN`.

### 값 확인

[Vault 준비](#vault-준비) 후. 화면에 남기지 않도록 변수로만 받는다:

```bash
P=$(vault kv get -mount=secret -field=kibana_viewer_password orbit/infra/efk) && [ -n "$P" ] && echo ok
# 이 셸에서 $P를 사용한 뒤
unset P
```

## Kibana 접속

공개 경로 `kibana.orbit-labs.space`(orbit `docs/infrastructure.md`: Cloudflare 프록시 → astra nginx → efk 5601)는 astra nginx(게이트웨이)를 구성한 뒤 진행한다. 그때 Kibana `server.publicBaseUrl`(efk role `kibana.yml.j2`)도 공개 주소로 바꾼다. `efk_kibana_url`은 Ansible이 Kibana API에 접속할 때도 쓰므로 그대로 둔다. 로그에 SSH 로그인·sudo 기록이 있으므로 공개할 때 Cloudflare Access 같은 앞단 인증을 검토한다. 그전까지는 Tailscale로 접속한다.

```
팀원 Mac ─Tailscale─▶ astra(서브넷 라우터, SNAT) ─▶ efk 10.0.0.205:5601
```

1. Tailscale을 켠다.
2. 브라우저에서 `https://10.0.0.205:5601`에 접속한다.
3. `kibana_viewer`와 Vault의 `kibana_viewer_password`로 로그인한다.
4. Discover에서 데이터 뷰 `orbit-k8s (k3s Pod)` 또는 `orbit-host (호스트 journald·파일)`를 고른다.

세 곳을 모두 통과해야 열린다.

| 관문 | 설정 | 관리 |
| --- | --- | --- |
| Tailscale ACL | 팀원 기기 → `10.0.0.205:5601` 허용 | Tailscale 관리 콘솔 (tailnet 관리자) |
| astra mangle `ORBIT-TS-EFK` | tailnet → efk는 TCP 22·5601과 ping만 통과 | `efk.yml` |
| efk `ORBIT-EFK` | 5601은 astra(`10.0.0.201`)에서만 | `efk.yml` |

인증서 경고: Kibana 인증서는 자체 CA로 서명해서 처음에는 브라우저가 경고한다. CA를 신뢰하면 경고가 사라진다. CA는 공개 인증서라 어느 호스트에서 복사해도 된다. 신뢰는 시스템 전체가 아닌 로그인 키체인에만 넣는다.

```bash
# Mac에서
scp <계정>@10.0.0.201:/etc/fluent-bit/efk-ca.crt ~/Downloads/efk-ca.crt
security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db ~/Downloads/efk-ca.crt
```

CA를 신뢰하면 이 CA로 서명된 인증서는 모두 믿게 된다. CA 개인키는 efk의 `/etc/elasticsearch/tls`에만 있고 root만 읽는다. 신뢰를 지우려면 키체인 접근에서 `ORBIT EFK CA`를 삭제한다.

## 인덱스와 보관

| 항목 | 값 |
| --- | --- |
| 인덱스 | 날짜별 `orbit-k8s-YYYY.MM.DD`(k3s Pod), `orbit-host-YYYY.MM.DD`(노드·astra·VM journald와 파일). 날짜는 UTC |
| 템플릿 | `orbit-logs` (두 패턴, 우선순위 200). primary 1, replica 0, `index.mapping.ignore_malformed: true` |
| ILM | `orbit-logs-7d`. 만든 지 7일 뒤 삭제. rollover·쓰기 alias 없음 |
| Kibana 데이터 뷰 | `orbit-k8s`, `orbit-host` (시간 필드 `@timestamp`, 인덱스가 없어도 있음) |

- 템플릿을 바꾸면 그 뒤에 새로 만들어지는 인덱스(보통 다음 날)부터 적용된다. 이미 있는 인덱스는 그대로다.
- 보관 기간은 `roles/efk/defaults/main.yml`의 `efk_retention`이다. 첫 주 저장 증가량을 보고 조정한다.
- 7일이 지나 Elasticsearch에서 지워진 로그도 각 호스트 journald(용량 기준, 기본 디스크의 최대 10%)에 남아 있으면 `journalctl`로 볼 수 있다.

## 필드

정의한 필드만 검색·집계할 수 있다(`dynamic: false`). 나머지는 `_source`에만 남는다. 송신 측은 아래 이름을 지켜야 한다. 같은 이름을 문자열과 객체로 섞어 보내면(예: `host`를 문자열로) 문서가 거부된다.

| 필드 | 타입 | 용도 |
| --- | --- | --- |
| `@timestamp` | date | 시간 |
| `message` | match_only_text | 원문. k3s 컨테이너 원문 `log`도 `message`로 바꿔 보냄 |
| `level` | keyword | 정규화한 로그 레벨 (`debug`, `info`, `warn`, `error` 등) |
| `stream` | keyword | `stdout`, `stderr` |
| `host.name` | keyword | 보낸 호스트 (노드·VM 이름) |
| `kubernetes.namespace_name`, `pod_name`, `container_name`, `host` | keyword | Pod 메타데이터 |
| `kubernetes.labels` | flattened | 라벨. `kubernetes.labels.app`으로 검색. 키에 점·슬래시가 있어도 됨 |
| `systemd.unit` | keyword | journald `_SYSTEMD_UNIT` |
| `syslog.identifier` | keyword | journald `SYSLOG_IDENTIFIER` (`sudo`, `sshd`, `kernel` 등) |
| `syslog.priority` | byte | journald `PRIORITY` (0 emerg ~ 7 debug, 4 이하가 warning 이상) |
| `file.path` | keyword | 파일 입력의 원본 경로 |
| `parsed.nginx.status`, `parsed.nginx.bytes` | long | CDN Nginx 상태 코드, 응답 본문 크기(`$body_bytes_sent`) |
| `parsed.nginx.cache` | keyword | CDN Nginx 캐시 결과 |
| `parsed.server.*` | (미정) | 서버 로그 파싱 결과. 필드를 정하면 템플릿에 추가 |

- 숫자 필드에 `-` 같은 값이 오면 문서는 저장되고 그 필드만 버려진다(`ignore_malformed`).
- `host.name`처럼 점이 들어간 이름으로 보내면 Elasticsearch가 객체로 색인한다. `_source`에는 보낸 모양(`"host.name"`) 그대로 남는다.

## 호스트 Fluent Bit (astra, VM 3대)

| 호스트 | journald | 파일 |
| --- | --- | --- |
| 공통 | `ssh.service`, 식별자 `sshd`·`sudo`, 커널 warning(PRIORITY 4) 이상 | |
| astra | `vault`, `tailscaled`, `libvirtd`, `virtlogd`, `smartmontools`, `systemd-networkd`, `orbit-net-revert`, 식별자 `wpa_supplicant`·`orbit-net` | `/var/log/libvirt/qemu/*.log` |
| VM 3대 | cloud-init 유닛 4개 | |
| efk | `elasticsearch`, `kibana` | `/var/log/elasticsearch/orbit-efk_server.json` (JSON을 풀어서) |

- 처음 제외: Vault 감사 로그(Wazuh 연동 계획), astra의 PostgreSQL·Samba·Docker, `systemd-resolved`, 백업 작업. lgtm·wazuh 스택 로그는 각 스택을 설치할 때 `roles/fluent_bit/defaults/main.yml`에 추가한다. astra에는 `orbit-gw-watch`가 없다(워커 노드에만 있어 k3s 쪽에서 수집).
- journald 조건은 OR로 묶인다. 커널은 `_TRANSPORT=kernel`로 받고, PRIORITY 5~7은 버린다.
- 보내는 필드는 `message`, `host.name`, `systemd.unit`, `syslog.identifier`, `syslog.priority`, `file.path`뿐이다. 나머지 journald 필드는 버린다.
- 버퍼: `/var/lib/fluent-bit` (읽기 위치 DB와 파일 버퍼). 상한 512M, efk만 64M. 재시도는 제한 없음. 상한에 닿으면 오래된 청크부터 버린다. 처음 시작할 때 이전 journal은 읽지 않는다.
- 비밀번호는 `/etc/default/fluent-bit`(root `0600`) 환경 변수로만 넣는다. 설정 파일 `/etc/fluent-bit/fluent-bit.conf`에는 값이 없다.
- 상태: 각 호스트 안에서 `curl -s http://127.0.0.1:2020/api/v1/health` → `ok`. 오류는 `sudo journalctl -u fluent-bit -n 50 --no-pager`.

## orbit-gitops#46 (k3s Fluent Bit)에 필요한 값

| 항목 | 값 |
| --- | --- |
| 주소 | `https://10.0.0.205:9200` |
| CA | efk-ca.crt (공개 인증서. astra `/etc/fluent-bit/efk-ca.crt`에서 복사해 ConfigMap 등으로 넣어도 됨) |
| 계정 | `fluentbit_k8s`. 비밀번호는 Vault `secret/orbit/k3s/fluent-bit`의 `password` (ESO `remoteRef.key: orbit/k3s/fluent-bit`, `property: password`) |
| 인덱스 | Pod 로그 `Logstash_Prefix orbit-k8s`, 노드 journald `Logstash_Prefix orbit-host`. `Logstash_Format On`, `Logstash_DateFormat %Y.%m.%d` |
| 출발지 | efk 방화벽은 9200을 노드 LAN IP(`10.0.0.200`, `.202`~`.204`)에서만 받는다. Pod에서 나가는 패킷이 노드 IP로 SNAT돼야 한다 |

Elasticsearch 출력에 아래 설정이 필요하다. 호스트 Fluent Bit(`roles/fluent_bit/templates/fluent-bit.conf.j2`)과 같다. classic 설정은 줄 맨 앞의 `#`만 주석으로 보므로, 값 뒤에 설명을 붙이지 않는다.

```
tls                  On
tls.verify           On
# 인증서 IP SAN 10.0.0.205로 주소까지 확인 (5.1.5에서 확인)
tls.verify_hostname  On
tls.ca_file          <efk-ca.crt 경로>
Suppress_Type_Name   On
# 쓰기 계정은 create_doc만 가능
Write_Operation      create
# 재전송해도 같은 ID → 409를 성공으로 처리, 중복 저장 없음
Generate_ID          On
Retry_Limit          no_limits
```

- 필드는 위 [필드](#필드) 표를 따른다. 컨테이너 원문 `log`는 `message`로 바꾸고, journald는 `systemd.unit`, `syslog.identifier`, `syslog.priority`, `host.name`으로 바꿔 보낸다.
- `Replace_Dots`는 끈 채로 둔다(기본값). `kubernetes.labels`는 flattened라 키에 점이 있어도 된다.
- `parsed.nginx.bytes`는 응답 본문 크기(`$body_bytes_sent`)로 고정한다. Grafana 담당자와 공유한다.

## Grafana (lgtm)에 필요한 값

| 항목 | 값 |
| --- | --- |
| 데이터 소스 | Elasticsearch, URL `https://10.0.0.205:9200` (efk 방화벽이 lgtm `10.0.0.206`에서 허용) |
| 계정 | `grafana_viewer`. 비밀번호는 Vault `secret/orbit/infra/efk`의 `grafana_viewer_password` |
| TLS | CA efk-ca.crt로 검증 (`tlsAuthWithCACert`) |
| 인덱스 | `orbit-k8s-*`, `orbit-host-*`, 시간 필드 `@timestamp` |

## 방화벽

| 위치 | 규칙 | 이유 |
| --- | --- | --- |
| efk `ORBIT-EFK` (filter INPUT 맨 앞) | 9200: k3s 노드 4대, astra, lgtm, wazuh. 5601: astra. 둘 다 `lo` 허용. 나머지 DROP. 22 등 다른 포트는 건드리지 않음 | 송신기·Grafana만 9200, 사람은 astra 경유로만 5601 |
| astra `ORBIT-TS-EFK` (mangle FORWARD 맨 앞) | `tailscale0` → `10.0.0.205`는 TCP 22·5601과 ICMP만, 나머지 DROP | 서브넷 라우터 SNAT 때문에 efk에서는 tailnet 접속과 astra가 같은 IP로 보여 구분할 수 없음 |

- astra 규칙을 filter가 아닌 mangle에 둔 이유: Tailscale은 재시작할 때 filter FORWARD 맨 앞에 tailnet 통과를 허용하는 `ts-forward`를 다시 넣는다. mangle은 filter보다 먼저 보고, mangle에서 버린 패킷은 뒤의 허용과 관계없이 버려진다.
- 두 규칙 모두 `iptables-restore`로 한 번에 바꾸고 `netfilter-persistent`로 저장한다(재부팅 뒤 유지). efk는 이때 쓰지 않던 `ufw`가 지워졌다(`iptables-persistent`와 함께 설치 불가).
- 허용 출발지는 인벤토리에서 가져온다. k3s 노드를 추가하면 `efk.yml`을 다시 실행한다.

확인:

```bash
# efk에서
sudo iptables -S INPUT | head -3; sudo iptables -S ORBIT-EFK
# astra에서
sudo iptables -t mangle -S FORWARD | head -3; sudo iptables -t mangle -S ORBIT-TS-EFK
# 팀원 Mac에서 (Tailscale 켠 상태)
nc -vz -G 5 10.0.0.205 5601   # 성공 (ACL 허용 후)
nc -vz -G 5 10.0.0.205 9200   # 실패
```

## 디스크와 용량

watermark는 기본값(85/90/95%)이다. 아래 인덱스 크기 조회는 [Vault 준비](#vault-준비) 후에 한다. watermark는 오래된 로그를 지우지 않고 쓰기를 막으므로 그 전에 대응한다.

| 사용률 | 할 일 |
| --- | --- |
| 70% | 경고. 어느 인덱스·호스트가 큰지 확인하고 팀에 알린다 |
| 80% | 대응. 보관 기간(`efk_retention`)을 줄여 `efk.yml`을 실행하거나, 많이 보내는 출처의 필터를 줄인다. 급하면 가장 오래된 날짜 인덱스를 `elastic`으로 지운다 |
| 85% 이상 | Elasticsearch가 새 샤드 배치를 멈춘다. 90%부터 샤드를 옮기려 하고(단일 노드라 옮길 곳 없음), 95%에서 인덱스가 읽기 전용이 된다 |

```bash
# efk에서: 디스크
df -h /var/lib/elasticsearch
# astra에서: 인덱스별 크기 (관리자 계정. 화면에 비밀번호를 남기지 않음). 먼저 Vault 준비
P=$(vault kv get -mount=secret -field=elastic_password orbit/infra/efk) && [ -n "$P" ] && echo ok
printf 'user = "elastic:%s"\n' "$P" | curl -s -K - --cacert /etc/fluent-bit/efk-ca.crt \
  'https://10.0.0.205:9200/_cat/indices/orbit-*?v&s=index&h=index,docs.count,store.size'
printf 'user = "elastic:%s"\n' "$P" | curl -s -K - --cacert /etc/fluent-bit/efk-ca.crt \
  'https://10.0.0.205:9200/_cat/allocation?v'
unset P
```

- 첫 주에는 매일 같은 시각에 인덱스별 크기를 기록해 하루 증가량을 잰다. 7일 보관이 디스크 70% 안에 들어오는지 보고 보관 기간을 정한다. 부하 시험 전에 여유 공간을 다시 확인한다.

## 장애 때

| 증상 | 확인 |
| --- | --- |
| Kibana에 새 로그가 안 보임 | 송신 호스트에서 `curl -s http://127.0.0.1:2020/api/v1/health`, `sudo journalctl -u fluent-bit -n 50 --no-pager`. 401이면 비밀번호(Vault 값과 다름), 403이면 권한, TLS 오류면 CA·인증서 SAN |
| Elasticsearch가 멈춤 | efk에서 `sudo systemctl status elasticsearch`, `sudo journalctl -u elasticsearch -n 100 --no-pager`, `sudo tail -n 100 /var/log/elasticsearch/orbit-efk_server.json`. 이때 efk 자신의 로그는 Elasticsearch에 들어가지 못하므로 efk journal을 직접 본다. 다른 송신기는 버퍼(512M)까지 쌓았다가 복구되면 다시 보낸다 |
| Kibana가 안 열림 | efk에서 `sudo systemctl status kibana`, `sudo tail -n 50 /var/log/kibana/kibana.log`. 팀원만 안 되면 Tailscale ACL과 astra `ORBIT-TS-EFK` |
| 디스크가 참 | [디스크와 용량](#디스크와-용량) |

## 사람 식별

astra 서브넷 라우터가 SNAT하므로 tailnet에서 온 SSH 접속은 노드·VM의 sshd 로그에 출발지가 모두 `10.0.0.201`(astra)로 남는다. IP로는 사람을 구분할 수 없다. 사람은 로그인 계정명과 SSH 인증서 ID로 식별한다.

```
Accepted publickey for jyvnee from 10.0.0.201 port 43456 ssh2: ED25519-CERT SHA256:... ID github-jyvnee (serial ...) CA ...
```

Kibana에서 `syslog.identifier: sshd and message: "Accepted publickey"`로 찾고 `ID github-<아이디>`를 본다. 공용 `orbit` 계정으로 들어와도 인증서 ID는 남는다. sudo 기록은 `syslog.identifier: sudo`다.
