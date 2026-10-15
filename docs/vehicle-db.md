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
| 앱 계정 권한 | `vehicle.*`에 `SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES` | |
| `max_connections` | 200 | |
| 서버 파드당 Hikari pool | 5 | orbit-gitops#7 `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` |

## 접속 허용 host

Calico IP Pool은 `natOutgoing: Enabled`이다. Pod가 IP Pool 밖(DB VM)으로 나가면 출발지가 Pod IP가 아니라
그 Pod가 뜬 worker 노드 IP로 바뀐다. 그래서 앱 계정은 worker IP에서만 접속할 수 있게 만든다.

`db_allowed_hosts`에서 빠진 host의 앱 계정은 role이 지운다. 예전의 `vehicle_app@192.168.100.%`도 이렇게 정리된다.
worker를 추가하거나 IP를 바꾸면 이 목록부터 고친다.

## 권한

서버는 기동할 때마다 Flyway migration을 실행한다. 그래서 앱 계정에 DML과 함께 migration에 필요한
DDL(CREATE, ALTER, INDEX, DROP, REFERENCES)을 준다. 권한 범위는 `vehicle` DB로 한정한다.

migration용 계정과 앱용 계정을 나누려면 서버 설정도 바꿔야 하므로 별도 서버 이슈로 다룬다.

## 연결 수

```text
필요 연결 = pool × (최대 replica + 롤링 업데이트 중 추가 파드) + 운영 여유
         = 5 × (4 + 1) + 20 = 45  ≤  max_connections 200
```

- 운영 여유 20은 운영자·모니터링·백업 접속 몫이다.
- pool 크기를 지정하지 않으면 Hikari 기본값 10이 적용된다. 이때는 10 × 5 + 20 = 70이 되어도 200 안에 들어온다.
- `ansible-playbook database.yml -e db_verify=true`를 실행하면 실제 `max_connections` 값으로 이 식을 assert한다.

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
| 각 worker에서 DB 3306 포트 접속 | 모두 ok |
| 결과 출력의 `DB` | `vehicle (utf8mb4 / utf8mb4_unicode_ci)` |
| 결과 출력의 `권한` | worker host마다 `GRANT SELECT, INSERT, ... ON vehicle.*` |

DB VM 자신은 허용 host가 아니므로 Ansible은 앱 계정으로 로그인하지 않는다.

### Pod에서 앱 계정 로그인

실제 출발지에서 확인한다. 비밀번호는 프롬프트로 입력하고 명령줄이나 문서에 남기지 않는다.

```bash
ssh -t orbit@192.168.100.101 kubectl run mysql-check -n orbit -it --rm --restart=Never \
  --image=mysql:8.4 -- mysql -h 192.168.100.106 -u vehicle_app -p vehicle \
  -e "SELECT CURRENT_USER(), @@max_connections"
```

`CURRENT_USER()`가 `vehicle_app@192.168.100.10x`(worker IP)로 나오면 정상이다.

### Flyway 적용

orbit-gitops#7 배포로 서버가 기동한 뒤 DB VM에서 확인한다.

```bash
ssh orbit@192.168.100.106 sudo mysql vehicle \
  -e "SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank"
```

모든 행의 `success`가 `1`이면 정상이다.

## 다른 저장소로 전달

- orbit-gitops#7: DB명 `vehicle`, 계정명 `vehicle_app`, 파드당 pool 상한 5
- 비밀번호: orbit-gitops#3 절차로 `orbit-server-secret`에 넣는다. 원문은 문서·이슈에 남기지 않는다.
