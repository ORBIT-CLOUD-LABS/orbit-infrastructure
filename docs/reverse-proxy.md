# 내부 리버스 프록시 (astra nginx)

팀원이 모니터링 화면을 포트 없이 서비스 이름으로 보도록 astra에 둔 nginx다. 모니터링 화면은 공개하지 않는다. 구현: [#34](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/34).

## 이름

| 종류 | 이름 | DNS (Cloudflare, DNS only) | 가는 곳 |
| --- | --- | --- | --- |
| 서비스 | `wazuh-ui.orbit-labs.space` | `10.0.0.201` | nginx → `https://10.0.0.207:443` (자체 서명, 확인 안 함) |
| 서비스 | `kibana.orbit-labs.space` | `10.0.0.201` | nginx → `https://10.0.0.205:5601` (efk CA로 확인) |
| 서비스 | `grafana.orbit-labs.space` | `10.0.0.201` | nginx → `http://10.0.0.206:3000` |
| 기기 | `astra`, `polaris`, `sol`, `terra`, `luna`, `efk`, `lgtm`, `wazuh` | 각 기기 주소 | SSH |

- 기기 이름은 SSH용, 서비스 이름은 nginx가 Host를 보고 나눈다. SSH는 이름을 서버에 보내지 않아 nginx가 나눌 수 없으므로 두 종류를 섞지 않는다.
- 모르는 이름은 연결을 끊는다 (`default_server`, 444).
- `http://`(80)는 받지 않는다. `https://`로 접속한다.

## 경로

```
팀원 ─Tailscale─▶ astra nginx 10.0.0.201:443 ─▶ 각 VM 포트
```

- nginx는 `10.0.0.201:443`에서만 받고, 방화벽 체인 `ORBIT-PROXY`가 `lo`, `br0`, `tailscale0` 밖에서 오는 443을 버린다 (Vault 8200과 같은 방식).
- Tailscale 정책: 팀원 443은 `10.0.0.201`(nginx) 하나만. VM 443 직접은 관리자만 (예비 경로). SSH(22)는 노드·VM 전부.
- 인증서는 자체 서명(825일). 브라우저 경고가 한 번 뜬다.

## 플레이북

astra 개인 계정으로 실행한다 ([개인 계정 문서](personal-accounts.md#ansible-실행)).

```bash
cd ~/orbit-infrastructure/ansible
ansible-playbook playbooks/reverse-proxy.yml -K --check --diff   # 미리보기
ansible-playbook playbooks/reverse-proxy.yml -K --diff           # 적용. 다시 실행하면 changed=0
```

서비스를 추가할 때는 `roles/reverse_proxy/defaults/main.yml`의 `rproxy_sites`에 한 항목을 더하고(`name`은 앞부분만, 예: `hubble`), Cloudflare에 `<앞부분>.orbit-labs.space`를 `10.0.0.201`로 등록한다. 인증서 SAN이 바뀌어 다시 발급된다.

## 확인

```bash
sudo ss -lntp 'sport = :443'          # astra: 10.0.0.201:443 nginx
sudo iptables -S ORBIT-PROXY
curl -skI https://kibana.orbit-labs.space/ | head -1   # 팀원 Mac: HTTP/1.1 302
```

## 기록

| 날짜 | 작업 | 결과 |
| --- | --- | --- |
| 2026-11-10 | 적용 | 미리보기 → 적용 → 재실행 `changed=0`. nginx `10.0.0.201:443`, `ORBIT-PROXY` 적용·저장 |
| 2026-11-10 | 접속 확인 | `wazuh-ui`·`kibana` 302, `grafana` 502(Grafana 설치 전), 모르는 이름 연결 끊김. Kibana `server.publicBaseUrl` 서비스 이름으로 변경 |