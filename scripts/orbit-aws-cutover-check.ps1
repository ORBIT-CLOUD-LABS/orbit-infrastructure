# 크레딧 계정 전환 후 보안 설정 검증(cutover) 및 기존 계정 과금 리소스 정리 확인(cleanup) 스크립트 (docs/aws.md)
# 사용 (저장소 최상위의 PowerShell에서):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-aws-cutover-check.ps1 -Mode cutover
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-aws-cutover-check.ps1 -Mode cutover -Profile orbit-credit -FirmwareBucket orbit-firmware-origin-prod -VaultBucket orbit-vault-snapshot-prod -ExpectObjectLock
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-aws-cutover-check.ps1 -Mode cleanup -Profile orbit-old
# 한글 주석 때문에 BOM 있는 UTF-8로 저장해야 Windows PowerShell 5.1이 읽음
param(
    [ValidateSet('cutover', 'cleanup')]
    [string]$Mode = 'cutover',
    [string]$Profile = $env:AWS_PROFILE,
    [string]$Region = 'ap-northeast-2',
    [string]$FirmwareBucket = 'orbit-firmware-origin-backup',
    [string]$VaultBucket = 'orbit-vault-snapshot-backup',
    [string]$RdsId = 'orbit-vehicle-mysql',
    [switch]$ExpectObjectLock
)

$ErrorActionPreference = 'Stop'

function Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" }
function Die([string]$msg) { [Console]::Error.WriteLine("orbit-aws-cutover-check: FAIL — $msg"); exit 1 }

if (-not (Get-Command 'aws' -ErrorAction SilentlyContinue)) { Die 'aws CLI가 필요합니다.' }
if ($Profile) { $env:AWS_PROFILE = $Profile }
$env:AWS_DEFAULT_REGION = $Region

& aws sts get-caller-identity --query Arn --output text | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'AWS 자격증명 확인에 실패했습니다.' }

if ($Mode -eq 'cleanup') {
    Step "기존 계정 잔여 과금 리소스 점검 (리전: $Region)"
    $ec2Cnt = [int](& aws ec2 describe-instances --filters 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'length(Reservations[].Instances[])' --output text)
    $rdsCnt = [int](& aws rds describe-db-instances --query 'length(DBInstances[])' --output text)
    $vpnCnt = [int](& aws ec2 describe-vpn-connections --filters 'Name=state,Values=pending,available' --query 'length(VpnConnections[])' --output text)
    $vpceCnt = [int](& aws ec2 describe-vpc-endpoints --filters 'Name=vpc-endpoint-state,Values=pending,available' --query 'length(VpcEndpoints[])' --output text)
    Write-Host "EC2=$ec2Cnt RDS=$rdsCnt VPN=$vpnCnt VPCE=$vpceCnt"
    if ($ec2Cnt -ne 0 -or $rdsCnt -ne 0 -or $vpnCnt -ne 0 -or $vpceCnt -ne 0) {
        Die '시간당 과금 리소스가 남아 있습니다. terraform destroy 수행 여부를 확인하세요.'
    }
    Write-Host 'PASS: 시간당 과금 리소스 0개 확인'
    exit 0
}

Step "1. S3 버킷 퍼블릭 액세스 차단·암호화·버전 관리 점검 ($FirmwareBucket, $VaultBucket)"
foreach ($b in @($FirmwareBucket, $VaultBucket)) {
    $pab = (& aws s3api get-public-access-block --bucket $b --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output json | ConvertFrom-Json)
    if (($pab | Where-Object { $_ -eq $true }).Count -ne 4) { Die "$b 퍼블릭 액세스 차단 4개 항목이 모두 True가 아닙니다." }
    $ver = (& aws s3api get-bucket-versioning --bucket $b --query 'Status' --output text)
    if ($ver -ne 'Enabled') { Die "$b 버전 관리가 Enabled가 아닙니다 (현재: $ver)." }
    $sse = (& aws s3api get-bucket-encryption --bucket $b --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)
    if ($sse -ne 'AES256') { Die "$b 기본 암호화가 AES256이 아닙니다 (현재: $sse)." }
}
Write-Host 'PASS: 두 버킷 퍼블릭 차단(4/4), 버전 관리(Enabled), 암호화(AES256) 확인'

if ($ExpectObjectLock) {
    Step "2. Vault 스냅샷 버킷 Object Lock(GOVERNANCE 30일) 점검 ($VaultBucket)"
    $lock = (& aws s3api get-object-lock-configuration --bucket $VaultBucket --query 'ObjectLockConfiguration.{Enabled:ObjectLockEnabled,Mode:Rule.DefaultRetention.Mode,Days:Rule.DefaultRetention.Days}' --output json | ConvertFrom-Json)
    if ($lock.Enabled -ne 'Enabled' -or $lock.Mode -ne 'GOVERNANCE' -or $lock.Days -ne 30) {
        Die "Object Lock 설정 불일치: $($lock | ConvertTo-Json -Compress)"
    }
    Write-Host 'PASS: Object Lock Enabled (GOVERNANCE, 30일) 확인'
}

Step "3. 사설 RDS 노출 차단 및 암호화 점검 ($RdsId)"
$rds = (& aws rds describe-db-instances --db-instance-identifier $RdsId --query 'DBInstances[0].{Public:PubliclyAccessible,Encrypted:StorageEncrypted}' --output json | ConvertFrom-Json)
if ($rds.Public -ne $false -or $rds.Encrypted -ne $true) {
    Die "RDS 보안 설정 불일치: $($rds | ConvertTo-Json -Compress)"
}
Write-Host 'PASS: RDS PubliclyAccessible=False, StorageEncrypted=True 확인'

Step '4. 공인 경로 S3 펌웨어 읽기 차단(403) 점검'
$httpCode = (& curl.exe -s -o NUL -w '%{http_code}' "https://${FirmwareBucket}.s3.${Region}.amazonaws.com/firmware/__cutover_probe__.bin")
if ($httpCode -ne '403') { Die "공인 경로 S3 요청이 403으로 차단되지 않았습니다 (현재: $httpCode)." }
Write-Host 'PASS: 공인 경로 S3 읽기 403 차단 확인'

Write-Host ''
Write-Host '모든 전환 보안 점검 통과'
