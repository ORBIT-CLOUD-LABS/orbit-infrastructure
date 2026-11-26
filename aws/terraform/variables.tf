variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로파일 이름 (새 계정 프로파일 지정)"
  type        = string
  default     = ""
}

variable "environment" {
  description = "배포 환경 구분"
  type        = string
  default     = "prod"
}

variable "owner" {
  description = "리소스 담당자 태그"
  type        = string
  default     = "sungahbak"
}

# ---------------------------------------------------------------------------
# 네트워크 & VPN 설정 (목표 구성도: orbit-vpc 10.20.0.0/16, 2a=10.20.2.0/24, 2c=10.20.4.0/24)
# 주의: 구성도 초안은 재설계 전 10.0.0.0/24 기준이나, W5 재설계(docs/fw.md)는 10.10.0.0/16을 사용하므로 변수화함
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "orbit-vpc CIDR (docs/fw.md의 fw_aws_net과 일치)"
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_2a_cidr" {
  description = "가용 영역 2a 프라이빗 서브넷 CIDR (리소스 주 배치)"
  type        = string
  default     = "10.20.2.0/24"
}

variable "subnet_2c_cidr" {
  description = "가용 영역 2c 프라이빗 서브넷 CIDR (RDS 서브넷 그룹 요건 충족용 예비)"
  type        = string
  default     = "10.20.4.0/24"
}

variable "onprem_cidr" {
  description = "VPN 경로 전파 및 S3·VPN 라우팅에 사용할 온프레미스 대역 (재설계 후: 10.10.0.0/16, 구버전: 10.0.0.0/24)"
  type        = string
  default     = "10.10.0.0/16"
}

variable "onprem_rds_cidrs" {
  description = "RDS 3306 인바운드를 허용할 온프레미스 클러스터 대역 목록 (재설계: ota-main/sub 10.10.41.0/24, 10.10.42.0/24)"
  type        = list(string)
  default     = ["10.10.41.0/24", "10.10.42.0/24"]
}

variable "enable_vpn" {
  description = "Site-to-Site VPN (VGW ASN 64512 + CGW + IPsec 터널 x2) 생성 여부"
  type        = bool
  default     = true
}

variable "customer_gateway_ip" {
  description = "강의실 온프레미스 공인 IP (Customer Gateway IP)"
  type        = string
}

variable "vgw_asn" {
  description = "Virtual Private Gateway ASN (목표 구성도 기준 64512)"
  type        = number
  default     = 64512
}

# ---------------------------------------------------------------------------
# 사설 엔드포인트 & admin-jump (SSM 포트 포워딩) 스위치
# ---------------------------------------------------------------------------
variable "enable_s3_vpce" {
  description = "2a 서브넷에 S3 Interface Endpoint(PrivateLink, Private DNS 켬) 생성 여부"
  type        = bool
  default     = true
}

variable "enable_admin_jump" {
  description = "관리자 SSM 포트 포워딩용 admin-jump EC2(t4g.nano) 및 SSM 엔드포인트 3종 생성 여부"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# RDS (vehicle DB) 설정 — 처음부터 사설 전용, 퍼블릭 접근·SourceIp 없음
# ---------------------------------------------------------------------------
variable "db_instance_class" {
  description = "RDS 인스턴스 클래스 (구성도 기준 db.t3.micro 또는 db.t4g.micro)"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS gp3 스토리지 용량 (GB)"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "초기 생성 데이터베이스 이름"
  type        = string
  default     = "vehicle"
}

variable "db_username" {
  description = "RDS 마스터 사용자 이름"
  type        = string
  default     = "vehicle_app"
}

variable "db_password" {
  description = "RDS 마스터 비밀번호 (민감값)"
  type        = string
  sensitive   = true
}

variable "db_multi_az" {
  description = "RDS Multi-AZ 여부 (기본 싱글 AZ)"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# S3 버킷 & IAM (기존 계정 재사용 모드 vs 새 계정 전체 생성 모드)
# ---------------------------------------------------------------------------
variable "use_existing_s3_iam" {
  description = "기존 계정(#10, #11)에 이미 생성된 S3 버킷 2개와 IAM 사용자(orbit-origin-backup, orbit-vault-backup)를 그대로 재사용할지 여부 (새 계정 전환 시 false)"
  type        = bool
  default     = true
}

variable "firmware_bucket_name" {
  description = "펌웨어 Origin S3 버킷 이름 (기존 계정 기본값: orbit-firmware-origin-backup)"
  type        = string
  default     = "orbit-firmware-origin-backup"
}

variable "vault_snapshot_bucket_name" {
  description = "Vault 스냅샷 백업용 S3 버킷 이름 (기존 계정 기본값: orbit-vault-snapshot-backup)"
  type        = string
  default     = "orbit-vault-snapshot-backup"
}

variable "origin_iam_user_name" {
  description = "펌웨어 Origin 전용 IAM 사용자 이름 (기존 계정: orbit-origin-backup, 새 계정 구성도: svc-origin)"
  type        = string
  default     = "orbit-origin-backup"
}

variable "vault_backup_iam_user_name" {
  description = "Vault 스냅샷 전용 IAM 사용자 이름 (기존 계정: orbit-vault-backup, 새 계정 구성도: svc-vault-backup)"
  type        = string
  default     = "orbit-vault-backup"
}

variable "enable_vault_object_lock" {
  description = "새 버킷 생성 시(use_existing_s3_iam = false) Vault 스냅샷 버킷에 Object Lock(Governance 30일) 적용 여부"
  type        = bool
  default     = true
}

variable "force_destroy_buckets" {
  description = "새 버킷 생성 시 terraform destroy 객체 강제 삭제 허용 여부"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# 보안·감사 기본선 & 모니터링 (CloudTrail, GuardDuty, Access Analyzer, Budgets)
# ---------------------------------------------------------------------------
variable "enable_security_baseline" {
  description = "CloudTrail(전 리전·무결성 검증), GuardDuty, IAM Access Analyzer 활성화 여부"
  type        = bool
  default     = true
}

variable "cloudtrail_bucket_name" {
  description = "CloudTrail 감사 로그 저장용 S3 버킷 이름 (enable_security_baseline = true 일 때 사용)"
  type        = string
  default     = ""
}

variable "enable_vpc_flow_logs" {
  description = "VPC Flow Logs(선택) 활성화 여부"
  type        = bool
  default     = false
}

variable "budget_limit_usd" {
  description = "월간 AWS 예산 상한 (USD)"
  type        = string
  default     = "200"
}

variable "budget_alert_email" {
  description = "예산 및 CloudWatch 알람 수신 이메일"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# 팀원 역할별 IAM 그룹 (목표 구성도: orbit-admins MFA 강제, orbit-devs ReadOnly)
# 기존 콘솔 생성 계정도 terraform import 로 편입하여 전원 Terraform으로 일원화 관리
# ---------------------------------------------------------------------------
variable "enable_team_iam_groups" {
  description = "팀원 역할별 IAM 그룹(orbit-admins, orbit-devs), 팀원 IAM 사용자, MFA 강제 정책, 계정 비밀번호 정책 관리 여부"
  type        = bool
  default     = false
}

variable "admin_group_members" {
  description = "orbit-admins 그룹(AdministratorAccess + MFA 강제)에 편입하고 Terraform으로 관리할 팀원 IAM 사용자 목록"
  type        = list(string)
  default     = []
}

variable "dev_group_members" {
  description = "orbit-devs 그룹(ReadOnlyAccess + MFA 강제)에 편입하고 Terraform으로 관리할 팀원 IAM 사용자 목록"
  type        = list(string)
  default     = []

  validation {
    condition     = length(setintersection(toset(var.admin_group_members), toset(var.dev_group_members))) == 0
    error_message = "동일한 IAM 사용자를 admin_group_members와 dev_group_members에 중복 지정할 수 없습니다."
  }
}
