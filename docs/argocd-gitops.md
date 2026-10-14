# Argo CD GitOps 최초 연결 (#34)

관련 작업: [infrastructure #34](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/34).
요구사항 원본의 `docs/infrastructure-plan.md`에서 ASTRA 클러스터 위치와 역할을 확인했다.
해당 문서에는 이 작업에 대응하는 REQ ID가 없어 임의로 추가하지 않는다.

## 관리 경계

| 구성 | 원본과 적용 주체 |
| --- | --- |
| Argo CD Helm 설치 | infrastructure의 `argocd` 롤 |
| 저장소 인증 Secret, AppProject, root Application, 허용 namespace | infrastructure의 `argocd_gitops` 롤 |
| 자식 Application, 앱 리소스 | orbit-gitops, Argo CD 수동 Sync |

Ansible은 root를 생성하고 Git manifest 조회 성공까지만 확인한다. root와 자식의 Sync를
실행하지 않는다. root는 `clusters/orbit-astra/apps`의 자식 Application 정의만 읽는다.
자식은 `workloads/<app>` 또는 `platform/<addon>`의 실제 리소스를 읽는다.
ApplicationSet은 배포 환경이나 클러스터가 늘어 반복 정의가 많아질 때 검토한다.

root와 Project는 Ansible이 계속 관리하므로 GitOps root 경로에 복제하지 않는다.
Helm 설치도 이 단계에서 Argo CD 자체 관리로 전환하지 않는다.

## 인증 선택

| 방식 | 장점 | 관리 부담 / 이번 선택 |
| --- | --- | --- |
| HTTPS 익명 조회 | 공개 저장소에서 키 없이 가능 | 현재 가능하지만 #34의 인증 주입과 비공개 전환을 검증하지 못함 |
| SSH Deploy Key | 저장소 하나의 읽기 권한, 개인 계정 토큰과 분리 | 키 만료가 없어 주기적인 회전·폐기 필요. 이번 구성에 사용 |
| HTTPS fine-grained PAT | 대상 저장소와 읽기 권한 제한, 만료 설정 | 사용자 계정 수명·만료·조직 승인 관리 필요 |
| GitHub App | 여러 저장소와 설치 단위 권한, 단기 토큰 | App 등록·설치와 개인키 관리 필요. 저장소가 늘면 검토 |

Deploy Key의 `Allow write access`는 선택하지 않는다. Argo CD는 Git 변경을 커밋하지 않는다.
테스트와 Lab에는 서로 다른 키와 Vault 파일을 사용한다. `secrets/argocd-vault.yml`은
암호화하여 제어 노드에 보관하고 Git에서는 제외한다. Vault 비밀번호도 Git에 저장하지 않는다.
Vault 암호화는 Git에 올리지 않기 위한 대체 수단이 아니다.

Secret은 `argocd.argoproj.io/secret-type: repository` 라벨을 사용한다. bootstrap/platform/workloads가
같은 URL을 읽으므로 이 단일 저장소의 인증을 공통으로 사용하고 각 Project의 sourceRepos로
출처를 제한한다. 조직 전체 URL을 허용하는 repo-creds는 만들지 않는다.
Secret task는 `no_log: true`, `diff: false`를 사용하고 개인키를 VM 임시 파일이나
last-applied annotation에 저장하지 않는다. Kubernetes Secret의 base64는 암호화가 아니므로
namespace 접근 권한과 클러스터 백업을 함께 관리한다.

## 최초 준비

1. orbit-gitops의 `clusters/orbit-astra/apps/smoke-test.yaml`과
   `workloads/smoke-test/configmap.yaml`을 먼저 `main`에 반영한다.
2. 안전한 제어 노드에서 passphrase 없는 전용 Ed25519 키를 생성한다.

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/orbit-gitops-readonly -C orbit-astra-argocd
   ```

   passphrase 질문에는 빈 값을 입력한다. 공개키 `.pub`만 GitHub 저장소의
   Settings → Deploy keys에 등록한다. 쓰기 권한은 부여하지 않는다.
3. `ansible/secrets/argocd-vault.yml.example`을 `argocd-vault.yml`로 복사하고
   개인키 전체를 `vault_argocd_gitops_ssh_private_key`의 block scalar에 입력한다.
   작업 동안 파일 권한은 0600으로 제한하고 즉시 암호화한다.

   ```bash
   cd ansible
   cp secrets/argocd-vault.yml.example secrets/argocd-vault.yml
   chmod 600 secrets/argocd-vault.yml
   # 편집기로 개인키 입력 후
   ansible-vault encrypt secrets/argocd-vault.yml
   ```

4. Helm chart가 제공하는 `argocd-ssh-known-hosts-cm`의 github.com host key를
   [GitHub 공개 지문](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)과 확인한다.
   `ssh-keyscan` 결과만 믿거나 `insecure`로 검증을 끄지 않는다.
   롤은 github.com 항목 존재를 검사하고 실제 SSH 연결의 host 검증은 repo-server가 수행한다.

## 적용

기존 설치만 수행할 때는 `ansible-playbook argocd.yml`을 그대로 사용한다.
GitOps 연결을 켜면 키가 반드시 필요하며 `--check`는 지원하지 않는다.
실행 제어 노드에는 ansible-core >= 2.16과 kubernetes.core 6.6.0이 필요하고,
대상 control plane에는 롤이 Python Kubernetes 의존성을 설치한다.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# 준비된 테스트 Kubernetes 클러스터에서 먼저 실행
ansible-playbook -i inventory/test.ini argocd.yml \
  -e argocd_gitops_enabled=true --ask-vault-pass

# 같은 구성 재실행: changed=0 확인
ansible-playbook -i inventory/test.ini argocd.yml \
  -e argocd_gitops_enabled=true --ask-vault-pass

# 테스트 성공 후 Lab용 Vault 파일로 교체해 적용
ansible-playbook argocd.yml \
  -e argocd_gitops_enabled=true --ask-vault-pass
```

GitOps 브랜치에서 먼저 테스트하면 `-e argocd_gitops_revision=task/5-argocd-gitops`로 root를
지정할 수 있다. 이 경우 테스트 브랜치의 자식 Application `targetRevision`도 같은 브랜치로
맞춰 커밋·push해야 한다. 로컬에만 있는 manifest는 Argo CD가 읽지 못한다.
검증 후 root와 자식 모두 `main`으로 되돌린다.

실패 시 root의 `.status.conditions`에서 인증, 잘못된 revision/path, 권한 오류를 확인한다.
마지막 조회는 Synced 또는 OutOfSync 상태이면서 자식 Application 리소스가 발견되어야 성공한다.
전체 키나 Secret YAML을 출력해 디버깅하지 않는다.

## 프로젝트 권한

| 프로젝트 | 대상 namespace | 초기 허용 리소스 |
| --- | --- | --- |
| bootstrap | argocd | argoproj.io/Application만 |
| platform | orbit-platform | ConfigMap만, 클러스터 리소스 없음 |
| workloads | orbit-gitops-test | ConfigMap만, 클러스터 리소스 없음 |

platform/workloads는 Application·ApplicationSet·AppProject를 명시적으로 금지한다. namespace는 Ansible이
생성하므로 업무 프로젝트에 Namespace 생성 권한을 주지 않는다. 실제 서비스와 애드온 추가 시
defaults의 namespace 및 리소스 허용 목록을 리뷰 후 확장한다. cluster-admin 역할이나 wildcard
허용을 편의상 추가하지 않는다. 외부 chart 저장소는 별도 sourceRepos 변경이 필요하다.

AppProject는 허용 범위이며 사용자 역할 분리 전체를 대신하지 않는다. 기존 admin은 모든 프로젝트에
접근할 수 있다. `default` 프로젝트나 root 경로를 수정할 권한도 업무 사용자에게 주지 않는다.
root는 다른 프로젝트의 Application을 생성할 수 있으므로 관리자만 승인·Sync한다.
root 경로의 `spec.project`, source, destination 변경은 필수 관리자 리뷰 대상으로 둔다.

## 수동 검증 체크리스트

로컬 회귀 검증은 저장소 루트에서 실행한다. ansible-core와 PyYAML이 필요하다.

```bash
python -m unittest discover -s tests -v
cd ansible
ansible-playbook -i inventory/test.ini argocd.yml --syntax-check
```

이 검증은 템플릿 권한 분리, 비밀값 출력 차단과 조회 완료 조건을 검사한다.
저장소 인증 성공과 실제 Sync, 재실행 멱등성은 아래 클러스터 검증으로 별도 확인한다.

Argo CD UI 접속은 `ansible/README.md`의 port-forward와 SSH 터널 절차를 따른다.
모든 Sync에서 Prune 옵션은 선택하지 않는다.

1. Settings → Repositories에서 SSH 저장소 연결이 Successful인지 확인한다.
2. root `orbit-astra-root`의 source/revision/path와 자식 Application diff를 확인한다.
   새 설치에서는 root가 OutOfSync이고 자식 Application은 아직 없어야 한다.
3. root를 수동 Sync한다. `orbit-astra-smoke-test` Application이 생성되지만 테스트 ConfigMap은
   아직 없어야 한다. root가 Synced인 것만으로 자식 배포 성공을 판단하지 않는다.
4. 자식을 수동 Sync하고 ConfigMap 값이 v1인지 확인한다.

   ```bash
   kubectl -n orbit-gitops-test get configmap gitops-smoke-test \
     -o jsonpath='{.data.message}'
   ```

5. GitOps의 ConfigMap 값을 `gitops-v2`로 변경하고 해당 revision에 반영한다.
   UI Refresh 후 자식이 OutOfSync가 되는지 확인한다. 실제 값은 여전히 v1이어야 한다.
6. 자식을 수동 Sync하고 실제 값이 v2인지 확인한다. Git을 v1으로 복원해 다시 수동 Sync한다.
7. Self Heal 검증: 테스트 ConfigMap만 직접 변경한다.

   ```bash
   kubectl -n orbit-gitops-test patch configmap gitops-smoke-test \
     --type merge -p '{"data":{"message":"manual-drift"}}'
   ```

   Refresh 후 OutOfSync이지만 값은 manual-drift로 유지되어야 한다.
   자식을 수동 Sync해 Git 값 v1으로 복구한다.
8. 범위 제한 검증: 테스트용 자식의 destination을 `argocd`로 바꾼 브랜치를 별도로 준비하면
   `InvalidSpecError`가 발생해야 한다. 원래 namespace로 복원 후 정상 조회를 확인한다.
9. Ansible 재실행 시 changed=0인지 확인한다. 테스트 결과에 Git SHA, 대상 클러스터,
   두 번째 실행 recap, root/자식 Sync 상태, ConfigMap 전후 값만 기록한다. 키는 기록하지 않는다.

실제 클러스터 접근과 Deploy Key 준비 전에는 이 체크리스트를 완료했다고 표시하지 않는다.

## Sync 정책과 삭제

root·자식 모두 `automated.enabled: false`, `prune: false`, `selfHeal: false`로 시작한다.
수동 Sync는 가능하며 수동 Sync의 Prune 옵션은 별도로 관리해야 한다.

- 자동 Sync: 반복 배포·롤백 검증, PR 승인 규칙, 변경 관찰과 실패 대응이 준비된 앱부터 활성화.
- Prune: 관리 리소스 목록과 삭제 diff, PVC·데이터 보호, 삭제 복구 절차 확인 후 별도로 활성화.
- Self Heal: 직접 변경의 허용 범위와 Git 반영·복구 규칙을 합의하고 drift 검증 후 활성화.

root 설정은 Ansible template에서, 자식 설정은 GitOps Application에서 각각 변경한다.
root 자동 Sync는 자식 정의를 적용할 뿐 자식 자동 Sync를 활성화하지 않는다.
root Prune은 자식 Application 삭제로 이어질 수 있어 초기에는 계속 비활성화한다.
연쇄 삭제 finalizer도 추가하지 않는다. finalizer 없는 Application 삭제는 리소스를 남기므로
검증 종료 시 테스트 ConfigMap과 Application은 별도로 정리한다. namespace나 인증정보를
지우기 전에는 그 안의 다른 리소스와 참조 Application을 먼저 확인한다.

키 회전은 새 Deploy Key 등록 → Vault 교체·Ansible 재적용 → 연결과 조회 성공 확인 →
기존 Deploy Key 폐기 순서로 진행한다.

## 테스트 검증 기록 (2026-10-14)

ASTRA의 별도 작업 경로 `/home/orbit/issue34-gitops-test`에서 infrastructure
`task/34-argocd-gitops`의 `afb657c`를 실행했다. 기존 `/home/orbit/orbit-infrastructure`
작업 폴더와 운영 VM에는 적용하지 않았다.

| 항목 | 검증 대상 / 결과 |
| --- | --- |
| 테스트 노드 | test-cp `.10`, test-w1 `.11`, test-w2 `.12` (192.168.122.0/24), 모두 Ready |
| Kubernetes / CNI | v1.33.13 / Calico v3.31.4, CoreDNS·Calico 시스템 Pod Ready |
| Argo CD | v3.5.5, Helm chart 10.10.3, 주요 Pod Ready |
| GitOps 브랜치 | task/5-argocd-gitops, 최종 검증 커밋 a66c2d0 |
| SSH 연결 | 테스트용 읽기 전용 Deploy Key로 root manifest 조회 성공, GitHub host key 지문 일치 확인 |
| 최초 bootstrap | 자식 Application과 ConfigMap이 자동으로 생성되지 않음 |
| root 수동 Sync | orbit-astra-smoke-test Application 생성, ConfigMap은 아직 없음 |
| 자식 수동 Sync | gitops-smoke-test ConfigMap 생성, 값 gitops-v1 |
| Git 변경 감지 | 94d3bea의 v2 변경을 OutOfSync로 조회, 수동 Sync 전 실제 값은 v1 유지 |
| 변경 반영 | 수동 Sync 후 실제 값 v2, a66c2d0으로 Git 값 복원·재Sync 후 v1 |
| Self Heal 비활성화 | 직접 변경한 manual-drift 값이 유지됨, 수동 Sync로 v1 복구 |
| 권한 제한 | 임시 Application의 argocd destination이 InvalidSpecError로 거부됨, Sync 없이 해당 Application 삭제 |
| 최종 상태 | root·자식 모두 Synced / Healthy, conditions 없음, ConfigMap 값 v1 |
| 설치만 재실행 | ok=14, changed=0, unreachable=0, failed=0 |
| GitOps 연결 포함 재실행 | ok=25, changed=0, unreachable=0, failed=0 |

수동 Sync는 kubectl의 Application `operation`으로 요청했으며 매번 `prune: false`를
지정했다. UI 로그인 검증과 `main` 전환·머지, 실제 플랫폼 애드온 배포는 이 기록에 포함하지 않는다.
이 작업 브랜치 검증 시점에는 root와 자식 모두 작업 브랜치를 읽었다.

실제 Sync 검증에서 `source.directory.recurse: false`가 Argo CD에 의해 생략되어 root에
불필요한 OutOfSync가 남는 문제를 확인했다. root template과 자식 manifest에서 해당 선언을
제거했다(infrastructure afb657c, GitOps 6554d24). Directory의 기본 동작은 비재귀이다.

GitHub 조직이 Deploy Key 생성을 차단하여 최초 등록은 실패했다. 사용자 승인 후
ORBIT-CLOUD-LABS의 `deploy_keys_enabled_for_repositories`를 true로 변경하고,
GitOps 저장소에 테스트용 읽기 전용 키를 등록했다. **허용 설정은 조직 전체에 유지되며**,
등록한 키의 접근 범위는 orbit-gitops 하나이다.

테스트 개인키는 ASTRA의 `~/.ssh/orbit-gitops-test-readonly`, 암호화된 Vault는 테스트
작업본의 `ansible/secrets/argocd-vault.yml`에 있다. 무인 테스트용 Vault 암호는
`/home/orbit/.config/orbit-issue34/vault-password`에 0600 권한으로 보관했다.
비밀값은 Git과 검증 기록에 포함하지 않았다. 이 자격증명은 테스트 전용으로 사용한다.

GitOps PR [#6](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/pull/6)이 main에 머지된 후
테스트 클러스터의 root를 `argocd_gitops_revision=main`으로 전환했다.
root → 자식 순서로 Prune 없이 수동 Sync하여 클러스터의 자식 설정도 main으로 적용했다.

- main 검증 커밋: `5779a03e978f5cc04bea6d0be4e61298b5faa486`
- root·자식 모두 `targetRevision: main`, Synced / Healthy, conditions 없음.
- ConfigMap 값은 `gitops-v1` 유지, 자동 Sync / Prune / Self Heal은 모두 비활성화.
- main 전환 Ansible 실행: changed=1(root 변경), 재실행: ok=25, changed=0, unreachable=0, failed=0.
- 운영 클러스터에는 적용하지 않았으며 UI 로그인 검증은 포함하지 않았다.

ASTRA에서 현재 main 연결을 재실행하려면 다음 명령을 사용한다.

```bash
cd /home/orbit/issue34-gitops-test/ansible
ansible-playbook -i inventory/test.ini argocd.yml \
  -e argocd_gitops_enabled=true \
  -e argocd_gitops_revision=main \
  --vault-password-file /home/orbit/.config/orbit-issue34/vault-password
```

## 애드온 추가 규칙과 참고

`orbit-gitops/platform/<addon>/`에 실제 manifest를 두고
`clusters/orbit-astra/apps/<addon>.yaml`에 platform 자식 Application을 추가한다.
필요한 권한, chart/이미지 버전, CRD 선행 적용, 데이터 보존, 롤백 및 삭제 영향을 PR에 기록한다.
이번 작업에서는 실제 애드온을 설치하지 않는다.

- [Argo CD 선언형 repository 설정](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)
- [App of Apps 관리자 권한](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern-alternative)
- [AppProject 허용 범위](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [자동 Sync 정책](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [GitHub Deploy Key 관리](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
