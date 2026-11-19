# 물리 호스트 네트워크 (network, gateway role)

물리 호스트 6대(astra, sol, mercury, vesper, terra, luna)의 주소, 브리지, 경로와 astra의 NAT를 다룬다. 구역 사이 통신을 맡는 방화벽 쌍은 `fw.md`(방화벽 작업에서 작성)에 둔다.

- 플레이북: `ansible/playbooks/network.yml` (role `network`, astra는 `gateway`도)
- 값: `ansible/inventory/hosts.yml`, `ansible/inventory/group_vars/all/main.yml`, `ansible/inventory/group_vars/vm_hosts.yml`

## 주소

온프레미스 전체는 `10.10.0.0/16`이고 구역 하나가 `10.10.<구역>.0/24`다. 모든 구역이 스위치 하나(같은 L2)에 있다.

| 구역 | 대역 | 물리 호스트가 가진 주소 |
| --- | --- | --- |
| 관리 | `10.10.0.0/24` | astra `.200`, sol `.201`, mercury `.202`, vesper `.203`, terra `.204`, luna `.205` (브리지 `br0`) |
| 바깥 | `10.10.10.0/24` | astra `.200` (브리지 `br-outer`), io `.206` |
| 관측 | `10.10.30.0/24` | 없음. 직접 경로만 둠 |

끝자리 규칙: VM `.1`부터, VIP `.100`부터, 물리 호스트 `.200`~`.206`, 방화벽 `.252`·`.253`, 구역 게이트웨이(방화벽 VIP) `.254`.

와이파이 주소는 강의실 예약대로 astra `.200`, sol `.201`, mercury `.202`, vesper `.203`, terra `.204`, luna `.205`다.

## 호스트별 구성

| 항목 | astra | 노트북 5대 |
| --- | --- | --- |
| `br0` | 유선 포트를 넣은 브리지. 관리 구역 주소 | 같음 |
| `br-outer` | 바깥 구역 브리지. fw 쌍의 바깥 NIC와 io가 붙음 | 없음 |
| 관측 구역 경로 | `10.10.30.0/24`를 `br0`로 직접, 출발지는 관리 구역 주소 | 같음 |
| 다른 구역 경로 | `10.10.0.0/16`을 방화벽 바깥 VIP `10.10.10.254`로 | 기본 경로를 따름 |
| 기본 경로 | 와이파이 | `net_role: wifi`면 와이파이, `net_role: fw`면 관리 구역 게이트웨이 `10.10.0.254`(와이파이는 예비) |

- VM은 호스트의 `br0`에 붙어 자기 구역 주소를 쓴다. 호스트는 그 구역 주소를 갖지 않는다.
- 관측 구역으로 가는 수집은 방화벽을 거치지 않는다. 부하 시험이나 방화벽 장애 때도 수집이 끊기지 않게 하려는 것이다.
- astra는 구역 VM에게 바깥 구역 주소 `10.10.10.200`으로 보인다(관리·관측 구역 제외).

## astra NAT (gateway role)

iptables 규칙이다. Docker가 있으면 `DOCKER-USER`, 없으면 `FORWARD` 체인에 넣고 `netfilter-persistent`로 저장한다.

| 규칙 | 내용 |
| --- | --- |
| NAT | `10.10.0.0/16`에서 와이파이로 나가는 패킷의 출발지를 astra 와이파이 주소로 |
| 통과 허용 | `br0`, `br-outer`에서 와이파이로 나가는 `10.10.0.0/16`, 그 응답 |
| 브리지 안 | `br0` 안, `br-outer` 안 통신 (Docker의 `br_netfilter` 때문에 필요) |
| 443 DNAT | 와이파이로 들어온 TCP 443의 목적지를 방화벽 바깥 VIP `10.10.10.254`로. 출발지는 바꾸지 않음 ([reverse-proxy.md](reverse-proxy.md)) |
| 443 통과 허용 | 와이파이에서 `br-outer`의 `10.10.10.254`로 가는 TCP 443 |

구역 VM의 인터넷 통신은 방화벽 쌍이 바깥 VIP로 SNAT한 뒤 `br-outer`로 들어와 astra NAT를 거친다.

## 적용

`vault.yml`(와이파이 비밀번호)이 필요해서 astra의 `orbit` 계정으로, `tmux` 안에서 실행한다. 한 번에 한 대만 적용한다.

```bash
cd ~/orbit-infrastructure/ansible
ansible-playbook playbooks/network.yml -K --ask-vault-pass --private-key ~/.ssh/orbit_ansible --check --diff --limit <호스트>
ansible-playbook playbooks/network.yml -K --ask-vault-pass --private-key ~/.ssh/orbit_ansible --limit <호스트>
```

- 적용하면 이전 netplan을 `/root/netplan-backup/prev`에 두고, 확인 ping(`net_checks`)이 5분 안에 끝나지 않으면 `orbit-net-revert.sh`가 이전 설정으로 되돌린다.
- 확인 대상(`net_checks`): astra는 다른 호스트 한 대와 인터넷, 노트북은 astra와 인터넷(`net_role: wifi`) 또는 게이트웨이(`net_role: fw`).
- 호스트를 새로 넣을 때는 `hosts.yml`에 `lan_mac`, `wifi_mac`을 적는다. role이 MAC으로 장치 이름을 찾는다.

## 기록

| 날짜 | 작업 | 결과 |
| --- | --- | --- |
| 2026-11-?? | 재설계 주소 적용 | (적용 순서, 호스트별 결과, 재실행 `changed=0`을 적음) |
