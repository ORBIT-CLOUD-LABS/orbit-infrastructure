# ORBIT Lab 운영 Runbook

Lab 인프라(astra + Sol·Terra·Luna)를 적용·되돌리기·복구·백업할 때 따르는 절차.
모든 명령은 **제어 노드(astra)** 의 `~/ws-<이름>/orbit-infrastructure/ansible` 에서 실행한다.

| 상황 | 바로 가기 |
|---|---|
| 처음 구축 / 변경 적용 | [1. 적용](#1-적용) |
| 변경이 문제를 일으킴 | [2. Rollback](#2-rollback) |
| 노드·서비스 장애 | [3. 장애 복구](#3-장애-복구) |
| DB·클러스터 백업과 복구 | [4. Backup / Restore](#4-backup--restore) |

---

## 0. 공통 규칙

- VM에 손으로 설치·수정하지 않는다. 급하게 했다면 그 주 안에 롤로 옮긴다 (계획서 규칙 3).
- 모든 변경은 Issue → Branch → PR → 리뷰 후 main 반영. 운영 적용은 **main 기준**으로 한다.
- 비밀값은 `secrets/vault.yml`(ansible-vault 암호화)에만 둔다. vault 비밀번호는 Slack DM으로만 공유.
- 작업 전후로 Slack `#orbit-infra`에 "적용 시작 / 완료(결과)" 한 줄을 남긴다.

### 플레이북 구성

| 플레이북 | 대상 | 내용 |
|---|---|---|
| `preflight.yml` | 전체 | 접속·OS·자원·중복·포트·인터넷·원격 사이트 경로 점검 (변경 없음) |
| `site.yml` | 전체 | preflight → k8s 설치 → 후처리 → DB → Monitoring (+NFS·Jenkins) |
| `k8s-post.yml` | control_plane | node label, Worker 3 예비 taint, 클러스터 검증 |
| `database.yml` | vehicle_db, campaign_db | MySQL, 데이터 디스크, 접근 제어, 백업 |
| `monitoring.yml` | 전체 + monitoring | node-exporter, Prometheus·Alertmanager·Loki·Grafana |

---

## 1. 적용

### 1-1. 사전 확인
```bash
git checkout main && git pull
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
ssh orbit@192.168.100.100 kubectl get nodes -L orbit.io/reserved
ansible-playbook database.yml --ask-vault-pass -e db_verify=true   # DB 접속 + 백업 검증
ansible-playbook site.yml --ask-vault-pass                     # 재실행 → PLAY RECAP changed ≈ 0 (멱등성)
```

---

## 2. Rollback

원칙: **코드를 되돌리고 다시 적용한다.** VM 안에서 손으로 되돌리지 않는다.

### 2-1. 설정 변경 되돌리기 (기본)
```bash
git log --oneline -10                 # 문제 커밋 확인
git revert <커밋>                      # 새 브랜치에서 → PR → 리뷰 → 머지
git checkout main && git pull
ansible-playbook site.yml --ask-vault-pass
```

### 2-2. 항목별 되돌리기

| 항목 | 방법 |
|---|---|
| 예비 노드 해제/지정 | `k8s_reserved_nodes` 수정 후 `ansible-playbook k8s-post.yml` (목록에서 빠진 노드는 taint 자동 제거) |
| 모니터링 이미지 버전 | `roles/monitoring_host/defaults/main.yml`의 이미지 태그를 이전 값으로 → `monitoring.yml` |
| Prometheus/Loki retention | 같은 파일의 retention 값 → `monitoring.yml` (줄이면 오래된 데이터 삭제됨) |
| MySQL 설정 | `templates/99-orbit.cnf.j2` 되돌림 → `database.yml` (MySQL 재시작 발생) |
| DB 데이터 | [4-1 DB 복구](#4-1-db) |
| Kubernetes 버전 | `k8s_version` 되돌림만으로는 **다운그레이드 안 됨** (패키지 hold). 노드 재구축으로 처리 → [3-4](#3-4-vm-자체를-잃었을-때-재구축) |

---

## 3. 장애 복구

먼저 범위를 확인한다.
```bash
ansible all -m ping -o                                 # 어떤 VM이 응답하지 않는가
ssh orbit@192.168.100.100 kubectl get nodes
ssh orbit@192.168.100.100 kubectl get pods -A | grep -v Running
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
ssh orbit@192.168.100.100 kubectl drain astra-worker-N --ignore-daemonsets --delete-emptydir-data
ssh orbit@192.168.100.100 kubectl delete node astra-worker-N
ssh orbit@<worker IP> sudo kubeadm reset -f
ansible-playbook site.yml --limit control_plane,astra-worker-N   # join 명령 재생성 + 재가입
ansible-playbook k8s-post.yml
```

### 3-2. 예비 노드(Worker 3) 투입
Worker 1·2 중 하나가 장시간 복구 불가일 때:
```bash
# group_vars 또는 -e 로 예비 목록을 비우고 적용
ansible-playbook k8s-post.yml -e '{"k8s_reserved_nodes": []}'
```
복구 후 원래대로: `ansible-playbook k8s-post.yml` (기본값으로 다시 taint).

### 3-3. Control plane 장애
```bash
ssh orbit@192.168.100.100 sudo crictl ps -a | grep -E "apiserver|etcd|scheduler|controller"
ssh orbit@192.168.100.100 sudo journalctl -u kubelet -n 80 --no-pager
```
- 단순 재기동으로 해결되지 않고 etcd가 손상됐다면 [4-2 etcd 복구](#4-2-kubernetes-etcd) 또는 Lab 전체 재구축.

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
```bash
ssh orbit@192.168.100.107 'cd /opt/orbit-monitoring && sudo docker compose ps && sudo docker compose logs --tail 50'
ansible-playbook monitoring.yml --ask-vault-pass --limit monitoring
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

### 4-2. Kubernetes (etcd)

스냅샷 저장 (control plane의 `/var/lib/etcd/snapshot-*.db`):
```bash
ssh orbit@192.168.100.100 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system exec etcd-astra-control-plane -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-$(date +%Y%m%d-%H%M).db'
```

복구 방침:
- Lab의 클러스터 상태(배포된 앱)는 **GitOps 저장소(Argo CD)가 원본**이다. etcd가 손상되면 우선 **클러스터 재구축 → Argo CD 재동기화**로 복구한다.
- etcd 스냅샷 복구(`etcdutl snapshot restore`)는 재구축이 불가능할 때만 사용하고, 수행 시 절차를 이 문서에 추가한다.

### 4-3. 모니터링 데이터

Prometheus·Loki 데이터는 retention(15일/14일) 동안만 보관하며 백업하지 않는다. 대시보드·알림 규칙은 Git(롤 템플릿)이 원본이다.

---

## 5. 기록

| 날짜 | 작업 | 대상 | 결과 / 소요 시간 | 작업자 |
|---|---|---|---|---|
| | | | | |
