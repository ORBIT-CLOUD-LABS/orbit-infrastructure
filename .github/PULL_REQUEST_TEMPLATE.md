## Related Issue

Closes #

## Summary

<!--
무엇을, 왜 변경했는지 2~4개의 불릿으로 작성합니다.
구현 문법보다 생성·수정·삭제되는 인프라 자원을 우선 작성합니다.

필요한 경우 아래 항목을 추가합니다.
- Infrastructure Changes: VM, network, storage 또는 Kubernetes node 변경
- IaC Changes: Terraform resource 또는 Ansible role·playbook 변경
- Configuration Changes: IP, port, variable, inventory 또는 접근 경로 변경
- Operational Impact: 재시작, 중단 시간, 데이터 이전 또는 수동 작업
- Destructive Changes: 삭제되거나 재생성되는 자원과 복구 방법
-->

-

## Verification

<!--
변경한 도구에 해당하는 검증만 작성합니다.

예:
- terraform fmt -check 통과
- terraform validate 통과
- terraform plan 결과 VM 1개 생성, 변경·삭제 없음
- ansible-playbook --syntax-check 통과
- 대상 VM에서 playbook 재실행 시 추가 변경 없음
-->

-

- [ ] 변경한 IaC 설정의 형식과 유효성을 확인했습니다.
- [ ] plan 또는 dry-run 결과를 확인했습니다.
- [ ] 의도하지 않은 자원 삭제·재생성이 없는지 확인했습니다.
- [ ] 네트워크, 스토리지 및 서비스 중단 영향을 확인했습니다.
- [ ] 변수나 적용 방법이 변경됐다면 관련 문서를 수정했습니다.

<!--
## To Reviewer

파괴적 변경, 적용 순서, 수동 작업, rollback 방법 또는
환경별 차이가 있을 때만 작성합니다.
-->