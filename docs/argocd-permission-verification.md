# #52 실제 GitOps 선언과 AppProject 대조

작성: 2026-10-16. 저장소 정적 검사와 이후 ASTRA 운영 조회 기록이다. 최신 판정은 마지막 운영 검증 기록을 따른다.
관련: [#52](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/52),
[기존 구현 #58](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/pull/58),
[수집기 권한 #60](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/pull/60).

## 구현과 확인 범위

root 자동 Sync·재시도와 workloads PV/PVC 권한은 #58, observability·chart 저장소·DaemonSet 권한은
#60에서 develop에 반영됐다. 이번에는 기존 권한을 확대하지 않고 실제 선언을 대조하는
`scripts/verify_gitops_projects.py`를 추가했다. 이 검사는 클러스터를 조회하거나 변경하지 않는다.

Application의 project·destination 및 모든 source 저장소를 검사하고, 실제 렌더링된 각 리소스의
namespace·group/kind를 AppProject 허용·차단 목록과 대조한다. namespace가 없는 업무 리소스에는
Application destination을 사용한다. PV와 ClusterRole 등은 고정된 Kubernetes 종류별 범위로 판단하며,
알 수 없는 종류는 실패한다. 비어 있는 렌더링도 성공으로 처리하지 않는다.

이 도구는 이 저장소의 명시적 server·namespace 정책을 검사하는 보조 도구다. Kubernetes RBAC,
CRD/Admission, Sync window, Project 역할, 리소스 Health, NFS 접근이나 Argo CD 전체 권한 판정을
대체하지 않는다. named cluster, 이름별 리소스 정책, 부정 source/destination 패턴과 project-scoped
cluster 정책은 지원하지 않는다. 새 정책·종류를 도입하면 도구도 함께 검토한다. 단순 `*` glob 외의
복잡한 Argo CD 패턴 동작과 저장소 URL 정규화까지 재현하는 도구가 아니다.

namespace whitelist 생략은 기본 허용, 명시적 빈 목록은 거부이며 blacklist가 우선한다.
[Argo CD v3.5.5 원본](https://github.com/argoproj/argo-cd/blob/v3.5.5/pkg/apis/application/v1alpha1/app_project_types.go)의
정책 의미를 기준으로 한다. 입력에는 Secret·Vault 파일을 사용하지 않는다.

## 고정 입력과 결과

인프라 기반: develop `110531216bd9fcfb0f551d981c1ff280db256e29`.
GitOps main: `ebc228019b9b584c0893f95fbe8457cd83aaeac6`.
수집기: [GitOps PR #27](https://github.com/ORBIT-CLOUD-LABS/orbit-gitops/pull/27)의
head `ebe0628757967d4142456cd9341f7f1f6841dea4`.

| Application | 출처·렌더링 | Project / namespace | 렌더링 리소스 수 | 대조 결과 |
| --- | --- | --- | --- | --- |
| orbit-astra-orbit-server | main의 workloads/orbit-server, Kustomize | workloads / orbit | 5 | 허용 |
| orbit-astra-cdn | main의 workloads/cdn, Kustomize | workloads / orbit | 10 | 허용, PV 2·PVC 2 포함 |
| orbit-astra-metrics-server | chart 3.13.1, Application valuesObject | platform / kube-system | 9 | 허용 |
| orbit-astra-alloy | PR #27 chart 1.13.1, values.yaml + config.alloy fileParameter | platform / observability | 6 | 허용, 미머지 입력 |
| orbit-astra-kube-state-metrics | PR #27 chart 8.6.0, values.yaml | platform / observability | 5 | 허용, 미머지 입력 |

총 35개 리소스가 허용 범위에 있다. Metrics Server는 ClusterRole·ClusterRoleBinding·APIService·RoleBinding,
Alloy는 DaemonSet·ConfigMap·Service·ServiceAccount·ClusterRole·ClusterRoleBinding,
kube-state-metrics는 Deployment·Service·ServiceAccount·ClusterRole·ClusterRoleBinding을 사용한다.
수집기는 prometheus-community·grafana chart 저장소와 `$values` GitOps SSH 저장소 모두 허용되어야 한다.

GitOps #10은 closed지만 실제 PR #27은 이번 조회 시 open·미머지였다. 따라서 현재 main에서
수집기 선언이 없다는 사실과 이슈 종료 상태를 구분한다. 이 문서의 수집기 결과는 해당 PR head의
정적 검사이며 운영 설치·관측 데이터 수신 성공을 의미하지 않는다. PR head가 바뀌면 재검사한다.

Kustomize는 kubectl 내장 기능, Helm은 공식 배포의 SHA256을 확인한 v3.18.6으로 렌더링했다.
검사용 manifest는 임시 파일이며 별도 구현 checkout이나 worktree를 만들지 않았다.

## 실행 방법

PyYAML을 설치한 Python에서 실행한다. Application은 단일 YAML, 리소스는 Kustomize 또는
고정 chart/values로 렌더링한 YAML, Project는 Ansible 렌더링 또는 실제 AppProject 조회 결과를 제공한다.
Project 입력은 여러 YAML 문서 또는 `kubectl get appproject ... -o yaml`의 List를 지원한다.

```bash
python scripts/verify_gitops_projects.py \
  --application /tmp/orbit-server-application.yaml \
  --resources /tmp/orbit-server-rendered.yaml \
  --projects /tmp/orbit-projects.yaml
```

위 파일명은 준비할 입력의 예시다. gitops checkout·revision·manifest diff를 확인하고 렌더링한다.
Project를 로컬 원본에서 얻으려면 저장소 루트에서 기존 테스트와 동일한 Ansible 렌더링을 사용할 수 있다.

```bash
PYTHONPATH=tests python - <<'PY'
from pathlib import Path
import yaml
from test_argocd_gitops import render
Path('/tmp/orbit-projects.yaml').write_text(yaml.safe_dump_all(render('projects.yml.j2')))
PY
python -m unittest discover -s tests -v
```

원본 렌더링과 운영 Project를 각각 입력하면 둘 다 선언을 허용하는지 검사할 수 있다.
허용된 리소스만 검사하므로 Project의 불필요한 추가 권한 유무는 원본과 운영 spec을 별도 비교한다.

## 이번 검증과 남은 운영 작업

- 회귀 검사: 기존 8개와 새 권한 거부 검사 7개, 총 15개 통과.
- Ansible `argocd.yml --syntax-check` 통과.
- 고정된 5개 Application·35개 리소스의 오프라인 권한 대조 통과.
- ASTRA SSH는 기본 키와 기존 OTA lab 키 모두 `Permission denied`였다. 비밀번호·키 내용을 읽거나 기록하지 않았다.
- 운영 root·Project 현재 상태, PV/PVC Bound, 실제 수집기 설치, Ansible 재실행 changed=0은 이번에 검증하지 못했다.

#58의 테스트망 자동 Sync·PV/PVC Bound·재시도·복구·멱등성 기록과 GitOps #15의 운영 Nginx 자동 배포
기록은 [기존 운영 문서](argocd-gitops.md) 및 GitOps `docs/deploy-test.md`를 참조한다. 과거 기록을
현재 운영 검증으로 바꾸지 않는다. 접속 복구 후 원본과 운영 정책을 비교하고, 필요한 적용만 수행한 뒤
동일 설정 재실행과 현재 자식 자동 반영 증거를 기록한다. #52는 그 전까지 종료하지 않는다.


## SSH 복구 후 ASTRA 운영 검증 — 2026-10-16

공개키 등록 후 `orbit@orbit-astra` 접속과 내부 `orbit@192.168.100.101` 경유 운영 조회에 성공했다.
운영 control-plane은 `astra-control-plane`, 노드 4개 모두 Ready이며 Kubernetes v1.33.13이다.
Secret/Vault 원문 조회·수동 Sync·직접 workload apply는 수행하지 않았다.

| 확인 항목 | 결과 |
| --- | --- |
| 운영 GitOps revision | `8db0459293ac19c0589c7ef7b7325ed0c90f31f0` |
| root | Synced / Healthy, 자동 Sync enabled, Prune·Self Heal false, retry 5 / 5s·2·3m. Ansible 원본의 project/source/destination/syncPolicy와 일치 |
| Project | bootstrap·platform·workloads의 원본 관리 필드가 실제 운영 값과 일치. namespace·repo·허용/차단 리소스 목록 대조 |
| 자식 | 서버·CDN·Metrics Server·Alloy·kube-state-metrics 모두 Synced / Healthy, conditions 없음 |
| 자동 반영 증거 | root operation 자동 실행·Succeeded, 종료 `2026-10-15T23:41:58Z`. Alloy·kube-state-metrics 자동 실행·Succeeded, 종료 `2026-10-15T23:42:04Z` |
| 실제 스토리지 | PV orbit-origin-nfs-ro·orbit-origin-nfs-rw 및 PVC orbit/origin-files·orbit/origin-files-rw 모두 Bound |
| workload Ready | 서버 2/2, CDN Origin 1/1·Edge 2/2, kube-state-metrics 1/1, Alloy DaemonSet 3/3 |
| 현재 운영 권한 대조 | 위 revision에서 5개 Application·35개 리소스를 다시 렌더링하고 실제 운영 Project JSON으로 검사, 모두 통과 |

앞선 PR #27 미머지 기록 이후 수집기가 운영에 반영됐다. 현재 판정에는 위 운영 revision의 chart·values를
사용한다. multi-source 자식은 단일 status.sync.revision 대신 status.sync.revisions의 chart 버전과 Git SHA를
함께 확인했다. 관측 데이터의 Prometheus/Loki 수신 검증은 #52의 권한 검증과 구분한다.

### 원격 checkout과 재실행 제한

ASTRA의 기존 checkout은 과거 `task/57-argocd-platform-observability`의 `de2d36d`였다.
실행 전 비교 검사에서 이 원본은 root 자동 Sync 비활성·PV/PVC 권한 누락·옛 namespace를 갖고 있어
플레이북을 실행하지 않았다. 기존 checkout을 `task/52-root-auto-sync-verify`의 `4235b59`로 전환했다.
미추적 `ansible/secrets/vault.yml`과 기존 인증 파일은 보존했다. 별도 checkout/worktree는 만들지 않았다.

최신 원본에서 GitOps role만 실행했으나 암호화 비밀값 로드 task에서 no_log 실패했다.
recap은 `ok=1 changed=0 unreachable=0 failed=1`로, 실제 자원 적용 task에 도달하지 않았다.
이는 멱등성 성공 결과가 아니다. 사용자가 안전한 ASTRA 터미널에서 Vault 비밀번호를 입력한
재실행 결과를 확인해야 한다.

```bash
cd ~/orbit-infrastructure/ansible
ansible-playbook argocd.yml --tags argocd_gitops \
  -e argocd_gitops_enabled=true --ask-vault-pass
```

같은 명령을 재실행한 recap의 changed=0·failed=0과 정책 유지를 기록하기 전에는 #52를 종료하지 않는다.
Vault 비밀번호는 채팅·명령 인수·Git에 남기지 않는다.
