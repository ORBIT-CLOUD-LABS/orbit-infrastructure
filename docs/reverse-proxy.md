# 리버스 프록시 (rp VM 쌍 3개)

서비스와 관제 화면의 입구다. astra 위 VM 쌍 3개가 nginx와 keepalived로 VIP를 나눠 든다. 같은 `reverse_proxy` role을 쓰고, 쌍마다 다른 값은 `ansible/inventory/group_vars/rp_core.yml`, `rp_ota.yml`, `rp_cdn.yml`에 둔다.

| 쌍 | VM | VIP | 하는 일 |
| --- | --- | --- | --- |
| `rp_core` | `rp-core-1` `10.10.20.1`, `rp-core-2` `.2` | `vip-rp-svc` `10.10.20.100`, `vip-rp-int` `10.10.20.101` | TLS를 끝내고 도메인을 보고 나눔 |
| `rp_ota` | `rp-ota-1` `10.10.20.3`, `rp-ota-2` `.4` | `vip-rp-ota` `10.10.20.102` | OTA-Main 클러스터로, 응답하지 않으면 OTA-Sub로 |
| `rp_cdn` | `rp-cdn-1` `10.10.20.5`, `rp-cdn-2` `.6` | `vip-rp-cdn` `10.10.20.103` | CDN-Main 클러스터로, 응답하지 않으면 CDN-Sub로 |

## 이름

| 도메인 | DNS (Cloudflare, DNS only) | 받는 VIP | 가는 곳 |
| --- | --- | --- | --- |
| `ota.orbit-labs.space` | `10.10.20.100` | `vip-rp-svc` | rp-ota `10.10.20.102:80` → OTA-Main `10.10.41.100:30080` (장애 시 OTA-Sub `10.10.42.100:30080`) |
| `cdn.orbit-labs.space` | `10.10.20.100` | `vip-rp-svc` | rp-cdn `10.10.20.103:80` → CDN-Main `10.10.51.100:30080` (장애 시 CDN-Sub `10.10.52.100:30080`) |
| `wazuh.orbit-labs.space` | `10.10.20.101` | `vip-rp-int` | secure `https://10.10.30.3:443` (자체 서명, 확인 안 함) |
| `kibana.orbit-labs.space` | `10.10.20.101` | `vip-rp-int` | log `https://10.10.30.1:5601` (log의 efk CA로 확인, 이름 `log`) |
| `grafana.orbit-labs.space` | `10.10.20.101` | `vip-rp-int` | metric `http://10.10.30.2:3000` |

- `ota`, `cdn`은 지금 내부(io, Tailscale을 켠 팀원)에서만 쓴다. 바깥 공개(Cloudflare 프록시, Origin Rules)는 나중에 정한다.
- 서비스 도메인은 `vip-rp-svc`에서만, 관제 도메인은 `vip-rp-int`에서만 받는다. 바깥에서 들어온 443은 `vip-rp-svc`로만 오므로 관제 화면에 닿지 않는다.
- VIP마다 모르는 이름은 연결을 끊는다 (`default_server`, 444). 다른 VIP의 이름도 여기에 걸린다.
- `http://`(80)는 rp-core에서 받지 않는다. rp-ota·rp-cdn의 80은 rp-core가 넘기는 요청만 받는다.

## 경로

```
인터넷 ─공유기─▶ astra 와이파이 443 ─DNAT─▶ fw 바깥 VIP 10.10.10.254 ─DNAT─▶ vip-rp-svc 10.10.20.100:443 ─▶ vip-rp-ota/cdn :80 ─▶ 클러스터 입구 VIP :30080 (Traefik)
팀원 ─Tailscale─▶ astra ─▶ fw ─▶ vip-rp-int 10.10.20.101:443 ─▶ log, metric, secure
io 10.10.10.206, 팀원 ─▶ astra ─▶ fw ─▶ vip-rp-svc 10.10.20.100:443 (ota, cdn 내부 경로)
```

- astra의 443 DNAT은 gateway role([network.md](network.md)), fw의 DNAT과 구역 사이 허용은 fw role([fw.md](fw.md))이 맡는다.
- rp-core에서 관측 VM으로 가는 요청은 같은 L2의 직접 경로로 간다. log 5601, metric 3000은 rp-core 주소(`10.10.20.1`·`.2`)를 허용한다 (efk, lgtm role).
- nginx는 VIP에만 listen한다. 대기 쪽도 같은 VIP에 listen하도록 `net.ipv4.ip_nonlocal_bind=1`을 둔다.
- 방화벽 체인 `ORBIT-PROXY`가 `lo`, `enp1s0` 밖에서 오는 포트(rp-core 443, rp-ota·rp-cdn 80)를 버린다.

## VIP (keepalived)

- 쌍의 `-1`이 우선순위 150, `-2`가 100이다. 평소 `-1`이 VIP를 들고, `-1`이 다시 뜨면 VIP를 되찾는다.
- `-1`의 nginx가 멈추거나(2초 간격 확인, 두 번 실패) VM이 멈추면 `-2`가 VIP를 넘겨받는다.
- 같은 L2에 VRRP가 여럿(fw, rp 쌍 3개)이라 짝에게만 보내고(`unicast_peer`), `virtual_router_id`를 쌍마다 다르게 둔다: rp_core 100, rp_ota 102, rp_cdn 103 (VIP 끝자리). fw는 254, 클러스터 입구는 41·42·51·52.
- rp-core의 두 VIP는 한 묶음으로 함께 넘어간다.

## Main·Sub 전환 (rp_ota, rp_cdn)

nginx upstream의 `backup`이다. Main에 3초 안에 연결되지 않거나 502·503·504를 받으면 그 요청을 Sub로 다시 보내고, Main을 10초 동안 빼 둔다. Main이 돌아오면 다시 Main으로 보낸다.

## 플레이북

astra 개인 계정으로 실행한다 ([개인 계정 문서](personal-accounts.md#ansible-실행)).

```bash
cd ~/orbit-infrastructure/ansible
../scripts/orbit-ssh-cert.sh                      # Vault 토큰 (8시간)
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)    # Cloudflare 토큰을 Vault에서 읽음 (rp_core)
ansible-playbook playbooks/reverse-proxy.yml -K --check --diff   # 미리보기
ansible-playbook playbooks/reverse-proxy.yml -K --diff           # 적용. 다시 실행하면 changed=0
unset VAULT_TOKEN
```

관제 사이트를 추가할 때는 `group_vars/rp_core.yml`의 `rproxy_sites`에 한 항목을 더하고(`name`은 앞부분만, `listen: 10.10.20.101`), Cloudflare에 `<앞부분>.orbit-labs.space`를 `10.10.20.101`로 등록한다. 와일드카드 인증서라 다시 받지 않는다.

## 인증서

| 항목 | 값 |
| --- | --- |
| 이름 | `*.orbit-labs.space` (certbot 인증서 이름 `orbit-labs.space`) |
| 발급 | Let's Encrypt, DNS-01. rp-core-1, rp-core-2가 각자 발급하고 각자 갱신한다. certbot Cloudflare 플러그인이 `_acme-challenge` TXT 레코드를 만들고 지움. 서버를 밖에 열지 않음 |
| 파일 | rp-core 각자 `/etc/letsencrypt/live/orbit-labs.space/fullchain.pem`, `privkey.pem` |
| 갱신 | 패키지의 `certbot.timer`(하루 두 번, 만료 30일 전부터). 갱신되면 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`가 nginx reload |
| Cloudflare 토큰 | API Token `orbit-astra-certbot-dns`, 권한 Zone → DNS → Edit, 대상 zone `orbit-labs.space` 하나, 만료 2027-11-10. Vault `secret/orbit/infra/cloudflare`의 `dns_api_token`. role이 Vault 호스트(`hvault_host`)에서 읽어 rp-core의 `/etc/letsencrypt/cloudflare.ini`(root `0600`)에 둠 |
| 되돌리기 | `rproxy_tls_mode: selfsigned`로 바꿔 적용하면 자체 서명 인증서(`/etc/nginx/tls`)로 돌아감 |

토큰 넣기와 바꾸기 (Vault CLI가 있는 곳. 토큰은 화면과 history에 남기지 않음, [vault.md](vault.md)):

```bash
export VAULT_TOKEN=$(cat ~/.orbit/vault-token)
read -rs CF && printf '%s' "$CF" | vault kv put -mount=secret orbit/infra/cloudflare dns_api_token=- ; unset CF
```

- 토큰이 만료되면 인증서 갱신이 실패하고, 마지막 인증서가 끝나는 날(최대 90일 뒤) 경고가 다시 뜬다. 만료일(2027-11-10) 전에 아래 방법으로 바꾼다.
- 바꿀 때: Cloudflare에서 새 토큰을 만들고 위 명령으로 넣은 뒤 플레이북을 적용한다(두 rp-core의 자격 증명 파일이 바뀜). 그다음 Cloudflare에서 옛 토큰을 지운다.
- 새었을 때: Cloudflare에서 그 토큰을 바로 지우고(Roll 또는 Delete), 새 토큰으로 위와 같이 바꾼다. 인증서 자체는 다시 받을 필요가 없다.

확인 (rp-core 각자):

```bash
sudo certbot certificates                 # 이름, 도메인, 만료일
sudo certbot renew --dry-run              # 갱신 시험 (실제로 바꾸지 않음)
systemctl list-timers certbot.timer       # 다음 갱신 시도 시각
```

## 확인

```bash
ip -br addr show enp1s0                   # rp VM: VIP를 든 쪽에 VIP가 보임
sudo ss -lntp | grep nginx                # rp VM: VIP의 443 또는 80
sudo iptables -S ORBIT-PROXY
journalctl -u keepalived -n 20 --no-pager # MASTER, BACKUP 전환 기록
curl -sI https://kibana.orbit-labs.space/ | head -1   # 팀원 Mac (Tailscale): HTTP/1.1 302
```

## 기록

| 날짜 | 작업 | 결과 |
| --- | --- | --- |
| 2026-11-10 | astra nginx 적용 | 미리보기 → 적용 → 재실행 `changed=0`. nginx `10.0.0.201:443`, `ORBIT-PROXY` 적용·저장 |
| 2026-11-10 | 접속 확인 | `wazuh-ui`·`kibana` 302, `grafana` 502(Grafana 설치 전), 모르는 이름 연결 끊김. Kibana `server.publicBaseUrl` 서비스 이름으로 변경 |
| 2026-11-10 | Cloudflare 토큰 | `orbit-astra-certbot-dns` 발급(만료 2027-11-10), Vault 저장 |
| 2026-11-10 | Let's Encrypt 적용 | staging 발급 확인 뒤 정식 발급(`*.orbit-labs.space`, 만료 2027-02-08), 재실행 `changed=0`, staging 인증서 삭제, `renew --dry-run` 성공 |
| 2026-11-?? | rp VM 쌍으로 이전 | (적용, 재실행 `changed=0`, 관제 도메인 응답, rp-core-1 중지 시 이어짐, `vip-rp-svc`로 관제 도메인 요청 끊김을 적음) |
