# Vault, SSH CA와 앱 비밀값

구현: [#7](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/7).
KV·Kubernetes 인증: [#13](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/13). 2026-11-02 astra에 적용하고 적용 후 미리보기에서 추가 변경 없음(`changed=0`)을 확인했다. 실제 k3s 로그인·권한 거부와 GitHub 조회·쓰기·부분 수정 및 SSH 서명을 검증했다. 시험 리소스 정리 완료는 별도 확인이 필요하며 root token 폐기는 운영자 요청으로 보류 중이다.
이 문서에는 이름과 절차만 기록한다. unseal 키, 토큰, 비밀번호, GitHub PAT 값은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다.

## 구성

| 항목 | 값 |
| --- | --- |
| 위치 | astra 호스트에 직접 설치 (systemd `vault`, 버전 고정·apt hold) |
| 주소 | 내부망 `https://10.0.0.201:8200` (팀원은 Tailscale subnet router 경유), astra 안 `https://127.0.0.1:8200` |
| TLS | 내부 CA `/opt/vault/tls/vault-ca.crt` (2036년 만료), 서버 인증서 `vault.crt` (2029-02-03 만료) |
| 저장소 | 단일 노드 Raft `/opt/vault/data`. 8201은 `127.0.0.1`에만 염 |
| 방화벽 | 8200은 `lo`, `br0`, `tailscale0`에서만 받음 (INPUT 맨 앞 `ORBIT-VAULT` 체인). 와이파이 등 나머지는 DROP |
| unseal | Shamir 5개 중 2개. 팀원 5명이 하나씩 보관. 같은 정족수로 임시 root를 만들 수 있음 (`generate-root`) |
| 감사 로그 | `/var/log/vault/audit.log` (`0600 vault`). 매일 회전, 14개 보관 |
| SSH CA | 엔진 `ssh-client-signer`, 역할 `orbit`, 정책 `ssh-orbit`. CA 키 ed25519 |
| 인증서 | `orbit` 계정만, 최대 8시간, 인증서 ID는 서버가 정함 (`github-<아이디>`, `userpass-<이름>`) |
| 로그인 | GitHub (`ORBIT-CLOUD-LABS`의 `orbit` 팀), 비상용 userpass `breakglass1`, `breakglass2`. 토큰 기본 8시간, 최대 24시간 |
| 노드 | 인벤토리 전체(노드 5대, VM 3대)가 `/etc/ssh/trusted-user-ca-keys.pem`을 신뢰 (`sshd_config.d/10-orbit-ssh-ca.conf`). 기존 `authorized_keys`는 그대로 |
| 비밀값 | KV v2 `secret/`. k3s 앱 `orbit/k3s/<앱 이름>`(ESO 연동 후 Kubernetes Secret으로 복제), 인프라 `orbit/infra/<서비스 이름>`(ESO 접근 불가). 원본은 Vault에서 관리 |
| Kubernetes 인증 | `auth/kubernetes`, API `https://10.0.0.200:6443`, 별도 reviewer JWT 없이 로그인 JWT로 TokenReview |
| ESO 역할 | `eso`: `external-secrets/external-secrets`만 허용, `eso-orbit` 정책, 토큰 기본·최대 수명 1시간 |

## 플레이북

astra에서 실행한다 (`ansible_connection: local`).

| 플레이북 | 하는 일 |
| --- | --- |
| `playbooks/vault.yml` | 설치, TLS, 방화벽, 감사 로그 회전, 상태 확인. `VAULT_TOKEN`이 있으면 Vault 안의 설정(감사 장치, SSH CA, 정책, 로그인)까지 |
| `playbooks/ssh-ca.yml` | 노드와 VM이 SSH CA를 신뢰하게 함. 한 대씩 적용하고, 검증에 실패하면 그 노드를 원래대로 되돌린 뒤 멈춤 |

- Vault 안의 설정은 관리자 토큰이 있을 때만 바뀐다. 토큰 없이 실행하면 설치와 확인만 한다.
- **버전(`hvault_version`)이나 `vault.hcl`이 바뀌면 Vault가 재시작되어 sealed가 된다.** unseal할 사람 2명이 있을 때 실행한다.
- SSH CA 키는 없을 때만 만들고 다시 만들지 않는다. 같은 경로에 다른 종류의 엔진·감사 장치가 있으면 덮어쓰지 않고 멈춘다.
- 비상 계정 비밀번호는 `inventory/group_vars/all/vault.yml`(ansible-vault)의 `vault_breakglass1_password`, `vault_breakglass2_password`. 계정을 처음 만들 때만 쓰인다.
- 관리자 토큰으로 실행하면 미리보기에서도 polaris에 SSH·sudo로 접속해 k3s CA를 읽는다. 읽기 실패 시 Vault 내부 설정을 쓰기 전에 멈춘다.
- `secret/`은 `type=kv`, `options.version=2`여야 한다. KV v1·다른 엔진이나 같은 경로의 다른 인증 방식은 자동 전환하지 않는다. 기존 별도 reviewer JWT가 있어도 중단한다.

## 비밀값 경로와 권한

비밀값은 모두 Vault에 둔다. k3s에서 쓰는 값과 인프라 관리용 값은 경로로 나누고, ESO는 k3s 구역만 읽는다. Elasticsearch 관리자 비밀번호처럼 k3s에 노출하면 안 되는 값은 인프라 구역에 둔다.

| 구분 | k3s 앱 | 인프라 |
| --- | --- | --- |
| 용도 | k3s 앱·에이전트가 쓰는 값 (예: `orbit-server`, k3s Fluent Bit 쓰기 계정) | Ansible·관리자가 쓰는 값 (예: `efk`의 Elasticsearch 관리자·Kibana·호스트 수집 계정) |
| CLI 경로 | `vault kv put -mount=secret orbit/k3s/<앱 이름> ...` | `vault kv put -mount=secret orbit/infra/<서비스 이름> ...` |
| Vault ACL·API 경로 | `secret/data/orbit/k3s/<앱 이름>` | `secret/data/orbit/infra/<서비스 이름>` |
| ESO | Store `path: secret`, `version: v2`. ExternalSecret `remoteRef.key: orbit/k3s/<앱 이름>`, `property: <키 이름>` | 읽을 수 없음 |

`orbit/` 바로 아래나 두 구역 밖에는 새 경로를 만들지 않는다. 비상 계정 비밀번호처럼 Vault가 없거나 고장 났을 때 필요한 값만 ansible-vault(`vault.yml`)에 둔다.

| 주체 | 정책 | 허용 범위 |
| --- | --- | --- |
| GitHub `orbit` 팀 | `ssh-orbit`, `orbit-secrets-write` | 기존 SSH 서명 + `secret/data/orbit/*`(k3s·인프라 두 구역) 조회·생성·전체 교체·부분 수정 |
| GitHub 사용자 (개인 명단) | `ssh-personal-<계정명>` | 본인 역할 `ssh-client-signer/sign/personal-<계정명>`의 서명만. 팀 정책에 더해짐. 명단에서 빠지면 Vault 플레이북이 삭제 ([개인 계정 문서](personal-accounts.md#vault-개인-ssh-역할정책)) |
| ESO SA | `eso-orbit` | `secret/data/orbit/k3s/*` 읽기만. 앱별 격리가 아닌 k3s 앱 공용 권한. 인프라 구역은 읽지 못함 |
| 비상 userpass 계정 | `ssh-orbit` | SSH 서명만 |
| 임시 root | `root` | 엔진·인증·정책 관리와 검증·정리. 완료 후 폐기 |

쓰기 정책은 `create`, `read`, `update`, `patch`를 허용하며 목록·삭제·SSH 서명 권한은 없다. SSH 서명은 별도 `ssh-orbit` 정책으로 허용한다. 이 정책들은 VM의 파일 권한이나 sudo 권한을 바꾸지 않는다. 현재는 orbit 팀원 전원이 k3s 앱과 인프라의 비밀값을 모두 읽고 바꿀 수 있다.

### 값 넣기·바꾸기

Vault CLI가 있는 macOS/Linux의 Bash에서 실행한다. 먼저 위의 접속 환경 변수(`VAULT_ADDR`, `VAULT_CACERT`)를 설정한다. root를 사용하는 운영 검증 터미널과 별도 터미널을 사용한다.

```bash
set +x
set -o pipefail
unset VAULT_TOKEN
VAULT_TOKEN=$(vault login -token-only -method=github)
export VAULT_TOKEN
```

PAT는 프롬프트에 입력한다. 새 로그인 토큰에 `ssh-orbit`, `orbit-secrets-write`가 있는지 `vault token lookup -format=json | jq '.data.policies'`로 확인한다. 비밀값은 인자·history에 쓰지 말고 보호된 JSON 파일로 입력한다. 다음은 `orbit-server`를 처음 만들 때 세 키를 숨김 입력하는 예다 (Python 3 필요).

```bash
umask 077
ORBIT_SECRET_FILE=$(mktemp)
python3 - "$ORBIT_SECRET_FILE" <<'PY'
import getpass, json, sys
values = {key: getpass.getpass(key + ': ')
          for key in ('DB_PASSWORD', 'ENROLLMENT_KEY', 'ADMIN_TOKEN')}
with open(sys.argv[1], 'w') as output:
    json.dump(values, output)
PY
# Python 입력이 성공한 경우에만 실행한다.
vault kv put -mount=secret orbit/k3s/orbit-server @"$ORBIT_SECRET_FILE"
rm -f "$ORBIT_SECRET_FILE"
unset ORBIT_SECRET_FILE
```

실패·중단 시에도 임시 파일은 삭제한다. 실제 앱이 요구하는 키 목록에 맞춰 입력한다. **`kv put`은 전체 교체이므로 변경하지 않는 키도 모두 다시 넣어야 한다.** 생략한 키는 새 버전에서 사라진다. 기존 값의 일부만 바꿀 때는 아래처럼 `kv patch`를 사용한다. 입력한 키만 갱신하고 다른 키는 유지한다. 존재하지 않는 경로에는 먼저 `put`으로 초기 값을 생성해야 한다.

```bash
read -rsp '새 ADMIN_TOKEN: ' ORBIT_ADMIN_TOKEN; printf '\n'
printf '%s' "$ORBIT_ADMIN_TOKEN" | vault kv patch -method=patch -mount=secret orbit/k3s/orbit-server ADMIN_TOKEN=-
unset ORBIT_ADMIN_TOKEN
```

기존 값 확인이 필요하면 `vault kv get -mount=secret orbit/k3s/orbit-server`를 사용한다. 실제 비밀값이 화면에 나오므로 화면 공유·터미널 녹화·출력 저장을 피한다. 여러 사람이 동시에 같은 키를 수정하지 않도록 조율한다.

ESO 설치 후에는 동기화 주기 또는 강제 동기화로 반영하며, `envFrom` 환경 변수는 파드 재시작 후 새 값을 읽는다. 기존 Secret이 있는 상태에서 Vault가 멈추면 동기화는 실패하지만 앱은 기존 값을 사용한다. Secret이 없거나 클러스터를 재구축했다면 Vault 복구·unseal 전에는 재생성할 수 없다.

입력 작업이 끝나면 `vault token revoke -self && unset VAULT_TOKEN`으로 해당 GitHub 토큰을 폐기한다. [KV put 공식 문서](https://developer.hashicorp.com/vault/docs/commands/kv/put).

## KV·Kubernetes 인증 운영 적용과 검증

이 절차는 astra의 Bash에서, 저장소 `ansible/` 디렉터리를 기준으로 실행한다. Vault CLI·kubectl·jq, polaris SSH·sudo 권한, `~/.kube/orbit-k3s.yaml`이 필요하다. kubeconfig는 k3s 플레이북이 astra 실행 사용자에게 `0600`으로 저장한 관리자 자격 증명이며 Git에 넣지 않는다. Argo CD·ESO 설치 전에도 임시 SA로 검증할 수 있다.

### 설정 출처와 적용

- API 주소는 `inventory/hosts.yml`의 첫 `cp` 호스트(polaris)의 `lan_ip`와 포트 6443으로 만든다.
- k3s CA는 그 호스트의 `/var/lib/rancher/k3s/server/tls/server-ca.crt`에서 읽는다. Git에 복사하지 않는다. 클러스터 재생성 후 CA가 바뀌면 플레이북 재실행으로 갱신한다.
- `hvault_eso_audience`는 `https://kubernetes.default.svc.cluster.local`이다. ESO TokenRequest에도 같은 값을 사용해야 하며 실제 k3s API가 허용하는지 아래 로그인으로 검증한다.
- Vault는 `disable_local_ca_jwt=true`이고 별도 reviewer JWT를 저장하지 않는다. 따라서 로그인하는 SA에 `system:auth-delegator` 권한이 필요하다. [Vault Kubernetes 인증 API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes).

먼저 `set +x`와 `set -o pipefail`을 실행한다. 파이프 앞의 토큰 발급 실패도 성공으로 처리하지 않게 한다.

1. [관리자 권한](#관리자-권한) 절차로 임시 root를 준비한다. 최초 root가 아직 유효하면 그것을 사용한다. `set +x`로 셸 추적을 끄고 root는 `VAULT_TOKEN`에 숨김 입력한다.
2. 변경 전 GitHub 팀 매핑을 `vault read -field=value auth/github/map/teams/orbit`로 기록한다. 실패 시 이 매핑으로 되돌릴 수 있게 한다.
3. 다음 미리보기 → 적용 → 재실행을 수행한다. polaris CA 조회가 성공하고 예상한 항목만 변경되는지 본다. 재실행은 바뀔 설정 목록 `[]`와 `설정 쓰기` 생략을 확인한다. 전체 플레이북의 다른 작업이 아니라 Vault 내부 설정의 무변경을 확인한다.

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=/opt/vault/tls/vault-ca.crt
ansible-playbook playbooks/vault.yml -K --ask-vault-pass --check --diff
ansible-playbook playbooks/vault.yml -K --ask-vault-pass
ansible-playbook playbooks/vault.yml -K --ask-vault-pass
```

위 명령은 최초 root가 유효하고 `hvault_allow_generate_root=false`인 현재 절차 기준이다. 이때 `-e hvault_allow_generate_root=true`를 추가하지 않는다. 꺼진 설정을 켜면 Vault가 재시작되어 sealed가 된다. 최초 root가 없어서 [관리자 권한](#관리자-권한)의 generate-root 절차로 임시 root를 만든 경우에만, 허용 설정을 켜고 unseal을 마친 뒤 세 명령 모두에 `-e hvault_allow_generate_root=true`를 붙여 설정을 유지한다.

검증 실패 시 root는 유지하고 원인을 해결한 뒤 재검증한다. SSH 발급이 막히면 `vault write auth/github/map/teams/orbit value=<변경 전 매핑>`으로 복구하고 코드도 맞춘다.

### 실제 k3s 로그인·권한 검증

아래 리소스가 모두 없는지 먼저 확인한다. 이미 있으면 생성·삭제를 진행하지 말고 소유자와 정리 범위를 확인한다. 특히 ESO 설치 후에는 기존 `external-secrets` namespace나 SA를 삭제하면 안 된다.

```bash
export KUBECONFIG="$HOME/.kube/orbit-k3s.yaml"
kubectl get namespace external-secrets vault-auth-check
kubectl get clusterrolebinding orbit-vault-auth-check
# 모두 NotFound일 때만 아래 생성 진행
kubectl create namespace external-secrets
kubectl create namespace vault-auth-check
kubectl -n external-secrets create serviceaccount external-secrets
kubectl -n external-secrets create serviceaccount vault-auth-denied
kubectl -n vault-auth-check create serviceaccount external-secrets
kubectl create clusterrolebinding orbit-vault-auth-check \
  --clusterrole=system:auth-delegator \
  --serviceaccount=external-secrets:external-secrets \
  --serviceaccount=external-secrets:vault-auth-denied \
  --serviceaccount=vault-auth-check:external-secrets
```

거부 시험용 SA에도 TokenReview 권한을 줘야 단순한 API 권한 부족이 아닌 Vault 역할의 이름·namespace 제한을 검증할 수 있다. 다음은 root가 `VAULT_TOKEN`에 남아 있는 같은 터미널에서 실행한다. 시험 경로는 충돌하지 않는 이름을 만들고 가짜 값만 쓴다.

```bash
ORBIT_TEST_PATH="orbit/k3s/vault-auth-check-$(date +%s)-$$"
vault kv put -mount=secret "$ORBIT_TEST_PATH" CHECK=dev-only-fake-value KEEP=unchanged
ESO_LOGIN=$(kubectl -n external-secrets create token external-secrets \
  --audience=https://kubernetes.default.svc.cluster.local --duration=10m | \
  vault write -format=json auth/kubernetes/login role=eso jwt=-)
# 로그인 명령이 성공한 경우에만 진행. 출력에는 토큰이 있으므로 echo하지 않음
ESO_TOKEN=$(printf '%s' "$ESO_LOGIN" | jq -er '.auth.client_token')
ESO_ACCESSOR=$(printf '%s' "$ESO_LOGIN" | jq -er '.auth.accessor')
unset ESO_LOGIN
VAULT_TOKEN="$ESO_TOKEN" vault kv get -mount=secret -field=CHECK "$ORBIT_TEST_PATH"
# 위는 dev-only-fake-value. 아래 셋은 반드시 403 permission denied (구역 밖, 인프라 구역, 쓰기)
VAULT_TOKEN="$ESO_TOKEN" vault kv get -mount=secret "outside-$ORBIT_TEST_PATH"
VAULT_TOKEN="$ESO_TOKEN" vault kv get -mount=secret "orbit/infra/${ORBIT_TEST_PATH#orbit/k3s/}"
VAULT_TOKEN="$ESO_TOKEN" vault kv put -mount=secret "$ORBIT_TEST_PATH" CHECK=denied
```

다음 두 로그인도 각각 실패해야 한다. 실패 원인은 SA 이름 또는 namespace 불일치여야 하며 TLS·네트워크·audience·TokenReview 권한 오류로 대신 통과 처리하지 않는다. 성공해 버리면 즉시 시험을 멈추고 역할 설정을 확인한다.

```bash
kubectl -n external-secrets create token vault-auth-denied \
  --audience=https://kubernetes.default.svc.cluster.local --duration=10m | \
  vault write auth/kubernetes/login role=eso jwt=- >/dev/null
kubectl -n vault-auth-check create token external-secrets \
  --audience=https://kubernetes.default.svc.cluster.local --duration=10m | \
  vault write auth/kubernetes/login role=eso jwt=- >/dev/null
```

### GitHub 재로그인·정리와 root 폐기

별도 터미널에서 위의 GitHub 새 로그인 방법으로 토큰을 받는다. 시험 경로 이름(`ORBIT_TEST_PATH`, 비밀값 아님)을 전달받아 아래를 실행한다. 모두 가짜 시험 값이며, 생성·전체 교체·읽기·부분 수정 권한과 다른 키 보존을 확인한다.

```bash
vault kv put -mount=secret "$ORBIT_TEST_PATH" CHECK=github-fake-value KEEP=unchanged
vault kv patch -method=patch -mount=secret "$ORBIT_TEST_PATH" CHECK=github-patched-value
vault kv get -mount=secret -field=CHECK "$ORBIT_TEST_PATH"  # github-patched-value
vault kv get -mount=secret -field=KEEP "$ORBIT_TEST_PATH"   # unchanged
```

같은 토큰으로 기존 [SSH 인증서 발급 절차](#macos-linux)도 성공해야 한다. root 터미널에서도 ESO 토큰으로 `CHECK`, `KEEP`를 읽어 같은지 확인한다. GitHub 검증 토큰은 그 별도 터미널에서 폐기한다.

root 터미널에서는 성공 여부와 무관하게 이번에 만든 시험 리소스를 정리한다. 아래 namespace 삭제는 앞에서 새로 만든 빈 namespace에만 해당한다.

```bash
vault token revoke -accessor "$ESO_ACCESSOR"
vault kv metadata delete -mount=secret "$ORBIT_TEST_PATH"
kubectl delete clusterrolebinding orbit-vault-auth-check
kubectl -n external-secrets delete serviceaccount external-secrets vault-auth-denied
kubectl -n vault-auth-check delete serviceaccount external-secrets
kubectl delete namespace external-secrets vault-auth-check
unset ESO_TOKEN ESO_ACCESSOR ORBIT_TEST_PATH
```

`metadata delete`는 시험 경로의 모든 버전을 제거한다. 앱 경로에는 실행하지 않는다. SA 삭제로 시험용 Kubernetes 토큰을 무효화하며, Vault 토큰은 accessor로 따로 폐기한다. 중간 실패로 변수가 비어 있으면 해당 생성 단계와 리소스부터 확인한다. 예상과 달리 거부 시험 로그인이 성공했다면 root로 `vault token revoke -mode=path auth/kubernetes/login`도 실행한다 (이 경로로 발급된 토큰 전체 폐기이므로 운영 ESO 설치 전 시험에만 사용).

검증·정리가 끝나면 [관리자 권한](#관리자-권한) 절차대로 root를 폐기하고, 임시 generate-root 허용 설정을 켰다면 다시 끄고 재시작 후 unseal까지 마친다. 운영 결과에는 성공·실패와 변경 항목만 남기고 토큰·비밀값은 남기지 않는다.

- [x] astra 적용·실제 k3s 로그인·GitHub 권한 검증 결과를 문서 상단에 기록했다.
- [ ] 시험 리소스 정리 완료를 확인한다.
- [ ] 운영자가 보류한 root token 폐기 후 문서 상태를 갱신한다.

ESO Helm Application, TokenReview RBAC, Vault CA ConfigMap, ClusterSecretStore와 앱별 ExternalSecret은 orbit-gitops에서 Argo CD 배포 후 진행한다. 생성 Secret 이름을 Deployment의 `envFrom`과 맞춘다.

## 팀원 접속 (자동 갱신, macOS)

Vault CLI 없이 쓸 수 있다. 한 번 설정하면 `ssh 10.0.0.202`처럼 접속하면 개인 계정으로 들어가고, 인증서가 없거나 만료 10분 전이면 ssh 직전에 자동으로 새로 받는다. 개인 계정과 접속 대상은 [개인 계정 문서](personal-accounts.md)를 따른다.

준비:

- GitHub `ORBIT-CLOUD-LABS` 조직 멤버이고, 개인 계정 명단(`personal_accounts`)에 있어야 한다. 관리자가 명단을 반영한 Vault 플레이북을 적용해야 개인 서명 권한(`ssh-personal-<계정명>`)이 생긴다.
- GitHub PAT (classic): scope는 `read:org` 하나만, 만료는 짧게.
- `jq` (macOS 15부터 기본 포함. 없으면 `brew install jq`), Tailscale 연결.

```bash
scripts/orbit-ssh-setup.sh             # 처음 한 번. 다시 실행해도 됨
scripts/orbit-ssh-setup.sh --reset-pat # PAT 만료 등으로 바꿀 때
```

설정 스크립트가 하는 일:

| 항목 | 위치 |
| --- | --- |
| 갱신 스크립트 (`scripts/orbit-ssh-refresh.sh` 복사본) | `~/.orbit/refresh-cert.sh` |
| Vault CA 인증서. 없으면 저장소의 `scripts/vault-ca.crt`, 그것도 없으면 `orbit@astra`에서 scp(공용 접속 회수 전까지만 됨). 둘 다 안 되면 다른 팀원에게 받아 이 위치에 둔다 | `~/.orbit/vault-ca.crt` |
| SSH 키. 없을 때만 만듦 | `~/.ssh/id_ed25519` |
| GitHub PAT | macOS 키체인 `orbit-github-pat` |
| Vault 토큰 (`0600`, 기본 8시간) | `~/.orbit/vault-token` |
| 개인 계정명. Vault 로그인 토큰의 `ssh-personal-<계정명>` 정책에서 알아냄. 찾지 못하면 여기서 멈추고 갱신 스크립트와 `~/.ssh/config`를 바꾸지 않음. 그래서 예전 설정은 계속 동작함 | `~/.orbit/user` |
| `Match host ... exec ...` 블록 (내부망, 와이파이, 노드 Tailscale 주소, `*.orbit-labs.space` 이름). `User`는 개인 계정명. 맨 뒤에 붙이고, 이전 파일은 `config.orbit-bak`. 노드나 Tailscale 주소가 바뀌면 스크립트의 `MATCH_HOSTS`를 고치고 다시 실행 | `~/.ssh/config` |

- 갱신 순서: 인증서가 충분히 남았고 principal이 내 계정명뿐이면 아무것도 안 함 → 저장된 Vault 토큰이 살아 있으면 그걸로 개인 역할(`personal-<계정명>`) 서명 → 거부되거나 토큰이 없으면 키체인의 PAT로 GitHub 로그인 후 서명.
- 기존 사용자 전환: 예전 설정(`User orbit`)을 쓰던 사람도 `scripts/orbit-ssh-setup.sh`를 다시 실행하면 된다. 남아 있던 `orbit` 인증서는 principal이 달라서 다음 접속 때 개인 인증서로 바뀐다. 개인 권한이 아직 없으면 setup이 멈추고, 설치된 갱신 스크립트와 `~/.ssh/config`가 예전 그대로 남아 `orbit` 인증서 갱신도 계속된다.
- 개인 계정이 아직 만들어지지 않은 호스트는 개인 인증서로 거부된다. 그때나 비상시에는 `ssh orbit@<호스트>`로 기존 키(`authorized_keys`)를 쓴다(공용 접속 회수 전까지).
- 갱신에 실패해도(Vault sealed, Tailscale 꺼짐, PAT 만료) 경고만 내고 ssh는 남은 인증서로 접속을 시도한다. Vault에 연결되지 않으면 1분 동안은 다시 시도하지 않는다. 개인 계정은 인증서로만 로그인되므로(`authorized_keys` 없음) 유효한 인증서가 없으면 거부된다. 그때는 위의 `ssh orbit@<호스트>`를 쓰고, 공용 접속 회수 후에는 [비상 접근](#비상-접근)을 따른다.
- 인증서로 들어갔는지 확인: `ssh -v 10.0.0.202 true 2>&1 | grep 'Server accepts key'` → `ED25519-CERT`면 인증서.
- 자동 갱신을 끄려면 `~/.ssh/config`에서 `orbit-vault-ssh` 표시 사이의 블록을 지운다.

## 수동으로 인증서 받기 (Vault CLI)

자동 갱신을 쓰지 않거나 macOS가 아니면 이 방법을 쓴다. GitHub `ORBIT-CLOUD-LABS` 조직 멤버이고 개인 계정 명단에 있어야 하며, Tailscale에 연결되어 있어야 한다. 아래 `<계정명>`은 명단의 Linux 계정명이다. `vault token lookup -format=json | jq '.data.policies'`의 `ssh-personal-<계정명>`으로도 확인할 수 있다. 다른 사람의 역할은 서명이 거부된다. Windows는 [아래](#windows-powershell)를 따른다.

### macOS, Linux

1. Vault CLI 설치 (HashiCorp 공식 배포본).
2. CA 인증서 받기: `mkdir -p ~/.orbit && scp orbit@10.0.0.201:/opt/vault/tls/vault-ca.crt ~/.orbit/vault-ca.crt` (공용 접속 회수 전까지. 안 되면 다른 팀원에게 받는다)
   SSH 키가 없으면 먼저 만든다: `test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`
3. 환경 변수
   ```bash
   export VAULT_ADDR=https://10.0.0.201:8200
   export VAULT_CACERT=~/.orbit/vault-ca.crt
   ```
4. GitHub PAT (classic) 만들기: scope는 `read:org` 하나만, 만료는 짧게. 비밀번호 관리자에 보관한다.

```bash
vault login -method=github          # PAT 입력. 토큰은 ~/.vault-token에 저장됨
vault write -field=signed_key ssh-client-signer/sign/personal-<계정명> \
  public_key=@$HOME/.ssh/id_ed25519.pub > ~/.ssh/id_ed25519-cert.pub
ssh <계정명>@10.0.0.202
```

### Windows (PowerShell)

Windows 10/11에 기본으로 있는 OpenSSH 클라이언트를 쓴다 (VS Code Remote-SSH도 같은 ssh를 씀). 아래 명령은 Windows에서 직접 실행해 확인하지 않았다. 처음 따라 하는 사람이 결과를 확인해 고친다.

1. Vault CLI 설치: `winget install Hashicorp.Vault` (ID가 다르면 `winget search hashicorp`로 확인). winget이 없으면 [releases.hashicorp.com/vault](https://releases.hashicorp.com/vault/)에서 `windows_amd64` zip을 받아 `vault.exe`를 PATH에 있는 폴더에 둔다. 새 PowerShell 창에서 `vault version`으로 확인.
2. CA 인증서와 SSH 키
   ```powershell
   New-Item -ItemType Directory -Force "$HOME\.orbit", "$HOME\.ssh" | Out-Null
   scp orbit@10.0.0.201:/opt/vault/tls/vault-ca.crt "$HOME\.orbit\vault-ca.crt"
   if (-not (Test-Path "$HOME\.ssh\id_ed25519")) { ssh-keygen -t ed25519 -f "$HOME\.ssh\id_ed25519" }
   ```
   astra에 아직 접속할 수 없으면 `vault-ca.crt`를 다른 팀원에게 받아 `$HOME\.orbit\`에 둔다.
3. 환경 변수 (사용자 환경 변수로 저장. 새 PowerShell 창부터 적용)
   ```powershell
   [Environment]::SetEnvironmentVariable("VAULT_ADDR", "https://10.0.0.201:8200", "User")
   [Environment]::SetEnvironmentVariable("VAULT_CACERT", "$HOME\.orbit\vault-ca.crt", "User")
   ```
4. GitHub PAT (classic) 만들기: scope는 `read:org` 하나만, 만료는 짧게. 비밀번호 관리자에 보관한다.

```powershell
vault login -method=github          # PAT 입력. 토큰은 $HOME\.vault-token에 저장됨
$cert = vault write -field=signed_key ssh-client-signer/sign/personal-<계정명> "public_key=@$HOME\.ssh\id_ed25519.pub"
[IO.File]::WriteAllText("$HOME\.ssh\id_ed25519-cert.pub", (($cert -join "").Trim() + "`n"))
ssh <계정명>@10.0.0.202
```

- 인증서 파일을 `>`나 `Out-File`로 저장하지 않는다. Windows PowerShell 5.1은 UTF-16으로 저장해서 ssh가 인증서를 읽지 못한다. 위처럼 `WriteAllText`(BOM 없는 UTF-8)로 저장한다.
- 인증서로 들어갔는지 확인: `ssh -v <계정명>@10.0.0.202 exit 2>&1 | Select-String "Server accepts key"` → `ED25519-CERT`면 인증서.
- 인증서 내용 확인: `ssh-keygen -L -f "$HOME\.ssh\id_ed25519-cert.pub"` (`Key ID`, `Valid` 줄).

### 공통

- 개인키 옆에 `-cert.pub`로 저장하면 ssh가 알아서 함께 쓴다.
- 인증서의 principal은 본인 계정명 하나다. `ssh-keygen -L -f ~/.ssh/id_ed25519-cert.pub`의 `Principals`로 확인한다.
- 인증서는 8시간 뒤 만료된다. 새 접속에는 다시 발급받는다. 이미 연결된 세션은 끊기지 않는다.
- 노드 sshd 로그에 `ID github-<아이디>`로 남는다. 보기: `journalctl -u ssh | grep "ID "` (`adm` 그룹이 아니면 sudo. terra의 `orbit`은 `adm`이 아님).

## 비상 접근

| 상황 | 방법 |
| --- | --- |
| GitHub에 닿지 않음 (강의실 와이파이 장애 등) | 비상 계정으로 로그인: `BG=$(vault login -token-only -method=userpass username=breakglass1)` 후 `VAULT_TOKEN=$BG vault write ...`. 비상 계정은 공용 `orbit` 역할(`ssh-client-signer/sign/orbit`)만 서명하므로 `ssh orbit@<호스트>`로 접속한다 |
| Vault가 sealed이거나 꺼짐 | 기존 키(`orbit_ansible`, 각자 `authorized_keys`에 넣은 키)로 접속 |

- `vault login`은 토큰을 화면에 출력한다. 다른 사람이 볼 수 있는 곳에서는 `-token-only`로 변수에 받는다.
- 셸에 `VAULT_TOKEN`이 있으면 그 값이 `~/.vault-token`보다 우선한다. `vault token revoke -self`를 실행하기 전에 지금 토큰이 무엇인지 `vault token lookup`으로 확인한다.

## unseal (재부팅·재시작 후)

```bash
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/vault-ca.crt
vault operator unseal               # 키를 인자로 쓰지 않음 (history에 남음)
```

- 보관자 2명이 서로 다른 키로 한 번씩 실행한다. 각자 Tailscale로 해도 된다.
- 진행 상황은 메모리에만 있다. 처음부터 다시: `vault operator unseal -reset`
- 끝나면 `ansible-playbook playbooks/vault.yml -K --ask-vault-pass`에서 `unsealed. 정상`을 확인한다.

## 권한 회수

- GitHub `orbit` 팀에서 빼면 팀 정책(`ssh-orbit`, `orbit-secrets-write`)이 새 로그인 토큰에서 빠진다. 하지만 GitHub 로그인은 조직 멤버이면 되고 개인 SSH 정책은 사용자 매핑으로 붙으므로, 팀 탈퇴만으로 개인 인증서 발급이 막히지는 않는다. 개인 명단에서 지우고 Vault·개인 계정 플레이북을 모두 적용한다. 전체 순서는 [탈퇴·접근 회수](personal-accounts.md#온보딩권한-변경탈퇴)를 따른다. 이미 받은 Vault 토큰은 최대 24시간, 이미 받은 인증서는 최대 8시간 동안 쓸 수 있다.
- 바로 막아야 하면 관리자 권한으로 GitHub 로그인 토큰을 모두 폐기한다 (전원 다시 로그인): `vault token revoke -mode=path auth/github/login`
- 열려 있는 SSH 세션은 자동으로 끊기지 않는다. 노드 로그에서 `ID github-<아이디>`의 sshd PID를 찾아 종료한다.
- 비상 계정 비밀번호 변경: 관리자 권한으로 `vault delete auth/userpass/users/<이름>` 후 `vault.yml` 값을 바꾸고 `vault.yml` 플레이북을 다시 실행한다.
- unseal 키 보관자가 바뀌면 `vault operator rekey`로 키를 새로 만들어 나눈다 (기존 키 2개 필요).

## 관리자 권한

평소에는 관리자 토큰을 두지 않는다. 설정을 바꿀 때만 보관자 2명이 임시 root token을 만들고, 쓴 뒤 폐기한다.

Vault 2.x부터 `generate-root`는 기본으로 인증을 요구한다. 토큰 없이 unseal 키 정족수만으로 root를 생성하려면 `vault.hcl`의 `enable_unauthenticated_access = ["generate-root"]`를 임시로 켜야 한다.

이 설정은 API에 닿는 누구나 절차를 시작·취소할 수 있게 하므로 평소에는 꺼 둔다 (`hvault_allow_generate_root: false`). 필요할 때만 켠다.

1. astra에서 `VAULT_TOKEN`을 unset하고, `ansible-playbook playbooks/vault.yml -K --ask-vault-pass -e hvault_allow_generate_root=true` → 재시작되어 sealed → unseal
2. 아래 절차로 임시 root를 만든다. 보관자는 시작한 사람이 따로 알려 준 nonce를 `-nonce`로 지정한다 (다른 사람이 시작한 절차에 키를 넣지 않게)
3. 허용 설정을 유지한 채 관리 작업을 수행한다. 플레이북으로 설정할 때도 `-e hvault_allow_generate_root=true`를 전달한다.
4. unsealed 상태에서 임시 root token 폐기 성공을 확인하고 `VAULT_TOKEN`을 unset한다.
5. 토큰 없이 기본값으로 플레이북을 다시 실행해 허용 설정을 끈다 → 재시작 → unseal

```bash
unset VAULT_TOKEN; rm -f ~/.vault-token                     # 폐기된 토큰이 남아 있으면 invalid token으로 실패
vault operator generate-root -init                          # OTP와 nonce 출력. OTP는 시작한 사람만 보관
vault operator generate-root -nonce=<nonce>                 # 보관자 2명이 각자 실행, 키는 프롬프트에 입력
read -rs OTP; read -rs ENC                                  # OTP와 마지막에 나온 Encoded Token을 숨김 입력 (history에 남기지 않음)
VAULT_TOKEN=$(vault operator generate-root -decode="$ENC" -otp="$OTP"); export VAULT_TOKEN; unset OTP ENC
```

- 키를 잘못 넣었거나 중단하려면 `vault operator generate-root -cancel`
- unseal 키를 다시 만들 때(`vault operator rekey`)도 Vault 2.x에서는 인증이 필요하다. 임시 root를 만든 뒤 그 토큰으로 한다.

설정 적용과 폐기 (위에서 생성·export한 `VAULT_TOKEN` 사용):

```bash
ansible-playbook playbooks/vault.yml -K --ask-vault-pass -e hvault_allow_generate_root=true
# 성공과 unsealed 상태를 확인한 뒤 실행. 폐기에 실패하면 토큰을 유지하고 원인을 확인한다.
vault token revoke -self && unset VAULT_TOKEN
# 폐기 성공 후에만 실행. 허용 설정을 제거하면서 재시작되어 sealed가 된다.
ansible-playbook playbooks/vault.yml -K --ask-vault-pass
# 보관자 2명이 각각 vault operator unseal 실행
```

관리 작업 중 버전·설정 변경으로 재시작되어 sealed가 되면 먼저 unseal한다. 실패한 설정 작업이 있다면 허용 설정을 유지한 채 다시 실행하고, 완료 후 토큰을 폐기한다.

- 최초 root token은 PR 머지 후 폐기한다.

## 백업과 복구

- 스냅샷 (관리자 권한): `umask 077; vault operator raft snapshot save vault-$(date +%Y%m%d).snap`
- 스냅샷은 Vault가 암호화한 상태라 unseal 키 없이 열 수 없다. 그래도 Git·공유 드라이브에는 두지 않고, unseal 키와 같은 곳에 보관하지 않는다.
- 최초 스냅샷: jyvnee의 Mac `~/Documents/orbit` (`0600`). S3로 옮길 때는 별도 경로에 퍼블릭 액세스 차단, 최소 권한, 서버 측 암호화, 버전 관리를 건다.
- 스냅샷에는 받은 시점의 토큰도 들어 있다. 최초 스냅샷에는 최초 root token이 들어 있으므로, 이 스냅샷으로 복구하면 나중에 폐기한 root token이 다시 살아난다.
- 복구 (astra를 새로 설치한 경우):
  1. `playbooks/vault.yml`로 설치. Raft `node_id`가 원래와 같은 `astra`여야 한다 (다르면 복구 뒤 스스로 sealed가 됨)
  2. 새로 `vault operator init -key-shares=5 -key-threshold=2` (원래와 같은 개수로. 다르면 원래 키를 받지 못함) → 새 키로 unseal
  3. 새 root token으로 `vault operator raft snapshot restore -force <파일>`
  4. 몇 초 뒤 sealed가 된다. **원래** unseal 키 2개로 unseal. 새로 받은 키와 root token은 버린다
  5. 스냅샷에 들어 있던 root token이 다시 살아나므로 바로 폐기한다. 관리자 권한이 필요하면 원래 키로 `generate-root`
  6. SSH CA 키도 돌아오므로 노드 설정은 바꾸지 않는다. `/opt/vault/tls`도 잃었다면 새 TLS CA가 만들어지므로 팀원에게 `vault-ca.crt`를 다시 나눠 준다.

## 주의

- 서버 인증서는 만료돼도 플레이북이 자동으로 다시 만들지 않는다. 만료 전에 `/opt/vault/tls/vault.crt`를 지우고 `vault.yml`을 실행한다 (reload만 하므로 sealed되지 않음).
- `/opt/vault/tls/tls.crt`, `tls.key`(패키지가 만든 파일)를 지우지 않는다. 지운 채 패키지를 다시 설치하면 `/opt/vault` 전체 소유자가 `vault`로 바뀐다.
- `disable_mlock = true`이고 astra에는 swap이 켜져 있다 (VM용). Vault만 `MemorySwapMax=0`(`vault.service.d/10-orbit-noswap.conf`)으로 swap을 쓰지 않게 하고, 확인 단계에서 `memory.swap.max`가 0인지 본다.
- astra의 Docker 컨테이너에서 Vault에 접속하려면 `hvault_allowed_ifaces`에 `docker0`(또는 해당 브리지)를 추가해야 한다.
- 감사 로그를 쓰지 못하면 Vault가 요청을 거부한다. logrotate는 하루 한 번 돌 때만 크기를 본다.
