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
