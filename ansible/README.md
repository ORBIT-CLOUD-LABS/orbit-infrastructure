# Ansible

ASTRA VM 구성(OS 레벨 설정)을 관리합니다. 인벤토리(`inventory/lab/hosts.ini`)는 Terraform의
`ansible-inventory` 모듈이 `apply` 시 생성하므로 직접 수정하지 않습니다.

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
다루지 않습니다.

### 변수

기본값은 `roles/base/defaults/main.yml`에 있습니다. 그룹/호스트별로 바꾸려면
`inventory/lab/group_vars/<그룹>.yml` 또는 `inventory/lab/host_vars/<호스트>.yml`에 지정합니다.

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

### Terraform state 백업

`terraform_states` DB를 PostgreSQL custom format으로 백업한 뒤 GPG로 암호화합니다.
systemd timer가 매일 18:00 UTC에 실행하며, 암호화 파일은 ASTRA와 TERRA에 14일간 보관합니다.
TERRA 전송에 실패하면 ASTRA 사본은 유지하고 service는 실패로 기록합니다.

| 항목 | ASTRA | TERRA |
|---|---|---|
| 저장 경로 | `/var/backups/orbit/terraform-state` | `/home/orbit-backup/terraform-state` |
| 소유 계정 | `root` | `orbit-backup` |
| 디렉터리 권한 | `0700` | `0700` |
| 파일 권한 | `0600` | `0600` |

백업 비밀번호는 `vault_terraform_state_backup_passphrase`로 관리하며 DB와 vault 비밀번호를
재사용하지 않습니다. 비밀번호를 교체하면 기존 백업에는 이전 비밀번호가 필요합니다.

### 백업 확인

ORBIT-ASTRA 호스트에서 timer와 최근 실행 결과를 확인합니다.

```bash
sudo systemctl status orbit-terraform-state-backup.timer
sudo systemctl list-timers orbit-terraform-state-backup.timer
sudo systemctl status orbit-terraform-state-backup.service
sudo journalctl -u orbit-terraform-state-backup.service --no-pager
```

수동으로 한 번 실행하려면 service를 시작합니다.

```bash
sudo systemctl start orbit-terraform-state-backup.service
```

ASTRA와 TERRA에 같은 이름의 `.dump.gpg` 파일이 있고 권한이 `0600`인지 확인합니다.

```bash
sudo find /var/backups/orbit/terraform-state \
  -maxdepth 1 -type f -printf '%M %u:%g %f\n'

sudo ssh \
  -i /etc/orbit/terraform-state-backup-ssh \
  -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/orbit/terraform-state-backup-known_hosts \
  -o StrictHostKeyChecking=yes \
  orbit-backup@orbit-terra \
  "find /home/orbit-backup/terraform-state -maxdepth 1 -type f -printf '%M %u:%g %f\\n'"
```

### 복구 확인

운영 DB에는 복원하지 않습니다. `<backup-file>`을 실제 파일명으로 바꾼 뒤 별도 시험 DB에
복원합니다.

```bash
sudo install -d -o root -g postgres -m 0750 /run/orbit-terraform-state-restore
sudo gpg --batch --yes --pinentry-mode loopback \
  --passphrase-file /etc/orbit/terraform-state-backup.passphrase \
  --output /run/orbit-terraform-state-restore/terraform_states.dump \
  --decrypt /var/backups/orbit/terraform-state/<backup-file>
sudo chown root:postgres /run/orbit-terraform-state-restore/terraform_states.dump
sudo chmod 0640 /run/orbit-terraform-state-restore/terraform_states.dump
```

시험 DB 이름이 사용 중인지 확인합니다. 결과가 없을 때만 복원합니다.

```bash
sudo -u postgres psql -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datname = 'terraform_states_restore_test';"
sudo -u postgres createdb terraform_states_restore_test
sudo -u postgres pg_restore --exit-on-error \
  --dbname=terraform_states_restore_test \
  /run/orbit-terraform-state-restore/terraform_states.dump
sudo -u postgres psql -d terraform_states_restore_test -c '\dn'
```

`terraform_remote_state_astra`와 `terraform_remote_state_jenkins` schema를 확인한 뒤 시험
DB와 평문 dump를 삭제합니다.

```bash
sudo -u postgres dropdb terraform_states_restore_test
sudo rm -f /run/orbit-terraform-state-restore/terraform_states.dump
sudo rmdir /run/orbit-terraform-state-restore
```
