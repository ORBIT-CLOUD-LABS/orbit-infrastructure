# 방화벽 쌍 (fw role)

구역 사이 통신이 지나는 방화벽 쌍 fw-1, fw-2를 다룬다. 둘 다 astra 위 VM이다. 물리 호스트의 주소와 astra NAT는 [network.md](network.md)에 둔다.

- 플레이북: `ansible/playbooks/fw.yml` (role `fw`)
- 값: `ansible/inventory/hosts.yml`(`lan_ip`, `outer_ip`, `zone_ips`), `ansible/inventory/group_vars/fw.yml`, `ansible/roles/fw/defaults/main.yml`(장치 이름, 포트)

## 주소

| 구역 | 대역 | fw-1 | fw-2 | VIP (게이트웨이) | NIC |
| --- | --- | --- | --- | --- | --- |
| 관리 | `10.10.0.0/24` | `.252` | `.253` | `.254` | 안쪽 `enp1s0` |
| 리버스 프록시 | `10.10.20.0/24` | `.252` | `.253` | `.254` | 안쪽 `enp1s0` |
| 관측 | `10.10.30.0/24` | `.252` | `.253` | `.254` | 안쪽 `enp1s0` |
| 클러스터 4개 | `10.10.41.0/24`, `.42`, `.51`, `.52` | `.252` | `.253` | `.254` | 안쪽 `enp1s0` |
| 바깥 | `10.10.10.0/24` | `.252` | `.253` | `.254` (바깥 VIP) | 바깥 `enp2s0` |

- 안쪽 NIC는 astra `br0`, 바깥 NIC는 astra 바깥 브리지에 붙는다. 주소는 VM을 만들 때 cloud-init이 넣고(libvirt role), VIP는 keepalived가 붙인다.
- fw의 기본 경로는 바깥 NIC로 astra 바깥 다리 `10.10.10.200`이다.
- 관측 구역으로 가는 수집은 방화벽을 거치지 않는다(각 호스트의 직접 경로). 관측 VM도 모든 구역으로 직접 보낸다.

## 규칙 (nftables)

`/etc/nftables.conf` 하나에 모두 있다. 파일 첫 줄이 `flush ruleset`이라 다시 읽으면 전체를 바꾼다. iptables로 넣은 규칙도 함께 지워지므로 fw에서는 다른 role의 iptables 단계를 쓰지 않는다.

통과(forward)는 기본 차단이고 아래만 허용한다. 응답(`established`, `related`)은 모두 허용한다.

| 출발 | 도착 | 포트 | 용도 |
| --- | --- | --- | --- |
| astra (`10.10.0.200`, `10.10.10.200`) | 모든 구역 | tcp 22, ping | Ansible, 관리 접속 |
| astra | 클러스터 구역 (API VIP `.100`) | tcp 6443 | `kubectl` |
| Tailscale 접속 (astra `10.10.10.200`으로 보임) | `vip-rp-int` `10.10.20.101` | tcp 443 | 관제 화면 |
| 바깥 구역 `10.10.10.0/24` (io, astra·Tailscale 접속) | `vip-rp-svc` `10.10.20.100` | tcp 443 | 서비스 (`ota`, `cdn`은 지금 내부에서만 씀) |
| 바깥 VIP `10.10.10.254`로 들어온 요청 | `vip-rp-svc` `10.10.20.100` | tcp 443 | 서비스 입구 (DNAT, SNAT) |
| 클러스터 구역 | Vault `10.10.0.1` | tcp 8200 | ESO, 인증 |
| Vault | 클러스터 구역 | tcp 6443 | Kubernetes 인증 |
| rp-ota | OTA-Main·Sub 입구 VIP `10.10.41.100`, `10.10.42.100` | tcp 30080·30443 | 서비스 (Traefik NodePort) |
| rp-cdn | CDN-Main·Sub 입구 VIP `10.10.51.100`, `10.10.52.100` | tcp 30080·30443 | 서비스 (Traefik NodePort) |
| rp-core | OTA-Main VIP `10.10.41.100` | tcp 31235 | Hubble UI (NodePort) |
| 클러스터 구역 | 클러스터 구역 | tcp 4240·4244·32379, udp 8472, ping | Cluster Mesh |
| 모든 구역 | 인터넷 | tcp 53·80·443, udp 53·123, ping | DNS, NTP, 패키지, 이미지 |
| 관리 구역 | 인터넷 | udp 3478, udp 출발 41641 | 물리 호스트의 Tailscale 직접 연결 |
| 클러스터 구역 | AWS `10.20.0.0/16` (VPN 터널만) | tcp 3306·443 | RDS, S3 엔드포인트 |

- 같은 구역 안의 통신은 fw를 지나지 않는다.
- 터널이 없는 동안 AWS 대역으로 가는 것은 모두 버린다(`rt ipsec missing`).
- 버리는 패킷은 분당 10개까지 커널 로그에 `orbit-fw drop:`으로 남는다 (`sudo journalctl -k -g orbit-fw`).

주소 변환:

| 규칙 | 내용 | 이유 |
| --- | --- | --- |
| DNAT | 바깥 NIC로 `10.10.10.254:443`에 온 요청을 `10.10.20.100:443`으로 | astra가 와이파이로 들어온 443을 바깥 VIP로 넘김 |
| SNAT | 그 요청의 출발지를 `10.10.20.254`로 | 응답이 fw를 거쳐 돌아오고, fw가 넘어가도 같은 주소 |
| SNAT | 구역에서 바깥 NIC로 인터넷에 나가는 것의 출발지를 `10.10.10.254`로 | astra가 관리·관측 구역에 직접 닿아 있어, 없으면 응답이 fw를 건너뛰어 상태 추적에 막힘 |

fw 자신(input)은 ping, astra의 SSH, 짝의 VRRP·conntrackd, metric의 node-exporter 수집(tcp 9100)만 받는다. 나가는 것(output)은 막지 않는다.

ICMP redirect는 보내지 않는다(`send_redirects=0`). 모든 구역이 안쪽 NIC 하나에 있어서, 켜 두면 fw가 상대에게 직접 보내라고 알려 통신이 방화벽을 건너뛴다.

## 이중화 (keepalived, conntrackd)

- keepalived 인스턴스 하나에 VIP 8개(구역 7개의 `.254`, 바깥 `10.10.10.254`)를 넣어 함께 넘어간다. VRID `254`, 쌍끼리 unicast, 평소에는 fw-1(우선순위 150)이 가진다. fw-1이 돌아오면 다시 가져간다.
- 바깥 NIC가 끊겨도 FAULT가 되어 VIP를 내려놓는다.
- 상태가 바뀌면 `/usr/local/sbin/orbit-fw-notify.sh`가 conntrackd 동기화를 전환하고(conntrackd 예제 `primary-backup.sh`와 같은 순서) strongSwan을 켜거나 끈다. 기록: `sudo journalctl -t orbit-fw`
- conntrackd는 FTFW 방식으로 관리 구역 주소끼리 UDP 3780으로 연결 상태를 맞춘다. VIP를 넘겨받은 쪽이 기존 연결을 이어 받는다.

## AWS VPN (strongSwan)

- `charon-systemd`(swanctl, `strongswan.service`)를 설치만 하고 부팅할 때 켜지지 않게 둔다. VIP를 가진 쪽에서만 알림 스크립트가 켠다.
- 터널 설정(`/etc/swanctl/conf.d/`), 사전 공유 키, 연결 확인은 AWS 쪽 VPN 연결과 customer gateway를 만든 뒤 따로 한다. 터널은 fw 쪽에서 먼저 연결한다(강의실 외부 포트로는 들어오는 연결을 받지 않음). NAT 뒤라 NAT-T(UDP 4500)로 동작한다.

## 적용

astra 개인 계정에서 실행한다. 한 대씩, 대기 쪽(fw-2)부터 적용한다.

```bash
cd ~/orbit-infrastructure/ansible
ansible-playbook playbooks/fw.yml -K --check --diff
ansible-playbook playbooks/fw.yml -K
```

- 규칙 파일은 `nft -c`, keepalived 설정은 `keepalived -t`로 검사한 뒤에만 바꾼다.
- keepalived 설정이 바뀌면 재시작한다. fw-1을 재시작하면 VIP가 잠깐 fw-2로 넘어갔다 돌아온다.

## 확인

```bash
ssh fw-1 'ip -br addr show enp1s0; ip -br addr show enp2s0'   # VIP .254가 fw-1에만
ssh fw-1 'sudo nft list ruleset | head -20'
ssh fw-1 'sudo conntrackd -s | head'
```

## 규칙을 잘못 넣어 접속이 끊겼을 때

astra에서 VM 콘솔로 들어간다 (`orbit` 계정, sudo 비밀번호).

```bash
sudo virsh console fw-1
```

```bash
sudo nft flush ruleset
```

- 규칙이 모두 없어져 모든 통신이 허용된다. 원인을 고친 뒤 fw 플레이북을 다시 실행한다.
- 콘솔에서 나오기: `Ctrl` + `]`

## 기록

| 날짜 | 작업 | 결과 |
| --- | --- | --- |
| 2026-11-?? | fw 쌍 구성 | (규칙, VIP 전환, 노트북 경로 전환 결과를 적음) |
