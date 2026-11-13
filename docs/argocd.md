# Argo CD와 orbit-gitops root Application

구현: [#27](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/27). 선행: [#28](https://github.com/ORBIT-CLOUD-LABS/orbit-infrastructure/issues/28) (k3s SQLite 재설치).
운영 클러스터에서 설치 상태·워커 배치·AppProject·root 설정과 재실행 무변경을 확인했다. root의 `Synced`·`Healthy`와 허용 범위 밖 리소스 거부 시험은 아직 확인하지 않았다 ([적용 기록](#적용-기록)).
이 문서에는 이름과 절차만 기록한다. admin 비밀번호 값은 Git·Issue·PR·문서·채팅 어디에도 남기지 않는다.

이 레포는 Argo CD 설치, AppProject(배포 허용 범위), root Application을 맡는다. orbit-gitops는 root가 읽는 경로에 자식 Application과 실제 선언을 둔다. 허용 범위는 orbit-gitops PR로 넓힐 수 없고 이 레포에서만 바꾼다.

## 구성

| 항목 | 값 |
| --- | --- |
| 설치 방식 | k3s HelmChart manifest (Cilium과 같음). polaris `/var/lib/rancher/k3s/server/manifests/orbit-argocd.yaml`을 k3s helm-controller가 설치 |
| 버전 | chart `argo-cd` 10.11.6 (Argo CD v3.5.6). `roles/argocd/defaults/main.yml`의 `argocd_chart_version` |
| namespace | `argocd` |
| 구성요소 | application-controller, repo-server, server, redis, applicationset-controller. dex(SSO)·notifications는 끔 |
| 리소스 | 요청 합계 약 0.5 CPU / 1Gi, 메모리 상한 합계 약 2Gi. CPU 상한 없음 (orbit `docs/infrastructure.md`의 1 CPU / 2Gi 안) |
| 배치 | 워커(sol, terra, luna)만. polaris는 control-plane NoSchedule taint로 제외되고, 플레이북이 taint와 실제 배치 노드를 확인 |
| UI | 공개하지 않음. Service ClusterIP, ingress 없음. 기본은 kubectl로 확인하고 UI는 필요할 때만 port-forward ([상태 확인과 UI](#상태-확인과-ui)) |
| 저장소 인증 | 없음. orbit-gitops는 공개 저장소라 HTTPS로 읽음. 비공개로 바꾸면 읽기 전용 인증을 추가해야 함 |

### AppProject

| 프로젝트 | 용도 | 저장소 | 배포 대상 | 리소스 |
| --- | --- | --- | --- | --- |
| `default` | 쓰지 않음 (잠금) | 없음 | 없음 | 없음 |
| `orbit-k3s-root` | root Application 전용 | orbit-gitops | `argocd` | Application만 |
| `orbit-k3s-addons` | 애드온 (ESO, Fluent Bit 등) | orbit-gitops, `https://charts.external-secrets.io`, `https://fluent.github.io/helm-charts` | `external-secrets`, `fluent-bit` | 클러스터: CRD, ClusterRole, ClusterRoleBinding, ValidatingWebhookConfiguration, ClusterSecretStore. namespace 안: Application·ApplicationSet·AppProject를 뺀 전부 |

- `default`는 Argo CD가 자동으로 만들고 모든 것을 허용한다. 자식 Application이 `project: default`로 제한을 우회하지 못하게 비워 둔다.
- 허용 namespace는 플레이북이 미리 만든다. 프로젝트에는 Namespace 생성 권한이 없다.
- 업무 앱 프로젝트(`orbit-k3s-workloads`)는 앱 namespace가 정해진 뒤 추가한다. [허용 범위 넓히기](#허용-범위-넓히기)

Fluent Bit의 orbit-gitops #45·#46 공통 값은 namespace `fluent-bit`, ExternalSecret·Secret 이름 `fluent-bit-elasticsearch`, Secret 키 `password`다. 이 플레이북은 namespace와 AppProject 허용 범위를 관리하며 ExternalSecret·Secret 선언은 orbit-gitops에서 관리한다.

### root Application

| 항목 | 값 |
| --- | --- |
| 이름·프로젝트 | `orbit-k3s-root` / `orbit-k3s-root` |
| 소스 | `https://github.com/ORBIT-CLOUD-LABS/orbit-gitops.git`, `develop`, `clusters/orbit-k3s/apps` |
| 배포 대상 | `argocd` namespace (자식 Application만) |
| Sync | 자동(`enabled: true`), Prune·Self Heal 끔, 실패 시 5회 재시도(5초부터 최대 3분) |
| 삭제 | finalizer 없음. root를 지워도 자식 Application과 그 리소스는 남음 |

orbit-gitops `develop`에 `clusters/orbit-k3s/apps`가 생기기 전에는 root가 "경로 없음" 오류 상태로 남는다. 정상이며, 경로가 생기면 자동 Sync가 알아서 읽는다. 경로에 자식 Application을 올리면 바로 배포가 시작되므로 그 전에 AppProject 허용 범위를 확인한다.

## 실행

astra 개인 계정으로 `ansible/`에서 실행한다 ([개인 계정 문서의 Ansible 실행](personal-accounts.md#ansible-실행)). 먼저 `playbooks/cluster.yml`로 k3s가 설치되어 있어야 한다.

```bash
../scripts/orbit-ssh-cert.sh                                  # SSH 인증서 (8시간)
ansible-playbook playbooks/argocd.yml -K --check --diff       # 미리보기
ansible-playbook playbooks/argocd.yml -K                      # 적용
ansible-playbook playbooks/argocd.yml -K                      # 재실행: changed=0
```

플레이북은 polaris에서 다음 순서로 실행하고, 하나라도 어긋나면 멈춘다.

1. k3s 자동 설치 폴더와 polaris control-plane taint 확인
2. HelmChart manifest 배치 → HelmChart spec 반영, 최신 Helm release가 원하는 chart 버전·values로 `deployed`인지 확인 (`roles/argocd/files/check-release.py`) → 구성요소 rollout
3. Argo CD 파드가 모두 워커에 있는지 확인
4. 애드온 namespace와 AppProject 적용 → `default` 잠금과 두 프로젝트 확인 (`/var/lib/rancher/k3s/orbit-argocd/projects.yaml`)
5. root Application 적용 → 프로젝트·소스·Sync 정책 확인 (`/var/lib/rancher/k3s/orbit-argocd/root.yaml`). Sync 상태는 보지 않음

미리보기에서는 파일 변경만 보이고 적용·대기·확인은 건너뛴다. taint 확인은 읽기 전용이라 미리보기에서도 실행한다.

## 상태 확인과 UI

### kubectl로 확인 (기본)

UI 없이 polaris에서 `kubectl`로 확인·조작한다.

```bash
sudo k3s kubectl -n argocd get applications                     # 이름, Sync, Health
sudo k3s kubectl -n argocd get application orbit-k3s-root \
  -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
sudo k3s kubectl -n argocd get application <이름> -o jsonpath='{range .status.resources[*]}{.kind}/{.name}: {.status} {.health.status}{"\n"}{end}'
sudo k3s kubectl -n argocd get appproject
sudo k3s kubectl -n argocd get pods -o wide
```

### UI (필요할 때만)

UI는 공개하지 않고 기본으로 쓰지 않는다. 필요하면 polaris에서 내부망 주소로 port-forward를 잠깐 연다.

```bash
sudo k3s kubectl -n argocd port-forward --address 10.0.0.200 svc/argocd-server 8080:443
# 브라우저: https://10.0.0.200:8080 (자체 서명 인증서 경고는 정상). 끝나면 Ctrl+C로 닫음
```

- 열어 둔 동안에는 내부망에서 로그인 화면에 접근할 수 있다. 쓸 때만 연다.
- 내부망에 직접 붙은 기기에서는 바로 된다. Tailscale(subnet router 경유) 기기에서는 tailnet ACL이 `10.0.0.200:8080`을 허용해야 한다. 2026-11-09 기준 허용되어 있지 않다.
- `ssh -L` 터널은 쓸 수 없다. 개인 계정 SSH 인증서에 포트 포워딩 권한이 없다 ([개인 계정 문서](personal-accounts.md)).

로그인은 `admin`. 초기 비밀번호는 polaris에서 화면에만 출력한다.

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 허용 범위 넓히기

orbit-gitops가 chart 렌더링 결과로 필요한 namespace·저장소·리소스 종류를 전달하면 이 레포의 `roles/argocd/defaults/main.yml`을 고치는 PR로 넓힌다.

| 바꿀 것 | 변수 |
| --- | --- |
| 애드온 namespace | `argocd_addons_namespaces` |
| 애드온 chart 저장소 | `argocd_addons_chart_repos` |
| 애드온 클러스터 리소스 종류 | `argocd_addons_cluster_resources` |
| 업무 앱 프로젝트 | 앱 namespace가 정해지면 `templates/argocd-projects.yaml.j2`에 `orbit-k3s-workloads` 추가 |

허용 범위를 줄일 때는 이미 그 범위로 배포된 자식 Application이 없는지 먼저 확인한다. 범위 밖이 된 리소스는 Sync가 실패한다.

## 업그레이드

1. 새 chart 버전의 릴리스 노트와 values 변경을 확인한다.
2. `argocd_chart_version`을 바꾸고 미리보기 → 적용한다. 플레이북은 새 버전 release가 `deployed`가 되고 rollout이 끝날 때까지 기다린다 (최대 10분).
3. 실패하면 `sudo k3s kubectl -n kube-system logs job/helm-install-argocd`로 설치 작업 로그를 본다. 버전을 되돌리고 다시 실행하면 이전 버전으로 돌아간다.

argocd용 HelmChartConfig를 만들면 그 values가 release에 합쳐져 플레이북의 values 비교가 맞지 않는다. 쓰려면 `check-release.py`도 함께 고친다.

## root 자동 Sync 중지·재개

orbit-gitops에 잘못된 선언이 올라와 배포를 멈춰야 할 때 쓴다. polaris에서 실행한다.

```bash
# 중지
sudo k3s kubectl -n argocd patch application orbit-k3s-root --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
# 재개
sudo k3s kubectl -n argocd patch application orbit-k3s-root --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":true}}}}'
```

- root만 멈춘다. 이미 만들어진 자식 Application은 각자의 Sync 정책대로 계속 동작하므로, 자식까지 멈추려면 자식 Application에도 같은 patch를 한다.
- **`playbooks/argocd.yml`을 다시 실행하면 root 자동 Sync가 다시 켜진다** (템플릿이 `enabled: true`를 명시함). 중지 중에는 플레이북을 실행하지 않는다.

## 제거와 복구

### 제거

HelmChart manifest 파일을 지워도 설치된 Argo CD는 지워지지 않는다. polaris에서 순서대로 실행한다.

```bash
sudo k3s kubectl -n argocd delete application orbit-k3s-root          # finalizer 없음: 자식은 남음
sudo rm /var/lib/rancher/k3s/server/manifests/orbit-argocd.yaml       # 먼저 지워야 k3s가 HelmChart를 다시 만들지 않음
sudo k3s kubectl -n kube-system delete helmchart argocd               # helm-controller가 helm uninstall 실행
sudo rm -r /var/lib/rancher/k3s/orbit-argocd
```

- chart의 `crds.keep: true`(기본값)로 Argo CD CRD는 남는다. CRD를 지우면 남은 Application·AppProject도 함께 지워진다.
- 자식 Application이 배포한 리소스(ESO 등)는 Argo CD 제거와 상관없이 남는다.

### k3s 재설치 뒤 복구

k3s를 다시 설치하면 Argo CD와 AppProject, root가 모두 사라진다. `cluster.yml` 다음에 `argocd.yml`을 실행하면 같은 설정으로 다시 만들어지고, root가 orbit-gitops를 다시 읽어 자식 Application을 배포한다.

## 적용 기록

아래는 `jyvnee`가 astra에서 실행하고 공유한 플레이북 출력과 orbit-gitops #45 적용·검증 완료 확인을 기준으로 작성했다. 최초 Argo CD 설치 시점은 이번 기록으로 확정하지 않는다.

| 날짜 | 단계 | 결과 |
| --- | --- | --- |
| 2026-11-10 | 미리보기 (`--check --diff`) | `changed=1`, `failed=0`, `unreachable=0`. projects.yaml에 `fluent-bit` Namespace와 `orbit-k3s-addons`의 해당 namespace 목적지만 추가. HelmChart·root 파일 변경 없음 |
| 2026-11-10 | 적용 | `ok=22`, `changed=2`, `failed=0`, `unreachable=0`. namespace·AppProject 정의 파일과 실제 적용 단계만 변경. 원하는 chart·values의 Helm release 배포 상태, 구성요소 5개 rollout, 파드 5개의 워커 배치, default 잠금·프로젝트 존재, root 프로젝트·소스·자동 Sync 정책 검사 통과 |
| 2026-11-10 | 재실행 | `ok=22`, `changed=0`, `failed=0`, `unreachable=0`, `skipped=0`. 모든 확인 단계 재통과 |
| 2026-11-10 | orbit-gitops #45 연결 검증 | 사용자 확인: #45 적용 완료, ESO의 Vault 연결·비밀값 읽기와 ExternalSecret 동기화 검증 완료. `fluent-bit` namespace 생성·배포 허용 설정과 함께 기록 |

root의 Sync·Health 상태는 이 플레이북이 검사하지 않는다. orbit-gitops 연결 후 `Synced`·`Healthy` 확인과 허용 범위 밖 리소스 거부 시험을 별도로 기록한다.
