# Wazuh 중앙 구성요소

[설치 이슈 #26](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/26) · [W3 모니터링 기반 구축](https://github.com/ORBIT-CLOUD-LABS/orbit/issues/58)

## 구성

전용 `secure` VM(`10.10.30.3`, 관측 구역, astra 안, 4 vCPU, 12GB, 디스크 60GB)에 Wazuh Manager·Indexer·Dashboard를 단일 호스트 구성으로 설치한다. 재설계에서 옛 `wazuh` VM을 없애고 `wazuh_central` role로 새로 설치했다(orbit-infrastructure#60, 기존 경보와 Agent 등록은 옮기지 않음). 처음 설치(#26)는 옛 `wazuh` VM(Ubuntu 24.04.5 LTS, x86_64, 4 vCPU, RAM 13 GiB, 루트 58 GiB)에 했다.

| 패키지 | 설치 버전 |
|---|---|
| `wazuh-manager` | `4.14.10-1` |
| `wazuh-indexer` | `4.14.10-1` |
| `wazuh-dashboard` | `4.14.10-1` |
| `filebeat` | `7.10.2-2` |

## 설치

신규 설치 전에 VM의 SSH·sudo 접근, OS·아키텍처, 메모리·디스크 여유, 시간 동기화, 사용 중인 포트와 기존 패키지를 확인한다. 운영 중인 VM은 아래 상태 확인 절차를 사용한다.

최초 설치는 `wazuh` VM의 SSH 세션에서 공식 4.14 설치 도우미로 수행했다. 다시 설치할 때는 사용할 버전과 복구 절차를 먼저 확인한다. [Wazuh Quickstart](https://documentation.wazuh.com/current/quickstart.html)

```bash
umask 077
mkdir -p ~/wazuh-install &&
  cd ~/wazuh-install &&
  curl -fSL -o wazuh-install.sh https://packages.wazuh.com/4.14/wazuh-install.sh &&
  sudo bash ./wazuh-install.sh -a
```

설치 완료 시 `Installation finished`가 표시된다. 상세 로그는 VM의 `/var/log/wazuh-install.log`에 있다. 설치 출력과 `wazuh-install-files.tar`에는 자격 증명과 인증서 자료가 포함되므로 접근을 제한한다. 관리자 암호는 팀이 승인한 비밀 저장소에서 관리한다. [Wazuh 자격 증명 관리](https://documentation.wazuh.com/current/user-manual/user-administration/password-management.html)

## 재설계 신규 설치 (orbit-infrastructure#60)

빈 `secure` VM에 role로 설치한다. astra 개인 계정에서 실행한다. 설치 도우미는 버전이 `wazuh_central_packages`(4.14.10)와 같은지 먼저 확인한다. 다르면 설치 뒤 버전 확인 단계에서 멈춘다.

```bash
curl -fsSL -o /tmp/wazuh-install.sh https://packages.wazuh.com/4.14/wazuh-install.sh
sha256sum /tmp/wazuh-install.sh
grep -m2 -E 'wazuh_(major|version)=' /tmp/wazuh-install.sh
```

```bash
(
  ../scripts/orbit-ssh-cert.sh &&
  VAULT_TOKEN="$(cat ~/.orbit/vault-token)" &&
  [ -n "$VAULT_TOKEN" ] &&
  export VAULT_TOKEN &&
  ansible-playbook playbooks/wazuh-central.yml --limit secure -K \
    -e 'wazuh_central_allow_install=true' \
    -e 'wazuh_central_installer_url=https://packages.wazuh.com/4.14/wazuh-install.sh' \
    -e 'wazuh_central_installer_sha256=<위 sha256sum 값>' \
    -e 'wazuh_central_indexer_url=https://127.0.0.1:9200' \
    -e 'wazuh_central_indexer_ca=/etc/filebeat/certs/root-ca.pem'
)
```

- 조회 계정 두 개는 Vault에 이미 있는 값(옛 VM에서 쓰던 비밀번호)으로 새 Manager·Indexer에 만든다.
- Dashboard 관리자 경로 `secret/orbit/infra/wazuh-dashboard-admin`은 비어 있어야 한다. 값이 있으면 설치 아카이브의 새 관리자 값을 저장하지 않고 옛 값으로 Indexer 인증을 시도해 멈춘다. 팀원 토큰에는 삭제 권한이 없으므로 [Vault 관리자 권한](vault.md#관리자-권한) 절차로 `vault kv metadata delete`를 한다.

## Dashboard 접속

Tailscale에 연결한 Mac에서 `https://wazuh-ui.orbit-labs.space/`를 열면 Dashboard 로그인 화면으로 이동한다. astra nginx가 이름을 보고 Wazuh VM의 TCP 443으로 넘긴다 ([내부 리버스 프록시](reverse-proxy.md)). `wazuh.orbit-labs.space`는 SSH용 기기 이름이며, 팀원 정책에서 VM 443 직접 접속은 막혀 있다.

설치 직후(2026-11-09)에는 VM 직통으로 접속했다. 최초에는 443 연결이 타임아웃됐으며 Tailnet 정책에 TCP 443을 추가한 뒤 브라우저 접속과 Overview 표시를 확인했다.

검증 당시 Chrome 주소창에 인증서 경고가 표시됐다. 최종 접근 허용 범위는 팀 정책에 맞춰 확인한다.

### 후속 작업 · Dashboard TLS 인증서

Vault PKI를 이용해 `wazuh.orbit-labs.space`가 SAN에 포함된 서버 인증서를 발급하는 방안을 검토한다. 발급 경로와 브라우저의 CA 신뢰 절차를 확정한 뒤 Dashboard에 인증서를 적용하고, Chrome에서 경고 없이 접속하고 로그인할 수 있는지 검증한다. [Wazuh Dashboard 인증서 설정](https://documentation.wazuh.com/current/user-manual/wazuh-dashboard/configuring-third-party-certs/index.html)

## Ansible 자동화

### 플레이북

[#48](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/48)에서 수동 설치와 상태 점검 절차를 `ansible/playbooks/wazuh-central.yml`과 `wazuh_central` 역할로 옮겼다. 지원 조건을 충족하는 미설치 VM의 설치 절차를 정의했고, 신규 설치는 기본적으로 비활성화했다. 기존 설치의 패키지 상태나 버전이 예상과 다르면 변경 전에 중단한다.

### 플레이북 실행 흐름 (#51)

```text
대상 VM의 OS·패키지·기존 설정 확인
├─ 빈 VM → 설치 허용·자원·포트·해시 확인 후 구성요소 설치
├─ 지원 버전 설치 완료 → 서비스 활성화 및 실행 단계로 진행
└─ 부분 설치 또는 버전 불일치 → 중단

서비스 자동 시작 설정 및 실행
├─ 신규 설치·초기화 재개 → 설치 아카이브의 관리자 정보로 초기 구성
│                         Dashboard admin을 관리자 전용 Vault 경로에 최초 저장
├─ 기존 VM 계정 보완 → Vault의 관리자 정보로 누락된 계정·권한 구성
└─ 일반 실행 → Vault에서 조회 계정 두 개 읽기

패키지 버전·서비스 상태·Dashboard 로컬 HTTPS 확인
├─ 초기 구성·재개·계정 보완 시 Dashboard admin으로 Indexer 인증 확인
├─ Manager 조회 계정으로 Agent 목록 조회
└─ Indexer 조회 계정으로 경보 검색 요청 확인
```

Indexer 관리자 인증은 Dashboard 브라우저 로그인과 별도로 확인한다.
실제 경보 수집은 시험 이벤트를 발생시킨 뒤 해당 경보를 조회해 확인한다.

### 기존 VM에서 일반 실행

`astra`의 `~/orbit-infrastructure/ansible`에서 실행한다. 플레이북은 Vault 호스트에서 Vault KV v2의 조회 계정을 읽고, `secure` VM에서 Manager API와 Indexer를 확인한다. 실행 전에 두 계정 경로에 `read` 권한이 있는 Vault 토큰을 준비한다.

실행 예제는 먼저 `../scripts/orbit-ssh-cert.sh`로 SSH 인증서와 Vault 토큰을 준비한다. 인증서 준비가 성공하면 토큰을 읽고 플레이북을 실행한다. 자세한 내용은 [개인 계정 운영 문서](personal-accounts.md)를 참고한다.

```bash
(
  ../scripts/orbit-ssh-cert.sh &&
  VAULT_TOKEN="$(cat ~/.orbit/vault-token)" &&
  [ -n "$VAULT_TOKEN" ] &&
  export VAULT_TOKEN &&
  ansible-playbook playbooks/wazuh-central.yml --limit secure -K \
    -e 'wazuh_central_allow_install=false' \
    -e 'wazuh_central_indexer_url=https://127.0.0.1:9200' \
    -e 'wazuh_central_indexer_ca=/etc/filebeat/certs/root-ca.pem'
)
```

`VAULT_TOKEN`은 괄호 안의 실행 환경에 전달한다. Manager API와 Indexer의 비밀번호는 플레이북이 Vault에서 읽는다. `--limit secure`는 대상을 VM 한 대로 제한하고, `-K`는 해당 VM의 `sudo` 비밀번호를 요청한다. `-e`는 이번 실행의 변수 값을 지정한다. Indexer URL과 CA 경로는 조회가 실행되는 `secure` VM 기준이다.

### Vault 계정과 권한

| 용도 | 계정 | 권한 | Vault KV v2 경로 |
| --- | --- | --- | --- |
| Manager API | `orbit-agent-reader` | Agent 조회 | `secret/orbit/infra/wazuh-agent-reader` |
| Indexer API | `orbit-alert-reader` | `orbit-alerts-readonly` 역할로 `wazuh-alerts-*` 읽기 | `secret/orbit/infra/wazuh-alert-reader` |

| Dashboard 로그인 및 Indexer 초기 구성 | `admin` | 관리자. 신규 설치에서 최초 저장 | `secret/orbit/infra/wazuh-dashboard-admin` |
| 기존 VM의 Manager 계정 보완 | `wazuh` | Manager API 관리자. 보완 실행 전에 현재 값을 준비 | `secret/orbit/infra/wazuh-manager-admin` |

일반 실행은 첫 두 조회 계정만 사용한다. 관리자 경로는 초기 구성·재개·계정 보완에 필요한 범위에서 사용한다. 신규 설치에서는 Manager 관리자 값을 설치 아카이브에서 읽는다.

두 조회용 Vault 항목은 `username`과 `password` 필드를 사용한다. 실행용 Vault 토큰에는 KV v2 데이터 경로 `secret/data/orbit/infra/wazuh-agent-reader`와 `secret/data/orbit/infra/wazuh-alert-reader`에 대한 `read` 권한이 필요하다.

자격 증명은 팀의 비밀 저장소에서 관리한다.

### 초기 구성과 Vault 권한

중앙 구성요소 플레이북은 설치 상태를 확인한다. 빈 VM에 신규 설치하려면
설치 허용 값, 설치 도우미의 HTTPS URL과 SHA256을 지정한다.
이미 지원 버전이 설치된 VM에서는 패키지를 재설치하지 않고 필요한 서비스를
실행 상태로 맞춘 뒤 조회 계정과 읽기 권한을 확인한다.

Manager API와 Indexer 조회 계정은 환경별 Vault KV v2 경로에서 읽는다.
계정과 Vault 값이 모두 없는 경우에만 비밀번호를 생성해 최초 저장한다.
신규 설치에서 발급된 Dashboard 관리자 자격 증명은 관리자 전용 경로에 보관한다.

초기 구성에는 지정 경로의 읽기·생성 권한과 Wazuh 계정 관리 권한이 필요하다.
이후 Agent 배포와 상태 점검에는 해당 조회 계정 경로의 읽기 권한을 사용한다.
운영 환경과 검증 환경은 별도 Vault 경로를 사용한다.

### 조회 계정 초기화와 재실행

신규 설치는 설치 아카이브의 관리자 정보로 조회 계정을 초기화한다.
설치 직후 초기화에 실패했다면 같은 VM과 설치 아카이브를 확인한 뒤
`wazuh_central_resume_bootstrap=true`로 초기화를 다시 실행할 수 있다.
기존 VM에서 누락된 계정이나 권한을 보완할 때는 현재 관리자 자격 증명을
승인된 Vault 경로에 준비하고 `wazuh_central_repair_accounts=true`를 지정한다.
일반 재실행은 Vault의 두 조회 계정으로 검증한다.

## 확인

아래 명령은 `secure` VM에서 실행한다.

```bash
sudo systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard filebeat
dpkg-query -W wazuh-manager wazuh-indexer wazuh-dashboard filebeat
sudo ss -lntp 'sport = :443'
curl -k -sS --max-time 10 -o /dev/null -w 'HTTP %{http_code}\n' https://127.0.0.1:443/
```

마지막 명령은 VM 내부에서 Dashboard가 HTTPS로 응답하는지 확인하는 용도다. 인증서 검증을 생략하는 이 검사에는 로그인 정보를 사용하지 않는다. `HTTP 302`는 리디렉션 응답이며 브라우저 로그인은 별도로 검증한다.

## 적용 기록

### 수동 설치 (#26)

| 날짜         | 확인 항목                              | 결과                                    |
| ---------- | ---------------------------------- | ------------------------------------- |
| 2026-11-09 | 설치 도우미 실행                          | `Installation finished` 확인            |
| 2026-11-09 | Manager·Indexer·Dashboard·Filebeat | 모두 `active`                           |
| 2026-11-09 | VM 내부 Dashboard HTTPS              | `HTTP 302`                            |
| 2026-11-09 | Mac에서 Dashboard 접속                 | 최초 타임아웃. Tailnet 정책 변경 후 로그인 화면 확인    |
| 2026-11-09 | Mac 브라우저 로그인                       | Dashboard Overview 확인. 브라우저 인증서 경고 표시 |

### Ansible 검증 (#48)

| 날짜 | 대상            | 확인 항목                                      | 결과                                                                      |
| --- | ------------- | ------------------------------------------ | ----------------------------------------------------------------------- |
| 2026-11-13 | 기존 `wazuh` VM | 신규 설치 조건 확인, 설치 도우미 다운로드 및 실행              | 모두 건너뜀                                                                  |
| 2026-11-13 | 기존 `wazuh` VM | 패키지 버전과 서비스 4개 상태                          | Manager·Indexer·Dashboard `4.14.10-1`, Filebeat `7.10.2-2`. 서비스 모두 실행 중 |
| 2026-11-13 | 기존 `wazuh` VM | Dashboard 로컬 HTTPS 응답                      | 통과                                                                      |
| 2026-11-13 | 기존 `wazuh` VM | Manager API 인증 및 Agent 조회                  | 통과                                                                      |
| 2026-11-13 | 기존 `wazuh` VM | Indexer에서 기존 경보 한 건 조회                     | 통과                                                                      |
| — | 신규 VM         | 최초 설치 및 설치 후 재실행                           | 미검증. 후속 작업에서 확인                                                         |
| 2026-11-13 | 기존 `wazuh` VM | Vault KV v2에서 Manager API·Indexer 조회 계정 읽기 | 두 계정 조회 및 필수 필드 확인 통과                                                   |

Vault 연동 후 기존 `wazuh` VM의 일반 실행 결과는 `ok=15 changed=0 unreachable=0 failed=0 skipped=6`이었다. 신규 설치 단계는 건너뛰었고, Manager API의 Agent 조회와 Indexer의 기존 경보 조회가 통과했다.

### Ansible 검증 (#51)

| 날짜 | 대상 | 확인 항목 | 결과 |
| --- | --- | --- | --- |
| 2026-11-15 | 기존 `wazuh` VM | SSH 인증서 준비 후 플레이북 일반 실행 | 성공. `ok=23 changed=0 unreachable=0 failed=0 skipped=12` |
| — | 신규 VM | 최초 설치 및 계정 초기화 | 미검증 |
| — | 기존 VM | 누락된 계정·권한 보완 및 관리자 인증 | 미검증 |
