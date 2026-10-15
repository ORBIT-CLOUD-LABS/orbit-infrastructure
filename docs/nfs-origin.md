# ASTRA NFS 원본 저장소 구성·검증

- 상태: Team Review
- 작성일: 2026-10-15
- 수정일: 2026-10-15
- 관련 이슈: [#43](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/43)

Phase1에서는 Ansible 없이 VM에 직접 구성합니다. 이 문서는 실제 적용한 설정과 다시 확인할 절차를 기록합니다. 원본 저장소는 `astra-nfs`, 서버·Origin의 PV·PVC와 Nginx 배포는 [orbit-gitops #9](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/9)에서 관리합니다.

## 구성과 적용값

| 항목 | 적용값 |
| --- | --- |
| NFS 서버 | `astra-nfs`, `192.168.100.105`, Ubuntu 24.04.5 LTS |
| 데이터 디스크 | `/dev/vdb`, 45GiB, ext4 |
| 데이터 마운트 | `/srv/nfs` |
| 파일시스템 UUID | `3e0288f1-3743-4484-8d74-9a45f12cd380` |
| export | `/srv/nfs/origin` |
| 허용 클라이언트 | worker1 `.102`, worker2 `.103`, worker3 `.104` |
| 원본 소유권 | UID/GID `10001:10001`, 디렉터리 `0755`, 파일 `0644` |
| 마운트 검증 옵션 | `vers=4.1,hard,rw` |

서버 Pod는 NFS에 쓰고 Origin Pod는 같은 원본을 읽습니다. 같은 worker에 배치될 수 있어 NFS의 클라이언트 IP로 두 Pod를 구분하지 않습니다. export는 `rw`로 두고 Origin의 쓰기 금지는 #9의 PV·volumeMount 읽기 전용 설정으로 보장합니다. Edge는 NFS를 직접 마운트하지 않습니다.

## 최초 설치: 빈 디스크를 새로 준비할 때만 수행합니다

**현재 구성된 VM에서는 포맷을 다시 실행하지 않습니다.** 아래 초기화는 `/dev/vdb`가 사용 이력 없는 데이터 디스크임을 확인한 뒤 한 번 수행한 작업입니다. 디스크 이름·크기만으로 초기화 대상을 결정하지 않습니다.

ASTRA에서 `ssh orbit@192.168.100.105`로 접속해 먼저 확인합니다.

```bash
hostname
lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS
sudo wipefs --no-act /dev/vdb
sudo blkid -p /dev/vdb
sudo ls -la /sys/class/block/vdb/holders
findmnt -rn -S /dev/vdb
```

기존 파일시스템·파티션·LVM/RAID 서명·holders·마운트가 있거나 판별이 불명확하면 중단합니다. `/dev/vda`는 OS 디스크입니다. 이번에는 위 사용 흔적이 없는 45GiB `/dev/vdb`를 확인하고 다음을 실행했습니다.

```bash
# 새 빈 디스크에만 실행합니다. 현재 VM에서는 재실행하지 않습니다.
sudo mkfs.ext4 /dev/vdb
sudo install -d -m 0755 /srv/nfs
sudo blkid /dev/vdb
```

기존 `/etc/fstab`을 `/etc/fstab.before-orbit-nfs43`로 백업하고 다음 항목을 추가했습니다. 새 VM에서는 위에 기록된 UUID를 복사하지 않고 그 디스크에서 조회한 UUID를 사용합니다. 기존 fstab 항목과 같은 마운트 지점의 중복을 확인합니다.

```text
UUID=3e0288f1-3743-4484-8d74-9a45f12cd380 /srv/nfs ext4 defaults,nofail 0 2
```

`sudo mount /srv/nfs` 후 `findmnt --mountpoint /srv/nfs`로 실제 디스크를 확인하고 원본 디렉터리를 생성합니다. 마운트가 안 된 OS 경로에 파일을 만들지 않습니다.

## NFS 서버와 worker 클라이언트를 구성합니다

다음 명령은 NFS VM에서 실행합니다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-kernel-server
sudo install -d -o 10001 -g 10001 -m 0755 /srv/nfs/origin /srv/nfs/origin/firmware
sudo install -d -m 0755 /etc/exports.d /etc/systemd/system/nfs-server.service.d
sudoedit /etc/exports.d/orbit-origin.exports
```

export 파일에는 아래 한 줄을 저장합니다. 기존 다른 export를 덮어쓰지 않으며 client IP와 괄호 사이에 공백을 넣지 않습니다.

```text
/srv/nfs/origin 192.168.100.102(rw,sync,root_squash,no_subtree_check) 192.168.100.103(rw,sync,root_squash,no_subtree_check) 192.168.100.104(rw,sync,root_squash,no_subtree_check)
```

`sudoedit /etc/systemd/system/nfs-server.service.d/orbit-data-mount.conf`로 다음 내용을 저장합니다. `nofail`로 부팅은 계속하더라도 NFS 서버는 데이터 마운트에 의존하도록 구성합니다.

```ini
[Unit]
RequiresMountsFor=/srv/nfs

[Service]
ExecStartPre=/usr/bin/mountpoint -q /srv/nfs
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable nfs-server
sudo systemctl restart nfs-server
sudo exportfs -ra
```

`root_squash`를 유지하고 원본 소유권으로 서버 쓰기를 허용합니다. `0777`·`no_root_squash`로 우회하지 않습니다. `sec=sys`는 UID를 신뢰하므로 이 설정을 강력한 사용자 인증으로 표현하지 않습니다. 기존 UFW는 inactive였으며 이번 작업에서 방화벽을 일괄 활성화하거나 규칙을 변경하지 않았습니다. export 허용 목록은 별도로 위 세 IP에 제한했습니다.

각 worker(`192.168.100.102~104`)에 접속해 실행합니다. 컨테이너가 아닌 worker OS에 설치합니다. kubelet이 NFS 볼륨을 마운트하기 때문입니다.

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
command -v mount.nfs
```

worker fstab에는 NFS 마운트를 추가하지 않았습니다. 실제 Pod용 마운트는 #9의 PV·PVC로 연결합니다.

## 기존 구성 확인: 포맷·재설치 없이 조회합니다

NFS VM에서 실행합니다.

```bash
findmnt --mountpoint /srv/nfs
sudo blkid /dev/vdb
sudo findmnt --verify --verbose
sudo exportfs -v
systemctl is-active nfs-kernel-server
systemctl is-enabled nfs-server
systemctl show nfs-server -p RequiresMountsFor
sudo stat -c '%u:%g %a %n' /srv/nfs/origin /srv/nfs/origin/firmware
```

`nfs-kernel-server`는 alias이므로 `is-enabled` 조회는 정식 unit인 `nfs-server`를 사용합니다. 실제 적용에서는 active·enabled, UUID 일치, fstab 오류·경고 없음, 데이터 마운트 의존성을 확인했습니다. 재부팅 후 보존은 검증하지 않았습니다.

## worker별 읽기·쓰기·하드링크를 검증합니다

아래 명령은 worker마다 실행합니다. 마운트가 실패하면 이후 명령을 계속 실행하지 않습니다. `.issue43-check.*`는 검사 전용 임시 디렉터리입니다.

```bash
hostname
showmount -e 192.168.100.105
orbit_mount_dir=$(mktemp -d /tmp/orbit-nfs43.XXXXXX)
sudo mount -t nfs -o vers=4.1,hard,rw 192.168.100.105:/srv/nfs/origin "$orbit_mount_dir"
findmnt --mountpoint "$orbit_mount_dir"
orbit_check_dir=$(sudo setpriv --reuid=10001 --regid=10001 --clear-groups mktemp -d "$orbit_mount_dir/.issue43-check.XXXXXX")
sudo setpriv --reuid=10001 --regid=10001 --clear-groups sh -ec 'printf "issue43\n" > "$1/temp.bin"; chmod 644 "$1/temp.bin"; ln "$1/temp.bin" "$1/final.bin"' sh "$orbit_check_dir"
sudo setpriv --reuid=10001 --regid=10001 --clear-groups cmp "$orbit_check_dir/temp.bin" "$orbit_check_dir/final.bin"
sudo setpriv --reuid=10001 --regid=10001 --clear-groups stat -c '%u:%g %a inode=%i links=%h %n' "$orbit_check_dir/temp.bin" "$orbit_check_dir/final.bin"
```

inode가 같고 링크 수가 2여야 합니다. 0700 임시 디렉터리 안의 비교·stat도 UID 10001로 실행합니다. 원격 root는 squash되므로 같은 경로 접근이 거부될 수 있습니다. 별도로 export 루트의 0755·소유자 10001 조건에서 root 쓰기를 확인합니다.

```bash
orbit_root_probe="$orbit_mount_dir/.issue43-root-write-$(hostname)-$$"
sudo touch "$orbit_root_probe"
```

위 `touch`의 Permission denied가 예상 결과입니다. 성공했다면 권한·ACL·root_squash 설정을 확인하고 해당 파일만 정리합니다. 이 검증은 root가 모든 NFS 경로에서 항상 쓰기를 거부당한다는 의미가 아닙니다.

검사 후 이번에 만든 임시 파일만 UID 10001로 제거합니다. 시험용 firmware.bin은 삭제하지 않습니다.

```bash
sudo setpriv --reuid=10001 --regid=10001 --clear-groups rm -- "$orbit_check_dir/temp.bin" "$orbit_check_dir/final.bin"
sudo setpriv --reuid=10001 --regid=10001 --clear-groups rmdir -- "$orbit_check_dir"
sudo umount "$orbit_mount_dir"
rmdir -- "$orbit_mount_dir"
```

## 시험 파일과 적용 결과

NFS VM에서 시험 전용 경로를 UID/GID 10001, 디렉터리 0755로 준비하고 `dd if=/dev/urandom ... bs=1M count=64 conv=excl`로 생성했습니다. 파일은 0644로 설정했습니다. `conv=excl`은 기존 파일을 덮어쓰지 않도록 사용했습니다. 생성 시간은 부하 측정에 포함하지 않습니다.

| 항목 | 실제 값 |
| --- | --- |
| 원본 파일 | `/srv/nfs/origin/firmware/NFS43FIXTURE/1.0.0/firmware.bin` |
| Origin·Edge에서 사용할 상대 경로 | `/firmware/NFS43FIXTURE/1.0.0/firmware.bin` |
| 크기 | `67108864 byte` (64 MiB) |
| SHA-256 | `91800c95b2c809c3d1c8df22ec87e4eb593a2117f8f4fe4de148a16ffd11e2f8` |

NFS VM에서는 다음으로 확인합니다. worker에서도 임시 마운트 상태에서 동일한 상대 경로를 읽습니다.

```bash
wc -c /srv/nfs/origin/firmware/NFS43FIXTURE/1.0.0/firmware.bin
sha256sum /srv/nfs/origin/firmware/NFS43FIXTURE/1.0.0/firmware.bin
```

2026-10-15 15:40 KST까지 worker 3대 모두 NFSv4.1 마운트, UID 10001 쓰기·하드링크 생성, root 쓰기 거부를 확인했습니다. UID/GID 65534로도 시험 파일을 읽었으며 VM 로컬과 세 worker의 크기·해시가 일치했습니다. 검사 파일·임시 마운트는 정리했고 위 원본 파일은 보존했습니다.

직접 만든 파일은 DB Artifact가 아닙니다. API 업로드 시험에는 다른 model/version을 사용합니다. Origin HTTP, PVC 읽기 전용, 실제 업로드 API, 재부팅·백업·복구는 이번 결과에 포함하지 않습니다. worker taint와 Kubernetes 설정도 변경하지 않았습니다.

GitOps #9에는 위 NFS IP·export·버전·권한·시험 파일 정보를 전달합니다. `orbit/docs/phase1.md`의 공통 값은 별도 담당자가 적용 결과와 맞춰 갱신합니다.
