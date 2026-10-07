# Ansible

ASTRA VM 구성(OS 레벨 설정)을 관리합니다. 인벤토리(`inventory/lab/hosts.ini`)는 Terraform의
`ansible-inventory` 모듈이 `apply` 시 생성하므로 직접 수정하지 않습니다.

## PostgreSQL (Terraform state 백엔드)

`astra-vehicle-db` VM(`vehicle_db` 그룹)에 PostgreSQL을 설치하고, `backend "pg"`가 사용할
`terraform_states` DB와 전용 계정(`terraform`)을 생성합니다.

### 최초 1회: 비밀번호 암호화

`group_vars/vehicle_db/vault.yml`에 평문 비밀번호가 들어 있습니다. 커밋 전에 반드시
ansible-vault로 암호화합니다.

```bash
cd ansible
ansible-vault encrypt group_vars/vehicle_db/vault.yml
```

vault 비밀번호는 별도로(패스워드 매니저 등) 보관합니다. 이후 플레이북 실행 시 매번
`--ask-vault-pass` 또는 `--vault-password-file`로 제공합니다.

### 실행

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/postgresql.yml --ask-vault-pass
```

### 확인

```bash
ansible vehicle_db -m postgresql_ping -a "db=terraform_states login_user=terraform login_password=<password>"
```

`terraform` 계정 비밀번호를 바꾸려면 `group_vars/vehicle_db/vault.yml`을
`ansible-vault edit`로 수정한 뒤 플레이북을 다시 실행합니다.
