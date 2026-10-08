# Ansible

ASTRA VM 구성(OS 레벨 설정)을 관리합니다. 인벤토리(`inventory/lab/hosts.ini`)는 Terraform의
`ansible-inventory` 모듈이 `apply` 시 생성하므로 직접 수정하지 않습니다.

## PostgreSQL (Terraform state 백엔드)

`astra-vehicle-db` VM이 아니라 **ORBIT-ASTRA 호스트 자신**(`astra_host` 그룹, `inventory/lab/astra_host.ini`에
`localhost ansible_connection=local`로 정의)에 PostgreSQL을 설치하고, `backend "pg"`가 사용할
`terraform_states` DB와 전용 계정(`terraform`)을 생성합니다. VM에 두면 그 VM이 astra 환경과
같은 state로 관리되는 자원이라 "state 저장소가 state 관리 대상에 의존하는" 순환 구조가 생기기
때문에, state와 무관한 호스트 자체에 둡니다.

### 비밀번호 (ansible-vault)

`terraform` 계정 비밀번호는 `group_vars/astra_host/vault.yml`에 ansible-vault로 암호화되어
커밋되어 있습니다. vault 비밀번호는 git 밖(패스워드 매니저 등)으로 공유하며, 플레이북 실행 시
`--ask-vault-pass` 또는 `--vault-password-file`로 제공합니다.

### 실행

ORBIT-ASTRA 호스트에서 실행합니다. 패키지 설치에 sudo가 필요하므로 `--ask-become-pass`를 함께 줍니다.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/postgresql.yml --ask-become-pass --ask-vault-pass
```

### 접속 제어

`listen_addresses`는 `*`로 두고, 접속 허용은 `pg_hba.conf`에서 `terraform` 계정의
`orbit-astra-net`(`192.168.100.0/24`) 접속만 허용하는 것으로 제한합니다. 호스트의 다른
인터페이스(LAN, tailscale)에서도 5432 포트는 열려 있으므로 `pg_hba.conf`에 넓은 범위의 규칙을
추가하지 않습니다.

### 확인

```bash
ansible astra_host -m postgresql_ping -a "db=terraform_states login_user=terraform login_password=<password>"
```

`terraform` 계정 비밀번호를 바꾸려면 `group_vars/astra_host/vault.yml`을
`ansible-vault edit`로 수정한 뒤 플레이북을 다시 실행합니다.
