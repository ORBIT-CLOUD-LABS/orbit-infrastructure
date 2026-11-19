# Vault SSH 인증서를 필요할 때만 새로 받음 (Windows. macOS는 orbit-ssh-refresh.sh, docs/vault.md)
# orbit-ssh-setup.ps1이 %USERPROFILE%\.orbit\refresh-cert.ps1로 복사하고, ~/.ssh/config의 Match exec가 ssh마다 실행함
# 사용: refresh-cert.ps1           인증서 확인·갱신 (ssh가 실행)
#       refresh-cert.ps1 -WhoAmI   Vault 로그인 후 내 개인 계정명을 stdout에 출력 (setup이 실행)
# - 개인 계정명은 %USERPROFILE%\.orbit\user (setup이 Vault 정책 ssh-personal-<계정명>에서 알아내 저장)
# - 인증서가 10분 넘게 남았고, 지금 공개키로 받았고, principal이 내 계정명뿐이면 아무것도 안 함
# - Vault 토큰(.orbit\vault-token)이 살아 있으면 그걸로, 아니면 GitHub PAT(.orbit\github-pat.dpapi, Windows DPAPI로 암호화)로 로그인
# - 갱신 모드는 항상 0으로 끝남. 실패하면 경고만 하고 ssh는 남은 인증서로 접속을 시도함
#   -WhoAmI는 실패하면 1 (setup이 갱신 스크립트 설치와 ~/.ssh/config 변경 전에 멈춤)
# 출력은 모두 stderr (ssh의 stdout은 scp, rsync, git이 데이터 통로로 씀). -WhoAmI 결과만 stdout
# 비밀값(PAT, 토큰)은 명령 인자로 넘기지 않음. 메모리와 사용자 전용 폴더의 파일로만 다룸
# Windows PowerShell 5.1과 PowerShell 7에서 동작. 한글 주석 때문에 BOM 있는 UTF-8로 저장해야 5.1이 읽음
param([switch]$WhoAmI)

# Stop으로 두면 Windows PowerShell 5.1에서 ssh-keygen이 stderr에 한 줄만 써도 예외가 되어 ssh가 멈춤. 필요한 곳에만 -ErrorAction Stop
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$OrbitDir = if ($env:ORBIT_DIR) { $env:ORBIT_DIR } else { Join-Path $env:USERPROFILE '.orbit' }
$VaultAddr = if ($env:ORBIT_VAULT_ADDR) { $env:ORBIT_VAULT_ADDR } else { 'https://vault.orbit-labs.space:8200' }   # vault VM (10.10.0.1)
$CaCert = if ($env:ORBIT_VAULT_CACERT) { $env:ORBIT_VAULT_CACERT } else { Join-Path $OrbitDir 'vault-ca.crt' }
$Key = if ($env:ORBIT_SSH_KEY) { $env:ORBIT_SSH_KEY } else { Join-Path $env:USERPROFILE '.ssh\id_ed25519' }
$SignPrefix = 'ssh-client-signer/sign/personal-'   # Vault 역할 personal-<계정명> (hvault_ssh_personal_role_prefix)
$PolicyPrefix = 'ssh-personal-'                    # Vault 정책 ssh-personal-<계정명> (hvault_ssh_personal_policy_prefix)
$UserFile = Join-Path $OrbitDir 'user'
$PatFile = Join-Path $OrbitDir 'github-pat.dpapi'
$TokenFile = Join-Path $OrbitDir 'vault-token'
$Cert = "$Key-cert.pub"
$Lock = Join-Path $OrbitDir '.refresh.lock'
$Down = Join-Path $OrbitDir '.vault-unreachable'   # 연결 실패 표시. 1분 동안은 다시 시도하지 않음
$Margin = 600   # 남은 시간이 이보다 짧으면 새로 받음 (초)
$NoCert = if ($WhoAmI) { '' } else { '남은 인증서로 접속을 시도함 (유효한 인증서가 없으면 개인 계정은 거부됨. 급하면 ssh orbit@<호스트>)' }

function Warn([string]$msg) { [Console]::Error.WriteLine("orbit-ssh: $msg") }

# 갱신 모드는 ssh를 막지 않게 0, -WhoAmI는 setup이 멈추게 1
function Bail { if ($WhoAmI) { exit 1 } else { exit 0 } }

# Linux 계정명 규칙 (ansible personal_accounts와 같음)
function Test-UserName([string]$name) { return ($name -cmatch '^[a-z][a-z0-9_]{0,31}$') }

# ssh-keygen -L 결과에서 만료 시각, 공개키 지문, principal 목록
function Read-CertInfo([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lines = & ssh-keygen -L -f $path 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $lines) { return $null }
    $info = @{ Until = $null; Fp = $null; Principals = @() }
    $inPrincipals = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*Valid: from \S+ to (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\s*$') {
            $info.Until = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        } elseif ($line -match '^\s*Public key: \S+ (SHA256:\S+)') {
            $info.Fp = $Matches[1]
        } elseif ($line -match '^\s*Principals:') {
            $inPrincipals = $true
        } elseif ($line -match '^\s*Critical Options:') {
            $inPrincipals = $false
        } elseif ($inPrincipals -and $line.Trim()) {
            $info.Principals += $line.Trim()
        }
    }
    return $info
}

function Get-KeyFingerprint {
    $out = & ssh-keygen -lf "$Key.pub" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return (($out | Select-Object -First 1) -split '\s+')[1]
}

# 인증서가 있고, Margin보다 오래 남았고, 지금 공개키로 받았고, principal이 내 계정명 하나뿐인지
# 공용 orbit 인증서가 남아 있으면 여기서 걸러져 개인 인증서를 새로 받음
function Test-CertOk {
    $info = Read-CertInfo $Cert
    if (-not $info -or -not $info.Until) { return $false }
    if (($info.Until - [datetime]::Now).TotalSeconds -le $Margin) { return $false }
    $want = Get-KeyFingerprint
    if (-not $want -or $want -ne $info.Fp) { return $false }
    return ($info.Principals.Count -eq 1 -and $info.Principals[0] -ceq $script:SshUser)
}

$script:SshUser = ''
if (-not $WhoAmI) {
    $script:SshUser = $env:ORBIT_SSH_USER
    if (-not $script:SshUser -and (Test-Path -LiteralPath $UserFile)) {
        $script:SshUser = (Get-Content -LiteralPath $UserFile -TotalCount 1).Trim()
    }
    if (-not (Test-UserName $script:SshUser)) {
        Warn "개인 계정 설정이 없거나 잘못됨 ($UserFile). scripts\orbit-ssh-setup.ps1을 다시 실행. $NoCert"
        exit 0
    }
    if (Test-CertOk) { exit 0 }
}

foreach ($c in 'ssh-keygen') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Warn "$c 없음. 인증서를 받지 못함. $NoCert"; Bail }
}
if (-not (Test-Path -LiteralPath "$Key.pub")) { Warn "$Key.pub 없음. scripts\orbit-ssh-setup.ps1 실행"; Bail }
if (-not (Test-Path -LiteralPath $CaCert)) { Warn "$CaCert 없음. scripts\orbit-ssh-setup.ps1 실행"; Bail }
New-Item -ItemType Directory -Force -Path $OrbitDir | Out-Null

# 와이파이처럼 8200이 막힌(DROP) 곳에서 ssh할 때마다 기다리지 않게. setup(-WhoAmI)은 매번 시도
if (-not $WhoAmI -and (Test-Path -LiteralPath $Down) -and
    ((Get-Item -LiteralPath $Down).LastWriteTime -gt [datetime]::Now.AddMinutes(-1))) {
    Warn "Vault에 연결되지 않아 잠시 갱신을 건너뜀. $NoCert"
    exit 0
}

# ssh를 여러 개 동시에 열어도 로그인은 한 번만 (먼저 잡은 쪽이 받고 나머지는 기다렸다가 그걸 씀)
$lockHeld = $false
for ($i = 0; -not $lockHeld; $i++) {
    try {
        New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
        $lockHeld = $true
    } catch {
        if ((Test-Path -LiteralPath $Lock) -and (Get-Item -LiteralPath $Lock).CreationTime -lt [datetime]::Now.AddMinutes(-1)) {
            Remove-Item -LiteralPath $Lock -Force -ErrorAction SilentlyContinue   # 1분 넘은 잠금은 죽은 것으로 봄
            continue
        }
        if ($i -ge 20) { Warn "다른 갱신이 끝나지 않음. $NoCert"; Bail }
        Start-Sleep -Seconds 1
    }
}

try {
    if (-not $WhoAmI -and (Test-CertOk)) { exit 0 }   # 기다리는 동안 다른 ssh가 받았을 수 있음

    # Vault 인증서는 내부 CA가 서명함. 그 CA만 믿고 확인하는 HTTP 클라이언트 (Windows 신뢰 저장소에는 넣지 않음)
    # PowerShell의 Invoke-RestMethod에는 CA를 지정하는 옵션이 없어서 C#으로 만듦. 5.1(.NET Framework)과 7(.NET)에서 같은 코드
    if (-not ('OrbitVault' -as [type])) {
        Add-Type -ReferencedAssemblies 'System.Net.Http' -TypeDefinition @'
using System;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;

public static class OrbitVault {
    static HttpClient client;

    public static void Init(string caPath) {
        X509Certificate2 ca = new X509Certificate2(caPath);
        HttpClientHandler h = new HttpClientHandler();
        h.SslProtocols = (System.Security.Authentication.SslProtocols)3072;   // TLS 1.2 (Vault 최소값)
        h.ServerCertificateCustomValidationCallback = (msg, cert, chain, errors) => {
            if (cert == null) return false;
            // 이름(주소)이 인증서와 맞지 않으면 거부. 신뢰 저장소에 없는 CA라서 생기는 체인 오류만 아래에서 다시 판단
            if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0) return false;
            if ((errors & SslPolicyErrors.RemoteCertificateNotAvailable) != 0) return false;
            using (X509Chain c = new X509Chain()) {
                c.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                c.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                c.ChainPolicy.ExtraStore.Add(ca);
                if (!c.Build(new X509Certificate2(cert))) return false;
                X509ChainElement root = c.ChainElements[c.ChainElements.Count - 1];
                if (!string.Equals(root.Certificate.Thumbprint, ca.Thumbprint, StringComparison.OrdinalIgnoreCase)) return false;
                foreach (X509ChainStatus s in c.ChainStatus) {
                    if (s.Status != X509ChainStatusFlags.NoError && s.Status != X509ChainStatusFlags.UntrustedRoot) return false;
                }
                return true;
            }
        };
        client = new HttpClient(h);
        client.Timeout = TimeSpan.FromSeconds(5);
    }

    // 상태 코드를 돌려줌. 연결 실패는 0이고 error에 이유
    public static int Send(string method, string url, string token, string body, out string response, out string error) {
        response = ""; error = "";
        try {
            HttpRequestMessage req = new HttpRequestMessage(new HttpMethod(method), url);
            if (!string.IsNullOrEmpty(token)) req.Headers.Add("X-Vault-Token", token);
            // PowerShell은 $null을 [string] 인자로 넘기면 빈 문자열로 바꿈. 빈 본문을 붙이면 GET이 "content-body를 보낼 수 없음"으로 실패함
            if (!string.IsNullOrEmpty(body)) req.Content = new StringContent(body, Encoding.UTF8, "application/json");
            HttpResponseMessage res = client.SendAsync(req).GetAwaiter().GetResult();
            response = res.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            return (int)res.StatusCode;
        } catch (Exception e) {
            Exception inner = e;
            while (inner.InnerException != null) inner = inner.InnerException;
            error = inner.Message;
            return 0;
        }
    }
}
'@
    }
    [OrbitVault]::Init((Resolve-Path -LiteralPath $CaCert).ProviderPath)

    $script:Resp = $null
    $script:NetErr = ''
    # 상태 코드를 돌려줌. 본문은 $script:Resp(JSON을 푼 객체)
    function Invoke-Vault([string]$method, [string]$path, [string]$token, $bodyObj) {
        $body = if ($null -ne $bodyObj) { $bodyObj | ConvertTo-Json -Compress } else { $null }
        $text = ''; $err = ''
        $code = [OrbitVault]::Send($method, "$VaultAddr/v1/$path", $token, $body, [ref]$text, [ref]$err)
        $script:NetErr = $err
        $script:Resp = $null
        if ($text) { try { $script:Resp = $text | ConvertFrom-Json } catch { } }
        return $code
    }

    function Get-VaultErrors {
        if ($script:Resp -and $script:Resp.errors) { return ($script:Resp.errors -join ', ') }
        return ''
    }

    function Fail-Network {
        Warn "Vault($VaultAddr)에 연결하지 못함: $($script:NetErr). Tailscale 연결을 확인. $NoCert"
        New-Item -ItemType File -Force -Path $Down | Out-Null
        Bail
    }

    function Get-Pat {
        if ($env:ORBIT_GITHUB_PAT) { return $env:ORBIT_GITHUB_PAT }
        if (-not (Test-Path -LiteralPath $PatFile)) { return $null }
        # DPAPI: 이 Windows 사용자만 풀 수 있음. 다른 PC나 다른 계정으로 복사하면 풀리지 않음
        $sec = (Get-Content -LiteralPath $PatFile -TotalCount 1) | ConvertTo-SecureString -ErrorAction Stop
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    $script:Tok = $null
    $script:Fresh = $false

    function Invoke-Login {
        $pat = $null
        try { $pat = Get-Pat } catch { $pat = $null }
        if (-not $pat) { Warn "GitHub PAT를 찾지 못함 ($PatFile). scripts\orbit-ssh-setup.ps1 실행"; return $false }
        $code = Invoke-Vault 'POST' 'auth/github/login' $null @{ token = $pat }
        $pat = $null
        switch ($code) {
            200 {
                $script:Tok = $script:Resp.auth.client_token
                $script:Resp = $null
                if (-not $script:Tok) { Warn 'Vault 로그인 응답에 토큰이 없음'; return $false }
                [IO.File]::WriteAllText($TokenFile, "$($script:Tok)`n")
                $script:Fresh = $true
                return $true
            }
            0 { Fail-Network }
            default {
                Warn "Vault GitHub 로그인 실패 (HTTP ${code}: $(Get-VaultErrors))"
                Warn 'PAT가 만료됐거나 read:org 권한이 없거나 ORBIT-CLOUD-LABS 조직 멤버가 아닐 수 있음. PAT 교체: scripts\orbit-ssh-setup.ps1 -ResetPat'
                return $false
            }
        }
    }

    # 저장된 토큰이 1분 넘게 남았으면 그대로 씀
    if ((Test-Path -LiteralPath $TokenFile) -and (Get-Item -LiteralPath $TokenFile).Length -gt 0) {
        $script:Tok = (Get-Content -LiteralPath $TokenFile -TotalCount 1).Trim()
        $code = Invoke-Vault 'GET' 'auth/token/lookup-self' $script:Tok $null
        if ($code -eq 0) { Fail-Network }
        if ($code -ne 200 -or [int]$script:Resp.data.ttl -le 60) { $script:Tok = $null }
    }
    if (-not $script:Tok) { if (-not (Invoke-Login)) { Bail } }
    Remove-Item -LiteralPath $Down -Force -ErrorAction SilentlyContinue

    # 토큰 정책 중 ssh-personal-<계정명>이 정확히 하나여야 함
    function Find-User {
        $code = Invoke-Vault 'GET' 'auth/token/lookup-self' $script:Tok $null
        if ($code -eq 0) { Fail-Network }
        if ($code -ne 200) { Warn "Vault 토큰 조회 실패 (HTTP ${code}: $(Get-VaultErrors))"; return $null }
        $found = @($script:Resp.data.policies | Where-Object { $_ -is [string] -and $_.StartsWith($PolicyPrefix) } |
                   ForEach-Object { $_.Substring($PolicyPrefix.Length) })
        if ($found.Count -eq 1 -and (Test-UserName $found[0])) { return $found[0] }
        return $null
    }

    if ($WhoAmI) {
        # 매핑이 생기기 전에 받은 토큰에는 개인 정책이 없음. 한 번만 새로 로그인
        $me = Find-User
        if (-not $me -and -not $script:Fresh) {
            if (-not (Invoke-Login)) { exit 1 }
            $me = Find-User
        }
        if (-not $me) {
            Warn "Vault 토큰에 개인 SSH 정책(${PolicyPrefix}<계정명>)이 하나만 있어야 함. 관리자에게 personal_accounts 명단 추가와 Vault 적용을 요청"
            exit 1
        }
        Write-Output $me   # setup이 결과를 받음. [Console]::Out은 파이프라인을 거치지 않아 받을 수 없음
        exit 0
    }

    function Invoke-Sign {
        $pub = ([IO.File]::ReadAllText("$Key.pub")).TrimEnd("`r", "`n")
        return (Invoke-Vault 'POST' "$SignPrefix$($script:SshUser)" $script:Tok @{ public_key = $pub })
    }

    $code = Invoke-Sign
    # 저장된 토큰이 그사이 폐기됐거나 개인 매핑 전에 받은 토큰이면 한 번만 다시 로그인
    if ($code -eq 403 -and -not $script:Fresh) {
        if (-not (Invoke-Login)) { exit 0 }
        $code = Invoke-Sign
    }
    switch ($code) {
        200 { }
        0 { Fail-Network }
        403 { Warn "개인 인증서 서명 거부 (역할 personal-$($script:SshUser)). 명단에서 빠졌거나 계정명이 바뀌었을 수 있음. 관리자에게 확인. $NoCert"; exit 0 }
        default { Warn "인증서 서명 실패 (HTTP ${code}: $(Get-VaultErrors)). $NoCert"; exit 0 }
    }

    $signed = [string]$script:Resp.data.signed_key
    $tmp = "$Cert.tmp"
    # BOM 없는 ASCII로 저장. PowerShell의 > 나 Out-File은 UTF-16이나 BOM이 붙어 ssh가 읽지 못함
    [IO.File]::WriteAllText($tmp, $signed.TrimEnd("`r", "`n") + "`n", (New-Object Text.ASCIIEncoding))
    if (-not (Read-CertInfo $tmp)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Warn "Vault가 돌려준 인증서를 읽을 수 없음. $NoCert"
        exit 0
    }
    Move-Item -LiteralPath $tmp -Destination $Cert -Force
    $until = (Read-CertInfo $Cert).Until
    Warn "SSH 인증서를 새로 받음 ($($script:SshUser), $($until.ToString('HH:mm:ss'))까지)"
    exit 0
} catch {
    Warn "갱신 중 오류: $($_.Exception.Message). $NoCert"
    Bail
} finally {
    Remove-Item -LiteralPath "$Cert.tmp" -Force -ErrorAction SilentlyContinue
    if ($lockHeld) { Remove-Item -LiteralPath $Lock -Force -ErrorAction SilentlyContinue }
}
