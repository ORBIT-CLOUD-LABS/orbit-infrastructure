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
- 인증서는 Let's Encrypt `*.orbit-labs.space` 와일드카드(90일, 자동 갱신). 브라우저 경고 없음. 아래 "인증서" 절.

## 플레이북

astra 개인 계정으로 실행한다 ([개인 계정 문서](personal-accounts.md#ansible-실행)).

```bash
cd ~/orbit-infrastructure/ansible
../scripts/orbit-ssh-cert.sh                      # Vault 토큰 (8시간)
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)    # Cloudflare 토큰을 Vault에서 읽음
ansible-playbook playbooks/reverse-proxy.yml -K --check --diff   # 미리보기
ansible-playbook playbooks/reverse-proxy.yml -K --diff           # 적용. 다시 실행하면 changed=0
unset VAULT_TOKEN
```

서비스를 추가할 때는 `roles/reverse_proxy/defaults/main.yml`의 `rproxy_sites`에 한 항목을 더하고(`name`은 앞부분만, 예: `hubble`), Cloudflare에 `<앞부분>.orbit-labs.space`를 `10.0.0.201`로 등록한다. 와일드카드 인증서라 다시 받지 않는다.

## 인증서

| 항목 | 값 |
| --- | --- |
| 이름 | `*.orbit-labs.space` (certbot 인증서 이름 `orbit-labs.space`) |
| 발급 | Let's Encrypt, DNS-01. certbot Cloudflare 플러그인이 `_acme-challenge` TXT 레코드를 만들고 지움. 서버를 밖에 열지 않음 |
| 파일 | `/etc/letsencrypt/live/orbit-labs.space/fullchain.pem`, `privkey.pem` |
| 갱신 | 패키지의 `certbot.timer`(하루 두 번, 만료 30일 전부터). 갱신되면 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`가 nginx reload |
| Cloudflare 토큰 | API Token `orbit-astra-certbot-dns`, 권한 Zone → DNS → Edit, 대상 zone `orbit-labs.space` 하나, 만료 2027-11-10. Vault `secret/orbit/infra/cloudflare`의 `dns_api_token`. astra에는 `/etc/letsencrypt/cloudflare.ini`(root `0600`) |
| 되돌리기 | `rproxy_tls_mode: selfsigned`로 바꿔 적용하면 자체 서명 인증서(`/etc/nginx/tls`)로 돌아감 |

토큰 넣기와 바꾸기 (astra. 토큰은 화면과 history에 남기지 않음):

```bash
export VAULT_ADDR=https://10.0.0.201:8200 VAULT_CACERT=/opt/vault/tls/vault-ca.crt
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)
read -rs CF && printf '%s' "$CF" | vault kv put -mount=secret orbit/infra/cloudflare dns_api_token=- ; unset CF
```

- 토큰이 만료되면 인증서 갱신이 실패하고, 마지막 인증서가 끝나는 날(최대 90일 뒤) 경고가 다시 뜬다. 만료일(2027-11-10) 전에 아래 방법으로 바꾼다.
- 바꿀 때: Cloudflare에서 새 토큰을 만들고 위 명령으로 넣은 뒤 플레이북을 적용한다(자격 증명 파일이 바뀜). 그다음 Cloudflare에서 옛 토큰을 지운다.
- 새었을 때: Cloudflare에서 그 토큰을 바로 지우고(Roll 또는 Delete), 새 토큰으로 위와 같이 바꾼다. 인증서 자체는 다시 받을 필요가 없다.

확인:

```bash
sudo certbot certificates                 # 이름, 도메인, 만료일
sudo certbot renew --dry-run              # 갱신 시험 (실제로 바꾸지 않음)
systemctl list-timers certbot.timer       # 다음 갱신 시도 시각
```

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
| 2026-11-10 | Cloudflare 토큰 | `orbit-astra-certbot-dns` 발급(만료 2027-11-10), Vault 저장 |
| 2026-11-?? | Let's Encrypt 적용 | (staging 발급 → 정식 발급, 재실행 `changed=0`, `renew --dry-run` 결과를 적음) |