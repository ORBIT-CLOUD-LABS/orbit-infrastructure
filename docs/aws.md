# AWS 구성 기록

Phase 2 AWS 저장소(S3, RDS) 및 사설 네트워크 구성을 기록한다.
이슈 요구사항(`#10`, `#11`, `#72`)에 따라 계정 ID(`${AWS_ACCOUNT_ID}`), 온프레미스 공인 IP(`${ONPREM_PUBLIC_IP}`), S3 엔드포인트 ID(`${S3_VPCE_ID}`), VPN 사전 공유 키 등은 변수로 표기하며 실제 값은 저장소에 커밋하지 않는다.

- 계정 ID: `${AWS_ACCOUNT_ID}`
- 리전: `ap-northeast-2` (서울)
- 관련 이슈: `orbit-infrastructure#10`, `orbit-infrastructure#11`, `orbit-infrastructure#72`, `ORBIT-CLOUD-LABS/orbit#86`, `ORBIT-CLOUD-LABS/orbit-server#79`

## 계정 보안 및 감사 기본선

| 항목 | 상태 |
|---|---|
| root MFA | 활성화 |
| root 액세스 키 | 없음 (발급하지 않음) |
| GuardDuty | 활성화 (`aws_guardduty_detector`) |
| IAM Access Analyzer | 계정 단위 활성화 (`orbit-account-analyzer`) |
| CloudTrail | 선택 변수(`cloudtrail_bucket_name`) 지정 시 전 리전·로그 무결성 검증 활성화 |
| 알람 및 예산 | VPN `TunnelState` CloudWatch 알람, 선택 변수(`budget_alert_email`) 지정 시 월간 `AWS Budgets` 알람 |

## 구성 정의 파일 (`aws/`)

사설 네트워크·RDS·엔드포인트·S3 정책·IAM 권한은 `aws/terraform/`으로 선언해 관리하며, 초기 S3·IAM 기준 JSON 정의 파일을 `aws/iam/`, `aws/s3/`에 함께 보관한다.

| 경로 | 역할 |
|---|---|
| `aws/terraform/providers.tf` | Terraform·AWS 프로바이더 버전 고정 및 S3 원격 state 백엔드(`use_lockfile = true`) 전환 템플릿 |
| `aws/terraform/variables.tf` | 네트워크 대역, RDS 사양, 계정 전환 스위치(`use_existing_s3_iam`), 보안·알람 변수 정의 |
| `aws/terraform/network.tf` | `orbit-vpc`, 프라이빗 서브넷(`2a`, `2c`), Site-to-Site VPN, `S3`·`SSM` 인터페이스 엔드포인트, `admin-jump` EC2 |
| `aws/terraform/rds.tf` | 사설 RDS for MySQL 8.0(`orbit-vehicle-mysql`), 파라미터 그룹(`require_secure_transport=1`), 최소 권한 보안 그룹 |
| `aws/terraform/s3_iam.tf` | 기존/신규 계정 S3·IAM 분기, 펌웨어 버킷 `aws:SourceVpce` 정책, 서비스 최소 권한 정책 |
| `aws/terraform/governance_outputs.tf` | 보안·예산 기본선 리소스 및 연동 출력값(VPN 터널 주소·사전 공유 키 `sensitive` 처리) |
| `aws/terraform/terraform.tfvars.example` | 로컬 `.tfvars` 작성용 예시 파일 (실제 `terraform.tfvars` 및 `.tfstate`는 `.gitignore`로 제외) |
| `aws/iam/orbit-origin-backup-policy.json` | `orbit-origin-backup` 최소 권한 정책 정의 (`s3:DeleteObject` 포함) |
| `aws/s3/firmware-origin-lifecycle.json` | `orbit-firmware-origin-backup` 수명 주기 규칙 정의 |
| `aws/s3/firmware-origin-bucket-policy.json` | `orbit-firmware-origin-backup` 사설 엔드포인트(`aws:SourceVpce`) 전용 버킷 정책 정의 |

## 사설 네트워크 · 엔드포인트 · RDS (`aws/terraform/`, #72)

모든 서비스 통신은 퍼블릭 서브넷, IGW, NAT 게이트웨이, `aws:SourceIp` 허용 정책 없이 Site-to-Site IPsec VPN과 인터페이스 엔드포인트를 거친다.

### 네트워크 및 VPN 구성

| 항목 | 값 |
|---|---|
| VPC | `orbit-vpc` (`10.20.0.0/16`), `enable_dns_support = true`, `enable_dns_hostnames = true`, IGW·NAT 없음 |
| 프라이빗 서브넷 (`2a`) | `orbit-private-2a` (`10.20.2.0/24`) — RDS, `admin-jump`, `S3`·`SSM` 엔드포인트 배치 |
| 프라이빗 서브넷 (`2c`) | `orbit-private-2c` (`10.20.4.0/24`) — 비어 있음 (RDS 서브넷 그룹 2개 AZ 요건 충족용 예비) |
| 라우팅 | `rt-private` 단일 프라이빗 라우팅 테이블, VGW 경로 전파 활성화 |
| Site-to-Site VPN | `orbit-vgw` (`ASN 64512`) + `orbit-fw-cgw` (`${ONPREM_PUBLIC_IP}`) + IPsec 터널 2개 (`IKEv2`, `AES256`, `SHA2-256`, DH `14~18`, 정적 경로 `10.10.0.0/16`) |

### 인터페이스 엔드포인트 및 관리 점프 호스트

비용 절감을 위해 인터페이스 엔드포인트 4개(`s3`, `ssm`, `ssmmessages`, `ec2messages`)는 `2a` 서브넷에만 단독 배치한다(`2a` 가용 영역 장애 시 해당 경로 중단, 필요 시 `2c` 추가).

| 리소스 | 세부 설정 및 접근 통제 |
|---|---|
| `orbit-s3-vpce` | `com.amazonaws.ap-northeast-2.s3` (`Interface`), Private DNS 활성화 (`private_dns_only_for_inbound_resolver_endpoint = false` — Gateway 엔드포인트 없이 단독 동작), 인바운드 `10.10.0.0/16` → `443`만 허용(아웃바운드 규칙 없음), 프로젝트 버킷 2개만 통과하는 엔드포인트 정책 적용 |
| `orbit-ssm-vpce` 외 2종 | `ssm`, `ssmmessages`, `ec2messages` (`Interface`), Private DNS 활성화, 인바운드 `admin-jump-sg` → `443`만 허용(아웃바운드 규칙 없음) |
| `admin-jump` | `t4g.nano` (Amazon Linux 2023 arm64), 퍼블릭 IP 없음, `IMDSv2` 강제(`http_tokens = required`), `gp3` 8GB 암호화, 인바운드 규칙 없음, 아웃바운드는 `SSM` 엔드포인트(`443`)와 `RDS`(`3306`)로만 제한 |

### 사설 RDS (`orbit-vehicle-mysql`)

| 항목 | 값 |
|---|---|
| 엔진 및 사양 | MySQL `8.0`, `db.t3.micro`, 싱글 AZ, `gp3` 20GB 스토리지 암호화, 자동 백업 보존 7일 |
| 초기 DB / 계정 | DB 이름 `vehicle`, 사용자 `vehicle_app` |
| 노출 및 전송 보안 | `publicly_accessible = false`, 파라미터 그룹(`orbit-mysql8-tls`)에서 `require_secure_transport = 1`, `utf8mb4` / `utf8mb4_0900_ai_ci` 적용 |
| 보안 그룹 (`orbit-rds-sg`) | 인바운드 `3306`은 온프레미스 OTA 클러스터 대역(`10.10.41.0/24`, `10.10.42.0/24`)과 `admin-jump-sg`만 허용, 아웃바운드 규칙 없음 |

### 계정 전환 모드 (`use_existing_s3_iam`)

- **기존 계정 유지 모드 (`use_existing_s3_iam = true`, 기본값)**: `#10`·`#11`에서 생성한 버킷 2개와 서비스 IAM 계정(`orbit-origin-backup`, `orbit-vault-backup`)을 `data` 블록으로 참조해 Vault 및 `ansible-vault`에 저장된 기존 액세스 키를 유지한다.
- **신규 크레딧 계정 생성 모드 (`use_existing_s3_iam = false`)**: 새 계정에 동일 구성으로 버킷 2개(Vault 스냅샷 버킷 `Object Lock` Governance 30일 포함)와 서비스 IAM 계정을 처음부터 생성한다.

### 실행 및 검증 절차

```powershell
# 1. 작업 디렉터리에서 로컬 변수 파일(terraform.tfvars) 작성 후 초기화·검증
terraform -chdir=aws/terraform init
terraform -chdir=aws/terraform fmt -check
terraform -chdir=aws/terraform validate

# 2. 변경 계획 확인 및 적용
terraform -chdir=aws/terraform plan
terraform -chdir=aws/terraform apply

# 3. 재실행 시 추가 변경 없음(멱등성) 확인
terraform -chdir=aws/terraform plan -detailed-exitcode

# 4. 후속 작업(strongSwan, SSM, Vault) 연동 값 로컬 조회 (외부 공유 시 평문 기록 금지)
terraform -chdir=aws/terraform output rds_endpoint
terraform -chdir=aws/terraform output s3_vpce_dns_entries
terraform -chdir=aws/terraform output -raw vpn_tunnel1_address
terraform -chdir=aws/terraform output -raw vpn_tunnel1_preshared_key
```

### 관리자 SSM 포트 포워딩 접속 (#74)

퍼블릭 IP나 SSH(`22`) 인바운드를 열지 않고, `admin-jump` 인스턴스와 `SSM` 인터페이스 엔드포인트 3종(`ssm`, `ssmmessages`, `ec2messages`)을 거쳐 로컬 `127.0.0.1:13306`을 사설 RDS(`3306`)로 연결한다.

사전 준비:
- AWS CLI v2 및 AWS Session Manager Plugin(`session-manager-plugin`)
- 관리자 IAM 계정에 `OrbitAdminSsmPortForwardPolicy`(`AWS-StartPortForwardingSessionToRemoteHost` 문서만 허용, 일반 셸 세션 제외) 연결

실행:

```bash
# macOS / Linux
scripts/orbit-rds-ssm.sh --check          # 인증 및 admin-jump Online 상태만 점검
scripts/orbit-rds-ssm.sh                  # 127.0.0.1:13306 포트 포워딩 시작
```

```powershell
# Windows (저장소 최상위 PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-rds-ssm.ps1 -CheckOnly
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-rds-ssm.ps1
```

별도 터미널에서 TLS 강제 옵션으로 접속한다(평문 연결은 `require_secure_transport = 1`에 의해 거부됨):

```bash
mysql -h 127.0.0.1 -P 13306 -u vehicle_app -p --ssl-mode=REQUIRED vehicle
```

## 버킷 1 — `orbit-firmware-origin-backup` (#10, #72)

Phase 2 펌웨어 원본(Origin) 저장소다. `orbit-server`가 VPN 및 S3 인터페이스 엔드포인트 경로로 펌웨어 바이너리를 업로드(`PutObject`)하고, 지역별 Nginx Edge(`seoul`, `daejeon`, `busan`)가 `secure_link` 서명·만료를 검증한 뒤 캐시 MISS 시 사설 S3 엔드포인트(`aws:SourceVpce`)로 원본을 가져간다(`GetObject`).

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` |
| 퍼블릭 액세스 차단 | 4개 항목 전체 차단 (`모든 퍼블릭 액세스 차단` 켜짐) |
| 버전 관리 | `Enabled` |
| 기본 암호화 | `SSE-S3` (`AES256`), Bucket Key 활성화 |
| 객체 키 경로 | `firmware/{model}/{version}/firmware.bin` |

### 수명 주기 규칙

접두사 `firmware/`에 적용하며, 스토리지 클래스 전환(Standard-IA, Glacier 등)은 두지 않는다.

| 규칙 ID | 접두사 | 내용 |
|---|---|---|
| `firmware-noncurrent-expire-30d` | `firmware/` | 이전 버전(noncurrent) 30일 후 영구 삭제 |
| `firmware-abort-multipart-7d` | `firmware/` | 미완료 멀티파트 업로드 7일 후 중단 |

### 버킷 정책 (`aws:SourceVpce` 전환)

1. `DenyInsecureTransport`: `aws:SecureTransport: false`인 평문 HTTP 요청을 전체 거부한다.
2. `AllowEdgeReadFromVpceOnly`: 초기 공인 IP(`aws:SourceIp`) 허용 규칙을 제거하고, `orbit-vpc`의 S3 인터페이스 엔드포인트(`${S3_VPCE_ID}`)를 통과한 `s3:GetObject`(`firmware/*`) 요청만 허용한다.

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
      "Sid": "AllowEdgeReadFromVpceOnly",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::orbit-firmware-origin-backup/firmware/*",
      "Condition": {
        "StringEquals": {
          "aws:SourceVpce": "${S3_VPCE_ID}"
        }
      }
    }
  ]
}
```

## 버킷 2 — `orbit-vault-snapshot-backup` (#11)

`astra` 노드의 HashiCorp Vault(단일 노드 Raft) 스냅샷 주기 백업 저장소다.

| 항목 | 값 |
|---|---|
| 리전 | `ap-northeast-2` |
| 퍼블릭 액세스 차단 | 4개 항목 전체 차단 |
| 버전 관리 | `Enabled` (신규 계정 생성 모드에서는 `Object Lock` Governance 30일 함께 적용) |
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
| `orbit-origin-backup` | `OrbitOriginBackupS3Policy` 및 인라인 `OrbitOriginFirmwarePolicy` | `orbit-server`의 펌웨어 Origin 업로드·조회·실패 롤백 삭제 |
| `orbit-vault-backup` | `OrbitVaultSnapshotBackupS3Policy` | `astra`의 Vault 스냅샷 업로드·복구 조회 |
| 관리자 계정 (필요 시 연결) | `OrbitAdminSsmPortForwardPolicy` | `admin-jump` 대상 포트 포워딩 세션(`AWS-StartPortForwardingSessionToRemoteHost`)만 허용 |

### 최소 권한 및 삭제 권한 원칙

1. **접두사 격리**: `s3:ListBucket`은 `s3:prefix` 조건으로 해당 접두사(`firmware/*`, `vault/*`)만 조회를 허용하고, 객체 작업도 해당 접두사 ARN으로만 제한한다.
2. **펌웨어 Origin (`orbit-origin-backup`)**: `ORBIT-CLOUD-LABS/orbit-server#79`의 업로드 후 DB 저장 실패 시 보상 삭제(`ArtifactRegistrationService.saveOrDiscardUpload()`) 요건에 맞춰 현재 버전 삭제(`s3:DeleteObject`)를 허용하되, 이전 버전 영구 삭제(`s3:DeleteObjectVersion`)는 부여하지 않는다.
3. **Vault 스냅샷 (`orbit-vault-backup`)**: 백업 자격증명이 탈취되더라도 기존 백업본을 지울 수 없도록 `s3:DeleteObject`를 부여하지 않는다.
4. **개인 IAM 계정 분리**: 서비스 전용 관리형 정책(`OrbitOriginBackupS3Policy`, `OrbitVaultSnapshotBackupS3Policy`)은 팀원 개인 계정에 연결하지 않고 각 서비스 전용 사용자 1개(`AttachmentCount = 1`)에만 단독 유지한다.

### 자격증명 보관 및 서버·Edge 사설 경로 연동 (#76)

- **`orbit-server` Vault 경로 (`secret/orbit/k3s/orbit-server`)**: `orbit-server/src/main/resources/application.yml` 바인딩 이름에 맞춰 아래 키로 저장하며, ESO가 Kubernetes Secret으로 동기화한다([docs/vault.md](vault.md) 참조).
  - DB 연결: `DB_URL`(`jdbc:mysql://<rds_endpoint>:3306/vehicle?sslMode=REQUIRED`), `DB_USERNAME`(`vehicle_app`), `DB_PASSWORD`
  - S3 Origin 연결: `ORIGIN_REGION`(`ap-northeast-2`), `ORIGIN_BUCKET`(`orbit-firmware-origin-backup`), `ORIGIN_ACCESS_KEY`, `ORIGIN_SECRET_KEY`, `ORIGIN_ENDPOINT`
  - 앱 인증·서명: `ENROLLMENT_KEY`, `ADMIN_TOKEN`, `CDN_URL_SIGNING_KEY_ID`, `CDN_URL_SIGNING_SECRET`
- **사설 S3 인터페이스 엔드포인트(`orbit-s3-vpce`) 연결 방식**:
  1. `ORIGIN_ENDPOINT`에 리전별 VPCE 버킷 DNS(`https://bucket.<vpce-id>-<suffix>.s3.ap-northeast-2.vpce.amazonaws.com`) 지정: 공용 DNS에서도 `10.20.2.x` 사설 IP로 바로 해석되며, `OriginStorageConfig.java`가 `forcePathStyle(true)`(`https://bucket.<vpce>.../orbit-firmware-origin-backup/firmware/...`)로 요청해 별도 내부 DNS 변경 없이 동작한다.
  2. 클러스터 CoreDNS `hosts`에서 `orbit-firmware-origin-backup.s3.ap-northeast-2.amazonaws.com`을 `orbit-s3-vpce` 사설 IP로 매핑하는 방식: `ORIGIN_ENDPOINT`를 비워 기본 버킷 도메인(virtual-hosted style)을 그대로 쓰며, CDN Edge `nginx`에서도 `proxy_ssl_server_name on`으로 동일 도메인을 프록시할 수 있다.
- **`orbit-vault-backup` 액세스 키 및 스냅샷 사설 경로**: `ansible-vault`로 암호화해 `vault` VM의 `/etc/vault.d/snapshot-aws.env`(`root:root`, `0600`)에 배치한다. VPN 개통 뒤 `inventory/group_vars/all/hashicorp-vault.yml`의 `hvault_snapshot_endpoint_url`에 위 `https://bucket.<vpce>...` 주소를 지정하면 스냅샷 업로드·복원도 사설 엔드포인트를 거친다.
- **경로 점검**: 터널 개통 후 OTA 클러스터 노드에서 `scripts/orbit-aws-path-check.sh --rds-host <rds-host> --vpce-dns <bucket.vpce-...>`로 사설 도달성과 공인 경로 `403` 차단을 함께 확인한다.
- 코드, ConfigMap, 공개 저장소에는 평문 키와 실제 공인 IP를 저장하지 않는다.
