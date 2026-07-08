<#
    SMBProxy client bootstrap (start-client.ps1)

    NOTE: This bootstrap file is intentionally ASCII-only. When invoked via
    "irm <url> | iex", PowerShell may decode the response as Latin1 if the
    mirror does not send charset=utf-8, which would corrupt any literal
    non-ASCII (Chinese) characters. To show Chinese safely on every mirror,
    all user-facing messages are stored as Base64(UTF-8) strings and decoded
    at runtime (see $T table + the M helper). The downstream setup scripts
    (which contain Chinese) are fetched as raw bytes and decoded as UTF-8
    explicitly inside this script, so their output is also fine.

    Responsibilities:
      1. Self-elevate (UAC) to Administrator
      2. Detect Windows edition -> route to the matching setup-client script
      3. Fetch the setup script online and run it in memory (no file on disk)
      4. Cache Win7/2008R2 offline plugins to a fixed temp dir (survives reboot)
      5. No auto-start: when a reboot is required, ask the user to re-run this
         same one-liner manually (Win+R) after rebooting. No scheduled task.
      6. Stage detection via dependency / SMB state
      7. When fully ready: clear cached plugins
      8. Multi-mirror download with automatic fallback (GitHub proxies + CDN)

    Usage:
      irm https://cdn.jsdelivr.net/gh/lcxxjmsg-cyber/SMBProxy@main/client/start-client.ps1 | iex
#>

# ============ config ============
$GitHubUser   = 'lcxxjmsg-cyber'
$GitHubRepo   = 'SMBProxy'
$GitHubBranch = 'main'
# ================================

$Repo      = "$GitHubUser/$GitHubRepo"
$cacheRoot = Join-Path $env:TEMP 'SMBProxy'
# Primary entry via jsDelivr (CDN-cached, CN-reachable, not rate-limited).
$SelfUrl   = "https://cdn.jsdelivr.net/gh/$Repo@$GitHubBranch/client/start-client.ps1"

# ---- localized messages: Base64(UTF-8), decoded at runtime to avoid mojibake ----
$T = @{
    title        = 'PT09PT09PT09PT09PT0gU01CUHJveHkg5a6i5oi356uv5byV5a+8ID09PT09PT09PT09PT09'
    elevate      = 'WypdIOato+WcqOivt+axgueuoeeQhuWRmOadg+mZkC4uLg=='
    elevateFail  = 'W+mUmeivr10g5o+Q5p2D6KKr5Y+W5raI5oiW5aSx6LSl44CC'
    cacheCleared = 'WypdIOW3sua4heeQhue8k+WtmOaPkuS7tg=='
    caching      = 'WypdIOato+WcqOe8k+WtmOemu+e6v+aPkuS7tu+8iOaWh+S7tui+g+Wkp++8jOW3suagoemqjOeahOWwhui3s+i/h++8iS4uLg=='
    skipVerified = 'ICAgIOW3sue8k+WtmDog'
    reDownload   = 'ICAgIOmHjeaWsOS4i+i9vSjnvJPlrZjmjZ/lnY8pOiA='
    downloading  = 'ICAgIOS4i+i9veS4rTog'
    fetching     = 'WypdIOato+WcqOiOt+WPluWuieijheiEmuacrC4uLg=='
    osLabel      = 'ICDns7vnu586IA=='
    verLabel     = 'ICDniYjmnKw6IA=='
    srv          = '5pyN5Yqh5Zmo'
    wks          = '5bel5L2c56uZ'
    unsupp1      = 'W+S4jeaUr+aMgV0g5b2T5YmN57O757uf5LiN5Zyo5pSv5oyB6IyD5Zu05YaF44CC'
    unsupp2      = 'ICDmlK/mjIE6IFdpbjcvOC84LjEvMTAvMTEsIFNlcnZlciAyMDA4UjIvMjAxMi8yMDEyUjIvMjAxNis='
    unsupp3      = 'ICDkuI3mlK/mjIE6IFNlcnZlciAyMDA4KOmdnlIyKSAvIFZpc3RhIC8gWFA='
    depReady     = '5bey5bCx57uq'
    depNeed      = '5b6F5a6J6KOFKOmcgOaPkuS7tik='
    smbOff       = '5bey56aB55SoKOerr+WPo+Wwsee7qik='
    smbOn        = '5pyq5aSE55CG'
    lblScript    = 'ICDohJrmnKw6IA=='
    lblDeps      = 'ICDkvp3otZY6IA=='
    lblSmb       = 'ICBTTUIgOiA='
    stageA       = 'W+mYtuautSBBXSDlronoo4Xns7vnu5/kvp3otZYgKFNIQS0yIC8gLk5FVCA0LjggLyBXTUYgNS4xKQ=='
    stageB       = 'W+mYtuautSBCXSDnpoHnlKjns7vnu58gNDQ1IOacjeWKoeW5tuWFs+mXreW/q+mAn+WQr+WKqA=='
    stageC       = 'W+mYtuautSBDXSDnjq/looPlt7LlsLHnu6rvvIzov5vlhaXphY3nva7oj5zljZU='
    errRun       = 'W+mUmeivr10g5omn6KGM5aSx6LSlOiA='
    errHint      = 'ICAgICAgIOiLpeS4uue9kee7nOmXrumimO+8jOmHjeaWsOi/kOihjOWRveS7pOWNs+WPr++8iOW3sue8k+WtmOWGheWuueS8muWkjeeUqO+8ieOAgg=='
}
function M([string]$key) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($T[$key])) }

# ---- force TLS 1.2 (required by GitHub) ----
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- self-elevate ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host (M 'elevate') -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-Command',
            "irm '$SelfUrl' | iex"
        )
    } catch {
        Write-Host (M 'elevateFail') -ForegroundColor Red
    }
    return
}

# ================= mirrors =================
# Order matters: fastest / least rate-limited first.
# jsDelivr (CDN) is preferred for scripts & small files (CN-reachable, cached,
# not rate-limited), but has a ~50MB limit so it is skipped for big plugins.
# GitHub proxies (gh-proxy/ghfast/ghproxy) can be flaky or rate-limited (429),
# so they come after the CDN; raw.githubusercontent is the last resort.
function Get-MirrorUrls([string]$rel, [bool]$includeCdn) {
    $b = $GitHubBranch
    $urls = @()
    if ($includeCdn) {
        $urls += @(
            "https://cdn.jsdelivr.net/gh/$Repo@$b/$rel",
            "https://fastly.jsdelivr.net/gh/$Repo@$b/$rel",
            "https://gcore.jsdelivr.net/gh/$Repo@$b/$rel"
        )
    }
    $urls += @(
        "https://gh-proxy.com/https://raw.githubusercontent.com/$Repo/$b/$rel",
        "https://ghfast.top/https://raw.githubusercontent.com/$Repo/$b/$rel",
        "https://ghproxy.net/https://raw.githubusercontent.com/$Repo/$b/$rel",
        "https://raw.githubusercontent.com/$Repo/$b/$rel"
    )
    return $urls
}

# Validate a byte array by its file-header magic number (inferred from ext).
# Rejects empty/truncated data and mirror HTML error pages without hard-coding
# any file sizes, so swapping plugin versions later needs no script changes.
#   .exe -> MZ    .zip -> PK    .msu -> MSCF (CAB container)
function Test-FileSignature([byte[]]$data, [string]$name) {
    if (-not $data -or $data.Length -lt 4) { return $false }
    $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
    switch ($ext) {
        '.exe' { return ($data[0] -eq 0x4D -and $data[1] -eq 0x5A) }
        '.zip' { return ($data[0] -eq 0x50 -and $data[1] -eq 0x4B) }
        '.msu' { return ($data[0] -eq 0x4D -and $data[1] -eq 0x53 -and $data[2] -eq 0x43 -and $data[3] -eq 0x46) }
        default { return $true }
    }
}
function Test-FileSignatureOnDisk([string]$path, [string]$name) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $buf = New-Object byte[] 4
            $read = $fs.Read($buf, 0, 4)
            if ($read -lt 4) { return $false }
            return (Test-FileSignature $buf $name)
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# Download raw bytes trying each mirror until one succeeds (silent about URLs).
function Download-Bytes([string]$rel, [bool]$includeCdn, [string]$validateName = $null) {
    foreach ($u in (Get-MirrorUrls $rel $includeCdn)) {
        $wc = $null
        try {
            $wc = New-Object System.Net.WebClient
            $data = $wc.DownloadData($u)
            if (-not $data -or $data.Length -eq 0) { continue }
            if ($validateName -and -not (Test-FileSignature $data $validateName)) { continue }
            return ,$data
        } catch {
        } finally {
            if ($wc) { $wc.Dispose() }
        }
    }
    throw "All mirrors failed for: $rel"
}

# Download a file to disk via mirrors. Writes to a .part temp file first and
# moves it into place only after a full, signature-verified download, so an
# interrupted run never leaves a corrupt file at the final path.
function Download-ToFile([string]$rel, [string]$dest, [bool]$includeCdn) {
    $name = [System.IO.Path]::GetFileName($dest)
    $bytes = Download-Bytes $rel $includeCdn $name
    $part = "$dest.part"
    try {
        [System.IO.File]::WriteAllBytes($part, $bytes)
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        Move-Item $part $dest -Force
    } finally {
        if (Test-Path $part) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
    }
}

# Fetch a text script via mirrors, decode as UTF-8 (strip BOM), return string.
function Download-Text([string]$rel) {
    $bytes = Download-Bytes $rel $true
    $s = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($s.Length -gt 0 -and $s[0] -eq [char]0xFEFF) { $s = $s.Substring(1) }
    return $s
}

# ================= helpers =================
function Clear-PluginCache {
    if (Test-Path $cacheRoot) {
        Remove-Item $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host (M 'cacheCleared') -ForegroundColor DarkGray
    }
}
function Test-SmbDisabled {
    $s = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ea SilentlyContinue
    return ($s -and $s.Start -eq 4)
}
function Test-DepsReady {
    if (-not (Get-HotFix -Id KB4490628 -ea SilentlyContinue)) { return $false }
    if (-not (Get-HotFix -Id KB4474419 -ea SilentlyContinue)) { return $false }
    $net = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ea SilentlyContinue
    if (-not $net -or $net.Release -lt 378389) { return $false }
    if ($PSVersionTable.PSVersion.Major -lt 5) { return $false }
    return $true
}
function Ensure-Plugins([string]$plugDir, [string[]]$plugFiles) {
    $plugPath = Join-Path $cacheRoot $plugDir
    New-Item -ItemType Directory -Path $plugPath -Force | Out-Null
    Write-Host (M 'caching') -ForegroundColor Yellow
    foreach ($f in $plugFiles) {
        $target = Join-Path $plugPath $f
        if (Test-Path $target) {
            if (Test-FileSignatureOnDisk $target $f) {
                Write-Host ((M 'skipVerified') + $f) -ForegroundColor DarkGray; continue
            }
            Write-Host ((M 'reDownload') + $f) -ForegroundColor Yellow
            Remove-Item $target -Force -ErrorAction SilentlyContinue
        }
        Write-Host ((M 'downloading') + $f) -ForegroundColor DarkGray
        Download-ToFile "client/$plugDir/$f" $target $false   # no CDN for big files
    }
}
function Invoke-Setup([string]$script) {
    Write-Host (M 'fetching') -ForegroundColor Yellow
    $text = Download-Text "client/$script"
    # In-memory run: original scripts derive plugin dir from their own path,
    # which is empty when run via iex. Redirect it to our plugin cache dir.
    $text = $text.Replace('Split-Path -Parent $MyInvocation.MyCommand.Path', "'$cacheRoot'")
    Clear-Host   # wipe the bootstrap's own output so the setup menu starts clean
    Invoke-Expression $text   # the setup script may call exit; nothing after runs
}

# ================= main =================
Write-Host ""
Write-Host (M 'title') -ForegroundColor Cyan
Write-Host ""

$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
if (-not $os) { $os = Get-WmiObject Win32_OperatingSystem }

$verParts = ($os.Version -split '\.')
$major    = [int]$verParts[0]
$minor    = [int]$verParts[1]
$isServer = ($os.ProductType -ne 1)
$is64     = [Environment]::Is64BitOperatingSystem
$arch     = if ($is64) { 'x64' } else { 'x86' }

$osKind = if ($isServer) { M 'srv' } else { M 'wks' }
Write-Host ((M 'osLabel') + $os.Caption)
Write-Host ((M 'verLabel') + $os.Version + "  ($osKind, $arch)")
Write-Host ""

$script    = $null
$plugDir   = $null
$plugFiles = @()

switch ($major) {
    10 {
        if ($isServer) { $script = 'setup-client-2016++.ps1' }
        else           { $script = 'setup-client-win10-11.ps1' }
    }
    6 {
        switch ($minor) {
            3 { if ($isServer) { $script = 'setup-client-2012-r2.ps1' } else { $script = 'setup-client-win8-1.ps1' } }
            2 { if ($isServer) { $script = 'setup-client-2012-r2.ps1' } else { $script = 'setup-client-win8-1.ps1' } }
            1 {
                if ($isServer) { $script = 'setup-client-2008r2.ps1'; $plugDir = '2008r2plug' }
                else           { $script = 'setup-client-win7.ps1';   $plugDir = 'win7plug'   }
            }
            0 { $script = $null }
        }
    }
    default { $script = $null }
}

if (-not $script) {
    Write-Host (M 'unsupp1') -ForegroundColor Red
    Write-Host (M 'unsupp2') -ForegroundColor Red
    Write-Host (M 'unsupp3') -ForegroundColor Red
    return
}

if ($plugDir -eq 'win7plug') {
    if ($is64) {
        $plugFiles = @(
            'ndp48-web.exe',
            'windows6.1-kb4490628-x64_d3de52d6987f7c8bdc2c015dca69eac96047c76e.msu',
            'windows6.1-kb4474419-v3-x64_b5614c6cea5cb4e198717789633dca16308ef79c.msu',
            'Win7AndW2K8R2-KB3191566-x64.zip'
        )
    } else {
        $plugFiles = @(
            'ndp48-web.exe',
            'windows6.1-kb4490628-x86_3cdb3df55b9cd7ef7fcb24fc4e237ea287ad0992.msu',
            'windows6.1-kb4474419-v3-x86_0f687d50402790f340087c576886501b3223bec6.msu',
            'Win7-KB3191566-x86.zip'
        )
    }
} elseif ($plugDir -eq '2008r2plug') {
    $plugFiles = @(
        'ndp48-web.exe',
        'windows6.1-kb4490628-x64_d3de52d6987f7c8bdc2c015dca69eac96047c76e.msu',
        'windows6.1-kb4474419-v3-x64_b5614c6cea5cb4e198717789633dca16308ef79c.msu',
        'Win7AndW2K8R2-KB3191566-x64.zip'
    )
}

$needsPlugin = [bool]$plugDir
$depsReady   = if ($needsPlugin) { Test-DepsReady } else { $true }
$smbDisabled = Test-SmbDisabled

Write-Host ((M 'lblScript') + $script) -ForegroundColor Green
Write-Host ((M 'lblDeps') + $(if($depsReady){M 'depReady'}else{M 'depNeed'})) -ForegroundColor Green
Write-Host ((M 'lblSmb') + $(if($smbDisabled){M 'smbOff'}else{M 'smbOn'})) -ForegroundColor Green
Write-Host ""

try {
    if ($needsPlugin -and -not $depsReady) {
        Write-Host (M 'stageA') -ForegroundColor Magenta
        Ensure-Plugins $plugDir $plugFiles
        Invoke-Setup $script
    }
    elseif (-not $smbDisabled) {
        Write-Host (M 'stageB') -ForegroundColor Magenta
        Invoke-Setup $script
    }
    else {
        Write-Host (M 'stageC') -ForegroundColor Magenta
        Clear-PluginCache
        Invoke-Setup $script
    }
}
catch {
    Write-Host ""
    Write-Host ((M 'errRun') + $_.Exception.Message) -ForegroundColor Red
    Write-Host (M 'errHint') -ForegroundColor DarkGray
}
