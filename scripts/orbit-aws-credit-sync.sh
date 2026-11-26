#!/usr/bin/env bash
# 크레딧 계정 CloudShell에서 S3 원격 state 연결, terraform.tfvars 자동 복원(use_existing_s3_iam = false),
# 콘솔 선발급 팀원 IAM 사용자(5명) idempotent import 및 태그 동기화를 한 번에 수행하는 스크립트 (docs/aws.md)
# 사용:
#   bash scripts/orbit-aws-credit-sync.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
TF_DIR="$REPO_ROOT/aws/terraform"

export PATH="$HOME/bin:$PATH"
# CloudShell 홈 디렉터리(1GB 제한) 용량 초과를 막기 위해 프로바이더 바이너리는 /tmp 에 배치
export TF_DATA_DIR="${TF_DATA_DIR:-/tmp/.terraform-orbit}"

echo "==> [1/5] CloudShell 디스크 여유 공간 확보 및 terraform 바이너리 확인"
rm -rf "$HOME/orbit-tf" "$TF_DIR/.terraform" 2>/dev/null || true
if ! command -v terraform >/dev/null 2>&1; then
  mkdir -p "$HOME/bin"
  TF_ARCH=$([ "$(uname -m)" = "aarch64" ] && echo "arm64" || echo "amd64")
  curl -fsSL "https://releases.hashicorp.com/terraform/1.10.5/terraform_1.10.5_linux_${TF_ARCH}.zip" -o /tmp/tf.zip
  unzip -qo /tmp/tf.zip -d "$HOME/bin" && rm -f /tmp/tf.zip
fi
terraform version | head -n 1

echo "==> [2/5] 크레딧 계정 S3 원격 state 버킷 및 Customer Gateway 자동 조회"
ACCT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="orbit-tfstate-prod-${ACCT_ID}"
aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null || {
  echo "오류: 현재 계정에 원격 state 버킷($STATE_BUCKET)이 없습니다. 크레딧 계정 CloudShell인지 확인하세요." >&2
  exit 1
}

CGW_IP=$(aws ec2 describe-customer-gateways --region ap-northeast-2 \
  --query "CustomerGateways[?State=='available'].IpAddress | [0]" --output text 2>/dev/null || true)
if [ -z "$CGW_IP" ] || [ "$CGW_IP" = "None" ]; then
  CGW_IP="203.0.113.10"
fi

CT_BUCKET="orbit-cloudtrail-logs-prod"
if (aws s3api head-bucket --bucket "$CT_BUCKET" 2>&1 || true) | grep -q "403"; then
  CT_BUCKET="orbit-cloudtrail-logs-prod-${ACCT_ID: -4}"
fi

echo "==> [3/5] backend_override.tf 및 크레딧 계정용 terraform.tfvars(use_existing_s3_iam = false) 생성"
cd "$TF_DIR"
cat <<'EOF' > backend_override.tf
terraform {
  backend "s3" {}
}
EOF

if [ ! -f terraform.tfvars ]; then
  umask 077
  cat <<EOF > terraform.tfvars
aws_region                 = "ap-northeast-2"
aws_profile                = ""
environment                = "prod"
owner                      = "sungahbak"
customer_gateway_ip        = "${CGW_IP}"
onprem_cidr                = "10.10.0.0/16"
onprem_rds_cidrs           = ["10.10.41.0/24", "10.10.42.0/24"]
db_instance_class          = "db.t4g.micro"
db_name                    = "vehicle"
db_username                = "vehicle_app"
db_password                = "SET_REAL_PASSWORD_BEFORE_RDS_APPLY"
use_existing_s3_iam        = false
enable_vault_object_lock   = true
firmware_bucket_name       = "orbit-firmware-origin-prod"
vault_snapshot_bucket_name = "orbit-vault-snapshot-prod"
origin_iam_user_name       = "svc-origin"
vault_backup_iam_user_name = "svc-vault-backup"
enable_team_iam_groups     = true
admin_group_members        = ["dohyun", "jihyun", "jiwoo", "sunga", "taekyung"]
dev_group_members          = []
enable_security_baseline   = true
cloudtrail_bucket_name     = "${CT_BUCKET}"
budget_limit_usd           = "100"
budget_alert_email         = ""
EOF
else
  sed -i '/^create_iam_users[[:space:]]*=/d; /^use_existing_s3_iam[[:space:]]*=/d' terraform.tfvars
  printf '\nuse_existing_s3_iam = false\n' >> terraform.tfvars
fi

echo "==> [4/5] S3 원격 state 초기화 및 팀원 5명 IAM 사용자 idempotent import"
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=orbit/aws/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

STATE_LIST=$(terraform state list || true)
for u in dohyun jihyun jiwoo sunga taekyung; do
  if printf '%s\n' "$STATE_LIST" | grep -Fq "aws_iam_user.team[\"$u\"]"; then
    echo "   ℹ️ 이미 state에 등록됨: $u"
  else
    echo "   📥 state로 import 중: $u"
    terraform import -input=false "aws_iam_user.team[\"$u\"]" "$u"
  fi
done

echo "==> [5/5] 팀원 IAM 사용자·그룹 멤버십 동기화 (일시 중지된 RDS 등 타 리소스 변경 없음)"
terraform apply -input=false -auto-approve \
  -target=aws_iam_user.team \
  -target=aws_iam_user_group_membership.admins \
  -target=aws_iam_user_group_membership.devs

echo "=== 최종 state 등록 확인 ==="
terraform state list | grep -E '^aws_iam_(user\.team|group\.)'
echo "✅ 크레딧 계정 팀원 IAM 전원 Terraform 일원화 완료!"
