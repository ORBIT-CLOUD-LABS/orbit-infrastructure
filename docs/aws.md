# AWS 구성 기록

Phase 2 AWS 전환 과정에서 AWS 콘솔로 구성한 S3·IAM 리소스를 기록한다.
이슈 요구사항(#10, #11)에 따라 계정 ID(`${AWS_ACCOUNT_ID}`)와 클러스터 공인 egress IP(`${CLUSTER_EGRESS_IP}`)는 변수로 표기하며 실제 값은 저장소에 커밋하지 않는다.

- 계정 ID: `${AWS_ACCOUNT_ID}`
- 리전: `ap-northeast-2` (서울)
- 관련 이슈: `orbit-infrastructure#10`, `orbit-infrastructure#11`, `orbit-server#79`

## 계정 보안

IAM 콘솔(보안 권장 사항 및 내 보안 자격 증명)에서 아래 두 항목을 확인했다.

| 항목 | 상태 |
|---|---|
| root MFA | 활성화 |
| root 액세스 키 | 없음 (발급하지 않음) |

## 구성 정의 파일 (`aws/`)

콘솔에서 설정한 정책과 수명 주기 규칙의 변경 이력을 코드로 추적하기 위해 JSON 정의 파일을 `aws/` 디렉터리에 함께 보관한다.

| 경로 | 적용 대상 | 콘솔 적용 위치 |
|---|---|---|
| `aws/iam/orbit-origin-backup-policy.json` | `OrbitOriginBackupS3Policy` | IAM → 정책 → `OrbitOriginBackupS3Policy` → 권한 편집(JSON) 및 기본 버전으로 설정 |
| `aws/s3/firmware-origin-lifecycle.json` | 버킷 1 수명 주기 | S3 → `orbit-firmware-origin-backup` → 관리 → 수명 주기 규칙 |
| `aws/s3/firmware-origin-bucket-policy.json` | 버킷 1 버킷 정책 (`${CLUSTER_EGRESS_IP}`를 실제 공인 IP로 치환) | S3 → `orbit-firmware-origin-backup` → 권한 → 버킷 정책 편집 |

## 버킷 1 — `orbit-firmware-origin-backup` (#10)

Phase 2 펌웨어 원본(Origin) 저장소다. `orbit-server`가 펌웨어 바이너리를 업로드(`PutObject`)하고, 지역별 Nginx Edge(`seoul`, `daejeon`, `busan`)가 `secure_link` 서명·만료를 검증한 뒤 캐시 MISS 시 HTTPS로 원본을 가져간다(`GetObject`).

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` |
| 퍼블릭 액세스 차단 | 4개 항목 전체 차단 (`모든 퍼블릭 액세스 차단` 켜짐) |
| 버전 관리 | `Enabled` |
| 기본 암호화 | `SSE-S3` (`AES256`), Bucket Key 활성화 |
| 객체 키 경로 | `firmware/{model}/{version}/firmware.bin` |

### 객체 접두사 통일 (`origin/` → `firmware/`)

초기 콘솔 생성 시 IAM 정책과 수명 주기 규칙의 접두사가 `origin/`으로 설정되어 있었으나, `orbit/docs/flow.md` 및 `orbit-server#79`의 업로드 객체 키 규칙은 `firmware/{model}/{version}/firmware.bin`이다. Phase 1(`docs/nfs-origin.md`)에서도 Origin/Edge 상대 경로가 `/firmware/<model>/<version>/firmware.bin`이었으므로, 버킷 객체 수가 0인 상태에서 IAM 정책과 수명 주기 규칙의 접두사를 모두 `firmware/`로 통일했다.

### 수명 주기 규칙

접두사 `firmware/`에 적용하며, 스토리지 클래스 전환(Standard-IA, Glacier 등)은 두지 않는다.

| 규칙 ID | 접두사 | 내용 |
|---|---|---|
| `firmware-noncurrent-expire-30d` | `firmware/` | 이전 버전(noncurrent) 30일 후 영구 삭제 |
| `firmware-abort-multipart-7d` | `firmware/` | 미완료 멀티파트 업로드 7일 후 중단 |

### 버킷 정책

1. `DenyInsecureTransport`: `aws:SecureTransport: false`인 평문 HTTP 요청을 전체 거부한다.
2. `AllowEdgeReadFromClusterEgress`: `orbit/docs/flow.md` 설계에 따라 클러스터 공인 egress IP(`${CLUSTER_EGRESS_IP}/32`)에서 오는 지역 Edge의 `s3:GetObject`(`firmware/*`) 요청을 허용한다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::orbit-firmware-origin-backup",
        "arn:aws:s3:::orbit-firmware-origin-backup/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    },
    {
      "Sid": "AllowEdgeReadFromClusterEgress",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::orbit-firmware-origin-backup/firmware/*",
      "Condition": {
        "IpAddress": {
          "aws:SourceIp": "${CLUSTER_EGRESS_IP}/32"
        }
      }
    }
  ]
}
```

> 참고: 퍼블릭 액세스 차단 4개 항목이 모두 켜져 있어도, `aws:SourceIp`가 단일 `/32` CIDR로 제한된 정책은 AWS S3가 퍼블릭 정책으로 분류하지 않으므로 퍼블릭 액세스 차단 설정과 충돌하지 않는다.

## 버킷 2 — `orbit-vault-snapshot-backup` (#11)

`astra` 노드의 HashiCorp Vault(단일 노드 Raft) 스냅샷 주기 백업 저장소다.

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` |
| 퍼블릭 액세스 차단 | 4개 항목 전체 차단 |
| 버전 관리 | `Enabled` |
| 기본 암호화 | `SSE-S3` (`AES256`), Bucket Key 활성화 |
| 객체 키 경로 | `vault/vault-<YYYYMMDDTHHMMSSZ>.snap` |

### 수명 주기 규칙 (`vault-snapshot-lifecycle`)

접두사 `vault/`에 적용하며, 스토리지 클래스 전환은 두지 않는다.

- 현재 버전 30일 후 만료 및 만료된 객체 삭제 마커 삭제
- 이전 버전(noncurrent) 30일 후 영구 삭제
- 미완료 멀티파트 업로드 7일 후 중단

### 버킷 정책

`DenyInsecureTransport` 문장으로 평문 HTTP 요청을 전체 거부한다.

## IAM

### 전용 사용자 및 정책

| 사용자 | 연결 정책 | 용도 |
|---|---|---|
| `orbit-origin-backup` | `OrbitOriginBackupS3Policy` (v3) | `orbit-server`의 펌웨어 Origin 업로드·조회 |
| `orbit-vault-backup` | `OrbitVaultSnapshotBackupS3Policy` (v1) | `astra`의 Vault 스냅샷 업로드·복구 조회 |

### 최소 권한 구조

두 정책 모두 동일한 3문장 구조로 대상 버킷과 접두사(`firmware/*`, `vault/*`)만 허용한다.

1. `s3:ListBucket` — 버킷 ARN에 `s3:prefix` 조건으로 해당 접두사만 조회 허용
2. `s3:GetObject`, `s3:PutObject` — 해당 접두사 하위 객체 ARN(`arn:aws:s3:::<버킷>/<접두사>/*`)만 허용
3. `s3:GetBucketLocation` — `s3:prefix` 조건 키가 없는 액션이므로 별도 문장으로 분리해 허용

### `s3:DeleteObject` 미부여 및 연관 확인 사항

- **Vault 스냅샷 (`orbit-vault-backup`)**: 백업 자격증명이 탈취되더라도 기존 백업본을 삭제할 수 없도록 `s3:DeleteObject`를 부여하지 않는다.
- **펌웨어 Origin (`orbit-origin-backup`)**: `#10` 초기 기준에 따라 `s3:DeleteObject`를 부여하지 않았다. 단, `orbit-server`의 `ArtifactRegistrationService.saveOrDiscardUpload()`는 업로드 후 DB 저장 실패 시 보상 삭제(`deleteObject`)를 호출하므로 `orbit-server#79`와 맞춰 허용 여부를 최종 확정한다.
- **개인 IAM 계정 분리**: IAM 콘솔의 정책 연결 엔터티 확인 결과 `OrbitOriginBackupS3Policy`에 서비스 계정(`orbit-origin-backup`) 외에 팀원 개인 IAM 계정들이 함께 연결되어 있어, 최소 권한 원칙에 따라 서비스 전용 정책은 `orbit-origin-backup`에만 유지하도록 분리한다.

### 자격증명 보관

- `orbit-origin-backup` 액세스 키: Vault `secret/orbit/orbit-server`에 `ORIGIN_S3_ACCESS_KEY`, `ORIGIN_S3_SECRET_KEY`로 저장하여 External Secrets Operator(ESO)가 `orbit-server-secret`으로 동기화한다([docs/vault.md](vault.md) 참조).
- `orbit-vault-backup` 액세스 키: `ansible-vault`로 암호화해 `astra`의 `/etc/vault.d/snapshot-aws.env`(`root:root`, `0600`)에 배치한다.
- 코드, ConfigMap, 공개 저장소에는 평문 키를 저장하지 않는다.
