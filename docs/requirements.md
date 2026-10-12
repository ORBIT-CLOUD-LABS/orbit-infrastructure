# 요구사항

이 저장소에는 요구사항 원본을 두지 않습니다. 서비스·인프라 요구사항은 [ORBIT-CLOUD-LABS/orbit](https://github.com/ORBIT-CLOUD-LABS/orbit) 저장소에서 관리합니다.

인프라 변경을 설계하거나 구현하기 전에 아래 문서에서 요구사항을 먼저 확인합니다.

| 문서 | 내용 |
| --- | --- |
| [`docs/infrastructure-plan.md`](https://github.com/ORBIT-CLOUD-LABS/orbit/blob/main/docs/infrastructure-plan.md) | 물리 호스트(astra, sol, terra, luna)별 하드웨어, VM 대역, VM 역할·사양·IP |
| [`docs/flow.md`](https://github.com/ORBIT-CLOUD-LABS/orbit/blob/main/docs/flow.md) | OTA 전체 흐름, 등장 주체(OTA 서버, Origin, CDN, 차량, DB 등) |
| [`docs/`](https://github.com/ORBIT-CLOUD-LABS/orbit/tree/main/docs) | 그 밖의 요구사항·설계 문서 전체 |

## 확인 방법

```bash
# 문서 목록
gh api repos/ORBIT-CLOUD-LABS/orbit/contents/docs --jq '.[].path'

# 문서 내용
gh api repos/ORBIT-CLOUD-LABS/orbit/contents/docs/infrastructure-plan.md --jq .content | base64 -d
```

## 규칙

- 요구사항과 이 저장소의 구현(Terraform 변수, Ansible 인벤토리 등)이 다르면 요구사항 문서를 기준으로 판단하고, 차이를 이슈로 남깁니다.
- 요구사항 자체를 바꿔야 하면 이 저장소가 아니라 `ORBIT-CLOUD-LABS/orbit` 저장소에서 변경합니다.
- 요구사항 내용을 이 저장소로 복사하지 않습니다. 원본과 사본이 어긋나는 것을 막기 위해 링크로만 참조합니다.
