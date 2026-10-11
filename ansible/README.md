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

## Jenkins (Controller와 Terraform runner)

Terraform `stacks/jenkins`로 생성한 `astra-jenkins` VM에 Jenkins와 Terraform 실행 도구를
설치합니다. Jenkins VM은 Terraform 생성 inventory에서 제외되므로
`inventory/lab/jenkins.ini`의 정적 `jenkins` 그룹으로 관리합니다.

### 실행

ORBIT-ASTRA 호스트에서 실행합니다. Jenkins 관리자 비밀번호는
`group_vars/jenkins/vault.yml`에 Ansible Vault로 암호화하여 관리합니다.

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

## PostgreSQL (Terraform state 백엔드)

ORBIT-ASTRA 호스트(`astra_host`)에 Terraform `pg` backend용 PostgreSQL과 state 백업을
구성합니다.

### 실행

ORBIT-ASTRA 호스트에서 실행합니다. DB와 백업 비밀번호는
`group_vars/astra_host/vault.yml`에 Ansible Vault로 암호화하여 관리합니다.

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
