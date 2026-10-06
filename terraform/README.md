# Terraform

Terraform은 물리 호스트별 libvirt network, storage pool, VM, volume, cloud-init을 관리합니다.

## ASTRA

`environments/astra`는 ORBIT-ASTRA에서 `qemu:///system` URI로 실행합니다.

- Network: `orbit-astra-net` (`192.168.100.0/24`)
- Bridge: `virbr100`
- Storage pool: `orbit-astra` (`/var/lib/libvirt/images/orbit-astra`)

ASTRA는 Ubuntu 24.04.5 cloud image의 고정 release와 SHA-256을 사용합니다. 각 VM은 qcow2 overlay와 cloud-init ISO로 생성합니다. NFS, Vehicle DB, Monitoring VM에는 별도 raw data volume을 연결합니다.

실행은 ORBIT-ASTRA에서 수행합니다.

```bash
sudo install -d -o orbit -g orbit /var/lib/orbit/terraform-state/astra
command -v cloud-localds
cd terraform/environments/astra
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
```

`cloud-localds`가 없으면 `sudo apt install cloud-image-utils`를 수행한 뒤 다시 확인합니다. `terraform.tfvars.example`을 `terraform.tfvars`로 복사하고 실제 SSH 공개키를 입력해야 합니다.

`terraform apply`는 생성 대상과 VM 자원량을 확인한 후 수동으로 실행합니다.
