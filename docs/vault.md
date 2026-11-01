# Vault와 SSH CA

구현: [#7](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/7).
이 문서에는 이름과 절차만 기록한다. unseal 키, 토큰, 비밀번호, GitHub PAT 값은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다.

## 구성

| 항목 | 값 |
| --- | --- |
| 위치 | astra 호스트에 직접 설치 (systemd `vault`, 버전 고정·apt hold) |
| 주소 | 내부망 `https://10.0.0.201:8200`, Tailscale `https://100.94.67.18:8200`, astra 안 `https://127.0.0.1:8200` |
| TLS | 내부 CA `/opt/vault/tls/vault-ca.crt` (2036년 만료), 서버 인증서 `vault.crt` (2029-02-03 만료) |
| 저장소 | 단일 노드 Raft `/opt/vault/data`. 8201은 `127.0.0.1`에만 염 |
| 방화벽 | 8200은 `lo`, `br0`, `tailscale0`에서만 받음 (INPUT 맨 앞 `ORBIT-VAULT` 체인). 와이파이 등 나머지는 DROP |
| unseal | Shamir 5개 중 2개. 팀원 5명이 하나씩 보관. 같은 정족수로 임시 root를 만들 수 있음 (`generate-root`) |
| 감사 로그 | `/var/log/vault/audit.log` (`0600 vault`). 매일 회전, 14개 보관 |
| SSH CA | 엔진 `ssh-client-signer`, 역할 `orbit`, 정책 `ssh-orbit`. CA 키 ed25519 |
| 인증서 | `orbit` 계정만, 최대 8시간, 인증서 ID는 서버가 정함 (`github-<아이디>`, `userpass-<이름>`) |
| 로그인 | GitHub (`ORBIT-CLOUD-LABS`의 `orbit` 팀), 비상용 userpass `breakglass1`, `breakglass2`. 토큰 기본 8시간, 최대 24시간 |
| 노드 | 인벤토리 전체(노드 5대, VM 3대)가 `/etc/ssh/trusted-user-ca-keys.pem`을 신뢰 (`sshd_config.d/10-orbit-ssh-ca.conf`). 기존 `authorized_keys`는 그대로 |

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

## 팀원 준비

1. Vault CLI 설치 (HashiCorp 공식 배포본).
2. CA 인증서 받기: `mkdir -p ~/.orbit && scp orbit@100.94.67.18:/opt/vault/tls/vault-ca.crt ~/.orbit/vault-ca.crt`
   SSH 키가 없으면 먼저 만든다: `test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`
3. 환경 변수
   ```bash
   export VAULT_ADDR=https://100.94.67.18:8200
   export VAULT_CACERT=~/.orbit/vault-ca.crt
   ```
4. GitHub PAT (classic) 만들기: scope는 `read:org` 하나만, 만료는 짧게. 비밀번호 관리자에 보관한다.

## 인증서 받아 접속하기

```bash
vault login -method=github          # PAT 입력. 토큰은 ~/.vault-token에 저장됨
vault write -field=signed_key ssh-client-signer/sign/orbit \
  public_key=@$HOME/.ssh/id_ed25519.pub > ~/.ssh/id_ed25519-cert.pub
ssh orbit@10.0.0.202
```

- 개인키 옆에 `-cert.pub`로 저장하면 ssh가 알아서 함께 쓴다.
- 인증서는 8시간 뒤 만료된다. 새 접속에는 다시 발급받는다. 이미 연결된 세션은 끊기지 않는다.
- 노드 sshd 로그에 `ID github-<아이디>`로 남는다. 보기: `journalctl -u ssh | grep "ID "` (`adm` 그룹이 아니면 sudo. terra의 `orbit`은 `adm`이 아님).

## 비상 접근

| 상황 | 방법 |
| --- | --- |
| GitHub에 닿지 않음 (강의실 와이파이 장애 등) | 비상 계정으로 로그인: `BG=$(vault login -token-only -method=userpass username=breakglass1)` 후 `VAULT_TOKEN=$BG vault write ...` |
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

- GitHub `orbit` 팀에서 빼면 새 로그인과 토큰 갱신이 막힌다. 이미 받은 Vault 토큰은 최대 24시간, 이미 받은 인증서는 최대 8시간 동안 쓸 수 있다.
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
