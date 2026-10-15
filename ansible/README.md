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
| Database | `database.yml` → `database`, `data_disk` | `vehicle_db` (campaign 테이블 포함, [`docs/vehicle-db.md`](../docs/vehicle-db.md)) |
| Monitoring | `monitoring.yml` → `node_exporter`, `monitoring_host`, `data_disk` | 전체 관리 노드, `monitoring` |
| Kubernetes 후처리 | `k8s-post.yml` → `k8s_post` | `control_plane[0]` |
| Argo CD bootstrap | `argocd.yml` → `argocd` | `control_plane[0]` |

`node_exporter`는 `playbooks/site.yml`에도 포함돼 있어 클러스터 구성 때 모든 VM·`astra_host`에 함께 설치된다. `monitoring.yml`은 재적용(`--tags node_exporter`)이나 `inventory/test-services.ini` 같은 별도 인벤토리에 단독으로 쓸 때 쓴다.

`node_exporter` 롤은 `ufw`로 9100(:9100)을 `monitoring` 그룹 IP에서만 허용하고 나머지는 차단하는 규칙도 같이 넣는다. 다만 **`ufw enable`은 이 롤에서 하지 않는다** — SSH(22)·Kubernetes 관련 포트(6443, 10250, 2379-2380 등)의 allowlist가 아직 없어서, 지금 ufw를 켜면 모든 VM 접속이 끊길 수 있다. ufw를 실제로 켜는 작업은 그 포트들을 먼저 정리하는 별도 이슈로 다룬다. `inventory/test.ini`처럼 `monitoring` 그룹이 없는 인벤토리에서는 이 규칙을 건너뛴다.

**node 이름 규칙 (node_exporter ↔ cAdvisor label 중복 방지):** `k8s_worker`, `k8s_control_plane` 롤은 `kubeadm join`/`init`에 `--node-name={{ inventory_hostname }}`를 명시해, Kubernetes Node 이름이 항상 Ansible 인벤토리 호스트명(`astra-worker-1` 등 — node_exporter가 쓰는 것과 같은 이름)과 일치하도록 고정한다. 클러스터 안 수집기(cAdvisor 등 Kubernetes 서비스 디스커버리 기반 수집기)가 이 Node 이름을 label로 쓰면 node_exporter 타겟과 별도 relabel 없이 같은 이름으로 맞아떨어지므로, 같은 노드가 두 다른 이름으로 중복 표현되지 않는다.

원격 사이트는 `inventory/lab/sites.ini`에서 관리한다.

- `sol`: CDN
- `terra`: Terraform state 백업 원격지 (`astra_host`의 `terraform_state_backup_remote_host`). Campaign DB는 별도로 두지 않고 `vehicle_db`에 합쳤다
- `luna`: Agent
- `remote`: 전체 원격 사이트

운영 절차는 [`RUNBOOK.md`](RUNBOOK.md)를 따른다.

### 설정

- 비밀값은 `secrets/vault.yml.example`을 복사해 `secrets/vault.yml`에 작성하고 Ansible Vault로 암호화한다.
- Database와 Monitoring 데이터 디스크는 `db_data_device`, `monitoring_data_device`로 지정한다.
- 데이터 디스크에 파일시스템이 있으면 다시 포맷하지 않는다.
- `k8s_reserved_nodes`의 기본값은 `[]`이며 worker 3대 모두 일반 Pod를 받는다.
- 필요할 때만 예비 노드를 목록에 지정해 `orbit.io/reserved=true:NoSchedule` taint를 적용한다. 목록에서 빼고 `k8s-post.yml`을 실행하면 예약 taint·label이 제거된다.
- worker-3 개방 후 실제 배치 확인은 [RUNBOOK의 검증 절차](RUNBOOK.md#3-2-worker-배치와-예비-노드-관리)를 따른다.

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

모든 VM(`all:!astra_host`)에 공통 OS 기본 설정을 적용한다. ORBIT-ASTRA 호스트(`astra_host`)는
대상에서 제외한다.

### 실행

ORBIT-ASTRA 호스트에서 실행한다. VM의 `orbit` 계정은 비밀번호 없이 sudo를 쓸 수 있으므로
`--ask-become-pass`는 필요 없다.

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
6. `node_exporter` 롤 (`all` — `astra_host` 포함): Monitoring VM의 Prometheus가 수집할 `:9100` 노출
7. 모든 노드 `Ready` 확인

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

## Argo CD bootstrap

준비된 Kubernetes 클러스터에 전용 플레이북으로 설치한다. Helm 실행 파일과
Python YAML 의존성은 첫 번째 control plane VM에 설치하며,
`/etc/kubernetes/admin.conf`로 클러스터에 접속한다.
실행 장비에는 `ansible-core >= 2.16`과 `kubernetes.core` collection이 필요하다.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# 테스트 Kubernetes 클러스터가 준비된 상태에서 먼저 검증
ansible-playbook -i inventory/test.ini argocd.yml

# 같은 설정으로 재실행하여 changed=0 확인
ansible-playbook -i inventory/test.ini argocd.yml

# 테스트 검증 후 Lab에 설치
ansible-playbook argocd.yml
```

이 플레이북은 `--check`를 지원하지 않는다. 설치와 Ready 검증은 테스트 클러스터에서
실제 실행으로 확인한다. 같은 설정의 두 번째 실행에서 Helm 버전과 release values를
비교하여 불필요한 설치·업그레이드를 건너뛴다. 클러스터 리소스의 수동 변경까지
자동 복구하는 검증은 포함하지 않는다.

기본 버전은 Helm `v4.2.3`, chart `10.10.3`, Argo CD `v3.5.5`이며,
`roles/argocd/defaults/main.yml`에서 관리한다. 업그레이드할 때는 chart의
`appVersion`과 Argo CD 버전을 함께 확인하고 해당 값을 수정한 뒤 테스트 클러스터에서
검증하고 Lab에 재적용한다.

`argocd` namespace를 만들고 CRD를 설치한다. API 서버는 HTTPS와 `ClusterIP`를
사용하며 Ingress는 만들지 않는다. 기본 실행에서는 GitOps 저장소 인증과 Application을 구성하지 않는다.
Helm 설치 완료 후 Deployment·StatefulSet의 rollout과 주요 Pod의 Ready 상태를 확인한다.

GitOps 최초 연결은 `-e argocd_gitops_enabled=true --ask-vault-pass`로 명시적으로 켠다.
이 경우 `argocd_gitops` 롤이 인증 Secret·AppProject·root Application을 적용하고,
root의 자식 manifest 조회를 확인한다. Sync는 수동으로 수행한다.
키 준비, 두 저장소 반영 순서와 검증 절차는 [GitOps 연결 문서](../docs/argocd-gitops.md)를 따른다.

### 임시 API·UI 접속 검증

control plane VM에서 실행한다. port-forward는 해당 VM의 `127.0.0.1`에만 열린다.

```bash
kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8080:443
```

같은 VM의 다른 터미널에서 API 응답을 확인한다. `-k`는 설치 검증용 자체 서명 인증서에만 사용한다.

```bash
curl --fail --silent --show-error -k https://127.0.0.1:8080/api/version
```

노트북에서 해당 VM으로 SSH 접속할 수 있으면 터널을 연결하고
브라우저에서 `https://localhost:8080`에 접속한다.

```bash
ssh -N -L 8080:127.0.0.1:8080 orbit@192.168.100.101
```

초기 사용자 이름은 `admin`이다. 초기 비밀번호는 control plane VM에서 직접 조회한다.
비밀번호를 Ansible 출력이나 PR에 남기지 않는다.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode
```

GitOps 저장소를 연결하지 않은 상태에서 API 응답과 UI 로그인을 확인한다.
검증이 끝나면 SSH 터널과 port-forward를 종료한다.

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

ASTRA 호스트에서 전용 계정과 공개키를 적용하고, Jenkins VM에는 검증한 ASTRA
SSH host key를 등록한다.

```bash
cd ansible

# 변경 내용 미리 보기
ansible-playbook playbooks/libvirt_remote.yml --check --diff --ask-become-pass

# 적용
ansible-playbook playbooks/libvirt_remote.yml --ask-become-pass

# 멱등성 확인: changed=0이어야 한다
ansible-playbook playbooks/libvirt_remote.yml --check --diff --ask-become-pass
```

이 플레이북은 다음 항목을 함께 관리한다.

| 대상 | 항목 |
|---|---|
| ASTRA 호스트 | `jenkins-libvirt` 계정, `libvirt` 그룹, Jenkins 공개키, `192.168.100.100` 출발지 제한 |
| Jenkins VM | `/var/lib/jenkins/.ssh/known_hosts`의 ASTRA host key |

Jenkins의 `Manage Jenkins` → `Credentials` → `System` → `Global credentials`에
다음 credential을 등록한다.

| ID | 종류 | 내용 |
|---|---|---|
| `astra-libvirt-ssh` | SSH Username with private key | 사용자 `jenkins-libvirt`와 `roles/libvirt_remote_user/defaults/main.yml`의 공개키에 대응하는 개인키 |

검증 Job은 UI에 Pipeline script를 직접 저장하지 않는다. 저장소를 SCM으로 지정하고
Script Path를 `jenkins/Jenkinsfile.libvirt-verify`로 설정한다. Jenkins VM을 재생성해도
검증 로직은 저장소에 남으며 같은 Job을 다시 구성할 수 있다.

개인키 자체를 출력하지 말고 공개키 지문이 일치하는지만 확인한다.

```bash
# ASTRA에 설치된 공개키 지문
sudo ssh-keygen -lf /home/jenkins-libvirt/.ssh/authorized_keys

# Jenkins credential에 넣을 개인키의 공개키 지문
ssh-keygen -y -f <private-key> | ssh-keygen -lf -
```

credential을 임시 파일로 바인딩한 Jenkins 작업에서 ASTRA libvirt 연결을 확인한다.

```bash
ssh -o BatchMode=yes \
  -i "${LIBVIRT_SSH_KEY}" \
  "${LIBVIRT_SSH_USER}@192.168.100.1" \
  'virsh -c qemu:///system list --all'
```

`LIBVIRT_SSH_USER`, `LIBVIRT_SSH_KEY`는 위 credential을 Jenkins 작업에 바인딩해
받은 값이다. 개인키를 저장소나 Jenkins workspace에 복사해 두지 않는다.

## PostgreSQL (Terraform state 백엔드)

Terraform state의 순환 의존성을 방지하기 위해, state 관리 대상이 아닌 ORBIT-ASTRA 호스트에 PostgreSQL `pg` backend와 state 백업을 구성한다.

### 실행

ORBIT-ASTRA 호스트에서 실행한다. DB와 백업 비밀번호는
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

백업 상태 확인, 수동 실행, 보관 파일 확인 및 복구 검증 절차는
[`RUNBOOK.md`](RUNBOOK.md)의 Terraform state PostgreSQL 백업·복구 절차를 따른다.

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
