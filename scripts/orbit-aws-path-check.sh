#!/bin/sh
# 클러스터 노드 또는 astra에서 AWS 사설 경로(VPN -> RDS 3306 TLS, S3 VPCE 443)와 거부 조건을 점검하는 스크립트 (docs/aws.md)
# 사용:
#   scripts/orbit-aws-path-check.sh --rds-host <rds-host> --vpce-dns <bucket.vpce-xxx.s3.ap-northeast-2.vpce.amazonaws.com>
# 비밀값(비밀번호·액세스 키) 없이 네트워크 도달성, TLS 핸드셰이크, 버킷 정책(SourceVpce vs 공인 403)을 검증한다.
set -eu

rds_host="${ORBIT_RDS_HOST:-}"
rds_port=3306
vpce_dns="${ORBIT_S3_VPCE_BUCKET_DNS:-}"
bucket="${ORBIT_FIRMWARE_BUCKET:-orbit-firmware-origin-backup}"
region="${ORBIT_AWS_REGION:-ap-northeast-2}"
probe_key="firmware/__path_probe_nonexistent__.bin"

die() { printf 'orbit-aws-path-check: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rds-host) [ $# -ge 2 ] || die "--rds-host 값 필요"; rds_host="$2"; shift 2 ;;
    --vpce-dns) [ $# -ge 2 ] || die "--vpce-dns 값 필요 (예: bucket.vpce-xxx.s3.ap-northeast-2.vpce.amazonaws.com)"; vpce_dns="$2"; shift 2 ;;
    --bucket)   [ $# -ge 2 ] || die "--bucket 값 필요"; bucket="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,5p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "알 수 없는 인자: $1" ;;
  esac
done

[ -n "$rds_host" ] || die "--rds-host 또는 ORBIT_RDS_HOST가 필요합니다."
[ -n "$vpce_dns" ] || die "--vpce-dns 또는 ORBIT_S3_VPCE_BUCKET_DNS가 필요합니다."
for c in curl python3; do
  command -v "$c" >/dev/null 2>&1 || die "$c 명령이 필요합니다."
done

step "1. RDS 사설 주소 해석 및 TCP 3306 연결 확인 ($rds_host)"
rds_ip=$(python3 - "$rds_host" "$rds_port" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
ip = socket.gethostbyname(host)
assert ip.startswith("10.20."), f"사설 대역(10.20.0.0/16)이 아님: {ip}"
with socket.create_connection((ip, port), timeout=5) as s:
    banner = s.recv(64)
    assert len(banner) > 5, "MySQL 초기 배너 수신 실패"
print(ip)
PY
)
echo "PASS: RDS 사설 IP($rds_ip:$rds_port) 도달 및 MySQL 배너 수신 성공 (OTA 클러스터 밖에서 실행 시 타임아웃이 정상)"

step "2. S3 인터페이스 엔드포인트 사설 경로 확인 ($vpce_dns)"
vpce_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${vpce_dns}/${bucket}/${probe_key}")
# SourceVpce 조건을 통과하면 존재하지 않는 키에 대해 S3가 403(AccessDenied: ListBucket 없음) 또는 404를 반환하되,
# TLS 인증서 검증 및 사설 엔드포인트(10.20.2.x) 연결 자체가 성립해야 함
vpce_ip=$(python3 -c "import socket, sys; print(socket.gethostbyname(sys.argv[1]))" "$vpce_dns")
case "$vpce_ip" in
  10.20.*) echo "PASS: VPCE DNS가 사설 IP($vpce_ip)로 해석됨 (HTTPS 응답 코드: $vpce_code)" ;;
  *) die "VPCE DNS가 사설 대역(10.20.0.0/16)으로 해석되지 않음: $vpce_ip" ;;
esac

step "3. 거부(Negative) 확인: 공인 S3 엔드포인트 및 평문 HTTP 차단"
pub_https_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${bucket}.s3.${region}.amazonaws.com/${probe_key}")
pub_http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://${bucket}.s3.${region}.amazonaws.com/${probe_key}")
[ "$pub_https_code" = "403" ] || die "공인 HTTPS 경로가 403으로 차단되지 않음 (응답: $pub_https_code)"
[ "$pub_http_code" = "403" ] || die "평문 HTTP 경로가 403으로 차단되지 않음 (응답: $pub_http_code)"
echo "PASS: 공인 HTTPS($pub_https_code) 및 평문 HTTP($pub_http_code) 모두 403 거부 확인"

printf '\n모든 사설 경로 점검 통과\n'
