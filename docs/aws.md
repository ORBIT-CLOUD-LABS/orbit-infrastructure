# AWS 구성 기록

Phase 2 AWS 전환 과정에서 **콘솔로 생성한** 리소스를 기록한다.
Terraform 관리 대상이 아니므로 변경 시 이 문서를 함께 갱신한다.

- 계정 ID: `${AWS_ACCOUNT_ID}` (실제 값은 커밋하지 않는다)
- 리전: `ap-northeast-2` (서울)
- 확인 기준일: 2026-11-04 (AWS CLI 조회값)
- 관련 이슈: orbit-infrastructure#10, orbit-infrastructure#11, orbit-server#79

## 계정 보안

| 항목 | 상태 |
|---|---|
| root MFA | 활성화 (`AccountMFAEnabled=1`) |
| root 액세스 키 | 없음 (`AccountAccessKeysPresent=0`) |

확인:

```bash
aws iam get-account-summary \
  --query 'SummaryMap.{MFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent}'
```

## 버킷 1 — orbit-firmware-origin-backup (#10)

펌웨어 원본 저장소. `orbit-server`가 업로드하고 지역 Edge가 캐시 MISS 시 읽어간다.

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` |
| 퍼블릭 액세스 | 4개 항목 전체 차단 |
| 버전 관리 | Enabled |
| 기본 암호화 | SSE-S3(AES256), Bucket Key 사용, SSE-C 차단 |
| Object Lock | **미설정** |
| 객체 수 | 0 (실사용 전) |

수명 주기 규칙 (접두사 `origin/`, 스토리지 클래스 전환 없음)

- 이전 버전(noncurrent) 30일 후 영구 삭제
- 미완료 멀티파트 업로드 7일 후 중단

버킷 정책 — `DenyInsecureTransport`

```json
{
  "Sid": "DenyInsecureTransport",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::orbit-firmware-origin-backup",
    "arn:aws:s3:::orbit-firmware-origin-backup/*"
  ],
  "Condition": { "Bool": { "aws:SecureTransport": "false" } }
}
```

평문 HTTP 요청만 거부한다. **Edge 읽기용 허용 구문은 아직 없다** (아래 "결정 필요 1").

## 버킷 2 — orbit-vault-snapshot-backup (#11)

`astra`의 Vault Raft 스냅샷 백업 저장소.

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` |
| 퍼블릭 액세스 | 4개 항목 전체 차단 |
| 버전 관리 | Enabled |
| 기본 암호화 | SSE-S3(AES256), Bucket Key 사용, SSE-C 차단 |
| 객체 수 | 0 (타이머 미구성) |

수명 주기 규칙 `vault-snapshot-lifecycle` (접두사 `vault/`)

- 이전 버전 30일 후 영구 삭제
- 미완료 멀티파트 업로드 7일 후 중단

버킷 정책은 버킷 1과 동일한 `DenyInsecureTransport` 하나다.

## IAM

### 사용자

| 사용자 | 정책 | 액세스 키 | 발급일 |
|---|---|---|---|
| `orbit-origin-backup` | `OrbitOriginBackupS3Policy` (v2) | 1개 Active | 2026-10-29 |
| `orbit-vault-backup` | `OrbitVaultSnapshotBackupS3Policy` (v1) | 1개 Active | 2026-11-01 |

### 공통 설계

두 정책 모두 같은 3문장 구조다.

1. `s3:ListBucket` — 버킷 ARN에 `s3:prefix` 조건으로 접두사 한정
2. `s3:GetObject` / `s3:PutObject` — 접두사 아래 객체 ARN만
3. `s3:GetBucketLocation` — **조건 없이 별도 문장으로 분리**

3번을 분리한 이유: `GetBucketLocation` 요청에는 `s3:prefix` 조건 키가 없으므로
1번과 같은 문장에 묶으면 `StringLike`가 평가 실패해 거부된다.

### 미부여 액션

**`s3:DeleteObject`를 두 사용자 모두에게 부여하지 않았다.**

- Vault 스냅샷: 백업 주체가 과거 백업을 지울 수 없어야 한다(랜섬웨어·오조작 대비).
  보존 기간 관리는 사용자 권한이 아니라 수명 주기 규칙이 담당한다.
- 펌웨어 Origin: 배포된 펌웨어를 서버 권한으로 지울 수 없게 한다.
  단, 이 때문에 orbit-server#79에 부작용이 있다(아래 "결정 필요 2").

검증:

```bash
aws s3 cp t.snap s3://orbit-vault-snapshot-backup/vault/t.snap --profile orbit-vault-backup   # 성공
aws s3 cp t.snap s3://orbit-vault-snapshot-backup/other/t.snap --profile orbit-vault-backup   # AccessDenied
aws s3 rm        s3://orbit-vault-snapshot-backup/vault/t.snap --profile orbit-vault-backup   # AccessDenied
```

### 액세스 키 보관

- 목표: 펌웨어 Origin 키는 Vault `secret/orbit/orbit-server`,
  스냅샷 키는 `ansible-vault`로 암호화해 `astra`에 `root:root` `0600` 배치
- **현재 상태: 미완료.** 두 키 모두 Vault/ansible-vault에 들어가 있지 않다.
- 코드·ConfigMap·공개 레포에는 어떤 경우에도 두지 않는다.

## 불일치 — 접두사가 맞지 않는다 (조치 필요)

**버킷 1의 접두사는 `origin/`이지만, 실제 업로드 객체 키는
`firmware/{model}/{version}/firmware.bin`이다** (#10 본문, orbit-server#79 본문).

그 결과 현재 구성에서는:

1. `OrbitOriginBackupS3Policy`가 `origin/*`만 허용하므로
   `orbit-server`가 `firmware/...`로 `PutObject` 하면 **AccessDenied**로 실패한다.
2. 수명 주기 규칙도 `origin/` 접두사에만 걸려 있어
   `firmware/` 객체에는 **이전 버전 삭제·멀티파트 중단이 적용되지 않는다.**

버킷이 아직 비어 있어(객체 0개) 지금 고치면 데이터 마이그레이션은 필요 없다.

선택지

- (A) 객체 키를 `origin/firmware/{model}/{version}/firmware.bin`으로 바꾼다 — AWS 설정 변경 없음
- (B) IAM 정책과 수명 주기 규칙의 접두사를 `firmware/`로 바꾼다 — 코드 변경 없음

`docs/nfs-origin.md`와 Phase 1 경로 규칙과의 일관성을 보고 정한다.

## 결정 필요

### 1. Edge → S3 읽기 인증 방식

#10 원안은 클러스터 공인 egress IP(`aws:SourceIp`)로 `s3:GetObject`를 허용하는 것이다.
이는 주체(`Principal: *`)를 묻지 않고 **출발 IP만 보는 네트워크 위치 기반 접근 제어**이므로,
같은 NAT를 공유하는 모든 워크로드에 사실상 열리고 공인 IP 변동 시 끊긴다.

Phase 2 AWS 결정서는 IAM Roles Anywhere로 장기 키와 IP 조건을 없애는 방향이지만,
Nginx는 S3 요청에 SigV4 서명을 할 수 없어 Edge에 그대로 적용되지 않는다.

후보 3개

| 방식 | 주체 | 제약 |
|---|---|---|
| `aws:SourceIp` | 없음(익명) | IP 변동에 깨짐, 같은 NAT 공유 범위에 노출 |
| IAM Roles Anywhere | IAM 역할 | Edge에서 서명 주체가 필요(사이드카·프록시) |
| CloudFront + OAC | CloudFront | 지역 Edge 3개 + `secure_link` 구성을 대체 |

지역 Edge(`seoul`/`daejeon`/`busan`)와 `secure_link` 유지 여부와 함께 결정해야 한다.
**이 결정 전까지 버킷 1의 Edge 읽기 허용은 추가하지 않는다.**

### 2. 등록 실패 시 S3 정리 방식 (orbit-server#79)

`s3:DeleteObject`가 없어 업로드 후 등록이 실패하면 객체가 남고,
같은 버전을 다시 등록할 수 없다. `DeleteObject` 허용 / 재등록 허용 중 선택이 필요하다.

### 3. Object Lock

버킷 1에 Object Lock이 설정되어 있지 않다. UN R155/R156 SUMS 근거로 채택할 경우
기존 버킷에 사후 활성화가 가능한지 확인이 필요하다.

```bash
aws s3api get-object-lock-configuration --bucket orbit-firmware-origin-backup
```

## 남은 작업

- [ ] 접두사 불일치 해소 (A/B 선택)
- [ ] 액세스 키를 Vault / `ansible-vault`로 이전
- [ ] 결정 1 확정 후 버킷 1에 Edge 읽기 허용 추가
- [ ] `roles/vault`에 스냅샷 AppRole·백업/복구 스크립트·systemd 타이머 (#11)
- [ ] `astra` 적용 후 업로드 및 `AccessDenied` 검증, `docs/vault.md` 문서화 (#11)
- [ ] 버킷 1 수명 주기 규칙 ID가 한글로 생성되어 있다 — IaC 전환 시 영문 ID로 재작성

## 참고 — 전체 설정 재확인

```bash
for B in orbit-firmware-origin-backup orbit-vault-snapshot-backup; do
  echo "## $B"
  aws s3api get-bucket-location --bucket $B
  aws s3api get-public-access-block --bucket $B
  aws s3api get-bucket-versioning --bucket $B
  aws s3api get-bucket-encryption --bucket $B
  aws s3api get-bucket-lifecycle-configuration --bucket $B
  aws s3api get-bucket-policy --bucket $B --query Policy --output text
done
```
