# 개인 Linux 계정과 호스트별 권한

개인 계정 role은 계정·홈·개인 그룹·개인 sudo 규칙과 인증서 전용 SSH 설정을 관리한다. Vault 역할·GitHub 매핑은 별도의 Vault 플레이북으로 적용하고, 팀원 인증서 자동 설정·갱신은 `scripts/orbit-ssh-setup.sh`가 맡는다([Vault 문서의 팀원 접속](vault.md#팀원-접속-자동-갱신-macos)). Linux 계정 role 적용만으로 개인 인증서가 발급되지는 않는다.

## 초기 비밀번호

- 담당자가 개인별 서로 다른 임시 비밀번호를 정하고, 터미널에서 `openssl passwd -6`의 숨김 프롬프트로 해시를 생성한다. 비밀번호를 명령 인자에 쓰지 않는다.
- `ansible-vault edit inventory/group_vars/all/vault.yml`에서 `vault_personal_accounts_password_hashes`에 사용자명별 해시를 넣는다. 형식은 `vault.yml.example`을 따른다. 실제 해시도 평문 파일·Git·이슈·채팅에 남기지 않는다.
- 담당자는 임시 비밀번호를 본인에게 개인별 안전한 경로로 전달한다. 본인은 개인 인증서 접속이 준비되면 각 서버·VM에서 `passwd`로 변경한다. SSH 비밀번호 로그인은 허용하지 않는다.
- 비밀번호는 호스트별로 독립적이다. 한 호스트에서 변경해도 다른 호스트로 전파되지 않는다. 최초 생성 때만 해시를 적용하고 이후에는 사용자 변경을 보존한다. 이미 생성된 계정의 초기 해시는 없어도 재실행할 수 있다.
- 분실 시 관리자가 해당 호스트에서 `sudo passwd <계정명>`으로 재설정하고 본인에게 안전하게 전달한다. 이 플레이북은 기존 비밀번호를 리셋하거나 잠긴 비밀번호를 자동 해제하지 않는다. 초기 해시가 없으면 새 계정을 만들지 않고 중단하며 `nopasswd`로 우회하지 않는다.

## 사전 검사와 소유권

- 개인 그룹의 GID는 UID와 동일하다. 모든 선택 호스트의 입력·계정·UID·GID·홈·비밀번호 준비·기존 SSH CA·sudo 설정을 먼저 조회하고 검사한다. 하나라도 실패하면 생성 단계로 넘어가지 않는다.
- principal 파일 경로의 상위 디렉터리(`/`, `/etc`, `/etc/ssh`)가 root 소유이고 그룹·기타 쓰기 권한이 없어야 한다. sshd `StrictModes`가 이 조건이 맞지 않으면 principal 파일을 읽지 않고 개인 인증서를 거부하기 때문이다. 이 문제는 `sshd -T -C`로는 드러나지 않고 로그인 때 `bad ownership or modes for directory`로만 나타나므로 사전 검사에서 멈춘다. 권한은 자동으로 고치지 않는다.
- root 전용 `/var/lib/orbit/personal-accounts/<계정명>.json`이 관리 기록이다. 기록 없이 같은 계정명·그룹명이 있으면 UID가 같아도 인수하지 않는다. 다른 이름의 UID/GID 충돌, 기존 홈 소유권 불일치도 자동 수정하지 않는다.
- 계정 생성 중 실패한 뒤에도 안전하게 재실행할 수 있도록 생성 의도를 먼저 기록한다. 이 파일을 손으로 추가해 기존 계정을 인수하지 않는다.
- 이 role이 관리하는 개인 계정은 보조 그룹을 비우고 개별 sudoers 파일로 권한을 준다. 별도의 그룹 접근 권한이 필요하면 모델을 먼저 확장한다.
- 관리 기록이 있는 사람이 명단에서 빠지면 principal 파일을 비우고 이 role의 sudoers 파일을 제거해 새 SSH 로그인과 이 role의 sudo 권한을 회수한다. 명단 전체를 비워도 같은 처리를 한다. 계정·그룹·홈·관리 기록은 보존하며, 이 role이 관리하지 않은 계정은 회수 대상에 넣지 않는다. 이미 열린 세션·root 프로세스와 다른 경로에서 부여한 권한은 별도 회수 절차로 확인한다.

## 적용

astra의 저장소 `ansible/`에서 실행한다. 초기 적용에서는 기존 관리 세션을 유지하고 한 호스트부터 진행한다. 계정명·UID·GID 2001~2005는 아직 실제 8대에 적용하지 않은 배정이다.

```bash
# 조회 검사와 허용·거부 대상 표시. 실제 계정·파일·비밀번호·SSH reload는 실행하지 않음
ansible-playbook playbooks/personal-accounts.yml -K --ask-vault-pass --check --limit sol
# 위는 파일 변경 diff를 계산하지 않으므로 changed=0을 실제 무변경으로 해석하지 않음
ansible-playbook playbooks/personal-accounts.yml -K --ask-vault-pass --limit sol
# 적용 후 일반 재실행 changed=0 확인
ansible-playbook playbooks/personal-accounts.yml -K --ask-vault-pass --limit sol
```

호스트를 제한하면 사전 검사도 그 대상에만 수행한다. 전체 적용은 모든 대상 사전 검사 후 한 대씩 진행하며, 적용 중 실패하면 앞서 끝난 호스트의 변경은 남는다. 전역 트랜잭션이나 전체 자동 롤백은 아니다.

## 접근 제어와 검증

- 개인 계정만 `Match User`로 제한한다. 공개키 직접 등록·SSH 비밀번호·외부 principal 조회 명령은 사용하지 않고, 기존 CA가 서명한 인증서와 root 소유 호스트별 principal 파일을 사용한다.
- 호스트 허용 목록에서 개인을 제외하면 해당 개인 principal 파일을 비우고 이 role의 sudo 규칙을 제거한다. 계정·홈은 남기고 새 인증서 로그인을 거부한다. 이미 열린 세션·기존 프로세스는 별도로 정리해야 한다.
- 공용 `orbit`, 기존 자동화·비상 접근과 Vault 정책은 변경하지 않는다. 공용 접근 회수는 개인 계정 전환 검증 이후의 별도 작업이다.
- sudoers 조각은 `visudo` 검사를 통과한 내용만 쓴다. `PASSWD`로 본인 비밀번호를 요구하고, 비밀번호 없는 `sudo true`가 성공하거나 `sudo -l`에 다른 비밀번호 면제 규칙이 있으면 중단한다. 실제 암호를 넣는 sudo 성공 검증과 limited 명령의 권한 확대 검토는 별도로 수행한다.
- SSH 조각을 쓴 뒤 전체 문법과 사용자별 `sshd -T -C`를 검사하고 통과한 경우만 서비스에 반영한다. 검사 실패 시 이 role의 SSH 조각을 복원하고 중단한다. 이미 만든 계정·그룹·sudo 규칙은 남으므로 기존 관리 세션에서 원인을 확인한다.
- 실제 환경 확인 항목은 [검증](#검증)과 [로그와 Wazuh 확인](#로그와-wazuh-확인)을 따른다.

## Vault 개인 SSH 역할·정책

`playbooks/vault.yml`의 관리자 토큰 조건부 설정 단계에서 `personal_accounts`를 읽어 개인별 역할·서명 정책·GitHub 사용자 매핑을 관리한다. 초기 비밀번호 해시는 이 단계에서 읽거나 설정하지 않는다. 기존 SSH CA 키는 재생성하지 않는다.

| 항목 | hyn128 예시 | 제한 |
| --- | --- | --- |
| SSH 역할 | `ssh-client-signer/roles/personal-hyn128` | principal `hyn128`만, 사용자 인증서만, 기본·최대 8시간 |
| 서명 정책 | `ssh-personal-hyn128` | `ssh-client-signer/sign/personal-hyn128`의 update만 |
| GitHub 사용자 매핑 | `auth/github/map/users/hyn128` | `ssh-personal-hyn128` 연결 |

이름 prefix는 `hashicorp-vault.yml`의 `hvault_ssh_personal_role_prefix`, `hvault_ssh_personal_policy_prefix`로 정한다. 현재 5명에 대해 개인 항목 15개를 추가한다. 본인 역할에 다른 principal·host 인증서·빈 principal의 무제한 인증서·과도한 TTL을 요청할 수 없으며, 인증서 key ID도 서버가 정한다. 다른 개인 역할의 서명·역할 설정 변경은 개인 정책에 없다.

기존 개인 역할이 OTP 등 다른 방식이거나, 명단에 있는 사람의 GitHub 사용자 매핑에 예상하지 않은 정책이 있으면 모든 쓰기 전에 중단한다. 그 매핑에 수동으로 넣은 정책을 조용히 지우거나 역할 방식을 자동 전환하지 않는다. 이 prefix의 역할·정책은 이 코드가 관리하므로, 수동 변경은 재실행하면 원하는 값으로 돌아가고 명단에 없는 항목은 삭제된다(아래 "명단에서 빠진 사람").

**전환 중에는 팀의 `ssh-orbit`과 `orbit-secrets-write`를 유지한다.** GitHub 사용자 정책은 팀 정책에 추가된다. 따라서 개인 로그인 토큰에는 본인 개인 역할 권한과 기존 공용 orbit 발급·앱 비밀값 권한이 함께 있을 수 있다. 다른 개인 역할까지 허용하는 것은 아니다. 공용 orbit 발급 제거는 개인 계정·접속 도구 검증이 끝난 후 별도 단계에서 진행한다. [Vault GitHub 사용자 매핑](https://developer.hashicorp.com/vault/api-docs/auth/github#map-github-users).

astra에서 root 등 관리자 토큰을 준비하고, [Vault 운영 문서](vault.md)의 미리보기 → 적용 → 재실행 절차를 따른다. 개인 Linux 계정과 호스트별 principal 설정을 먼저 준비해야 실제 개인 계정으로 로그인할 수 있다. 예를 들어 개인 인증서는 GitHub로 새 로그인한 뒤 `vault write -field=signed_key ssh-client-signer/sign/personal-hyn128 public_key=@<본인 공개키 파일>`로 받는다. 다른 사람의 역할을 지정하지 않는다. macOS 자동 설정(`scripts/orbit-ssh-setup.sh`)은 토큰의 개인 정책에서 계정명을 알아내 이 역할로 서명하며, 개인 정책이 없으면 기존 설정을 바꾸지 않고 멈춘다.

### 명단에서 빠진 사람

GitHub 사용자 매핑은 팀과 관계없이 붙는다. GitHub 로그인은 조직 멤버이기만 하면 성공하므로, `orbit` 팀에서 빠져도 조직에 남아 있으면 사용자 매핑으로 개인 인증서를 계속 받을 수 있다. 그래서 Vault 플레이북이 명단에 없는 개인 항목을 지운다.

- 지우는 대상: 명단에 없는 `personal-*` 역할과 `ssh-personal-*` 정책. 그리고 명단에 없는 GitHub 사용자 매핑 중 `ssh-personal-*` 정책만 가리키는 것.
- 지우지 않는 대상: 개인 정책을 가리키지 않는 사용자 매핑. 개인 정책과 다른 정책이 섞인 매핑은 모든 쓰기 전에 멈추며, 관리자가 확인해 정리한다.
- 순서: 사용자 매핑 → 정책 → 역할. 미리보기에서는 지울 목록만 표시한다.
- 명단을 비우면 모든 개인 항목이 지워진다. 실수로 지웠다면 명단을 되돌리고 다시 실행하면 같은 이름으로 다시 만들어진다.

Linux 쪽 회수(principal 비우기, sudoers 제거)는 개인 계정 플레이북을 각 호스트에 적용해야 반영된다. 명단에서 사람을 지우면 두 플레이북을 모두 실행한다. Vault 항목을 지워도 이미 발급한 Vault 토큰(최대 24시간), SSH 인증서(최대 8시간), 열린 세션은 바로 사라지지 않는다. 즉시 막으려면 Linux 플레이북으로 principal을 비우고, 필요하면 토큰 폐기와 세션 종료를 따로 한다.

## 전환 절차

공용 `orbit` 접속에서 개인 계정으로 옮기는 순서다. 한 명·한 호스트에서 끝까지 검증한 뒤 넓힌다. 모든 단계에서 기존 관리 세션(`orbit`)을 하나 열어 둔 채, 새 터미널로 시험한다.

1. **사전 결정 확인.** 명단(GitHub 아이디·계정명·UID), 사람별 접속 호스트, sudo 범위, Wazuh 수집 담당 저장소가 이슈에서 확정됐는지 확인한다. `inventory/group_vars/all/personal-accounts.yml`이 그 결정과 같아야 한다.
2. **초기 비밀번호 해시 준비.** [초기 비밀번호](#초기-비밀번호) 절차대로 암호화 `vault.yml`에 넣는다. 플레이북은 호스트 단위로 적용되어 그 호스트에 명단 전원의 계정을 만들므로, 전원의 해시가 있어야 사전 검사를 통과한다.
3. **Vault 적용.** astra에서 관리자 토큰으로 [Vault 운영 문서](vault.md#설정-출처와-적용)의 미리보기 → 적용 → 재실행을 한다. 미리보기에서 개인 항목(사람마다 역할·정책·사용자 매핑)이 추가되고 `삭제할 개인 SSH 항목`이 모두 빈 목록인지 본다.
4. **첫 대상 한 대.** 호스트 한 대(예: `sol`)와 먼저 시험할 사람 한 명을 정한다. [적용](#적용)의 `--limit sol` 미리보기 → 적용 → 재실행을 한다. 이때 `sol`에는 명단 전원의 계정이 만들어지지만, 각자 setup을 하기 전에는 아무도 개인 인증서로 로그인하지 않는다.
5. **본인 설정.** 시험하는 사람이 자기 Mac에서 `scripts/orbit-ssh-setup.sh`를 다시 실행한다. 계정명이 맞게 나오고 `완료`가 나와야 한다. 개인 정책을 못 찾고 멈추면 3번을 확인한다. 이때 기존 설정은 그대로다.
6. **검증.** 아래 [검증](#검증) 표를 그 한 대에서 모두 확인하고 [기록](#전환회수-기록)에 남긴다.
7. **확대.** 같은 사람으로 나머지 호스트를 한 대씩 적용·검증한 뒤, 나머지 팀원이 5번을 실행한다. `--limit` 없이 전체를 적용할 때도 플레이북이 한 대씩 진행한다.
8. **공용 접속 회수.** 전원이 개인 계정으로 접속되는 것을 기록한 뒤에 별도 작업으로 진행한다. 이 단계 전까지 `ssh orbit@<호스트>`가 대체 경로다.

## 검증

호스트마다 확인한다. `<나>`는 시험하는 사람의 계정명, `<남>`은 다른 팀원의 계정명, `<허용>`·`<미허용>`은 그 사람의 접속 허용 여부에 따른 호스트다.

| 확인 | 명령 (시험하는 사람의 Mac) | 기대 결과 |
| --- | --- | --- |
| 허용 호스트 로그인 | `ssh -v <허용> true 2>&1 \| grep 'Server accepts key'` | `ED25519-CERT`, 종료 코드 0 |
| 미허용 호스트 거부 | `ssh <나>@<미허용> true` | `Permission denied (publickey)` |
| 다른 사람 계정으로 로그인 거부 | `ssh <남>@<허용> true` | `Permission denied` |
| 다른 사람 역할 서명 거부 | `vault write ssh-client-signer/sign/personal-<남> public_key=@$HOME/.ssh/id_ed25519.pub` | `403 permission denied` |
| 인증서 없는 키로 로그인 거부 | `ssh-keygen -q -t ed25519 -N '' -f /tmp/orbit-nocert` 후 `ssh -F /dev/null -o IdentitiesOnly=yes -i /tmp/orbit-nocert <나>@<허용> true`. 끝나면 `rm /tmp/orbit-nocert*` | `Permission denied` |
| 허용한 sudo | 호스트 안에서 `sudo -k` 후 `full`이면 `sudo true`, `limited`면 허용 목록의 명령 (본인 비밀번호 입력) | 성공 |
| 비밀번호 없는 sudo 거부 (`sudo_auth: password`일 때) | 호스트 안에서 `sudo -k; sudo -n true` | `a password is required` |
| 금지한 sudo 거부 | `limited`면 목록 밖 명령, `none`이면 `sudo true` | 거부 |
| 재실행 무변경 | astra에서 개인 계정 플레이북 재실행 | 그 호스트 `changed=0` |
| 자동화 유지 | astra의 `ansible/`에서 `ansible <호스트> -m ping --ask-vault-pass` | `pong` |
| 공용 대체 경로 유지 | `ssh orbit@<허용> true` | 성공 (공용 접속 회수 전까지) |

수동 서명 시험은 [수동 발급](vault.md#수동으로-인증서-받기-vault-cli)처럼 GitHub로 로그인한 Vault CLI에서 한다. 이 토큰은 끝나면 `vault token revoke -self`로 폐기한다.

## 로그와 Wazuh 확인

### 호스트 로그

검증한 접속과 sudo가 호스트 로그에 사람 단위로 남는지 먼저 본다. `orbit`이 `adm` 그룹이 아니면 sudo로 본다.

```bash
# SSH 로그인: 계정명, 출발지 IP, 인증서 ID(github-<아이디>)가 한 줄에 남음
journalctl -u ssh --since '-30 min' | grep 'Accepted publickey for <나>'
# sudo: 실행한 사람(<나>)과 명령이 남음
journalctl _COMM=sudo --since '-30 min' | grep '<나>'
```

- SSH 성공 줄은 `Accepted publickey for <나> from <IP> port ... ED25519-CERT ID github-<아이디> (serial ...) CA ...` 형태다.
- 개인 계정 플레이북은 실행할 때마다 비밀번호 없는 sudo가 거부되는지 검사한다. 그래서 각 개인 계정 이름으로 `TTY=unknown ; ... COMMAND=/usr/bin/true`와 `a password is required` 줄이 남는다. 실제 사용이 아니므로, 플레이북을 실행한 시각과 명령으로 구분한다.

### Wazuh

Wazuh 에이전트·수집·디코더 설정과 대시보드 검색 방법은 이 저장소가 아니라 Wazuh 담당 저장소에서 관리한다. 담당 저장소와 확인 담당자는 이슈의 사전 결정 항목이며, 정해지면 아래에 링크한다.

- Wazuh 담당 저장소·문서: (사전 결정 후 링크)

[검증](#검증)에서 만든 실제 시험 이벤트로 다음을 확인하고 [기록](#전환회수-기록)에 남긴다.

- [ ] SSH 로그인 성공: 계정명, 호스트, 시간, 출발지 IP가 보인다.
- [ ] sudo 실행: 실행한 사람(개인 계정명), 호스트, 시간이 보인다.
- [ ] 거부된 로그인: 다른 사람 계정·미허용 호스트 시험이 남는다.
- [ ] 인증서 ID(`github-<아이디>`)를 원본 로그에서 확인할 수 있다.
- [ ] 플레이북의 sudo 확인용 실행(`COMMAND=/usr/bin/true`, `a password is required`)을 실제 사용과 구분할 수 있다.

이 확인은 로그인과 sudo의 사용자 식별까지다. 실행한 모든 명령의 기록(auditd)은 이 작업 범위가 아니다.

## 온보딩·권한 변경·탈퇴

| 상황 | 관리자 (astra) | 본인 |
| --- | --- | --- |
| 새 팀원 | 명단에 GitHub 아이디·계정명·미사용 UID(2000~2999)·접속 호스트를 추가한다. 초기 비밀번호 해시를 넣고 임시 비밀번호를 따로 전달한다. Vault 플레이북 → 개인 계정 플레이북 순서로 적용한다 | PAT 준비 → `scripts/orbit-ssh-setup.sh` → 각 호스트에서 `passwd`로 비밀번호 변경 |
| 접속 호스트 추가·제거 | 그 사람의 `access`를 바꾸고 개인 계정 플레이북을 적용한다. 제거하면 그 호스트의 principal을 비우고 sudoers를 지운다. 계정·홈은 남는다 | 없음 |
| sudo 범위 변경 | `sudo`·`sudo_auth`·`sudo_commands`를 바꾸고 개인 계정 플레이북을 적용한다 | 없음 |
| 탈퇴·접근 회수 | 아래 순서 | 없음 |

탈퇴·접근 회수 순서:

1. 명단에서 그 사람을 지운다.
2. 개인 계정 플레이북을 전체에 적용한다. 모든 호스트에서 principal이 비워지고 sudoers가 지워져 개인 계정 SSH 로그인과 이 role의 sudo가 바로 막힌다. 이미 받은 개인 인증서도 이 시점부터 쓸 수 없다.
3. Vault 플레이북을 적용한다. 그 사람의 사용자 매핑·정책·역할이 지워져 새 개인 인증서를 받을 수 없다([명단에서 빠진 사람](#명단에서-빠진-사람)).
4. GitHub 조직·`orbit` 팀에서 뺀다. 팀에서 빠지면 새 토큰에 공용 정책이 붙지 않고, 조직에서 빠지면 GitHub 로그인 자체가 막힌다.
5. 그 사람의 Vault 토큰을 폐기한다. 토큰은 최대 24시간 남고, 공용 접속 회수 전에는 팀 정책(`ssh-orbit`, `orbit-secrets-write`)이 붙어 있어 `orbit` 인증서 서명과 앱 비밀값 수정이 가능하다. 토큰 목록 조회에는 관리자(root) 토큰이 필요하다:
   ```bash
   vault list -format=json auth/token/accessors | jq -r '.[]' | while read -r a; do
     vault token lookup -format=json -accessor "$a" </dev/null |
       jq -r --arg n "github-<아이디>" 'select(.data.display_name == $n) | .data.accessor'
   done | while read -r a; do vault token revoke -accessor "$a" </dev/null; done
   ```
6. 열린 세션과 프로세스를 정리한다. 각 호스트에서 `sudo loginctl terminate-user <계정명>`을 실행하고 `ps -u <계정명>`이 비었는지 확인한다. 그 사람이 `orbit`으로 연 세션은 계정명으로 구분되지 않으므로, [Vault 권한 회수](vault.md#권한-회수)처럼 sshd 로그의 `ID github-<아이디>`로 PID를 찾아 종료한다.
7. 공용 `orbit`의 `authorized_keys`에 그 사람의 키가 있으면 지운다(공용 접속 회수 전까지). 이미 받은 `orbit` 인증서는 폐기할 수 없어서 만료(최대 8시간)까지 `orbit`으로 들어올 수 있다. 공용 접속 회수 전 탈퇴라면 이 시간 동안 sshd 로그를 지켜본다.
8. 계정·홈 데이터는 남는다. 삭제가 필요하면 백업 여부를 정한 뒤 별도로 지우고, 관리 기록(`/var/lib/orbit/personal-accounts/<계정명>.json`)도 함께 지운다.
9. [기록](#전환회수-기록)에 남긴다.

## 복구

| 증상 | 조치 |
| --- | --- |
| 개인 계정 플레이북 적용 후 SSH가 이상함 | 열어 둔 관리 세션에서 `/etc/ssh/sshd_config.d/20-orbit-personal-accounts.conf`를 다른 곳으로 옮기고 `sudo sshd -t && sudo systemctl try-reload-or-restart ssh.service`. 원인을 고친 뒤 다시 적용한다 |
| sudo 설정 오류 | 관리 세션(`orbit`)에서 `sudo visudo -cf /etc/sudoers`로 확인하고 `/etc/sudoers.d/90-orbit-personal-<계정명>`을 지운다. `orbit`의 sudo는 이 role이 건드리지 않는다 |
| 개인 인증서를 못 받음 | `ssh orbit@<호스트>`로 접속한다(공용 접속 회수 전까지). Vault 쪽은 [비상 접근](vault.md#비상-접근)을 따른다 |
| 본인 Mac 설정을 되돌리기 (공용 접속 회수 전까지) | `~/.ssh/config`만 복원하면 갱신 스크립트가 새 버전이라 `orbit` 인증서를 받지 않는다. 개인 계정 전환 이전 버전으로 setup을 다시 실행한다: `git worktree add /tmp/orbit-ssh-old 47f66ee && /tmp/orbit-ssh-old/scripts/orbit-ssh-setup.sh`, 끝나면 `git worktree remove /tmp/orbit-ssh-old`. 다시 개인 계정으로 가려면 현재 버전 setup을 실행한다 |
| 모든 개인 접속이 막힘 | astra 콘솔이나 `orbit_ansible` 키로 접속해 위 조치를 한다 |

## 전환·회수 기록

각 단계를 마칠 때 아래 형식으로 이슈 댓글이나 이 문서 아래에 남긴다. 토큰·비밀번호·개인키는 적지 않는다.

| 날짜 | 작업 | 대상 (사람 / 호스트) | 결과 | 확인한 사람 | 비고 |
| --- | --- | --- | --- | --- | --- |
| YYYY-MM-DD | 전환 / 권한 변경 / 회수 | `<계정명>` / `sol` | 검증 표 전부 통과, Wazuh 로그인·sudo 확인 | `<GitHub 아이디>` | |
| 2026-11-02 | Vault 개인 항목 적용 | 명단 5명 / astra Vault | 미리보기에서 개인 역할·정책·사용자 매핑 15개만 추가 대상, 삭제 목록 비어 있음. 적용 15개, 재실행 `바뀔 설정 []` | `jyvnee` | 브랜치 `task/15-personal-accounts-vault-ssh` `8f213ed`에서 적용 |
| 2026-11-02 | 개인 계정 적용 | 명단 5명 / `sol` | 사전 검사 통과, 계정·그룹(UID=GID 2001~2005)·홈(`0700`)·sudoers·principal·SSH 조각 생성, 재실행 `changed=0`. 자동화(`orbit_ansible`) 접속 유지 | `jyvnee` | |
| 2026-11-02 | 전환 검증 | `jyvnee` / `sol` | 실제 GitHub PAT로 setup 완료(인증서 `github-jyvnee`, principal `jyvnee`). 개인 인증서 로그인, 비밀번호 sudo 성공. 거부 확인: `hyn128@sol`, 인증서 없는 키, 개인 계정 없는 `luna`, 다른 사람 역할(`personal-hyn128`) 서명 403, 비밀번호 없는 sudo. `orbit@astra` 대체 경로 유지 | `jyvnee` | 호스트 로그에 `Accepted publickey for jyvnee from 100.115.101.78 ... ID github-jyvnee`와 sudo `jyvnee : TTY=pts/1 ...` 확인. Wazuh 수집은 미확인(담당 저장소 미정). 다른 팀원 4명은 setup 전 |
| 2026-11-03 | 개인 계정 적용·전환 검증 | 명단 5명 / `terra`, `luna`, `efk`, `lgtm`, `polaris` | 호스트마다 미리보기(5명 신규·허용) → 적용(`changed=9`) → 재실행 `changed=0`. `jyvnee` 개인 인증서 로그인 성공, `hyn128@<호스트>`·인증서 없는 키·비밀번호 없는 sudo 거부, 자동화(`orbit_ansible`) 접속 유지. VM(`efk`, `lgtm`)은 astra 경유(`-J`)로 확인. 호스트 키는 Tailscale·astra 내부망 지문을 대조해 등록 | `jyvnee` | 비밀번호 sudo 성공은 `sol`에서만 확인. `polaris`는 k3s `active` 확인 |
| 2026-11-03 | 문제 발견·조치 | `polaris` | `/etc`가 `775`(그룹 쓰기)라 sshd `StrictModes`가 principal 파일을 거부(`bad ownership or modes for directory /etc`). `orbit`은 영향 없음. 관리 세션에서 `sudo chmod g-w /etc`로 `755`로 고친 뒤 개인 로그인 성공. 같은 문제를 적용 전에 멈추도록 사전 검사 추가 | `jyvnee` | 원래 이미지 설정으로 추정. astra·wazuh·sol은 `755` |

## 구현 검증 범위

Ubuntu 24.04 컨테이너의 Ansible Core 2.16.3에서 가짜 계정·비밀번호·CA로 생성·일반 재실행 무변경, 사용자 변경 비밀번호 보존, 준비 누락·UID/GID·이름·홈 충돌 시 중단을 시험했다. 서로 다른 두 인벤토리 대상을 같은 격리 환경에 연결해, 한 대상의 준비 실패가 생성 단계 전체를 막는 것도 확인했다.

컨테이너의 실제 sshd에 접속해 본인 인증서 성공, 다른 principal·일반 공개키 거부, 호스트 권한 회수 후 로그인·sudo 거부, 공용 orbit 접속 유지, 제한 sudo 명령과 SSH 조각 복원을 확인했다. 외부 NOPASSWD 규칙은 중단한다. 관리 기록이 있는 계정 한 명 또는 전체 명단을 제거하면 새 SSH 로그인·이 role의 sudo 권한이 회수되며 계정·홈은 보존된다.

컨테이너에는 systemd가 없어 테스트용 서비스 반영 명령으로 sshd에 HUP을 보냈다. 실제 호스트의 systemd·PAM·sudo 정책과 운영 CA·Vault 개인 역할을 조합한 검증은 아직 하지 않았다. 운영 서버·VM에 실제 계정을 생성하거나 비밀번호를 설정한 결과가 아니다.

Vault 개인 SSH 설정은 Vault 2.2.1 dev 환경을 사용해 로컬 Ansible Core 2.21.5와 astra 2.16.3에서 검증했다. 5명 모두 본인 principal만 서명되며, 다른 개인 역할·root·공용 orbit 발급은 개인 정책만으로 거부된다. 호스트 인증서·TTL 초과·포트 포워딩 확장 요청도 거부된다. 팀 정책을 합친 토큰은 전환 목적대로 공용 orbit 서명을 계속 허용한다. 미리보기 무쓰기, 반복 실행 무변경, 역할 변경 복구, 예상 밖 사용자 매핑·OTP 역할 충돌 시 중단, CA 보존도 확인했다.

명단에서 빠진 항목 정리는 Vault 2.2.1 dev 컨테이너에서 정리 단계만 따로 실행해 시험했다. 미리보기 무쓰기, 명단 밖 매핑·정책·역할 삭제와 명단·공용 항목 유지, 재실행 무변경, 섞인 매핑에서 쓰기 전 중단, 명단 전체 비우기, 엔진·GitHub 로그인이 없는 Vault, 출력에 토큰이 남지 않음을 확인했다.

이 시험의 사용자 토큰은 dev root가 해당 정책으로 발급한 대체 토큰이다. 개인별 실제 GitHub PAT 로그인에서 사용자 매핑이 붙는지와 운영 호스트의 최종 접속은 아직 검증하지 않았다. astra에서도 운영 Vault와 별개인 임시 dev 프로세스·임시 CA만 사용했고 시험 후 종료했다.
