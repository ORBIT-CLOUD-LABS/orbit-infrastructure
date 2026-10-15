# SOL File Storage·CDN Vagrant VM

> Phase1 에서는 이 구성을 사용하지 않는다. 펌웨어 원본은 `astra-nfs`, CDN 은 orbit-astra Kubernetes 안의 Origin·Edge 로 대체했다. 기준은 orbit 레포 `docs/phase1.md`.

ORBIT-SOL에서 QEMU/KVM, libvirt와 Vagrant로 CDN VM과 원본 파일 저장소 VM을 생성합니다. 이 구성은 VM과 기본 OS 설정만 관리하며 CDN·SeaweedFS 서비스 설치는 포함하지 않습니다.

## VM 명세

| VM | 역할 | vCPU | RAM | OS disk | Data disk | 서비스 IP |
|---|---|---:|---:|---:|---:|---|
| `orbit-sol-cdn` | CDN cache | 4 | 6GiB | 20GiB | 50GiB `qcow2` cache | `192.168.101.100` |
| `orbit-sol-storage` | Origin storage | 2 | 4GiB | 20GiB | 80GiB `qcow2` persistent | `192.168.101.101` |

- Box: `cloud-image/ubuntu-24.04`, version `20260926.0.0`, libvirt amd64
- Service network: `orbit-sol-net`, `192.168.101.0/24`, gateway `192.168.101.1`, NAT
- Dynamic DHCP range: `192.168.101.200`~`192.168.101.249`
- CDN MAC: `52:54:00:01:01:64`
- Storage MAC: `52:54:00:01:01:65`

Vagrant-libvirt는 `vagrant ssh`와 provisioner 실행을 위해 기본 management network NIC를 추가합니다. `192.168.101.x` NIC는 서비스 통신용이며, 다른 물리 호스트에서는 별도 route나 port forwarding 없이는 직접 접근할 수 없습니다.

## 사전 조건

실행 위치는 ORBIT-SOL입니다. SOL에는 Ansible과 Terraform을 설치하지 않습니다.

```bash
# KVM과 현재 route 확인
ls -l /dev/kvm
ip route show table all

# 기존 libvirt 자원 확인
virsh -c qemu:///system list --all
virsh -c qemu:///system net-list --all
virsh -c qemu:///system pool-list --all

# 실행 도구 확인
vagrant --version
vagrant plugin list
```

다음을 충족해야 합니다.

- 현재 사용자가 `/dev/kvm`과 `qemu:///system`에 접근할 수 있음
- `192.168.101.0/24`와 겹치는 route·libvirt network가 없음
- `default` storage pool이 active 상태이며 VM disk를 저장할 여유 공간이 있음
- `vagrant-libvirt` plugin이 설치됨

`default` storage pool의 상태와 실제 경로를 확인합니다.

```bash
virsh -c qemu:///system pool-info default
virsh -c qemu:///system pool-dumpxml default
```

## SSH 공개키

기본값은 `~/.ssh/id_ed25519.pub`입니다. 다른 공개키를 사용하려면 파일 경로나 공개키 내용을 지정합니다.

```bash
export ORBIT_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/orbit.pub"
```

또는:

```bash
export ORBIT_SSH_PUBLIC_KEY="$(< "$HOME/.ssh/orbit.pub")"
```

Private key, password와 token은 Vagrantfile이나 저장소에 넣지 않습니다.

## 정적 검증

```bash
cd vagrant/sol
vagrant validate
VAGRANT_DEFAULT_PROVIDER=libvirt vagrant status
```

## 생성

처음에는 한 대씩 생성합니다.

```bash
vagrant up orbit-sol-storage --provider=libvirt
vagrant up orbit-sol-cdn --provider=libvirt
```

상태와 접속을 확인합니다.

```bash
vagrant status
virsh -c qemu:///system list --all
vagrant ssh orbit-sol-storage
vagrant ssh orbit-sol-cdn
```

`orbit` 계정의 공개키 접속도 별도로 확인합니다. 기본 공개키와 짝이 되는 private key가 다른 경로라면 `ORBIT_SSH_PRIVATE_KEY_FILE`을 지정합니다.

```bash
export ORBIT_SSH_PRIVATE_KEY_FILE="${ORBIT_SSH_PRIVATE_KEY_FILE:-$HOME/.ssh/id_ed25519}"
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -i "$ORBIT_SSH_PRIVATE_KEY_FILE" orbit@192.168.101.100 'hostname && sudo -n true'
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -i "$ORBIT_SSH_PRIVATE_KEY_FILE" orbit@192.168.101.101 'hostname && sudo -n true'
```

각 VM에서 자원과 disk를 확인합니다.

```bash
hostnamectl
nproc
free -h
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,SERIAL
ip -brief address
ip route
```

정상 상태:

- CDN cache disk가 `/dev/vdb`이고 `/var/cache/orbit-cdn`에 mount됨
- Storage data disk가 `/dev/vdb`이고 `/srv/orbit-storage`에 mount됨
- `orbit` 계정으로 공개키 SSH와 비밀번호 없는 sudo를 사용할 수 있음
- 서비스 IP가 VM 명세와 일치함

`machine_virtual_size`는 가상 OS disk를 20GiB로 만들지만 guest filesystem 확장을 보장하지 않습니다. `lsblk`와 `df -h /` 결과가 다르면 VM을 서비스에 사용하기 전에 root partition과 filesystem 확장 여부를 확인합니다.

## 디스크 수명주기

OS disk와 CDN cache disk는 Vagrant가 관리하므로 `vagrant destroy` 때 삭제됩니다. CDN cache는 원본 데이터가 아니므로 VM 재생성 후 다시 채웁니다.

Storage data disk는 `default` storage pool에 다음 volume 이름으로 생성합니다.

```text
orbit-sol-storage-data.qcow2
```

Vagrantfile은 상대 volume 이름과 `allow_existing: true`를 사용합니다. 따라서 Storage VM을 삭제해도 이 volume은 남고, VM을 다시 만들면 기존 disk를 재연결합니다. 기존 filesystem이 있으면 다시 포맷하지 않습니다. 실제 host 경로는 storage pool 설정에 따라 결정됩니다.

삭제·재생성 검증에는 폐기 가능한 데이터만 사용합니다.

```bash
# Storage data disk에 검증 파일 생성
vagrant ssh orbit-sol-storage -c 'sudo -u orbit touch /srv/orbit-storage/recreate-test'

# VM과 Vagrant 관리 disk 삭제
vagrant destroy

# 영구 data volume이 남았는지 확인
virsh -c qemu:///system vol-info \
  --pool default orbit-sol-storage-data.qcow2
virsh -c qemu:///system vol-path \
  --pool default orbit-sol-storage-data.qcow2

# 재생성 후 검증 파일 확인
vagrant up orbit-sol-storage --provider=libvirt
vagrant ssh orbit-sol-storage -c 'test -f /srv/orbit-storage/recreate-test'
```

Storage data disk는 운영 데이터 백업을 확인한 뒤 명시적으로만 삭제합니다. `vagrant destroy`로 삭제되지 않는 것이 정상입니다.

## 중지와 재시작

```bash
vagrant halt
vagrant up --provider=libvirt
```

## 참고자료

- [Vagrant Multi-Machine](https://developer.hashicorp.com/vagrant/docs/multi-machine)
- [vagrant-libvirt Configuration](https://vagrant-libvirt.github.io/vagrant-libvirt/configuration.html)
- [cloud-image/ubuntu-24.04](https://portal.cloud.hashicorp.com/vagrant/discover/cloud-image/ubuntu-24.04)
