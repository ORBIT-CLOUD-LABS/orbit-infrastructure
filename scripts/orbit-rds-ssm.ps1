# 관리자 Windows PC에서 admin-jump EC2를 거쳐 사설 RDS(3306)로 SSM 포트 포워딩을 여는 스크립트 (macOS/Linux는 orbit-rds-ssm.sh, docs/aws.md)
# 사용 (저장소 최상위의 PowerShell에서):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-rds-ssm.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-rds-ssm.ps1 -LocalPort 23306 -Profile prod
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-rds-ssm.ps1 -CheckOnly
# 한글 주석 때문에 BOM 있는 UTF-8로 저장해야 Windows PowerShell 5.1이 읽음
param(
    [int]$LocalPort = 13306,
    [int]$RemotePort = 3306,
    [string]$InstanceId = $env:ORBIT_JUMP_INSTANCE_ID,
    [string]$RdsHost = $env:ORBIT_RDS_HOST,
    [string]$Profile = $env:AWS_PROFILE,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$RepoRoot = Split-Path -Parent $Here
$TfDir = Join-Path $RepoRoot 'aws\terraform'

function Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" }
function Die([string]$msg) { [Console]::Error.WriteLine("orbit-rds-ssm: $msg"); exit 1 }

foreach ($c in 'aws', 'session-manager-plugin') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        Die "$c 명령을 찾을 수 없습니다. AWS CLI 및 Session Manager Plugin 설치 후 새 PowerShell 창에서 다시 실행하세요."
    }
}

if ($Profile) {
    $env:AWS_PROFILE = $Profile
}

if ((-not $InstanceId -or -not $RdsHost) -and (Get-Command 'terraform' -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $TfDir 'terraform.tfstate'))) {
    if (-not $InstanceId) {
        $InstanceId = (& terraform "-chdir=$TfDir" output -raw admin_jump_instance_id 2>$null)
    }
    if (-not $RdsHost) {
        $rdsEndpoint = (& terraform "-chdir=$TfDir" output -raw rds_endpoint 2>$null)
        if ($rdsEndpoint) {
            $RdsHost = ($rdsEndpoint -split ':')[0]
        }
    }
}

if (-not $InstanceId) { Die 'admin-jump 인스턴스 ID를 알 수 없습니다. -InstanceId 또는 ORBIT_JUMP_INSTANCE_ID로 지정하세요.' }
if (-not $RdsHost) { Die 'RDS 호스트 주소를 알 수 없습니다. -RdsHost 또는 ORBIT_RDS_HOST로 지정하세요.' }

Step "AWS 인증 및 admin-jump SSM 상태 확인 ($InstanceId)"
& aws sts get-caller-identity --query Arn --output text | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'AWS 자격증명이 유효하지 않습니다. aws configure 또는 -Profile 설정을 확인하세요.' }

$pingStatus = (& aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$InstanceId" --query "InstanceInformationList[0].PingStatus" --output text 2>$null)
if ($pingStatus -ne 'Online') {
    Die "admin-jump($InstanceId) SSM 상태가 Online이 아닙니다 (현재: $pingStatus). SSM 인터페이스 엔드포인트 상태를 확인하세요."
}
Write-Host 'SSM PingStatus: Online'

if ($CheckOnly) {
    Write-Host "사전 점검 통과 (127.0.0.1:$LocalPort -> ${RdsHost}:$RemotePort)"
    exit 0
}

Step "SSM 포트 포워딩 시작: 127.0.0.1:$LocalPort -> ${RdsHost}:$RemotePort (종료: Ctrl+C)"
Write-Host "별도 터미널 접속 예시: mysql -h 127.0.0.1 -P $LocalPort -u vehicle_app -p --ssl-mode=REQUIRED vehicle"

$paramsJson = @{
    host            = @($RdsHost)
    portNumber      = @("$RemotePort")
    localPortNumber = @("$LocalPort")
} | ConvertTo-Json -Compress

& aws ssm start-session --target $InstanceId --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters $paramsJson
exit $LASTEXITCODE
