# Terraform

Terraform은 물리 호스트별 libvirt network, storage pool, VM, volume, cloud-init을 관리합니다.

이 저장소의 코드가 기준입니다. 물리 호스트에는 terraform 코드를 보관하지 않고, 실행할 때마다 이 저장소를 clone해서 사용합니다.

## 구조

| 경로 | 관리 대상 | state |
| --- | --- | --- |
| `environments/astra` | ASTRA의 network, storage pool, 업무 VM | `/var/lib/orbit/terraform-state/astra/terraform.tfstate` |
| `stacks/jenkins` | Jenkins VM 1대 | `/var/lib/orbit/terraform-state/jenkins/terraform.tfstate` |
| `modules/libvirt-network` | libvirt NAT network와 DHCP 예약 | - |
| `modules/libvirt-vm` | VM, OS/data volume, cloud-init ISO | - |
| `modules/ansible-inventory` | Ansible inventory 파일 생성 | - |

`environments/astra`에는 Jenkins VM 정보가 없습니다. Jenkins VM은 `stacks/jenkins`가 별도 state로 관리하므로, 업무 스택을 apply해도 Jenkins VM은 영향을 받지 않습니다.

## ASTRA

- Network: `orbit-astra-net` (`192.168.100.0/24`, DHCP 동적 범위 `.200`~`.249`)
- Bridge: `virbr100`
- Storage pool: `orbit-astra` (`/var/lib/libvirt/images/orbit-astra`)

ASTRA는 Ubuntu 24.04.5 cloud image의 고정 release와 SHA-256을 사용합니다. 각 VM은 qcow2 overlay와 cloud-init ISO로 생성합니다. NFS, Vehicle DB, Monitoring VM에는 별도 raw data volume을 연결합니다.

업무 VM의 IP는 network의 DHCP 예약(`dhcp_hosts`)으로 고정합니다.

## 실행 준비

terraform을 실행하는 머신에 다음이 필요합니다.

- terraform `>= 1.16.0, < 2.0.0`
- `cloud-localds` (`sudo apt install cloud-image-utils`)
- 대상 호스트의 libvirt 접근 권한 (`libvirt` 그룹)
- state 디렉토리

```bash
sudo install -d -o orbit -g orbit /var/lib/orbit/terraform-state/astra
sudo install -d -o orbit -g orbit /var/lib/orbit/terraform-state/jenkins
```

state backend가 local이므로, 현재는 state 디렉토리가 있는 ASTRA에서 실행합니다.

## 실행 방법

```bash
git clone https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure.git
cd orbit-infrastructure/terraform/environments/astra   # 또는 stacks/jenkins
cp terraform.tfvars.example terraform.tfvars            # 실제 SSH 공개키 입력
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
```

`terraform apply`는 plan에서 생성·변경·삭제 대상과 VM 자원량을 확인한 후 수동으로 실행합니다.

새로 clone한 디렉토리에서는 cloud-init 생성물(`modules/libvirt-vm/.generated/`)과 Ansible inventory 파일이 없어서, 첫 plan에 `local_file` 생성이 표시될 수 있습니다. 같은 내용으로 파일을 다시 쓰는 것이며 VM은 변경되지 않습니다.

### 원격 실행

기본 libvirt URI는 `qemu:///system`(실행 머신의 로컬 libvirt)입니다. 다른 머신에서 실행할 때는 `libvirt_uri`로 대상 호스트를 지정합니다.

```bash
terraform plan -var 'libvirt_uri=qemu+ssh://<user>@<host>/system?keyfile=<private-key>'
```

원격 실행 머신에서도 state에 접근할 수 있어야 하므로, state backend를 원격으로 옮기기 전까지는 사용하지 않습니다.

## State 백엔드 (ORBIT-ASTRA 호스트 PostgreSQL)

`backend.tf`는 `backend "pg"`를 사용하며, 접속 정보(비밀번호 포함)는 파일에 두지 않고
`-backend-config`로 전달합니다. PostgreSQL은 `astra-vehicle-db` VM이 아니라 **ORBIT-ASTRA 호스트
자신**에 설치합니다(VM에 두면 그 VM도 astra 환경 state로 관리돼서 state 저장소가 state 관리
대상에 의존하는 순환 구조가 생기기 때문). 접속 주소는 호스트의 `orbit-astra-net` 브리지 IP인
`192.168.100.1`입니다. 설치/`terraform_states` DB·계정을 만드는 절차는 `ansible/README.md`를
참고합니다.

```bash
cd terraform/environments/astra
cp backend-config/astra.conf.example backend-config/astra.conf
# backend-config/astra.conf의 CHANGE_ME를 ansible vault에 저장한 실제 비밀번호로 교체
terraform init -backend-config=backend-config/astra.conf
```

`backend-config/astra.conf`는 비밀번호를 포함하므로 git에 커밋하지 않습니다(`.gitignore` 처리됨).

state를 다른 backend나 주소에서 옮겨올 때는 `terraform state pull`로 백업한 뒤
`terraform init -backend-config=backend-config/astra.conf -migrate-state`를 실행하고,
`terraform plan`이 `No changes`인지 확인합니다.

## Jenkins 스택

`stacks/jenkins`는 Jenkins VM을 업무 VM과 분리해 관리합니다.

- 전용 base volume(`jenkins-ubuntu-24.04-...qcow2`)을 사용해 업무 VM과 backing file을 공유하지 않습니다.
- cloud-init network-config로 static IP(`192.168.100.104/24`)를 설정해 업무 스택의 DHCP 예약에 의존하지 않습니다.
- VM 사양과 network 설정은 `variables.tf`의 기본값으로 둡니다. `terraform.tfvars`에는 SSH 공개키만 입력합니다.
- 자동화의 출발점이므로 Jenkins가 아니라 사람이 Jenkins를 올릴 호스트에서 직접 apply합니다.

storage pool과 network는 업무 스택이 관리하는 자원을 이름으로 참조합니다. 업무 스택보다 먼저 apply할 수 없습니다.

`environments/astra`의 `dhcp_hosts`에는 `astra-jenkins` 예약이 남아 있습니다. 예약을 지우면 provider가 network를 재생성해 모든 VM 연결이 끊기므로, network를 변경할 때 함께 정리합니다.

## Jenkins 스택 전환 절차

기존 `astra-jenkins`는 업무 스택이 관리하던 VM입니다. Jenkins가 설치되지 않은 빈 VM이므로 삭제 후 `stacks/jenkins`로 다시 생성합니다. 두 VM은 이름, MAC, IP, volume 이름이 같으므로 반드시 아래 순서로 적용합니다.

1. `environments/astra`에서 plan을 실행하고, `astra-jenkins` 관련 자원 6개 삭제와 inventory 파일 재생성만 있는지 확인한 후 apply합니다.
2. `stacks/jenkins`에서 plan을 실행하고, 생성 9개만 있는지 확인한 후 apply합니다.
3. 두 스택 모두 plan 결과가 `No changes`인지, network UUID와 업무 VM 상태가 그대로인지 확인합니다.

순서를 바꾸면 같은 이름의 VM과 volume이 이미 있어 `stacks/jenkins` apply가 실패합니다.
