# Wazuh 중앙 구성요소

[설치 이슈 #26](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/26) · [W3 모니터링 기반 구축](https://github.com/ORBIT-CLOUD-LABS/orbit/issues/58)

## 구성

전용 `wazuh` VM에 Wazuh Manager·Indexer·Dashboard를 단일 호스트 구성으로 설치했다. 설치 시 확인한 OS는 Ubuntu 24.04.5 LTS(x86_64)이며, VM 자원은 4 vCPU, RAM 13 GiB, 루트 파일시스템 58 GiB였다. 호스트 Agent 배포는 후속 작업에서 다룬다.

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

## Dashboard 접속

Tailscale에 연결한 Mac에서 `https://wazuh-ui.orbit-labs.space/`를 열면 Dashboard 로그인 화면으로 이동한다. astra nginx가 이름을 보고 Wazuh VM의 TCP 443으로 넘긴다 ([내부 리버스 프록시](reverse-proxy.md)). `wazuh.orbit-labs.space`는 SSH용 기기 이름이며, 팀원 정책에서 VM 443 직접 접속은 막혀 있다.

설치 직후(2026-11-09)에는 VM 직통으로 접속했다. 최초에는 443 연결이 타임아웃됐으며 Tailnet 정책에 TCP 443을 추가한 뒤 브라우저 접속과 Overview 표시를 확인했다.

검증 당시 Chrome 주소창에 인증서 경고가 표시됐다. 최종 접근 허용 범위는 팀 정책에 맞춰 확인한다.

### 후속 작업 · Dashboard TLS 인증서

Vault PKI를 이용해 `wazuh.orbit-labs.space`가 SAN에 포함된 서버 인증서를 발급하는 방안을 검토한다. 발급 경로와 브라우저의 CA 신뢰 절차를 확정한 뒤 Dashboard에 인증서를 적용하고, Chrome에서 경고 없이 접속하고 로그인할 수 있는지 검증한다. [Wazuh Dashboard 인증서 설정](https://documentation.wazuh.com/current/user-manual/wazuh-dashboard/configuring-third-party-certs/index.html)

## 상태 확인

아래 명령은 `wazuh` VM에서 실행한다.

```bash
sudo systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard filebeat
dpkg-query -W wazuh-manager wazuh-indexer wazuh-dashboard filebeat
sudo ss -lntp 'sport = :443'
curl -k -sS --max-time 10 -o /dev/null -w 'HTTP %{http_code}\n' https://127.0.0.1:443/
```

마지막 명령은 VM 내부에서 Dashboard가 HTTPS로 응답하는지 확인하는 용도다. 인증서 검증을 생략하는 이 검사에는 로그인 정보를 사용하지 않는다. `HTTP 302`는 리디렉션 응답이며 브라우저 로그인은 별도로 검증한다.

## 검증 기록

| 날짜 | 확인 항목 | 결과 |
|---|---|---|
| 2026-11-09 | 설치 도우미 실행 | `Installation finished` 확인 |
| 2026-11-09 | Manager·Indexer·Dashboard·Filebeat | 모두 `active` |
| 2026-11-09 | VM 내부 Dashboard HTTPS | `HTTP 302` |
| 2026-11-09 | Mac에서 Dashboard 접속 | 최초 타임아웃. Tailnet 정책 변경 후 로그인 화면 확인 |
| 2026-11-09 | Mac 브라우저 로그인 | Dashboard Overview 확인. 브라우저 인증서 경고 표시 |
