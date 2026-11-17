# Vault SSH 인증서 자동 갱신 설정. 팀원 Windows PC에서 한 번 실행 (macOS는 orbit-ssh-setup.sh, docs/vault.md)
# 사용 (저장소 최상위의 PowerShell에서):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-ssh-setup.ps1            처음 설정, 다시 실행해도 됨
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\orbit-ssh-setup.ps1 -ResetPat  저장한 GitHub PAT만 새 값으로 바꿈
# 하는 일
#   1. %USERPROFILE%\.orbit 폴더를 나만 읽을 수 있게 만듦 (토큰과 PAT를 둠)
#   2. Vault CA 인증서 .orbit\vault-ca.crt (없으면 저장소의 scripts\vault-ca.crt, 그것도 없으면 astra에서 scp)
#   3. SSH 키 %USERPROFILE%\.ssh\id_ed25519 (없으면 만듦)
#   4. GitHub PAT를 .orbit\github-pat.dpapi에 저장 (Windows DPAPI로 암호화. 이 PC의 이 계정만 풀 수 있음)
#   5. Vault에 로그인해 내 개인 계정명을 확인하고 .orbit\user에 저장 (정책 ssh-personal-<계정명>)
#      찾지 못하면 여기서 멈춤. 설치된 갱신 스크립트와 ~/.ssh/config는 바꾸지 않음
#   6. .orbit\refresh-cert.ps1 설치 (이 저장소의 orbit-ssh-refresh.ps1)
#   7. ~/.ssh/config에 Match 블록 추가. orbit 노드에 ssh할 때마다 인증서를 확인하고 필요하면 새로 받음
# Windows 10/11 기본 OpenSSH 클라이언트와 Windows PowerShell 5.1(또는 PowerShell 7)에서 동작. 다른 설치는 필요 없음
# 한글 주석 때문에 BOM 있는 UTF-8로 저장해야 5.1이 읽음
param([switch]$ResetPat)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Here = $PSScriptRoot
$OrbitDir = Join-Path $env:USERPROFILE '.orbit'
$SshDir = Join-Path $env:USERPROFILE '.ssh'
$Key = Join-Path $SshDir 'id_ed25519'
$Astra = '10.0.0.201'
# 자동 갱신을 켤 주소와 이름. 내부망(노드, VM), 와이파이, 노드 이름(*.orbit-labs.space, Cloudflare DNS)
# 노드 Tailscale 주소(예비 경로)는 넣지 않음. 팀원은 Tailscale 정책으로 막혀 있고, 공개 저장소에 두지 않기로 한 값
$MatchHosts = '10.0.0.20?,192.168.200.20?,*.orbit-labs.space'
$PatFile = Join-Path $OrbitDir 'github-pat.dpapi'
$SshConfig = Join-Path $SshDir 'config'
$Begin = '# >>> orbit-vault-ssh (orbit-infrastructure/scripts/orbit-ssh-setup.ps1가 관리) >>>'
$End = '# <<< orbit-vault-ssh <<<'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" }
function Die([string]$msg) { [Console]::Error.WriteLine("orbit-ssh-setup: $msg"); exit 1 }

if ($env:OS -ne 'Windows_NT') { Die 'Windows 전용. macOS는 scripts/orbit-ssh-setup.sh' }
if ($PSVersionTable.PSVersion.Major -lt 5) { Die 'PowerShell 5.1 이상이 필요함' }
foreach ($c in 'ssh', 'ssh-keygen', 'scp', 'icacls') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        Die "$c 없음. 설정 → 시스템 → 선택적 기능에서 'OpenSSH 클라이언트'를 추가한 뒤 새 PowerShell 창에서 다시 실행"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $Here 'orbit-ssh-refresh.ps1'))) { Die "같은 폴더에 orbit-ssh-refresh.ps1이 없음 ($Here)" }

# 현재 사용자 SID. 이름 대신 써서 한글이나 공백이 든 계정 이름에서도 권한 설정이 같음
$Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

Step "폴더 ($OrbitDir, 나만 읽음)"
New-Item -ItemType Directory -Force -Path $OrbitDir, $SshDir | Out-Null
# 상속을 끊고 나에게만 전체 권한. 안에 만드는 파일(토큰, PAT)도 이 권한을 따름
& icacls $OrbitDir /inheritance:r /grant:r "*${Sid}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { Die "$OrbitDir 권한 설정 실패" }
Write-Host '설정함'

Step "Vault CA 인증서 ($OrbitDir\vault-ca.crt)"
$caPath = Join-Path $OrbitDir 'vault-ca.crt'
if (Test-Path -LiteralPath $caPath) {
    Write-Host '이미 있음'
} else {
    $tmp = "$caPath.tmp"
    # 공개 인증서라 저장소에 둘 수 있음. 없으면 공용 orbit 계정으로 scp (공용 접속 회수 전까지만 됨)
    $repoCa = Join-Path $Here 'vault-ca.crt'
    if (Test-Path -LiteralPath $repoCa) {
        Copy-Item -LiteralPath $repoCa -Destination $tmp -Force
    } else {
        & scp -q "orbit@${Astra}:/opt/vault/tls/vault-ca.crt" $tmp
        if ($LASTEXITCODE -ne 0) { Die "astra에서 받지 못함. 다른 팀원에게 vault-ca.crt를 받아 $caPath 에 둔 뒤 다시 실행" }
    }
    try { New-Object Security.Cryptography.X509Certificates.X509Certificate2($tmp) | Out-Null }
    catch { Remove-Item -LiteralPath $tmp -Force; Die '받은 파일이 인증서가 아님' }
    Move-Item -LiteralPath $tmp -Destination $caPath -Force
    Write-Host '받음'
}

Step "SSH 키 ($Key)"
if (-not (Test-Path -LiteralPath $Key)) {
    & ssh-keygen -t ed25519 -f $Key
    if ($LASTEXITCODE -ne 0) { Die 'SSH 키를 만들지 못함' }
} elseif (-not (Test-Path -LiteralPath "$Key.pub")) {
    $pub = & ssh-keygen -y -f $Key
    if ($LASTEXITCODE -ne 0) { Die '개인키에서 공개키를 만들지 못함' }
    [IO.File]::WriteAllText("$Key.pub", (($pub -join '').Trim() + "`n"), $Utf8NoBom)
    Write-Host '공개키를 개인키에서 다시 만듦'
} else {
    Write-Host '이미 있음'
}

Step "GitHub PAT ($PatFile)"
if (-not $ResetPat -and (Test-Path -LiteralPath $PatFile)) {
    Write-Host '이미 있음 (바꾸려면 -ResetPat)'
} else {
    Write-Host 'GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)에서 만든 PAT'
    Write-Host 'scope는 read:org 하나만. 입력한 값은 화면에 보이지 않음 (두 번 입력)'
    $a = Read-Host -AsSecureString 'PAT'
    $b = Read-Host -AsSecureString 'PAT 한 번 더'
    $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)
    $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)
    try {
        $same = ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pa) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pb))
        $empty = ($a.Length -eq 0)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb)
    }
    if ($empty) { Die 'PAT가 비어 있음' }
    if (-not $same) { Die '두 번 입력한 값이 다름. 다시 실행' }
    # ConvertFrom-SecureString은 키를 주지 않으면 DPAPI(현재 사용자)로 암호화함
    [IO.File]::WriteAllText($PatFile, ($a | ConvertFrom-SecureString) + "`n", $Utf8NoBom)
    Remove-Item -LiteralPath (Join-Path $OrbitDir 'vault-token') -Force -ErrorAction SilentlyContinue   # 예전 PAT로 받은 토큰은 버림
    Write-Host '저장함'
}

# 설치된 갱신 스크립트는 아직 바꾸지 않음. 여기서 멈춰도 예전 설정이 그대로 동작하게
Step '개인 계정 확인 (Vault GitHub 로그인)'
$whoami = & (Join-Path $Here 'orbit-ssh-refresh.ps1') -WhoAmI
if ($LASTEXITCODE -ne 0 -or -not $whoami) {
    Die 'Vault에서 개인 SSH 권한을 찾지 못함 (위 orbit-ssh: 메시지 확인). 갱신 스크립트와 ~/.ssh/config는 바꾸지 않았음'
}
$sshUser = ([string]($whoami | Select-Object -Last 1)).Trim()
[IO.File]::WriteAllText((Join-Path $OrbitDir 'user'), "$sshUser`n", $Utf8NoBom)
Write-Host "$sshUser ($OrbitDir\user)"

Step "갱신 스크립트 설치 ($OrbitDir\refresh-cert.ps1)"
Copy-Item -LiteralPath (Join-Path $Here 'orbit-ssh-refresh.ps1') -Destination (Join-Path $OrbitDir 'refresh-cert.ps1') -Force
Write-Host '설치함'

Step "~/.ssh/config ($SshConfig)"
# Windows OpenSSH는 Match exec를 cmd.exe로 실행함. 경로에 공백이나 한글이 있어도 깨지지 않게
# 실행할 명령을 -EncodedCommand(영문·숫자만)로 넘기고, 경로는 PowerShell 안에서 %USERPROFILE%로 찾음
$inner = '& (Join-Path $env:USERPROFILE ''.orbit\refresh-cert.ps1''); exit $LASTEXITCODE'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
$execCmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"

$old = @()
if (Test-Path -LiteralPath $SshConfig) {
    Copy-Item -LiteralPath $SshConfig -Destination "$SshConfig.orbit-bak" -Force
    $old = [IO.File]::ReadAllLines($SshConfig)   # BOM이 있으면 여기서 빠지고, 아래에서 BOM 없이 다시 씀
}
# 예전 블록을 빼고 맨 뒤에 다시 붙임 (사용자가 앞에 둔 Host 설정이 먼저 적용됨)
$kept = New-Object Collections.Generic.List[string]
$skip = $false
foreach ($line in $old) {
    if ($line -eq $Begin) { $skip = $true; continue }
    if ($line -eq $End) { $skip = $false; continue }
    if (-not $skip) { $kept.Add($line) }
}
while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') { $kept.RemoveAt($kept.Count - 1) }
$block = @(
    $Begin,
    '# orbit 노드(내부망, 와이파이, 이름)에 ssh하기 직전에 Vault SSH 인증서를 확인하고 필요하면 새로 받음',
    '# 실행하는 것: powershell로 %USERPROFILE%\.orbit\refresh-cert.ps1 (긴 영문은 그 명령을 인코딩한 것)',
    "# 개인 계정($sshUser)으로 접속. 인증서는 이 계정에만 유효함",
    '# 개인 계정이 아직 없는 호스트나 비상시에는 ssh orbit@<호스트> (authorized_keys의 기존 키)',
    "Match host $MatchHosts exec `"$execCmd`"",
    "  User $sshUser",
    '  IdentityFile ~/.ssh/id_ed25519',
    '  CertificateFile ~/.ssh/id_ed25519-cert.pub',
    $End
)
$lines = @($kept) + $(if ($kept.Count -gt 0) { @('') } else { @() }) + $block
# BOM 없는 UTF-8, LF. BOM이 있으면 Windows OpenSSH가 첫 줄을 읽지 못함
[IO.File]::WriteAllText($SshConfig, (($lines -join "`n") + "`n"), $Utf8NoBom)
Write-Host "Match 블록 추가 (이전 파일: $SshConfig.orbit-bak)"

Step '인증서 받기'
& (Join-Path $OrbitDir 'refresh-cert.ps1')
# 파일이 있는지만 보면, 갱신에 실패하고 예전(만료된) 인증서가 남은 경우도 완료로 보임
# 유효기간이 남았고 지금 공개키로 받았고 principal이 내 계정명인지까지 확인
$cert = "$Key-cert.pub"
$certLines = @()
if (Test-Path -LiteralPath $cert) { $certLines = @(& ssh-keygen -L -f $cert 2>$null) }
$until = $null; $certFp = $null; $principals = @(); $inP = $false
foreach ($line in $certLines) {
    if ($line -match '^\s*Valid: from \S+ to (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\s*$') {
        $until = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    } elseif ($line -match '^\s*Public key: \S+ (SHA256:\S+)') { $certFp = $Matches[1] }
    elseif ($line -match '^\s*Principals:') { $inP = $true }
    elseif ($line -match '^\s*Critical Options:') { $inP = $false }
    elseif ($inP -and $line.Trim()) { $principals += $line.Trim() }
}
$keyFp = ((& ssh-keygen -lf "$Key.pub" 2>$null | Select-Object -First 1) -split '\s+')[1]
if ($until -and $until -gt [datetime]::Now -and $certFp -and $certFp -eq $keyFp -and
    $principals.Count -eq 1 -and $principals[0] -ceq $sshUser) {
    $certLines | Where-Object { $_ -match '^\s+(Key ID|Valid):' } | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "완료. 이제 ssh 10.0.0.202 처럼 접속하면 개인 계정($sshUser)으로 들어감 (만료 10분 전부터 접속할 때 자동으로 새로 받음)"
    Write-Host "인증서로 들어갔는지 확인: ssh -v 10.0.0.202 exit 2>&1 | Select-String 'Server accepts key'  → ED25519-CERT 이면 정상"
    Write-Host '개인 계정이 아직 만들어지지 않은 호스트는 거부됨. 그때는 ssh orbit@<호스트> (기존 키)'
    exit 0
}
if ($certLines.Count -gt 0) {
    Write-Host "남아 있는 인증서는 쓸 수 없음 (만료: $(if ($until) { $until } else { '알 수 없음' }), 다른 키나 다른 계정(orbit)으로 받은 것일 수도 있음)"
}
Write-Host ''
Write-Host '설정은 끝났지만 유효한 인증서를 받지 못함. 위 orbit-ssh: 메시지를 확인'
Write-Host 'Vault가 sealed이거나 Tailscale이 꺼져 있으면 다음 접속 때 다시 시도함'
Write-Host '개인 계정은 인증서로만 로그인되므로 그동안은 거부됨. 급하면 ssh orbit@<호스트> (기존 키)'
exit 1
