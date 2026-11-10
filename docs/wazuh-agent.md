# Wazuh Agent 시범 설치

[Agent 시범 설치 #30](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/30) · [중앙 구성요소 설치 #26](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/26)

## 구성

`astra` 한 대에 Wazuh Agent를 설치해 중앙 Manager에 등록했다. 이 절차는 Dashboard에서 설치 명령을 생성해 대상 호스트에서 실행하는 방식이다.

| 항목 | 시범 환경 |
| --- | --- |
| 대상 호스트 | `astra` (`10.0.0.201`), Ubuntu 24.04.5 LTS, x86_64 |
| Wazuh Manager | `wazuh` VM (`10.0.0.207`), 패키지 버전 `4.14.10-1` |
| Agent 패키지 | Linux DEB amd64, `4.14.10-1` |
| Agent 등록 | 이름 `astra`, ID `001`, 그룹 `default` |

## 사전 점검

대상 호스트의 SSH 세션에서 OS와 아키텍처를 확인한다. 기존 Agent가 설치돼 있거나 Dashboard에 같은 이름이 등록돼 있으면 기존 상태부터 확인한다.

```bash
hostname
cat /etc/os-release
uname -m
dpkg-query -W wazuh-agent wazuh-manager
nc -vz -w 5 10.0.0.207 1515
nc -vz -w 5 10.0.0.207 1514
```

`astra`에는 기존 Wazuh 패키지가 없었고, Manager의 TCP 1515(등록)와 1514(Agent 통신) 연결이 모두 성공했다. [Agent 등록 요구사항](https://documentation.wazuh.com/current/user-manual/agent/agent-enrollment/requirements.html)

## 설치 및 등록

1. Dashboard의 **Endpoints → Deploy new agent**에서 **Linux → DEB amd64**를 선택한다.
2. **Server address**에 `10.0.0.207`, **Agent name**에 `astra`를 입력하고 그룹은 `Default`로 둔다. 다른 호스트에 배포할 때는 대상 OS·아키텍처와 고유한 Agent 이름을 적용한다.
3. 생성된 명령을 대상 호스트에서 실행한다. Agent 패키지 버전은 Manager와 같거나 낮아야 한다. 아래는 `astra`에서 실행한 명령이다. [Wazuh Agent 설치](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/index.html)

```bash
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.10-1_amd64.deb &&
  sudo WAZUH_MANAGER='10.0.0.207' WAZUH_AGENT_NAME='astra' \
    dpkg -i ./wazuh-agent_4.14.10-1_amd64.deb
```

설치가 완료되면 같은 호스트에서 서비스를 시작한다.

```bash
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent
systemctl is-active wazuh-agent
```

`systemctl`에서 `active`를 확인한다. Dashboard의 **Endpoints**에서도 대상 Agent가 `Active`인지 확인한다. 시범 설치에서는 `astra`(ID `001`)가 버전 `v4.14.10`, 상태 `Active`로 표시됐다.

## 시험 이벤트 검증

`astra`에서 `/var/ossec/etc/ossec.conf`의 `<localfile>` 블록에 `location`과 `log_format`이 모두 `journald`로 설정된 것을 확인했다. 아래 명령은 실행 시각을 기록하고 sudo 시험 로그를 만든 뒤 로컬 저널에서 조회한다. [journald 수집 설정](https://documentation.wazuh.com/current/user-manual/capabilities/log-data-collection/journald.html)

```bash
date -u '+%Y-%m-%dT%H:%M:%SZ'
sudo /usr/bin/true
sudo journalctl --since '5 minutes ago' -t sudo --no-pager
```

Dashboard의 **Threat Hunting → Events**에서 시험 시각을 포함하는 범위를 선택하고 `agent.name: "astra"`로 필터링한다. 해당 행의 상세 아이콘을 눌러 `data.command`와 `full_log`를 대조한다. `sudo journalctl` 실행도 같은 규칙의 별도 경보를 남기므로 `/usr/bin/true`가 찍힌 행을 확인한다.

2026-11-09 **12:57:29 UTC**에 실행한 시험 명령은 Dashboard에서 **규칙 `5402`**, 레벨 `3`의 경보로 조회됐다. Agent는 `astra`(ID `001`), 수집 소스는 `journald`였고, `full_log`의 `sudo[1801685]`와 `COMMAND=/usr/bin/true`가 로컬 저널 기록과 일치했다.

## Ansible 배포 및 검증

[#35](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/35)에서 `astra` 시범 설치를 바탕으로 Wazuh Agent 배포와 연결 검증을 자동화했다.

### 작업 내용

| 설정          | 적용 내용                                                                                                                                                                                        |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 배포 대상과 순서   | [인벤토리](../ansible/inventory/hosts.yml)에 `wazuh_agents` 그룹을 추가했다. `sol`에서 먼저 검증한 뒤 `terra`, `luna`, `lgtm`, `efk`에 배포했다. 기존 `astra`를 관리 대상에 포함하고, k3s control plane인 `polaris`는 마지막에 단독 배포했다. |
| 패키지와 버전     | [Ansible 역할](../ansible/roles/wazuh_agent/tasks/main.yml)은 Ubuntu의 x86_64와 ARM64에 맞는 공식 DEB `4.14.10-1`을 선택하고 SHA512 검증 후 직접 설치하며 Wazuh APT 저장소는 추가하지 않는다.                                   |
| 등록과 서비스     | 설치 전 Manager 연결과 같은 이름의 등록 여부를 확인한다. 인벤토리 호스트 이름으로 Agent를 등록하고 서비스를 시작하며, 부팅 시 자동 시작을 설정한다. 실행 후 Manager API에서 `Active`를 확인한다.                                                               |
| 기존 Agent 보호 | 동일 버전이 정상 설치돼 있으면 다운로드와 재설치를 건너뛰고, 실행 전후 등록 ID를 비교한다.                                                                                                                                        |
| 순차 적용       | [플레이북](../ansible/playbooks/wazuh-agent.yml)은 한 대씩 적용하고, 실패하면 다음 대상으로 넘어가기 전에 중단한다.                                                                                                          |

### 팀에서 알아둘 운영 정보

- **Vault와 Wazuh API** — Wazuh에 조회 전용 계정 `orbit-agent-reader`를 만들고 `agents_readonly` 역할을 부여했다. 자격 증명은 Vault KV v2의 `secret/orbit/infra/wazuh-agent-reader`에 `username`, `password`로 저장했다. 실행용 Vault 토큰에는 해당 경로의 읽기 권한이 필요하다. 계정 비밀번호를 교체할 때는 Vault 값도 함께 갱신한다.
- **API 접속 경로** — Ansible은 `astra`에서 실행하고 Wazuh API 요청은 `wazuh` VM에 위임한다. VM 내부의 `https://localhost:55000`에서 서버 인증서를 검증하고 조회용 JWT를 발급받는다. 실행 계정에는 대상 노드와 `wazuh` VM에 대한 SSH 및 sudo 권한이 필요하다.
- **Agent 통신과 대상 범위** — 각 대상에서 Manager의 TCP `1514`에 연결할 수 있어야 하며, 신규 등록에는 TCP `1515`도 필요하다. 중앙 구성요소를 실행하는 `wazuh` VM은 Agent 배포 그룹에서 제외했다.

### 실행

`astra` SSH 세션에서 실행한다. 예시는 `--limit sol`로 한 대만 선택한다. 다른 대상에 적용할 때는 인벤토리의 호스트 이름으로 바꾼다.

```bash
cd ~/orbit-infrastructure/ansible &&
../scripts/orbit-ssh-cert.sh &&
(
  VAULT_TOKEN="$(cat ~/.orbit/vault-token)" &&
  export VAULT_TOKEN &&
  ansible-playbook playbooks/wazuh-agent.yml --limit sol -K --check
)
```

`--check`는 OS·아키텍처, 기존 패키지, Manager 연결과 등록 상태를 확인한다. 패키지 다운로드와 SHA512 검증, 신규 설치, 설치 후 Active 검증은 실제 실행에서 수행한다. 사전 검사가 통과하면 같은 명령에서 `--check`를 빼고 실행한다.

실제 실행 후 Dashboard의 **Endpoints**에서 대상이 `Active`인지 확인한다. 같은 명령을 다시 실행해 `changed=0`, `failed=0`, `unreachable=0`이고 기존 등록 ID 확인 단계가 `ok`인지 확인한다.

### 검증 결과

| 대상 | 확인 결과 |
| --- | --- |
| 전체 7대 | Dashboard에서 Agent `v4.14.10`과 `Active` 상태를 확인했다. 재실행 결과는 모두 `changed=0`, `failed=0`, `unreachable=0`이었다. |
| `astra` | 기존 설치를 재사용했고 등록 ID `001`이 유지됐다. |
| `sol` | Dashboard에서 sudo 시험 이벤트를 확인했다. |
| `polaris` | ARM64 Agent가 ID `007`로 등록됐다. 설치 후 k3s `/readyz`가 `ok`를 반환했고 노드 4대가 모두 `Ready`였다. 1분 평균 부하는 설치 전 `0.55`, 설치 직후 `2.08`, 재측정 시 `0.22`였다. 재측정 시 가용 메모리는 `5.1 GiB`, 디스크 여유는 `52G`였다. |
