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
