# Terraform

Terraform은 물리 호스트별 libvirt network, storage pool, VM, volume, cloud-init을 관리합니다.

## ASTRA

`environments/astra`는 ORBIT-ASTRA에서 `qemu:///system` URI로 실행합니다.

- Network: `orbit-astra-net` (`192.168.100.0/24`)
- Bridge: `virbr100`
- Storage pool: `orbit-astra` (`/var/lib/libvirt/images/orbit-astra`)

ASTRA는 Ubuntu 24.04.5 cloud image의 고정 release와 SHA-256을 사용합니다. 각 VM은 qcow2 overlay와 cloud-init ISO로 생성합니다. NFS, Vehicle DB, Monitoring VM에는 별도 raw data volume을 연결합니다.

실행은 ORBIT-ASTRA에서 수행합니다. state는 호스트 PostgreSQL에 저장하므로 먼저 아래
[State 백엔드](#state-백엔드-orbit-astra-호스트-postgresql)의 `backend-config/astra.conf`를 준비합니다.

```bash
command -v cloud-localds
cd terraform/environments/astra
terraform init -backend-config=backend-config/astra.conf
terraform fmt -check -recursive
terraform validate
terraform plan
```

`cloud-localds`가 없으면 `sudo apt install cloud-image-utils`를 수행한 뒤 다시 확인합니다. `terraform.tfvars.example`을 `terraform.tfvars`로 복사하고 실제 SSH 공개키를 입력해야 합니다.

`terraform apply`는 생성 대상과 VM 자원량을 확인한 후 수동으로 실행합니다.

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
