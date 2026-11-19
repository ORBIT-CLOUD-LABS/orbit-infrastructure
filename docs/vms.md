# VM 만들기 (libvirt role)

물리 호스트(astra와 노트북 5대)마다 자기 VM을 KVM으로 만든다. 주소와 구역은 [network.md](network.md)를 따른다.

- 플레이북: `ansible/playbooks/vms.yml` (role `libvirt`, 끝에 `base`)
- 값: `ansible/inventory/hosts.yml`(VM마다 `vm_host`, `lan_ip`, `vm_mac`, 자원), `ansible/inventory/group_vars/k3s.yml`(클러스터 VM 자원), `ansible/roles/libvirt/defaults/main.yml`

## 어느 호스트에 무엇을 만드는가

| 물리 호스트 | VM |
| --- | --- |
| astra | `vault`, `fw-1`·`fw-2`, `rp-core-1`·`2`, `rp-ota-1`·`2`, `rp-cdn-1`·`2`, `secure` |
| sol | `ota-main-1`~`3` |
| mercury | `ota-sub-1`~`3` |
| vesper | `cdn-main-1`~`3` |
| terra | `cdn-sub-1`~`3` |
| luna | `log`, `metric` |

- 실행할 때 `-e vm_pattern=<인벤토리 패턴>`으로 만들 VM을 정한다(필수). role은 패턴에 든 VM 중 `vm_host`가 자기인 것만 만들고, 고른 VM이 없는 호스트는 KVM 설치도 하지 않고 건너뛴다.
- 이미 있는 VM(`virsh dominfo`로 확인)은 다시 만들지 않는다. 사양 변경은 아직 수동(`virsh`)이다.
- VM은 Ubuntu 24.04 서버 클라우드 이미지 하나로 만들고, 첫 부팅 때 cloud-init이 이름, `orbit` 계정, 네트워크를 넣는다.

## VM 네트워크 (`network-config.j2`)

| VM | NIC | 주소 | 기본 경로 | 그 밖의 경로 |
| --- | --- | --- | --- | --- |
| fw 쌍 | 안쪽 `enp1s0`(`br0`), 바깥 `enp2s0`(astra 바깥 브리지 `outer_bridge`) | 안쪽: 관리 구역 `lan_ip`와 `zone_ips`(구역 6개의 `.252`·`.253`). 바깥: `outer_ip` | 바깥 NIC로 astra 바깥 다리 `10.10.10.200` | 없음. 구역 게이트웨이 VIP `.254`는 keepalived가 붙임 |
| 관측 VM | `enp1s0`(`br0`) | `lan_ip` | 자기 구역 `.254` | `10.10.0.0/16` 직접 (요청과 응답이 방화벽을 거치지 않게) |
| 나머지 | `enp1s0`(`br0`) | `lan_ip` | 자기 구역 `.254` (방화벽 VIP) | 관측 구역 `10.10.30.0/24` 직접 |

- 첫 부팅의 cloud-init은 패키지(`qemu-guest-agent`) 설치에 인터넷이 필요하다. fw 쌍은 바깥 다리로 바로 나가고, 나머지 VM은 방화벽 쌍이 게이트웨이 VIP를 들고 있어야 나간다.

## 실행

`vault.yml`(VM `orbit` 계정의 sudo 비밀번호 해시)이 필요해서 astra의 `orbit` 계정으로 실행한다 ([personal-accounts.md](personal-accounts.md#ansible-실행)).

```bash
ansible-playbook playbooks/vms.yml -K --ask-vault-pass --private-key ~/.ssh/orbit_ansible -e vm_pattern=fw --check --limit vm_hosts   # 미리보기. 아직 없는 VM에는 접속하지 않게
ansible-playbook playbooks/vms.yml -K --ask-vault-pass --private-key ~/.ssh/orbit_ansible -e vm_pattern=fw
```

| 순서 | `vm_pattern` | 언제 |
| --- | --- | --- |
| 1 | `fw` | 물리 호스트 네트워크(`br0`, 바깥 브리지) 뒤 |
| 2 | `'vms:!obs'` | 방화벽 쌍 구성 뒤. astra의 옛 관측 VM(efk, lgtm, wazuh)을 먼저 끔 |
| 3 | `obs` | 관측 VM을 새로 구성할 때 |

플레이북은 세 단계다. 물리 호스트에 VM 만들기, 이번 패턴의 VM 접속과 이름 확인, 물리 호스트와 이번 VM에 `base`(이름, `/etc/hosts`, 시간대). 대상이 전체가 아니라서 astra의 호스트 키 목록(`/etc/ssh/ssh_known_hosts`)은 바뀌지 않는다.

만든 뒤 같은 패턴으로 SSH 인증서와 개인 계정을 넣는다. 개인 계정 접근 목록(`group_vars/all/personal-accounts.yml`)에는 VM이 미리 들어 있다.

```bash
ansible-playbook playbooks/ssh-ca.yml -K --ask-vault-pass --private-key ~/.ssh/orbit_ansible --limit fw
ansible-playbook playbooks/personal-accounts.yml -K --ask-vault-pass --private-key ~/.ssh/orbit_ansible --limit fw
```

## 확인

```bash
virsh list --all                           # 그 호스트의 VM만 running
virsh domiflist fw-1                       # fw: br0와 바깥 브리지에 NIC 2개
ansible fw -m ansible.builtin.ping --private-key ~/.ssh/orbit_ansible
```

## 자원

| 호스트 | VM | vCPU / 메모리(GB) / 디스크(GB) |
| --- | --- | --- |
| astra | `vault` | 1 / 2 / 20 |
| astra | `fw-1`, `fw-2` | 2 / 2 / 10 씩 |
| astra | `rp-core-1`, `rp-core-2` | 2 / 2 / 20 씩 |
| astra | `rp-ota-*`, `rp-cdn-*` | 1 / 1 / 10 씩 |
| astra | `secure` | 4 / 12 / 60 |
| 클러스터 노트북 4대 | 클러스터 VM 3대 | 4 / 8 / 50 씩 |
| luna | `log`, `metric` | 4 / 14 / 90, 4 / 10 / 60 |

VM 전체의 CPU 우선순위는 호스트보다 낮다(`machine.slice` `CPUWeight=50`).
