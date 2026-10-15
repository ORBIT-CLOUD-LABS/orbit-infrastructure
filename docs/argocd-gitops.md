# Argo CD GitOps 연결과 자동 Sync 운영 (#34, #52)

관련 작업: [infrastructure #34](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/34),
[infrastructure #52](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/52).
요구사항 원본의 `docs/infrastructure-plan.md`에서 ASTRA 클러스터 위치와 역할을 확인했다.
해당 문서에는 이 작업에 대응하는 REQ ID가 없어 임의로 추가하지 않는다.

## 관리 경계

| 구성 | 원본과 적용 주체 |
| --- | --- |
| Argo CD Helm 설치 | infrastructure의 `argocd` 롤 |
| 저장소 인증 Secret, AppProject, root Application, 허용 namespace | infrastructure의 `argocd_gitops` 롤 |
| 자식 Application 정의 | orbit-gitops, root의 자동 Sync |
| 앱 리소스 | orbit-gitops, 각 자식 Application의 Sync 정책 |

Ansible은 root를 생성하고 Git manifest 조회 성공까지만 확인한다. 별도 Sync 요청은 보내지 않으며,
root의 자동 Sync는 Argo CD가 수행한다. 플레이북 성공은 자동 Sync나 자식 배포 완료를 보장하지 않는다.
root는 `clusters/orbit-astra/apps`의 자식 Application 정의만 읽는다.
자식은 `workloads/<app>` 또는 `platform/<addon>`의 실제 리소스를 읽는다.
ApplicationSet은 배포 환경이나 클러스터가 늘어 반복 정의가 많아질 때 검토한다.

root와 Project는 Ansible이 계속 관리하므로 GitOps root 경로에 복제하지 않는다.
Helm 설치도 이 단계에서 Argo CD 자체 관리로 전환하지 않는다.

이 문서의 #52 정책은 저장소에 선언된 설정이다. ASTRA 적용과 실제 자동 배포 검증은 별도로 수행하고
결과를 기록한다. 아래 #34의 과거 수동 Sync 기록은 #52 적용 완료의 근거가 아니다.
자동 Sync 전환은 CI/CD 부모 [orbit-server #61](https://github.com/ORBIT-CLOUD-LABS/orbit-server/issues/61)의
범위로 진행한다. 원본 `orbit/docs/phase1.md`에 남아 있는 수동 Sync 설명과 공통 값의 미확정 표시는
원본 저장소에서 정리할 항목이며, 이 저장소에서 원본을 수정하지 않는다.

최신 실제 선언·chart 권한 대조와 검사 도구는 [#52 권한 검증](argocd-permission-verification.md)을 따른다.
이 문서의 기존 테스트망 검증과 현재 운영 상태는 구분한다.

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

적용 전에 root가 읽을 GitOps revision과 자식 Application diff를 검토한다. root 자동 Sync를 켜면
기존 자식 선언도 바로 반영될 수 있고, 자동 Sync가 켜진 자식은 실제 앱 배포를 시작할 수 있다.
root 경로 변경은 관리자 리뷰 후 반영하며, Secret·namespace·스토리지 등 자식의 선행 조건을 먼저 준비한다.

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

GitOps 브랜치에서 먼저 테스트하면 `-e argocd_gitops_revision=<검증용-GitOps-브랜치>`로 root를
지정할 수 있다. 이 경우 테스트 브랜치의 자식 Application `targetRevision`도 같은 브랜치로
맞춰 커밋·push해야 한다. 로컬에만 있는 manifest는 Argo CD가 읽지 못한다.
검증 후 root와 자식 모두 `main`으로 되돌린다.

실패 시 root의 `.status.conditions`에서 인증, 잘못된 revision/path, 권한 오류를 확인한다.
마지막 조회는 Synced 또는 OutOfSync 상태이면서 자식 Application 리소스가 발견되어야 성공한다.
OutOfSync도 조회 성공으로 처리하므로 자동 배포 성공은 아래 체크리스트에서 별도로 확인한다.
전체 키나 Secret YAML을 출력해 디버깅하지 않는다.

## 프로젝트 권한

| 프로젝트 | 대상 namespace | 선언된 허용 리소스 |
| --- | --- | --- |
| bootstrap | argocd | argoproj.io/Application만 |
| platform | orbit-platform, kube-system, observability | ConfigMap, ServiceAccount, Service, Deployment, DaemonSet, RoleBinding. 클러스터 리소스는 ClusterRole, ClusterRoleBinding, APIService |
| workloads | orbit-gitops-test, orbit | ConfigMap, Deployment, Service, HorizontalPodAutoscaler, PodDisruptionBudget, PersistentVolumeClaim. 클러스터 리소스는 PersistentVolume |

platform/workloads는 Application·ApplicationSet·AppProject를 명시적으로 금지한다. namespace는 Ansible이
생성하므로 업무 프로젝트에 Namespace 생성 권한을 주지 않는다. `orbit`과 업무 리소스 권한은
[infrastructure #39](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/39)의 적용 대상이다.
Secret은 이 허용 목록에 없으며, [orbit-gitops #3](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/3)의
수동 생성 절차를 따른다. `platform`의 `kube-system` 대상과 metrics-server Helm 저장소
(`https://kubernetes-sigs.github.io/metrics-server/`)·리소스 권한은
[infrastructure #40](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/40)의 적용 대상이다.
이는 [orbit-gitops #8](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/8)의 설치 권한만 준비하며,
metrics-server 자식 Application이나 앱 리소스는 만들지 않는다. `kube-system`은 기존 namespace이므로 Ansible이 유지한다.
클러스터 리소스 허용 목록은 종류 기준이며 metrics-server의 특정 이름으로 제한되지 않는다. 실제 애드온
추가 시 defaults의 namespace·리소스·sourceRepos 허용 목록을 다시 검토한다. cluster-admin 역할이나
wildcard 허용을 편의상 추가하지 않는다.

#52는 [orbit-gitops #9](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/9)의 정적 NFS 볼륨 배포를
위해 `workloads`에 PV·PVC 종류를 허용한다. PV는 클러스터 범위이므로 namespace, 특정 PV 이름이나
NFS 볼륨 유형으로 제한되는 권한이 아니다. `workloads`의 허용 namespace 양쪽에서 PVC를 만들 수 있다.
PV의 `claimRef`, PVC의 정적 바인딩, Origin 읽기 전용 설정, `Retain` 정책은 GitOps 선언에서 검토한다.
권한 추가 자체가 PV·PVC나 NFS 데이터를 생성하지는 않는다.

`platform`의 `observability` 대상과 kube-state-metrics(`https://prometheus-community.github.io/helm-charts`)·
Alloy(`https://grafana.github.io/helm-charts`) Helm 저장소·`apps/DaemonSet` 리소스 권한은
[infrastructure #57](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/57)의 적용 대상이다.
이는 [orbit-gitops #10](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/10)의 클러스터 메트릭·로그 수집기
설치 권한만 준비하며, Application 생성이나 Sync를 수행하지 않는다. `observability`는 이 롤의 namespace
생성 단계(`argocd_gitops_workload_namespaces + argocd_gitops_platform_namespaces`)에서 새로 만들어진다.
네임스페이스 이름은 `orbit` 레포 `docs/phase1.md`의 공통 값(미확정)을 따른다.
단일 Helm 저장소만 받던 `argocd_gitops_platform_helm_repo_url`은 애드온별로 저장소가 늘어나 복수형
`argocd_gitops_platform_helm_repo_urls`(리스트)로 바꿨다. ClusterRole·ClusterRoleBinding은 metrics-server
때 이미 연 종류를 kube-state-metrics·Alloy가 재사용하므로 클러스터 리소스 허용 목록 자체는 늘지 않았다.

[orbit-gitops #10](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/10)의 수집기는 #57로 설치 권한만
준비됐다. 실제 선언과 namespace·프로젝트·배포 방식·chart 저장소가 확정된 뒤 권한을 대조한다. 현재
허용 목록에 준비된 것은 설치 권한뿐이며, 실제 kube-state-metrics·Alloy Application과 고정 버전 chart
렌더링 결과와 대조하기 전에는 #52·#57 전체 권한 검증을 완료로 기록하지 않는다.

AppProject는 허용 범위이며 사용자 역할 분리 전체를 대신하지 않는다. 기존 admin은 모든 프로젝트에
접근할 수 있다. `default` 프로젝트나 root 경로를 수정할 권한도 업무 사용자에게 주지 않는다.
root는 다른 프로젝트의 Application을 생성할 수 있으므로 root 경로의 `spec.project`, source,
destination, Sync 정책 변경은 필수 관리자 리뷰 대상으로 둔다. 승인 후 Git에 반영하면 자동 Sync가
진행되며, 수동 복구 Sync 권한도 관리자로 제한한다.

## 검증 체크리스트 (#52 / GitOps #15)

로컬 회귀 검증은 저장소 루트에서 실행한다. ansible-core와 PyYAML이 필요하다.

```bash
python -m unittest discover -s tests -v
cd ansible
ansible-playbook -i inventory/test.ini argocd.yml --syntax-check
```

이 검증은 root 자동 Sync·제한된 재시도, 프로젝트 권한 분리, 비밀값 출력 차단과 조회 완료 조건을
검사한다. 저장소 인증 성공과 실제 자동 Sync, 재실행 멱등성은 클러스터에서 별도로 확인한다.
Argo CD UI 접속은 `ansible/README.md`의 port-forward와 SSH 터널 절차를 따른다.
수동 복구 Sync를 사용할 때도 Prune 옵션은 선택하지 않는다.

1. 적용 전 대상 클러스터, infrastructure 커밋, GitOps revision과 자식 선언 diff를 기록한다.
   Settings → Repositories에서 SSH 저장소 연결이 Successful인지 확인한다.
2. 플레이북 적용 후 root `orbit-astra-root`의 source/revision/path와 정책을 조회한다.
   `automated.enabled: true`, `prune: false`, `selfHeal: false`, retry limit 5와 backoff를 확인한다.
   AppProject 허용 목록과 필요한 namespace도 확인한다.

   ```bash
   kubectl -n argocd get application orbit-astra-root -o yaml
   kubectl -n argocd get appproject bootstrap platform workloads -o yaml
   kubectl get namespaces
   ```

3. root가 수동 Sync 없이 Git의 자식 Application을 생성·갱신하는지 확인한다.
   기존 smoke-test는 자식 자동 Sync가 꺼져 있으므로 ConfigMap까지 자동 배포될 것으로 기대하지 않는다.
   root가 Synced인 것만으로 자식 앱 배포 성공을 판단하지 않는다.
4. [GitOps #15](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/issues/15)의 임시 Nginx 선언과
   자동 Sync·제한된 재시도를 설정한 자식을 준비하고 관리자 리뷰 후 GitOps main에 반영한다.
   root 수동 Sync 없이 자식이 생성되고, 자식 수동 Sync 없이 Pod가 Ready가 되는지 확인한다.
5. #15의 Pod template을 Git에서 변경하고 자동 rollout과 Service HTTP 응답을 확인한다.
   Git 커밋과 root·자식의 적용 revision, Pod 실행 이미지를 대조한다.
6. 실패가 있으면 root·자식의 `.status.conditions`와 `.status.operationState`에서 원인을 확인한다.
   실패 operation의 재시도 횟수가 설정 범위를 넘지 않는지 확인한다. 실제 실패·재시도를 관찰하지
   않았다면 retry 설정 확인만 기록하며, 동작 검증 완료로 표시하지 않는다.
7. 같은 Ansible 설정을 재실행해 `changed=0`과 root 정책 유지를 확인한다. Git SHA, 대상 클러스터,
   두 번째 실행 recap, root·자식 Sync/Health, 이미지와 HTTP 결과만 기록하며 인증정보는 남기지 않는다.
8. #7~#10의 실제 선언 또는 고정 버전 chart 렌더링 결과와 AppProject 허용 목록을 대조한다.
   PV·PVC와 수집기가 지정한 프로젝트로 배포 가능한지 별도로 확인한다. 선언이 없거나
   미확정 값이 남은 항목은 미검증으로 기록한다.

이 목록은 수행할 절차다. #52의 별도 테스트 클러스터 결과는 아래 검증 기록을 따른다.
운영 ASTRA 적용과 #15의 Nginx 자동 배포 검증은 아직 완료하지 않았다.
#15의 임시 리소스와 정리 절차는 해당 GitOps 이슈에서 관리한다.

## Sync 정책과 삭제

| 대상 | 자동 Sync | Prune / Self Heal | 재시도 |
| --- | --- | --- | --- |
| root (Ansible 관리) | 활성화 | 모두 비활성화 | 최대 5회, 5초부터 2배씩 증가, 대기 상한 3분 |
| 기존 smoke-test 자식 | 기존 수동 정책 유지 | 모두 비활성화 | 기존 자식 선언 기준 |
| #15 및 #7~#10 자식 | GitOps에서 자동 Sync·제한된 재시도 구성 | 모두 비활성화 | 각 자식 선언에서 검토 |

root 설정은 Ansible template에서, 자식 설정은 GitOps Application에서 각각 변경한다.
root 자동 Sync는 Git에 있는 자식 정의를 적용하며, 자식의 자동 Sync 설정도 그 정의를 따른다.
root 정책만 바꿔도 기존 수동 자식의 자동 Sync가 켜지는 것은 아니다.
실험 중에는 이미지·GitOps 설정 변경을 멈추고 revision을 기록한다.

Self Heal 비활성화는 클러스터 직접 변경만을 원인으로 자동 복구하지 않는다는 뜻이다.
새 Git revision의 자동 Sync나 수동 Sync에서는 Git 값으로 덮어쓸 수 있으므로 직접 수정값의 보존을
보장하지 않는다. 긴급 수정은 Git에도 반영하고, 필요한 배포 중지는 각 Application의 자동 Sync를
원본에서 비활성화한다. root를 중지해도 이미 존재하는 자식의 자동 Sync는 독립적으로 동작한다.
root는 Ansible, 자식은 GitOps에서 정책을 변경해야 재적용 시 되돌아가지 않는다.

실패한 동일 revision을 재시도 한도 이후 무한히 재배포하지 않는다. 원인을 수정해 새 Git revision을
반영하거나, 복구 준비 후 Prune 없는 수동 Sync를 수행한다. 자동 Sync가 켜진 앱의 롤백은 Git revert로
수정 revision을 만드는 방식을 사용하고, root·자식 및 실제 리소스의 복구 결과를 확인한다.

Prune은 Git에서 삭제한 리소스를 자동 제거하지 않도록 계속 비활성화한다. root 경로에서 자식 파일을
지워도 기존 Application이 남고, 자식 경로에서 리소스를 지워도 클러스터 리소스가 남을 수 있다.
삭제 연쇄 finalizer도 추가하지 않는다. finalizer 없는 Application 삭제는 앱 리소스를 남긴다.

정리할 때는 삭제할 파일·Application·앱 리소스 목록을 먼저 확인하고, Git에서 정의를 제거한 뒤
클러스터 잔여 리소스를 명시적으로 정리한다. 정의가 남은 상태에서 리소스만 지우면 이후 Sync에서
다시 생성될 수 있다. namespace나 인증정보를 지우기 전에는 다른 리소스와 참조 Application을 확인한다.
PV·PVC 삭제는 사용 Pod, 바인딩과 `Retain` 정책, NFS 데이터 보존을 확인한 뒤 별도로 수행한다.
`Retain`은 백업을 대신하지 않는다. metrics-server 삭제는 HPA의 사용률 수집을 중단하므로 영향을
확인하고, 앱과 스토리지를 한꺼번에 Prune하여 정리하지 않는다.

키 회전은 새 Deploy Key 등록 → Vault 교체·Ansible 재적용 → 연결과 조회 성공 확인 →
기존 Deploy Key 폐기 순서로 진행한다.

## 테스트 검증 기록 (2026-10-14)

아래는 #34 당시 수동 Sync 정책의 과거 기록이다. #52 자동 Sync 검증 결과가 아니다.

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

당시 테스트 경로에서 main 연결을 재실행한 명령은 다음과 같다. 경로·VM·자격증명의 현재 존재를
확인한 뒤 사용한다. #52 코드로 실행하면 root 자동 Sync 정책이 적용되므로 과거 수동 동작과 다르다.

```bash
cd /home/orbit/issue34-gitops-test/ansible
ansible-playbook -i inventory/test.ini argocd.yml \
  -e argocd_gitops_enabled=true \
  -e argocd_gitops_revision=main \
  --vault-password-file /home/orbit/.config/orbit-issue34/vault-password
```

## #52 테스트 클러스터 검증 기록 (2026-10-15)

infrastructure `task/52-root-auto-sync`의 `73881a8`을 원격에 push한 뒤, ASTRA 호스트의
별도 경로 `/home/orbit/issue52-gitops-test`에서 검증했다. 기존 테스트 VM이 없어
`scripts/test-vms.sh`로 기본 libvirt 망에 테스트 VM 3대를 새로 만들었다.
운영망 `192.168.100.0/24`의 클러스터에는 플레이북이나 테스트 리소스를 적용하지 않았다.

| 항목 | 대상 / 결과 |
| --- | --- |
| 테스트 노드 | test-cp `.10`, test-w1 `.11`, test-w2 `.12` (`192.168.122.0/24`), 모두 Ready |
| Kubernetes / CNI | v1.33.13 / Calico v3.31.4 |
| Argo CD | v3.5.5, Helm chart 10.10.3, 주요 Pod Ready |
| 로컬 회귀 검증 | 테스트 7개 통과, 플레이북 문법 검사·`git diff --check` 통과 |
| ASTRA 제어 노드 | ansible-core 2.16.3, kubernetes.core 6.6.0, 문법 검사 통과 |
| 최초 Argo CD·GitOps 적용 | `ok=30 changed=12 unreachable=0 failed=0` |
| 동일 설정 재실행 | `ok=25 changed=0 unreachable=0 failed=0 skipped=5`, root 정책 유지 |
| root 정책 | 자동 Sync 활성화, Prune·Self Heal 비활성화, retry limit 5·5s·factor 2·maxDuration 3m |
| GitOps 연결 | 테스트 전용 읽기 전용 Deploy Key 사용, GitHub SSH 호스트 키 지문 공식 문서와 일치 |
| 최초 자동 Sync | 수동 Refresh·Sync 없이 root가 `orbit-issue52-test` 생성, 자식이 ConfigMap·PV·PVC 생성 |
| 스토리지 권한 | `workloads`의 `issue52-test-pv`·`orbit-gitops-test/issue52-test-pvc`가 모두 Bound |
| Git 변경 자동 반영 | 자식 라벨 `v2`, ConfigMap `issue52-v2`로 자동 갱신, root·자식 모두 `1c7ce17`에서 Synced / Healthy |
| 기존 수동 자식 | smoke-test는 자동 Sync 비활성 상태 유지, 테스트 클러스터에서 OutOfSync·operation 없음 |
| 권한 차단·재시도 | bootstrap에 금지된 ConfigMap 선언을 추가하자 생성 차단, root가 retryCount 5 후 Failed로 종료 |
| 실패 후 복구 | 오류 선언 revert 후 정상 라벨 변경 `f2bb21a`를 자동 적용, root operation Succeeded·retryCount 0 |

테스트용 GitOps 브랜치는 `task/52-auto-sync-test`이며 운영 main은 수정하지 않았다.
검증 revision은 최초 `d1a0d78`, Git 변경 `1c7ce17`, 권한 오류·재시도 `ad1c5e3`이다.
오류 선언은 `8288c6a`에서 revert하고, `f2bb21a`에서 복구 확인용 자식 라벨을 추가했다.
오류 제거만으로는 이전 실패 operation 이력이 남을 수 있어, 새 정상 변경이 자동 적용되어
root operation이 Succeeded로 바뀌는 것까지 확인했다. root·테스트 자식은 최종 Synced / Healthy이다.
이 검증에서는 수동 Sync operation을 요청하지 않았다.

PV·PVC는 권한과 정적 바인딩을 검증하기 위한 테스트용 hostPath 볼륨이다. 마운트하는 Pod는
만들지 않았으므로 실제 hostPath 디렉터리 생성·NFS 접근·Origin 읽기 전용 설정·데이터 보존의
동작 검증을 의미하지 않는다. 이는 GitOps #9의 실제 NFS 선언으로 별도 검증한다.
#15의 Nginx Pod·HTTP·rollout, #7~#10 실제 선언 및 수집기 권한 대조도 이 기록에 포함하지 않는다.

테스트 VM 3대와 GitOps 테스트 브랜치·전용 읽기 전용 Deploy Key는 후속 검증을 위해 유지한다.
암호화된 테스트 Vault는 테스트 작업본의 `ansible/secrets/argocd-vault.yml`에 보관하며,
개인키와 Vault 비밀번호는 출력·커밋하지 않았다. 실행 로그와 인증정보를 제외한 상태 기록은
ASTRA의 `/home/orbit/.config/orbit-issue52/`에 있다.

재실행은 ASTRA에서 다음과 같이 수행한다. 테스트 전용 Vault 비밀번호를 입력하며 운영용 Vault를
복사하지 않는다. 이 명령은 테스트 인벤토리와 테스트 GitOps 브랜치를 대상으로 한다.

```bash
cd /home/orbit/issue52-gitops-test/ansible
ansible-playbook -i inventory/test.ini argocd.yml \
  -e argocd_gitops_enabled=true \
  -e argocd_gitops_revision=task/52-auto-sync-test \
  --ask-vault-pass
```

## 애드온 추가 규칙과 참고

`orbit-gitops/platform/<addon>/`에 실제 manifest를 두고
`clusters/orbit-astra/apps/<addon>.yaml`에 platform 자식 Application을 추가한다.
필요한 권한, chart/이미지 버전, CRD 선행 적용, 데이터 보존, 롤백 및 삭제 영향을 PR에 기록한다.
권한 준비는 infrastructure에서, 실제 애드온 선언과 배포 검증은 GitOps의 각 이슈에서 수행한다.
외부 Helm chart를 직접 참조하는 자식은 `source.repoURL`·`chart`·고정 `targetRevision`을 지정하며,
필요한 values를 GitOps에서 관리한다. `source.path`는 Git 저장소를 읽는 경우에 사용한다.

- [Argo CD 선언형 repository 설정](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)
- [App of Apps 관리자 권한](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern-alternative)
- [AppProject 허용 범위](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)
- [자동 Sync 정책](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [Application 삭제와 finalizer](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/)
- [GitHub Deploy Key 관리](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
