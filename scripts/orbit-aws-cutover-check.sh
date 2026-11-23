#!/bin/sh
# 크레딧 계정 전환 후 보안 설정 검증(cutover) 및 기존 계정 과금 리소스 정리 확인(cleanup) 스크립트 (docs/aws.md)
# 사용:
#   scripts/orbit-aws-cutover-check.sh --mode cutover [--profile <profile>] [--firmware-bucket <name>] [--vault-bucket <name>] [--expect-object-lock]
#   scripts/orbit-aws-cutover-check.sh --mode cleanup [--profile <old-profile>]
set -eu

mode="cutover"
aws_profile="${AWS_PROFILE:-}"
region="${AWS_DEFAULT_REGION:-ap-northeast-2}"
fw_bucket="orbit-firmware-origin-backup"
vault_bucket="orbit-vault-snapshot-backup"
rds_id="orbit-vehicle-mysql"
expect_lock=0

die() { printf 'orbit-aws-cutover-check: FAIL — %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)               [ $# -ge 2 ] || die "--mode 값 필요"; mode="$2"; shift 2 ;;
    --profile)            [ $# -ge 2 ] || die "--profile 값 필요"; aws_profile="$2"; shift 2 ;;
    --region)             [ $# -ge 2 ] || die "--region 값 필요"; region="$2"; shift 2 ;;
    --firmware-bucket)    [ $# -ge 2 ] || die "--firmware-bucket 값 필요"; fw_bucket="$2"; shift 2 ;;
    --vault-bucket)       [ $# -ge 2 ] || die "--vault-bucket 값 필요"; vault_bucket="$2"; shift 2 ;;
    --rds-id)             [ $# -ge 2 ] || die "--rds-id 값 필요"; rds_id="$2"; shift 2 ;;
    --expect-object-lock) expect_lock=1; shift ;;
    -h|--help)
      sed -n '2,5p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws CLI가 필요합니다."
[ -n "$aws_profile" ] && export AWS_PROFILE="$aws_profile"
export AWS_DEFAULT_REGION="$region"

aws sts get-caller-identity --query Arn --output text >/dev/null || die "AWS 인증 실패"

if [ "$mode" = "cleanup" ]; then
  step "기존 계정 잔여 과금 리소스 점검 (리전: $region)"
  ec2_cnt=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "length(Reservations[].Instances[])" --output text)
  rds_cnt=$(aws rds describe-db-instances --query "length(DBInstances[])" --output text)
  vpn_cnt=$(aws ec2 describe-vpn-connections --filters "Name=state,Values=pending,available" --query "length(VpnConnections[])" --output text)
  vpce_cnt=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-endpoint-state,Values=pending,available" --query "length(VpcEndpoints[])" --output text)
  printf 'EC2=%s RDS=%s VPN=%s VPCE=%s\n' "$ec2_cnt" "$rds_cnt" "$vpn_cnt" "$vpce_cnt"
  [ "$ec2_cnt" = "0" ] && [ "$rds_cnt" = "0" ] && [ "$vpn_cnt" = "0" ] && [ "$vpce_cnt" = "0" ] ||
    die "시간당 과금 리소스가 남아 있습니다."
  echo "PASS: 시간당 과금 리소스 0개 확인"
  exit 0
fi

[ "$mode" = "cutover" ] || die "--mode는 cutover 또는 cleanup 이어야 합니다."

step "1. S3 버킷 퍼블릭 액세스 차단·암호화·버전 관리 점검 ($fw_bucket, $vault_bucket)"
for b in "$fw_bucket" "$vault_bucket"; do
  pab=$(aws s3api get-public-access-block --bucket "$b" --query "PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]" --output text)
  [ "$pab" = "$(printf 'True\tTrue\tTrue\tTrue')" ] || die "$b 퍼블릭 액세스 4개 항목이 모두 True가 아님: $pab"
  ver=$(aws s3api get-bucket-versioning --bucket "$b" --query "Status" --output text)
  [ "$ver" = "Enabled" ] || die "$b 버전 관리가 Enabled가 아님: $ver"
  sse=$(aws s3api get-bucket-encryption --bucket "$b" --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text)
  [ "$sse" = "AES256" ] || die "$b 기본 암호화가 AES256이 아님: $sse"
done
echo "PASS: 두 버킷 퍼블릭 차단(4/4), 버전 관리(Enabled), 암호화(AES256) 확인"

if [ "$expect_lock" = 1 ]; then
  step "2. Vault 스냅샷 버킷 Object Lock(GOVERNANCE 30일) 점검 ($vault_bucket)"
  lock_info=$(aws s3api get-object-lock-configuration --bucket "$vault_bucket" --query "ObjectLockConfiguration.[ObjectLockEnabled,Rule.DefaultRetention.Mode,Rule.DefaultRetention.Days]" --output text)
  [ "$lock_info" = "$(printf 'Enabled\tGOVERNANCE\t30')" ] || die "Object Lock 설정 불일치: $lock_info"
  echo "PASS: Object Lock Enabled (GOVERNANCE, 30일) 확인"
fi

step "3. 사설 RDS 노출 차단 및 암호화 점검 ($rds_id)"
rds_info=$(aws rds describe-db-instances --db-instance-identifier "$rds_id" --query "DBInstances[0].[PubliclyAccessible,StorageEncrypted]" --output text)
[ "$rds_info" = "$(printf 'False\tTrue')" ] || die "RDS 보안 설정 불일치(PubliclyAccessible=False, StorageEncrypted=True 필요): $rds_info"
echo "PASS: RDS PubliclyAccessible=False, StorageEncrypted=True 확인"

step "4. 공인 경로 S3 펌웨어 읽기 차단(403) 점검"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${fw_bucket}.s3.${region}.amazonaws.com/firmware/__cutover_probe__.bin")
[ "$code" = "403" ] || die "공인 경로 S3 요청이 403으로 차단되지 않음: $code"
echo "PASS: 공인 경로 S3 읽기 403 차단 확인"

printf '\n모든 전환 보안 점검 통과\n'
