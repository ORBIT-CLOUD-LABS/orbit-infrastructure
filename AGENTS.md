# AGENTS.md

ORBIT Lab 물리 호스트(astra, sol, terra, luna) 위에 VM과 Kubernetes·인프라 서비스를 구성하는 IaC 저장소입니다.
이 문서는 작업에 필요한 문서가 어디에 있는지 알려주는 지도입니다. 상세 내용은 각 문서를 직접 읽습니다.

## 문서 지도

| 알고 싶은 것 | 문서 |
| --- | --- |
| 요구사항 (호스트·VM 사양, OTA 흐름) | [`docs/requirements.md`](docs/requirements.md) → `ORBIT-CLOUD-LABS/orbit` 저장소 |
| Terraform 구조, state, 실행 방법 | [`terraform/README.md`](terraform/README.md) |
| Ansible 인벤토리, 롤, 플레이북 실행 방법 | [`ansible/README.md`](ansible/README.md) |
| 적용·rollback·장애 복구·백업 절차 | [`ansible/RUNBOOK.md`](ansible/RUNBOOK.md) |
| PR 작성 형식 | [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md) |

## 디렉터리 지도

| 경로 | 역할 |
| --- | --- |
| `terraform/environments/astra` | ASTRA의 network, storage pool, 업무 VM |
| `terraform/stacks/jenkins` | Jenkins VM (별도 state) |
| `terraform/modules` | libvirt network·VM, Ansible inventory 생성 모듈 |
| `ansible/inventory/lab` | 사이트·호스트 인벤토리 (`hosts.ini`는 Terraform이 생성) |
| `ansible/playbooks` | `site.yml`, `base.yml`, `jenkins.yml`, `postgresql.yml`, `preflight.yml` |
| `ansible/roles` | base, k8s_*, database, postgresql, monitoring_host, jenkins 등 롤 |
| `ansible/group_vars`, `ansible/secrets` | 그룹 변수, ansible-vault로 암호화한 비밀값 |
| `scripts` | 제어 노드 점검, VM 테스트 스크립트 |
| `.github/workflows` | GitHub Project 상태 연동 workflow |

## 작업 규칙

- 모든 변경은 Issue → Branch(`task/<이슈번호>-<요약>`) → PR(`develop` 대상) 순서로 진행합니다.
- 커밋·PR 제목은 `[Task/#<이슈번호>] <요약>` 형식을 따릅니다.
- 비밀값은 평문으로 커밋하지 않고 `ansible/secrets`의 vault 파일에만 둡니다.
- 문서를 추가하거나 옮기면 이 문서의 지도도 함께 수정합니다.
