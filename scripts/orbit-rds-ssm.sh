#!/bin/sh
# 관리자 노트북에서 admin-jump EC2를 거쳐 사설 RDS(3306)로 SSM 포트 포워딩을 여는 스크립트 (docs/aws.md)
# 사용:
#   scripts/orbit-rds-ssm.sh                                    aws/terraform 출력값에서 자동 조회 (기본 로컬 포트 13306)
#   scripts/orbit-rds-ssm.sh --local-port 23306 --profile prod  로컬 포트·AWS 프로파일 지정
#   scripts/orbit-rds-ssm.sh --check                            포트 포워딩을 열지 않고 사전 조건과 admin-jump Online 상태만 점검
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/.." && pwd)
tf_dir="$repo_root/aws/terraform"

local_port=13306
remote_port=3306
instance_id="${ORBIT_JUMP_INSTANCE_ID:-}"
rds_host="${ORBIT_RDS_HOST:-}"
aws_profile="${AWS_PROFILE:-}"
check_only=0

die() { printf 'orbit-rds-ssm: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --local-port)  [ $# -ge 2 ] || die "--local-port 값 필요"; local_port="$2"; shift 2 ;;
    --instance-id) [ $# -ge 2 ] || die "--instance-id 값 필요"; instance_id="$2"; shift 2 ;;
    --rds-host)    [ $# -ge 2 ] || die "--rds-host 값 필요"; rds_host="$2"; shift 2 ;;
    --profile)     [ $# -ge 2 ] || die "--profile 값 필요"; aws_profile="$2"; shift 2 ;;
    --check)       check_only=1; shift ;;
    -h|--help)
      sed -n '2,6p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "알 수 없는 인자: $1 (--help 참조)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws CLI가 없습니다. 설치 후 다시 실행하세요."
command -v session-manager-plugin >/dev/null 2>&1 ||
  die "session-manager-plugin이 없습니다. AWS Session Manager Plugin 설치 후 다시 실행하세요."

if [ -n "$aws_profile" ]; then
  export AWS_PROFILE="$aws_profile"
fi

if [ -z "$instance_id" ] && command -v terraform >/dev/null 2>&1 && [ -f "$tf_dir/terraform.tfstate" ]; then
  instance_id=$(terraform -chdir="$tf_dir" output -raw admin_jump_instance_id 2>/dev/null || true)
fi
if [ -z "$rds_host" ] && command -v terraform >/dev/null 2>&1 && [ -f "$tf_dir/terraform.tfstate" ]; then
  rds_ep=$(terraform -chdir="$tf_dir" output -raw rds_endpoint 2>/dev/null || true)
  rds_host="${rds_ep%:*}"
fi

[ -n "$instance_id" ] || die "admin-jump 인스턴스 ID를 알 수 없습니다. --instance-id 또는 ORBIT_JUMP_INSTANCE_ID로 지정하세요."
[ -n "$rds_host" ] || die "RDS 호스트 주소를 알 수 없습니다. --rds-host 또는 ORBIT_RDS_HOST로 지정하세요."

step "AWS 인증 및 admin-jump SSM 상태 확인 ($instance_id)"
aws sts get-caller-identity --query Arn --output text >/dev/null ||
  die "AWS 자격증명이 유효하지 않습니다. aws configure 또는 AWS_PROFILE을 확인하세요."

ping_status=$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$instance_id" \
  --query "InstanceInformationList[0].PingStatus" \
  --output text 2>/dev/null || echo "None")

[ "$ping_status" = "Online" ] ||
  die "admin-jump($instance_id) SSM 상태가 Online이 아닙니다 (현재: $ping_status). SSM 인터페이스 엔드포인트 상태를 확인하세요."
echo "SSM PingStatus: Online"

if [ "$check_only" = 1 ]; then
  echo "사전 점검 통과 (127.0.0.1:${local_port} -> ${rds_host}:${remote_port})"
  exit 0
fi

step "SSM 포트 포워딩 시작: 127.0.0.1:${local_port} -> ${rds_host}:${remote_port} (종료: Ctrl+C)"
echo "별도 터미널 접속 예시: mysql -h 127.0.0.1 -P ${local_port} -u vehicle_app -p --ssl-mode=REQUIRED vehicle"

exec aws ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${rds_host}\"],\"portNumber\":[\"${remote_port}\"],\"localPortNumber\":[\"${local_port}\"]}"
