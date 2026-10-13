# Ansible — ORBIT Lab 구성

Terraform이 astra에 만든 VM에 Kubernetes(kubeadm)와 인프라 서비스를 설치한다.

## 제어 노드 (astra)

준비 상태 점검 (Ansible·SSH 키·libvirt·ansible.cfg·인벤토리·ping을 한 번에 확인):

```bash
./scripts/setup-control-node.sh
```

## Terraform ↔ Ansible 연결: 인벤토리

Terraform은 `inventory/lab/hosts.ini`를 생성하고, Ansible은 이 파일과
`astra_host.ini`, `sites.ini`, `jenkins.ini` 정적 인벤토리를 함께 읽는다.

```
terraform apply → inventory/lab/hosts.ini 생성 → ansible-playbook playbooks/site.yml
```

| VM | IP | Ansible 그룹 |
|---|---|---|
| `astra-control-plane` | 192.168.100.101 | `control_plane` |
| `astra-worker-1` ~ `3` | 192.168.100.102 ~ 104 | `workers` |
| `astra-nfs` | 192.168.100.105 | `nfs` |
| `astra-vehicle-db` | 192.168.100.106 | `vehicle_db` |
| `astra-monitoring` | 192.168.100.107 | `monitoring` |

`k8s` = `control_plane` + `workers` (공통 설치 대상). 롤의 `hosts:`는 위 그룹 이름을 그대로 쓴다.

> `astra-jenkins`는 `stacks/jenkins`에서 별도로 관리하므로 Terraform이 생성하는
> `inventory/lab/hosts.ini`에 포함되지 않는다. Ansible에서는
> `inventory/lab/jenkins.ini`의 정적 `jenkins` 그룹으로 관리한다.

## 서비스 롤과 멀티 사이트

| 작업 | 플레이북 / 롤 | 대상 |
|---|---|---|
| Database | `database.yml` → `database`, `data_disk` | `vehicle_db`, `campaign_db` |
| Monitoring | `monitoring.yml` → `node_exporter`, `monitoring_host`, `data_disk` | 전체 관리 노드, `monitoring` |
| Kubernetes 후처리 | `k8s-post.yml` → `k8s_post` | `control_plane[0]` |

원격 사이트는 `inventory/lab/sites.ini`에서 관리한다.

- `sol`: CDN
- `terra`: Campaign DB
- `luna`: Agent
- `remote`: 전체 원격 사이트

운영 절차는 [`RUNBOOK.md`](RUNBOOK.md)를 따른다.

### 설정

- 비밀값은 `secrets/vault.yml.example`을 복사해 `secrets/vault.yml`에 작성하고 Ansible Vault로 암호화한다.
- Database와 Monitoring 데이터 디스크는 `db_data_device`, `monitoring_data_device`로 지정한다.
- 데이터 디스크에 파일시스템이 있으면 다시 포맷하지 않는다.
- `k8s_reserved_nodes`의 기본값은 `astra-worker-3`이며 `orbit.io/reserved=true:NoSchedule` taint를 적용한다.

### 서비스 롤 테스트

Lab VM을 변경하지 않고 테스트 VM에서 실행한다.

```bash
NODES="test-db:13 test-mon:14" ./scripts/test-vms.sh

cd ansible

ansible-playbook -i inventory/test-services.ini database.yml \
  -e db_app_password=testpass123 \
  -e db_verify=true

ansible-playbook -i inventory/test-services.ini monitoring.yml \
  -e grafana_admin_password=testpass123

cd ..
NODES="test-db:13 test-mon:14" ./scripts/test-vms.sh delete
```

## Base (VM 공통 OS 설정)

모든 VM(`all:!astra_host`)에 공통 OS 기본 설정을 적용합니다. ORBIT-ASTRA 호스트(`astra_host`)는
대상에서 제외합니다.

### 실행

ORBIT-ASTRA 호스트에서 실행합니다. VM의 `orbit` 계정은 비밀번호 없이 sudo를 쓸 수 있으므로
`--ask-become-pass`는 필요 없습니다.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# 변경 내용 미리 보기
ansible-playbook playbooks/base.yml --check --diff

# 적용 (특정 VM만 적용하려면 --limit <호스트|그룹>)
ansible-playbook playbooks/base.yml
```

### 관리하는 설정

| 항목 | 설정 위치 (VM) | 내용 |
|---|---|---|
| 공통 패키지 | - | `base_packages` + `base_extra_packages` 설치 |
| 시간 | - | timezone 설정, `systemd-timesyncd` 활성화 |
| sshd | `/etc/ssh/sshd_config.d/10-orbit-base.conf` | `base_sshd_options` (변경 시 sshd reload) |
| journald | `/etc/systemd/journald.conf.d/10-orbit-base.conf` | `base_journald_options` (변경 시 journald 재시작) |
| 자동 업데이트 | `/etc/apt/apt.conf.d/60orbit-unattended-upgrades` | 실행 여부, 적용 저장소, 자동 재부팅 |

cloud-init이 관리하는 설정(hostname, `orbit` 계정, SSH 키, 비밀번호 로그인 차단, `/etc/hosts`)은
다루지 않는다.

### 변수

기본값은 `roles/base/defaults/main.yml`에 있다. 그룹/호스트별로 바꾸려면
`inventory/lab/group_vars/<그룹>.yml` 또는 `inventory/lab/host_vars/<호스트>.yml`에 지정한다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `base_packages` | `ca-certificates`, `curl`, `vim`, `htop`, `jq`, `bind9-dnsutils` | 모든 VM 공통 패키지 |
| `base_extra_packages` | `[]` | 그룹/호스트별 추가 패키지 |
| `base_apt_cache_valid_time` | `3600` | apt 캐시 재갱신 간격(초) |
| `base_timezone` | `Etc/UTC` | timezone |
| `base_sshd_options` | `PermitRootLogin: "no"`, `X11Forwarding: "no"` | sshd 설정 (`키: 값`) |
| `base_journald_options` | `SystemMaxUse: 2G` | journald 설정 (`키: 값`) |
| `base_unattended_upgrades_enabled` | `true` | 패키지 목록 갱신·자동 업그레이드 매일 실행 |
| `base_unattended_upgrades_origins` | Ubuntu 기본값 (보안 업데이트) | 자동 업그레이드를 적용할 저장소 |
| `base_unattended_upgrades_automatic_reboot` | `false` | 업데이트 후 자동 재부팅 |

## Kubernetes 클러스터 (kubeadm)

`playbooks/site.yml`이 아래 순서로 클러스터를 구성한다.

1. `playbooks/preflight.yml`: 접속, OS, 디스크, 인터넷, CPU·메모리, hostname/MAC/product_uuid 중복, 포트 점검
2. `playbooks/base.yml`: 위의 VM 공통 OS 설정
3. `k8s_node` 롤 (`k8s` 그룹): swap 끄기, 커널 모듈·sysctl, containerd, kubelet/kubeadm/kubectl 설치
4. `k8s_control_plane` 롤 (`control_plane` 그룹): `kubeadm init`, Calico(Tigera Operator) 설치, join 명령 생성
5. `k8s_worker` 롤 (`workers` 그룹): `kubeadm join`
6. 모든 노드 `Ready` 확인

### 실행

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# 설치 전 점검만
ansible-playbook playbooks/preflight.yml

# 전체 구성
ansible-playbook playbooks/site.yml
```

join 명령은 같은 실행 안에서 control plane 플레이가 만들어 worker에 넘긴다. 그래서
`--limit workers`처럼 worker만 따로 실행하면 안 된다.

### 테스트 VM

Lab VM을 건드리지 않고 롤을 검증하려면 libvirt 기본망(`192.168.122.0/24`)에 테스트 VM 3대를 만들어 사용한다.

```bash
./scripts/test-vms.sh            # test-cp, test-w1, test-w2 생성
cd ansible
ansible-playbook -i inventory/test.ini playbooks/site.yml
cd .. && ./scripts/test-vms.sh delete   # VM·디스크·DHCP 예약·known_hosts 항목까지 정리
```

- sudo 없이 `libvirt` 그룹 권한만으로 동작한다. 디스크는 `images` 풀의 볼륨으로 만든다.
- Lab VM과 같은 Ubuntu 24.04 베이스 이미지가 `images` 풀에 `noble-server-cloudimg-amd64.img` 볼륨으로
  있어야 한다. 없으면 스크립트가 올리는 방법을 안내한다. 여러 번 쓰는 준비물이라 `delete`로 지우지 않는다.

### 변수

| 변수 | 위치 | 기본값 | 설명 |
|---|---|---|---|
| `k8s_version` | `playbooks/group_vars/all.yml` | `v1.33` | pkgs.k8s.io 저장소의 마이너 버전 |
| `preflight_min_disk_gb` | `playbooks/group_vars/all.yml` | `15` | 루트 디스크 최소 여유 공간(GB) |
| `pod_network_cidr` | `roles/k8s_control_plane/defaults/main.yml` | `10.244.0.0/16` | Pod 대역 (Lab 망 `192.168.100.0/24`와 겹치면 안 됨) |
| `calico_version` | `roles/k8s_control_plane/defaults/main.yml` | `v3.31.4` | Calico 매니페스트 버전 |

`playbooks/group_vars/`는 `playbooks/` 아래 플레이북에 자동으로 적용된다. `astra_host` 변수는 아직
`group_vars/astra_host/`에 있고 `postgresql.yml`이 `vars_files`로 직접 읽는다.
나중에 `playbooks/group_vars/`로 합칠 예정이다.

## Jenkins (Controller와 Terraform runner)

Terraform `stacks/jenkins`로 생성한 `astra-jenkins` VM에 Jenkins와 Terraform 실행 도구를
설치한다. Jenkins VM은 Terraform 생성 inventory에서 제외되므로
`inventory/lab/jenkins.ini`의 정적 `jenkins` 그룹으로 관리한다.

### 실행

ORBIT-ASTRA 호스트에서 실행한다. Jenkins 관리자 비밀번호는
`group_vars/jenkins/vault.yml`에 Ansible Vault로 암호화하여 관리한다.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# 변경 내용 미리 보기
ansible-playbook playbooks/jenkins.yml --check --diff --ask-vault-pass

# 적용
ansible-playbook playbooks/jenkins.yml --ask-vault-pass
```

### 관리하는 설정

| 항목 | 내용 |
|---|---|
| 공통 OS 설정 | `base` role 적용 |
| Jenkins | OpenJDK 21, Jenkins LTS, plugin 설치 |
| JCasC | 로컬 관리자, 익명 접근 차단, Executor 1개 설정 |
| Terraform runner | Terraform, `cloud-localds`, Git 설치 |

### Jenkins에서 ASTRA libvirt 접속

Jenkins VM(`192.168.100.100`)이 ASTRA 호스트의 libvirt에 원격 접속할 때는
전용 계정 `jenkins-libvirt`를 사용한다. 이 계정은 `libvirt` 그룹 권한을 가지므로
SSH 개인키는 Jenkins credential에만 보관한다.

ASTRA 호스트에서 전용 계정과 공개키를 적용한다.

```bash
cd ansible

# 변경 내용 미리 보기
ansible-playbook playbooks/libvirt_remote.yml --check --diff --ask-become-pass

# 적용
ansible-playbook playbooks/libvirt_remote.yml --ask-become-pass

# 멱등성 확인: changed=0이어야 한다
ansible-playbook playbooks/libvirt_remote.yml --check --diff --ask-become-pass
```

Jenkins의 `Manage Jenkins` → `Credentials` → `System` → `Global credentials`에
다음 credential을 등록한다.

| ID | 종류 | 내용 |
|---|---|---|
| `astra-libvirt-ssh` | SSH Username with private key | 사용자 `jenkins-libvirt`와 `roles/libvirt_remote_user/defaults/main.yml`의 공개키에 대응하는 개인키 |
| `astra-terraform-backend` | Secret file | 실제 비밀번호를 넣은 `terraform/environments/astra/backend-config/astra.conf` |

개인키 자체를 출력하지 말고 공개키 지문이 일치하는지만 확인한다.

```bash
# ASTRA에 설치된 공개키 지문
sudo ssh-keygen -lf /home/jenkins-libvirt/.ssh/authorized_keys

# Jenkins credential에 넣을 개인키의 공개키 지문
ssh-keygen -y -f <private-key> | ssh-keygen -lf -
```

credential을 임시 파일로 바인딩한 Jenkins 작업에서 연결과 Terraform plan을 확인한다.
`ssh_authorized_keys`에는 현재 ASTRA 업무 스택에 적용 중인 공개키 목록을 그대로 전달해야
`No changes` 결과를 확인할 수 있다.

```bash
ssh -o BatchMode=yes \
  -i "${LIBVIRT_SSH_KEY}" \
  "${LIBVIRT_SSH_USER}@192.168.100.1" \
  'virsh -c qemu:///system list --all'

cd terraform/environments/astra
terraform init -backend-config="${TF_BACKEND_CONFIG}"
terraform fmt -check -recursive
terraform validate
terraform plan \
  -var "libvirt_uri=qemu+ssh://${LIBVIRT_SSH_USER}@192.168.100.1/system?keyfile=${LIBVIRT_SSH_KEY}" \
  -var 'ssh_authorized_keys=["<현재 ASTRA 업무 VM에 적용 중인 SSH 공개키>"]'
```

`LIBVIRT_SSH_USER`, `LIBVIRT_SSH_KEY`, `TF_BACKEND_CONFIG`는 위 credential을
Jenkins 작업에 바인딩해 받은 값이다. 개인키와 backend 설정 파일을 저장소나 Jenkins
workspace에 복사해 두지 않는다.

## PostgreSQL (Terraform state 백엔드)

ORBIT-ASTRA 호스트(`astra_host`)에 Terraform `pg` backend용 PostgreSQL과 state 백업을
구성한다.

### 실행

ORBIT-ASTRA 호스트에서 실행합니다. DB와 백업 비밀번호는
`group_vars/astra_host/vault.yml`에 Ansible Vault로 암호화하여 관리한다.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# 변경 내용 미리 보기
ansible-playbook playbooks/postgresql.yml --check --diff --ask-become-pass --ask-vault-pass

# 적용
ansible-playbook playbooks/postgresql.yml --ask-become-pass --ask-vault-pass
```

### 관리하는 설정

| 항목 | 내용 |
|---|---|
| PostgreSQL | `terraform_states` DB와 `terraform` 계정 생성 |
| 접속 제어 | `192.168.100.0/24`의 Terraform backend 접속 허용 |
| State 백업 | PostgreSQL custom format dump를 GPG로 암호화 |
| 백업 주기 | systemd timer로 매일 18:00 UTC에 실행 |
| 보관 | ASTRA와 TERRA에 14일간 보관 |

### 접속 제어

`listen_addresses`는 `*`로 두고, 접속 허용은 `pg_hba.conf`에서 `terraform` 계정의
`orbit-astra-net`(`192.168.100.0/24`) 접속만 허용하는 것으로 제한한다.
PostgreSQL이 호스트의 모든 인터페이스에서 5432 포트를 수신하므로 `pg_hba.conf`에 넓은 범위의 규칙을
추가하지 않는다.

### 확인

```bash
ansible astra_host -m postgresql_ping -a "db=terraform_states login_user=terraform login_password=<password>"
```

`terraform` 계정 비밀번호를 바꾸려면 `group_vars/astra_host/vault.yml`을
`ansible-vault edit`로 수정한 뒤 플레이북을 다시 실행한다.
