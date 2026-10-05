# Ansible — ORBIT Lab 구성

Terraform이 astra에 만든 VM에 Kubernetes(kubeadm)와 인프라 서비스를 설치한다.
계획서 기준: **`terraform apply` → `ansible-playbook site.yml`, 명령 2번으로 Lab 재구축.**

## 1. 전체 구조

```
                Terraform (VM 생성)                     Ansible (VM 안에 설치)
                ───────────────────                     ──────────────────────
 astra 호스트 ─▶ astra-control-plane ┐                   common → control_plane
 (libvirt)       astra-worker-1, 2   ├─ k8s 클러스터 ◀── common → worker
                 astra-worker-3      ┘  (예비, spare)
                 astra-jenkins        ◀── jenkins     (예정)
                 astra-monitoring     ◀── monitoring  (예정)
                 astra-nfs            ◀── nfs         (예정)
                 astra-vehicle-db     ◀── db          (예정)
```

## 2. 구성 요소와 우리 팀 적용

| 구성 요소 | 의미 | ORBIT에서 |
|---|---|---|
| 제어 노드 | Ansible을 설치하고 플레이북을 실행하는 컴퓨터 | **astra 호스트** (`orbit` 계정, 각자 `~/ws-<이름>/orbit-infrastructure`) |
| 관리 노드 | 명령을 받아 작업이 수행되는 서버. 에이전트 없이 SSH | `astra-*` VM 8대. `ubuntu` 계정 + 키 인증, Python만 있으면 됨 |
| 인벤토리 | 관리 노드 목록·그룹 | `inventory/lab/hosts.ini` (실제), `inventory/test.ini` (테스트 VM) |
| 플레이북 | 어떤 그룹에 어떤 작업을 할지 순서대로 정의한 YAML | `site.yml` (전체), `preflight.yml` (사전 점검) |
| 롤 | 작업을 기능 단위로 묶은 폴더 | `roles/common`, `control_plane`, `worker` |
| 모듈 | 관리 노드에서 실제로 실행되는 작업 단위 | 아래 6번 표 |
| 변수 | 환경마다 바뀌는 값 | `group_vars/all.yml` |
| 팩트 | 실행 시 자동 수집되는 서버 정보 | preflight의 CPU·RAM·OS·디스크 점검, swap 판단 |
| 핸들러 | 변경이 있을 때만 실행되는 작업 | containerd 설정 변경 시에만 재시작 |
| Vault | 비밀값 암호화 | (예정) MySQL 비밀번호, Slack Webhook — 평문으로 Git에 올리지 않음 |

## 3. 제어 노드 (astra)

| 항목 | 값 |
|---|---|
| 접속 | 교육장 `ssh orbit@192.168.200.200`, 외부 Tailscale `ssh orbit@100.94.67.18` |
| 작업 폴더 | `~/ws-<이름>/orbit-infrastructure` — **공용 계정이라 각자 clone** |
| 설정 | `ansible/ansible.cfg` (프로젝트별). `/etc/ansible/ansible.cfg`는 수정하지 않음 |
| SSH 키 | `~/.ssh/id_ed25519` — 이 공개키가 모든 관리 노드에 등록돼 있어야 함 |

준비 상태 점검 (Ansible·SSH 키·libvirt·ansible.cfg·인벤토리·ping을 한 번에 확인):
```bash
./scripts/setup-control-node.sh
```

## 4. Terraform ↔ Ansible 연결: 인벤토리

두 도구를 잇는 건 **인벤토리 파일 하나**다. Terraform이 정한 VM 이름·IP를 Ansible이 읽어서 접속한다.

```bash
./scripts/gen-inventory.sh     # libvirt에서 astra-* VM의 IP를 읽어 inventory/lab/hosts.ini 생성
```

| VM 이름 | Ansible 그룹 |
|---|---|
| `astra-control-plane` | `control_plane` |
| `astra-worker-1`, `astra-worker-2` | `workers` |
| `astra-worker-3` | `spare` (클러스터 미포함, `SPARE=""`로 포함 가능) |
| `astra-jenkins` / `astra-monitoring` / `astra-nfs` / `astra-vehicle-db` | `jenkins` / `monitoring` / `nfs` / `db` |

`k8s` = `control_plane` + `workers` (공통 설치 대상)

**Terraform 담당과의 약속**
- VM 이름 규칙 `astra-<역할>` 유지 (그룹 판단 기준)
- 접속 계정 `ubuntu`, sudo 비밀번호 없음
- astra `orbit` 계정의 `~/.ssh/id_ed25519.pub`를 cloud-init으로 주입
- 고정 IP (재구축해도 같은 IP)

## 5. 플레이북 실행 순서 (`site.yml`)

| 순서 | 플레이 | 대상 | 내용 |
|---|---|---|---|
| 0 | Preflight | all / k8s | 설치 전 점검 (아래) |
| 1 | Common | k8s | swap 끄기, overlay·br_netfilter, sysctl, containerd(SystemdCgroup), kubelet·kubeadm·kubectl 설치·hold |
| 2 | Control plane | control_plane | `kubeadm init`, kubeconfig, Flannel, join 명령 생성 |
| 3 | Workers | workers | `kubeadm join` |
| 4 | Verify | control_plane | 모든 노드 Ready 대기, `kubectl get nodes` 출력 |

### Preflight (`preflight.yml`)

설치 도중 실패하지 않도록 **시작 전에** 조건을 확인하고, 안 맞으면 이유를 출력하고 멈춘다.

| 대상 | 점검 | 실패 시 의미 |
|---|---|---|
| all | SSH 접속, cloud-init 완료 | VM 미부팅, 키 미등록 |
| all | Ubuntu 22.04 이상 | 이미지 불일치 |
| all | `/` 여유 15GB 이상 | 디스크 부족 |
| all | `pkgs.k8s.io` 접근 | 인터넷/DNS 문제 |
| all | NTP 동기화 (경고만) | 인증서 시간 오류 가능 |
| k8s | vCPU 2개·RAM 1700MB 이상 | kubeadm 최소 요구 미달 |
| k8s | hostname·MAC·product_uuid 중복 없음 | VM을 복제해서 만든 경우 |
| k8s | 노드 간 통신 | 네트워크 분리 |
| k8s | 6443·2379·2380·10250·10257·10259 비어 있음 (설치 전만) | 다른 프로세스가 포트 사용 |

kubeadm도 `init`/`join` 직전에 자체 preflight를 수행한다. Ansible preflight는 그보다 앞에서 **VM·네트워크 조건**을 먼저 걸러낸다.

## 6. 사용 모듈

| 모듈 | 용도 | 사용 위치 |
|---|---|---|
| `wait_for_connection`, `setup` | 접속 대기, 팩트 수집 | preflight |
| `assert` | 조건 점검 후 실패 메시지 | preflight |
| `uri`, `wait_for` | 인터넷·포트·노드 간 통신 확인 | preflight |
| `apt`, `apt_repository`, `dpkg_selections` | 패키지 설치, k8s 저장소, 버전 고정 | common |
| `copy`, `replace`, `file`, `get_url` | 설정 파일 작성·수정, 키 다운로드 | common, control_plane |
| `systemd` | containerd·kubelet 실행/재시작 | common |
| `command`, `stat` | kubeadm 실행, 이미 설치됐는지 확인 | control_plane, worker |
| `set_fact`, `debug` | join 명령 전달, 결과 출력 | control_plane, verify |

## 7. 변수 (`group_vars/all.yml`)

| 변수 | 값 | 설명 |
|---|---|---|
| `ansible_user` | ubuntu | 관리 노드 접속 계정 |
| `k8s_version` | v1.33 | Kubernetes 마이너 버전 |
| `pod_cidr` | 10.244.0.0/16 | Pod 대역 (노드망과 겹치면 안 됨) |
| `flannel_manifest` | 공식 manifest URL | CNI |
| `preflight_*` | 15GB, 포트 목록 | preflight 기준값 |
| `join_command` | (실행 중 생성) | control_plane에서 `set_fact` → worker가 `hostvars`로 읽음 |

## 8. 실행

```bash
cd ~/ws-<이름>/orbit-infrastructure
./scripts/setup-control-node.sh        # 제어 노드 점검
./scripts/gen-inventory.sh             # 인벤토리 생성
cd ansible
ansible all -m ping                    # 접속 확인
ansible-playbook preflight.yml         # 사전 점검만
ansible-playbook site.yml              # 전체 설치 (preflight 포함)
```

테스트 VM으로 검증 (실제 VM을 건드리지 않음):
```bash
./scripts/test-vms.sh                                   # test-cp, test-w1, test-w2 생성
cd ansible && ansible-playbook -i inventory/test.ini site.yml
cd .. && ./scripts/test-vms.sh delete
```
테스트 VM 이름이 고정이라 동시에 두 명이 쓰면 충돌한다. 쓰기 전 Slack에 공유.

## 9. 멱등성

여러 번 실행해도 결과가 같다.
- `kubeadm init`: `/etc/kubernetes/admin.conf`가 있으면 건너뜀
- `kubeadm join`: `/etc/kubernetes/kubelet.conf`가 있으면 건너뜀
- containerd 재시작: 설정이 바뀐 경우에만 (핸들러)
- 확인: 두 번째 실행에서 `PLAY RECAP`의 `failed=0`, `changed` 거의 0

## 10. 롤 추가 규칙

1. 이슈 생성 → `task/<번호>-ansible-<롤이름>` 브랜치 → 바로 push
2. `roles/<롤이름>/tasks/main.yml` 작성
3. `site.yml`에 플레이 추가 (`hosts:`는 4번 표의 그룹 이름)
4. 테스트 VM 또는 Lab에서 실행해 확인 → `feat: ...` 커밋 → PR (`Closes #번호`)
5. VM에 손으로 설치하지 않는다 — 모든 변경은 롤로 (계획서 규칙 3)

## 11. 검증 기록

| 날짜 | 대상 | 결과 | 소요 시간 |
|---|---|---|---|
| 10/5 | 테스트 VM 3대 (test-cp, test-w1, test-w2) | 3대 Ready, v1.33.13 | |
