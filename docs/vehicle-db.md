# Vehicle DB 앱 계정·연결 상한 (#44)

관련 작업: [infrastructure #44](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/44).
요구사항 원본의 `docs/phase1.md`, `docs/infrastructure-plan.md`에서 DB VM 주소와 `max_connections`를 확인했다.
해당 문서에는 이 작업에 대응하는 REQ ID가 없어 임의로 추가하지 않는다.

설정 원본은 `ansible/group_vars/vehicle_db.yml`과 `ansible/roles/database`이다. 값을 바꾸면 이 문서도 함께 고친다.

## 확정 값

| 항목 | 값 | 비고 |
| --- | --- | --- |
| DB 주소 | `192.168.100.106:3306` | `astra-vehicle-db` |
| DB명 | `vehicle` | `utf8mb4` / `utf8mb4_unicode_ci` |
| 앱 계정 | `vehicle_app` | 비밀번호는 Vault(`vault_vehicle_db_password`)에만 둔다 |
| 접속 허용 host | `192.168.100.102`, `.103`, `.104` | `astra-worker-1` ~ `3` |
| 앱 계정 권한 | `vehicle.*`에 `SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE VIEW, ALTER, INDEX, DROP, REFERENCES` | |
| `max_connections` | 200 | |
| 서버 파드당 Hikari pool | 5 | orbit-gitops#7 `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` |
| `innodb_flush_log_at_trx_commit` | 2 | 아래 "commit 동기화" |
| `sync_binlog` | 0 | 아래 "commit 동기화" |

## 접속 허용 host

Calico IP Pool은 `natOutgoing: Enabled`이다. Pod가 IP Pool 밖(DB VM)으로 나가면 출발지가 Pod IP가 아니라
그 Pod가 뜬 worker 노드 IP로 바뀐다. 그래서 앱 계정은 worker IP에서만 접속할 수 있게 만든다.

`db_allowed_hosts`에서 빠진 host의 앱 계정은 role이 지운다. 예전의 `vehicle_app@192.168.100.%`도 이렇게 정리된다.
worker를 추가하거나 IP를 바꾸면 이 목록부터 고친다. 이때 뷰 DEFINER도 함께 확인한다 (아래 [권한](#권한)).

## 권한

서버는 기동할 때마다 Flyway migration을 실행한다. 그래서 앱 계정에 DML과 함께 migration에 필요한
DDL(CREATE, CREATE VIEW, ALTER, INDEX, DROP, REFERENCES)을 준다. 권한 범위는 `vehicle` DB로 한정한다.

- MySQL은 뷰 생성을 `CREATE`와 별도인 `CREATE VIEW` 권한으로 다룬다. orbit-server의
  `V2__create_vehicle_status_view.sql`이 `vehicle_status` 뷰를 만들므로 이 권한이 없으면 Flyway가 실패해 서버가 기동하지 않는다.
- 나중에 뷰를 `CREATE OR REPLACE VIEW`로 바꾸는 migration은 `CREATE VIEW`와 `DROP`을 함께 쓴다. 둘 다 부여되어 있다.
- migration을 추가할 때 트리거·프로시저·이벤트처럼 위 목록에 없는 객체를 만들면 권한(`TRIGGER`, `CREATE ROUTINE`, `EVENT` 등)을 먼저 추가한다.

뷰는 기본값으로 `DEFINER = 만든 계정@host`, `SQL SECURITY DEFINER`로 생성된다. Flyway를 실행한 Pod가 있던 worker의 계정
(예: `vehicle_app@192.168.100.103`)이 DEFINER가 된다. 그 host가 허용 목록에서 빠져 계정이 지워지면 뷰 조회가 실패하므로,
worker를 바꾸기 전에 확인한다.

```bash
ssh orbit@192.168.100.106 'sudo mysql -e "SELECT TABLE_NAME, DEFINER FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \"vehicle\""'
```

migration용 계정과 앱용 계정을 나누려면 서버 설정도 바꿔야 하므로 별도 서버 이슈로 다룬다.

## 연결 수

```text
필요 연결 = pool × (최대 replica + 롤링 업데이트 중 추가 파드) + 운영 여유
         = 5 × (4 + 1) + 20 = 45  ≤  max_connections 200
```

- 운영 여유 20은 운영자·모니터링·백업 접속 몫이다.
- pool 크기를 지정하지 않으면 Hikari 기본값 10이 적용된다. 이때는 10 × 5 + 20 = 70이 되어도 200 안에 들어온다.
- `ansible-playbook database.yml -e db_verify=true`를 실행하면 실제 `max_connections` 값으로 이 식을 assert한다.

## commit 동기화

MySQL 기본값(`innodb_flush_log_at_trx_commit=1`, `sync_binlog=1`)은 commit 마다 redo log 와 binlog 를 디스크에 동기화(fsync)한다. 서버는 체크인마다 트랜잭션을 commit 하므로 요청 수만큼 동기화가 생긴다.

DB 데이터 디스크는 ASTRA 호스트 NVMe(Samsung SSD 980, DRAM 없는 소비자용, 모든 VM 공유) 위의 raw 파일이다. 2026-10-17 서버 부하 사전 측정([orbit#23](https://github.com/ORBIT-CLOUD-LABS/orbit/issues/23))에서 다음을 확인했다.

| DB 설정 | DB 한계 (P95 500ms 기준) | 막힌 곳 |
| --- | --- | --- |
| 기본값 (1 / 1) | 약 290 req/s, 쓰기가 몇 분 이어지면 약 180 | 디스크 동기화. 쓰기 약 2300회/s 에서 꺾이고, 계속되면 쓰기 지연이 0.35 → 1.1~1.5ms 로 늘어 20분가량 쉬어야 회복. DB CPU(user+system)는 55~58% |
| 완화 (2 / 0) | 약 700~750 req/s | DB CPU (user+system 93~98%). 디스크 쓰기 약 50회/s, iowait 거의 0 |

그래서 redo log 는 1초마다 동기화(`innodb_flush_log_at_trx_commit=2`)하고 binlog 동기화는 OS 에 맡긴다(`sync_binlog=0`).

- 대가: DB VM 이나 ASTRA 호스트가 갑자기 꺼지면 최대 약 1초치 commit 이 유실될 수 있다. MySQL 프로세스만 죽는 경우에는 유실되지 않는다
- 차량은 다음 체크인 주기에 상태를 다시 보내므로 체크인 기록 유실은 다음 주기에 복구된다. 관리자 작업(파일·캠페인 등록)은 장애 직후 결과를 확인한다
- 설정을 바꾸면 Ansible 이 MySQL 을 재시작한다. 부하 실험 중에는 적용하지 않는다

## 시간대

DB 기본 시간대는 `+09:00`이다. 서버는 접속할 때 세션 시간대를 `+00:00`으로 강제하므로 시간대 테이블을 적재하지 않아도 된다.

## 검증

### Ansible

```bash
cd ansible
ansible-playbook database.yml --ask-vault-pass -e db_verify=true
```

| 확인 항목 | 기대 결과 |
| --- | --- |
| 연결 수 assert | `필요 연결 45 ≤ max_connections 200` |
| commit 동기화 설정 | `ssh orbit@192.168.100.106 'sudo mysql -e "SELECT @@innodb_flush_log_at_trx_commit, @@sync_binlog"'` 결과 `2  0` |
| 각 worker에서 DB 3306 포트 접속 | 모두 ok |
| 결과 출력의 `DB` | `vehicle (utf8mb4 / utf8mb4_unicode_ci)` |
| 결과 출력의 `권한` | worker host마다 `GRANT SELECT, INSERT, ... ON vehicle.*` |

DB VM 자신은 허용 host가 아니므로 Ansible은 앱 계정으로 로그인하지 않는다.

### Pod에서 앱 계정 로그인

실제 출발지에서 확인한다. 비밀번호는 프롬프트로 입력하고 명령줄이나 문서에 남기지 않는다.
ssh는 원격 명령을 한 줄로 이어 붙여 넘기므로 원격 명령 전체를 작은따옴표로 감싼다.

```bash
ssh -t orbit@192.168.100.101 'kubectl run mysql-check -n orbit -it --rm --restart=Never --image=mysql:8.4 -- mysql -h 192.168.100.106 -u vehicle_app -p vehicle -e "SELECT CURRENT_USER(), @@max_connections"'
```

- `If you don't see a command prompt, try pressing enter.`만 보이면 그 상태에서 비밀번호를 입력한다.
- `CURRENT_USER()`가 `vehicle_app@192.168.100.10x`(worker IP)로 나오면 정상이다.
- 뷰 권한까지 보려면 `-e` 쿼리를 `CREATE VIEW zz_priv_check AS SELECT 1 AS ok; DROP VIEW zz_priv_check`로 바꿔 실행한다. 오류 없이 끝나면 된다.
- 이미지 pull이 늦어 attach가 끊기면 `mysql-check` Pod가 남는다. `kubectl delete pod mysql-check -n orbit` 후 다시 실행한다.

### Flyway 적용

orbit-gitops#7 배포로 서버가 기동한 뒤 DB VM에서 확인한다.

```bash
ssh orbit@192.168.100.106 'sudo mysql vehicle -e "SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank"'
```

모든 행의 `success`가 `1`이면 정상이다.

## 다른 저장소로 전달

- orbit-gitops#7: DB명 `vehicle`, 계정명 `vehicle_app`, 파드당 pool 상한 5
- 비밀번호: orbit-gitops#3 절차로 `orbit-server-secret`에 넣는다. 원문은 문서·이슈에 남기지 않는다.
