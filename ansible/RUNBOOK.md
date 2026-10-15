# ORBIT Lab 운영 Runbook

Lab 인프라(astra + Sol·Terra·Luna)를 적용·되돌리기·복구·백업할 때 따르는 절차.
모든 Ansible 명령은 제어 노드(ASTRA)의 저장소 `ansible/` 디렉터리에서 실행한다.

| 상황 | 바로 가기 |
|---|---|
| 처음 구축 / 변경 적용 | [1. 적용](#1-적용) |
| 변경이 문제를 일으킴 | [2. Rollback](#2-rollback) |
| 노드·서비스 장애 | [3. 장애 복구](#3-장애-복구) |
| DB·클러스터 백업과 복구 | [4. Backup / Restore](#4-backup--restore) |

---

## 0. 공통 규칙

- VM에 손으로 설치·수정하지 않는다. 급하게 했다면 그 주 안에 롤로 옮긴다 (계획서 규칙 3).
- 모든 변경은 Issue → Branch → PR → 리뷰 후 develop 반영. 운영 적용은 **develop 기준**으로 한다.
- 비밀값은 `secrets/vault.yml`(ansible-vault 암호화)에만 둔다. vault 비밀번호는 Slack DM으로만 공유.
- Vault 비밀번호 관리 담당자: **@sungahbak** — 비밀번호 변경/교체, 담당자 공유 범위 관리를 책임진다.
- 작업 전후로 Slack `#orbit-infra`에 "적용 시작 / 완료(결과)" 한 줄을 남긴다.

### 플레이북 구성

| 플레이북 | 대상 | 내용 |
|---|---|---|
| `preflight.yml` | 전체 | 접속·OS·자원·중복·포트·인터넷·원격 사이트 경로 점검 (변경 없음) |
| `site.yml` | 전체 | preflight → k8s 설치 → 후처리 → DB → Monitoring (+NFS·Jenkins) |
| `k8s-post.yml` | control_plane | node label, 선택적 예비 노드 taint, 클러스터 검증 |
| `database.yml` | vehicle_db | MySQL, 데이터 디스크, 접근 제어, 백업 (campaign 테이블도 같은 `vehicle` DB) |
| `monitoring.yml` | 전체 | node-exporter (Prometheus·Alertmanager·Loki·Grafana는 monitoring VM에 systemd로 직접 구성, orbit-observability#3) |

---

## 1. 적용

### 1-1. 사전 확인
```bash
git checkout develop && git pull
../scripts/setup-control-node.sh          # 제어 노드 점검 (ansible, SSH 키, cfg, 인벤토리, ping)
ansible-inventory --graph                 # 대상 그룹 확인 (hosts.ini + sites.ini)
ansible-playbook preflight.yml            # 변경 없이 점검만
```

### 1-2. 미리보기 (변경 없음)
```bash
ansible-playbook site.yml --check --diff --ask-vault-pass
```
`--check`는 설치되지 않은 패키지 이후 단계에서 실패할 수 있다. **이미 구축된 환경의 설정 변경**을 미리 볼 때 쓴다.

### 1-3. 전체 적용
```bash
time ansible-playbook site.yml --ask-vault-pass
```

### 1-4. 일부만 적용
```bash
ansible-playbook database.yml --ask-vault-pass                 # DB만
ansible-playbook monitoring.yml --ask-vault-pass               # 모니터링만
ansible-playbook k8s-post.yml                                  # 라벨·taint·검증만
ansible-playbook site.yml --limit astra-worker-2               # 특정 노드만
ansible-playbook site.yml --tags database --ask-vault-pass     # 태그로 선택
```

### 1-5. 적용 후 확인
```bash
ssh orbit@192.168.100.101 kubectl get nodes -L orbit.io/reserved
ansible-playbook database.yml --ask-vault-pass -e db_verify=true   # 연결 수·권한·worker 포트 + 백업 검증
ansible-playbook site.yml --ask-vault-pass                     # 재실행 → PLAY RECAP changed ≈ 0 (멱등성)
```

---

## 2. Rollback

원칙: **코드를 되돌리고 다시 적용한다.** VM 안에서 손으로 되돌리지 않는다.

### 2-1. 설정 변경 되돌리기 (기본)
```bash
git log --oneline -10                 # 문제 커밋 확인
git revert <커밋>                      # 새 브랜치에서 → PR → 리뷰 → 머지
git checkout develop && git pull
ansible-playbook site.yml --ask-vault-pass
```

### 2-2. 항목별 되돌리기

| 항목 | 방법 |
|---|---|
| 예비 노드 해제/지정 | `k8s_reserved_nodes` 수정 후 `ansible-playbook k8s-post.yml` (목록에서 빠진 노드는 taint 자동 제거) |
| MySQL 설정 | `templates/99-orbit.cnf.j2` 되돌림 → `database.yml` (MySQL 재시작 발생) |
| DB 데이터 | [4-1 DB 복구](#4-1-db) |
| Kubernetes 버전 | `k8s_version` 되돌림만으로는 **다운그레이드 안 됨** (패키지 hold). 노드 재구축으로 처리 → [3-4](#3-4-vm-자체를-잃었을-때-재구축) |

---

## 3. 장애 복구

먼저 범위를 확인한다.
```bash
ansible all -m ping -o                                 # 어떤 VM이 응답하지 않는가
ssh orbit@192.168.100.101 kubectl get nodes
ssh orbit@192.168.100.101 kubectl get pods -A | grep -v Running
virsh -c qemu:///system list --all                     # astra VM 상태
```

### 3-1. Worker가 NotReady
```bash
ssh orbit@<worker IP> sudo systemctl status kubelet containerd --no-pager
ssh orbit@<worker IP> sudo journalctl -u kubelet -n 50 --no-pager
```
| 원인 | 조치 |
|---|---|
| VM 꺼짐 | `virsh -c qemu:///system start astra-worker-N` |
| kubelet/containerd 중지 | `ansible-playbook site.yml --limit astra-worker-N` (롤이 서비스 재기동) |
| 계속 실패 | 노드 제거 후 재가입 (아래) |

노드 제거 후 재가입:
```bash
ssh orbit@192.168.100.101 kubectl drain astra-worker-N --ignore-daemonsets --delete-emptydir-data
ssh orbit@192.168.100.101 kubectl delete node astra-worker-N
ssh orbit@<worker IP> sudo kubeadm reset -f
ansible-playbook site.yml --limit control_plane,astra-worker-N   # join 명령 재생성 + 재가입
ansible-playbook k8s-post.yml
```

### 3-2. Worker 배치와 예비 노드 관리

기본값은 `k8s_reserved_nodes: []`로 worker 3대 모두 일반 Pod를 받는다.
worker-3 개방은 HPA가 늘린 Pod의 배치 공간 부족이 부하 실험 결과에 섞이지 않게 하기 위한 구성이다 (#46).
원본 요구사항은 orbit의 `docs/phase1.md`, `docs/infrastructure-plan.md`를 따른다.

제어 노드의 `ansible/`에서 적용 전 대상 그룹과 변수 재정의 여부를 확인한 뒤 실행한다.

```bash
ansible-inventory --graph
# inventory/group_vars, host_vars, 실행 옵션에서 k8s_reserved_nodes를 재정의하지 않았는지 확인
ansible-playbook k8s-post.yml --syntax-check
ansible-playbook k8s-post.yml
```

control plane VM의 kubectl 사용 환경에서 예약 label과 taint 제거를 확인한다.

```bash
kubectl get nodes -L orbit.io/reserved
kubectl describe node astra-worker-3
```

worker-3에서 `orbit.io/reserved` label과 `orbit.io/reserved=true:NoSchedule` taint가 없어야 한다.
기존 스모크 테스트는 예약 목록이 비어 있으면 어느 노드에 배치돼도 통과하므로,
worker-3 지정 검증을 별도로 수행한다. 기존 Pod는 taint를 해제해도 자동 재배치되지 않는다.

아래 임시 Pod는 `nodeSelector`로 worker-3를 선택하고 예약 taint의 toleration은 넣지 않는다.
`nodeName` 직접 지정은 스케줄러를 우회하므로 사용하지 않는다.
같은 이름의 Pod가 없는지 먼저 확인한다 (NotFound가 정상).

```bash
kubectl -n default get pod orbit-worker3-smoke
kubectl -n default create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: orbit-worker3-smoke
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: astra-worker-3
  containers:
    - name: dns
      image: busybox:1.36
      command: ["nslookup", "kubernetes.default.svc.cluster.local"]
YAML
kubectl -n default wait pod/orbit-worker3-smoke \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl -n default get pod orbit-worker3-smoke -o wide
kubectl -n default logs orbit-worker3-smoke
```

`Succeeded`와 배치 노드 `astra-worker-3`, DNS 조회 성공을 확인한다.
실패하면 `kubectl -n default describe pod orbit-worker3-smoke`의 Events를 확인하고 결과를 기록한다.
확인이 끝나면 성공·실패와 관계없이 생성한 테스트 Pod를 삭제한다.

```bash
kubectl -n default delete pod orbit-worker3-smoke
```

제어 노드에서 `ansible-playbook k8s-post.yml`을 다시 실행하고,
예약 taint·label이 돌아오지 않는지 확인한다. 검증 기록에는 적용 Git SHA, 대상 클러스터,
실행 recap, 예약 taint·label 상태, 테스트 Pod의 배치 노드와 DNS 결과를 남긴다.
실제 클러스터에서 확인하기 전에는 검증 완료로 기록하지 않는다.

ASTRA는 물리 CPU 12스레드에 VM vCPU 합계 14개를 할당한다.
worker-3를 열어도 물리 CPU는 늘지 않으므로 부하 실험 기록에 이 조건과 호스트 CPU 사용률을 함께 남긴다.

필요할 때만 inventory의 그룹/호스트 변수로 `k8s_reserved_nodes`를 지정한다.
예를 들어 worker-3를 예비 노드로 지정하려면 `[astra-worker-3]`로 설정하고 `k8s-post.yml`을 실행한다.
다시 개방할 때는 재정의를 제거하거나 `[]`로 바꾸고 같은 플레이북을 실행한다.
`NoSchedule`은 새 일반 Pod 배치를 막으며 이미 실행 중인 Pod를 퇴거시키지는 않는다.

### 3-3. Control plane 장애
```bash
ssh orbit@192.168.100.101 sudo crictl ps -a | grep -E "apiserver|etcd|scheduler|controller"
ssh orbit@192.168.100.101 sudo journalctl -u kubelet -n 80 --no-pager
```
- 단순 재기동으로 해결되지 않고 etcd가 손상됐다면 [4-3 etcd 복구](#4-3-kubernetes-etcd) 또는 Lab 전체 재구축.

### 3-4. VM 자체를 잃었을 때 (재구축)
```bash
# Terraform 담당과 함께: 해당 VM 재생성 → hosts.ini 갱신
ansible-playbook preflight.yml --limit <VM>
ansible-playbook site.yml --ask-vault-pass --limit control_plane,<VM>
```
Lab 전체: `terraform destroy && terraform apply` → `ansible-playbook site.yml` (계획서 재구축 절차, 시간 기록).

### 3-5. DB 장애
```bash
ssh orbit@192.168.100.106 sudo systemctl status mysql --no-pager
ssh orbit@192.168.100.106 sudo journalctl -u mysql -n 50 --no-pager
ssh orbit@192.168.100.106 df -h /var/lib/mysql            # 디스크 가득 참 여부
```
| 원인 | 조치 |
|---|---|
| 서비스 중지 | `ansible-playbook database.yml --ask-vault-pass --limit astra-vehicle-db` |
| 데이터 디스크 미마운트 | `mount | grep mysql` 확인 → `database.yml` 재실행 (fstab 재적용) |
| 데이터 손상 | [4-1 DB 복구](#4-1-db) |
| VM 재생성 | 데이터 volume이 보존됐다면 `database.yml`만 실행 (기존 파일시스템은 포맷하지 않음) |

### 3-6. 원격 사이트(Sol·Terra·Luna) 연결 끊김
```bash
ansible remote -m ping -o
ansible-playbook preflight.yml --limit remote
```
| 증상 | 조치 |
|---|---|
| 노트북 절전 | 해당 노트북 깨우기, 절전 해제 설정 |
| Tailscale 끊김 | 해당 VM에서 `sudo tailscale up --accept-routes` |
| astra 대역 경로 없음 | astra: `tailscale up --advertise-routes=192.168.100.0/24` + 관리 콘솔 승인 |
| 지연 큼 (relay) | `tailscale status`에서 direct 여부 확인. 측정 결과에 relay 사용 명시 |

### 3-7. 모니터링 스택 장애

Prometheus·Alertmanager·Loki·Grafana는 이 레포의 Ansible이 아니라 monitoring VM에 systemd 서비스로 직접 구성한다 (orbit-observability#3). 장애 대응은 그 서비스 운영 절차를 따른다.

```bash
ssh orbit@192.168.100.107 'sudo systemctl status loki --no-pager'
ansible-playbook monitoring.yml --limit monitoring   # node-exporter만 재적용
```

---

## 4. Backup / Restore

### 4-1. DB

**자동 백업**: 매일 03:17, `/var/backups/mysql/<db>-YYYYmmdd-HHMMSS.sql.gz`, 7일 보관 (데이터 디스크와 다른 디스크).

```bash
# 수동 백업
ssh orbit@192.168.100.106 sudo /usr/local/sbin/orbit-db-backup

# 백업 목록
ssh orbit@192.168.100.106 sudo /usr/local/sbin/orbit-db-restore

# 복구 (복구 직전 상태를 자동으로 한 번 더 백업한 뒤 덮어씀)
ssh orbit@192.168.100.106 sudo /usr/local/sbin/orbit-db-restore vehicle-20261008-031700.sql.gz --yes
```

외부 보관 (astra로 복사):
```bash
mkdir -p ~/backups/vehicle-db
scp orbit@192.168.100.106:/var/backups/mysql/vehicle-*.sql.gz ~/backups/vehicle-db/   # 권한 오류 시 sudo cp 후 chown
```

복구 리허설 (분기 1회 권장): 테스트 VM에 DB 롤 적용 → 최신 백업 복사 → `orbit-db-restore --yes` → 앱 쿼리 확인.

### 4-2. Terraform state DB

**자동 백업**: 매일 18:00 UTC, PostgreSQL custom format을 GPG로 암호화해 ASTRA와 TERRA에 14일간 보관한다.

| 항목 | ASTRA | TERRA |
|---|---|---|
| 저장 경로 | `/var/backups/orbit/terraform-state` | `/home/orbit-backup/terraform-state` |
| 소유 계정 | `root` | `orbit-backup` |
| 디렉터리 권한 | `0700` | `0700` |
| 파일 권한 | `0600` | `0600` |

TERRA의 `orbit-backup` 계정과 `/home/orbit-backup/terraform-state` 디렉터리는
이 플레이북이 생성하지 않으므로 백업 실행 전에 별도로 준비해야 한다.

백업 암호는 `vault_terraform_state_backup_passphrase`로 관리한다. 암호를 교체하면 기존 백업 복구에는 이전 암호가 필요하므로, 해당 백업의 보관 기간이 끝날 때까지 이전 암호를 보관한다.

#### 백업 상태 확인과 수동 실행

ORBIT-ASTRA 호스트에서 실행한다.

```bash
# 백업 timer 실행 상태 확인
sudo systemctl status orbit-terraform-state-backup.timer --no-pager

# 마지막 실행 시각과 다음 실행 시각 확인
sudo systemctl list-timers orbit-terraform-state-backup.timer --no-pager

# 최근 백업 작업의 성공·실패 상태 확인
sudo systemctl status orbit-terraform-state-backup.service --no-pager

# 최근 백업 작업 로그 확인
sudo journalctl -u orbit-terraform-state-backup.service -n 50 --no-pager

# 백업을 지금 한 번 실행하고 ASTRA 저장·TERRA 전송까지 확인
sudo systemctl start orbit-terraform-state-backup.service
```

#### 백업 파일 확인

```bash
# ASTRA에 저장된 백업 파일의 이름·소유자·권한 확인
sudo find /var/backups/orbit/terraform-state \
  -maxdepth 1 -type f -name 'terraform_states-*.dump.gpg' \
  -printf '%M %u:%g %f\n'

# TERRA에 전송된 백업 파일의 이름·소유자·권한 확인
sudo ssh \
  -i /etc/orbit/terraform-state-backup-ssh \
  -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/orbit/terraform-state-backup-known_hosts \
  -o StrictHostKeyChecking=yes \
  orbit-backup@orbit-terra \
  "find /home/orbit-backup/terraform-state \
  -maxdepth 1 -type f -name 'terraform_states-*.dump.gpg' \
  -printf '%M %u:%g %f\n'"
```

ASTRA와 TERRA에 같은 이름의 파일이 있고 권한이 `0600`인지 확인한다.

#### 복구 검증

운영 DB에 직접 복원하지 않는다. ORBIT-ASTRA 호스트에서 백업을 별도의 시험 DB에 복원한다.

```bash
# 실제 복구할 파일명으로 변경해 지정
RESTORE_BACKUP="/var/backups/orbit/terraform-state/terraform_states-20261012T180000Z.dump.gpg"

# 복호화한 dump를 임시로 저장할 디렉터리 생성
sudo install -d -o root -g postgres -m 0750 \
  /run/orbit-terraform-state-restore

# GPG 백업을 PostgreSQL custom format dump로 복호화
sudo gpg --batch --yes --pinentry-mode loopback \
  --passphrase-file /etc/orbit/terraform-state-backup.passphrase \
  --output /run/orbit-terraform-state-restore/terraform_states.dump \
  --decrypt "$RESTORE_BACKUP"

# postgres 계정이 dump를 읽을 수 있도록 권한 설정
sudo chown root:postgres \
  /run/orbit-terraform-state-restore/terraform_states.dump
sudo chmod 0640 \
  /run/orbit-terraform-state-restore/terraform_states.dump

# 시험 DB가 이미 존재하는지 확인 — 결과가 없어야 다음 단계 진행
sudo -u postgres psql -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datname = 'terraform_states_restore_test';"

# 빈 시험 DB 생성
sudo -u postgres createdb terraform_states_restore_test

# 시험 DB에 dump 복원
sudo -u postgres pg_restore --exit-on-error \
  --dbname=terraform_states_restore_test \
  /run/orbit-terraform-state-restore/terraform_states.dump

# Terraform state 스키마 복원 여부 확인
sudo -u postgres psql \
  -d terraform_states_restore_test \
  -c '\dn'
```

출력에서 `terraform_remote_state_astra`와 `terraform_remote_state_jenkins` 스키마를 확인한 뒤 시험 데이터를 삭제한다.

```bash
# 시험 DB 삭제
sudo -u postgres dropdb terraform_states_restore_test

# 복호화한 평문 dump와 임시 디렉터리 삭제
sudo rm -f /run/orbit-terraform-state-restore/terraform_states.dump
sudo rmdir /run/orbit-terraform-state-restore
```

### 4-3. Kubernetes (etcd)

스냅샷 저장 (control plane의 `/var/lib/etcd/snapshot-*.db`):
```bash
ssh orbit@192.168.100.101 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system exec etcd-astra-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-$(date +%Y%m%d-%H%M).db'
```

복구 방침:
- Lab의 클러스터 상태(배포된 앱)는 **GitOps 저장소(Argo CD)가 원본**이다. etcd가 손상되면 우선 **클러스터 재구축 → Argo CD 재동기화**로 복구한다.
- etcd 스냅샷 복구(`etcdutl snapshot restore`)는 재구축이 불가능할 때만 사용하고, 수행 시 절차를 이 문서에 추가한다.

### 4-4. 모니터링 데이터

Prometheus·Loki 데이터는 retention 기간 동안만 보관하며 백업하지 않는다. 설정값과 보관 정책은 orbit-observability에서 관리한다.

---

## 5. 기록

| 날짜 | 작업 | 대상 | 결과 / 소요 시간 | 작업자 |
|---|---|---|---|---|
| | | | | |
