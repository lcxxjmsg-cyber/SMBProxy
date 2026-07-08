<#
    SMBProxy client bootstrap (start-client.ps1)

    NOTE: This bootstrap is intentionally ASCII-only. When invoked via
    "irm <url> | iex", PowerShell may decode the response as Latin1 if the
    mirror does not send charset=utf-8, which corrupts non-ASCII characters.
    Keeping this file ASCII makes it safe on every mirror. The downstream
    setup scripts (which contain Chinese text) are fetched as raw bytes and
    decoded as UTF-8 explicitly inside this script, so their output is fine.

    Responsibilities:
      1. Self-elevate (UAC) to Administrator
      2. Detect Windows edition -> route to the matching setup-client script
      3. Fetch the setup script online and run it in memory (no file on disk)
      4. Cache Win7/2008R2 offline plugins to a fixed temp dir (survives reboot)
      5. Smart resume: install needs 1-3 reboots, continued by a logon task
      6. Stage detection via dependency / SMB state
      7. When fully ready: remove the resume task + clear cached plugins
      8. Multi-mirror download with automatic fallback (GitHub proxies + CDN)

    Usage:
      irm https://gh-proxy.com/https://raw.githubusercontent.com/lcxxjmsg-cyber/SMBProxy/main/client/start-client.ps1 | iex
#>

# ============ config ============
$GitHubUser   = 'lcxxjmsg-cyber'
$GitHubRepo   = 'SMBProxy'
$GitHubBranch = 'main'
# ================================

$Repo      = "$GitHubUser/$GitHubRepo"
$TaskName  = 'SMBProxy_ClientBootstrap'
$cacheRoot = Join-Path $env:TEMP 'SMBProxy'
# The URL used by the resume task (primary proxy mirror). ASCII script, so safe.
$SelfUrl   = "https://gh-proxy.com/https://raw.githubusercontent.com/$Repo/$GitHubBranch/client/start-client.ps1"

# ---- force TLS 1.2 (required by GitHub) ----
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- self-elevate ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[*] Requesting administrator privileges..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-Command',
            "irm '$SelfUrl' | iex"
        )
    } catch {
        Write-Host "[ERROR] Elevation cancelled or failed." -ForegroundColor Red
    }
    return
}

# ================= mirrors =================
# Build a fallback URL list for a repo-relative path (e.g. "client/xxx.ps1").
# GitHub proxy mirrors have no size limit and are usually reachable in CN.
# jsDelivr is fast for small files but limited to ~50MB, so skip it for plugins.
function Get-MirrorUrls([string]$rel, [bool]$includeCdn) {
    $b = $GitHubBranch
    $urls = @(
        "https://gh-proxy.com/https://raw.githubusercontent.com/$Repo/$b/$rel",
        "https://ghfast.top/https://raw.githubusercontent.com/$Repo/$b/$rel",
        "https://ghproxy.net/https://raw.githubusercontent.com/$Repo/$b/$rel",
        "https://raw.githubusercontent.com/$Repo/$b/$rel"
    )
    if ($includeCdn) {
        $urls += @(
            "https://cdn.jsdelivr.net/gh/$Repo@$b/$rel",
            "https://fastly.jsdelivr.net/gh/$Repo@$b/$rel"
        )
    }
    return $urls
}

# Validate a byte array by its file-header magic number, inferred from the
# extension. This rejects empty/truncated data and mirror HTML error pages
# (which start with '<') without hard-coding any file sizes, so swapping plugin
# versions later needs no script changes.
#   .exe -> 'MZ'      .zip -> 'PK'      .msu -> 'MSCF' (CAB container)
function Test-FileSignature([byte[]]$data, [string]$name) {
    if (-not $data -or $data.Length -lt 4) { return $false }
    $ext = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
    switch ($ext) {
        '.exe' { return ($data[0] -eq 0x4D -and $data[1] -eq 0x5A) }                                  # MZ
        '.zip' { return ($data[0] -eq 0x50 -and $data[1] -eq 0x4B) }                                  # PK
        '.msu' { return ($data[0] -eq 0x4D -and $data[1] -eq 0x53 -and $data[2] -eq 0x43 -and $data[3] -eq 0x46) } # MSCF
        default { return $true }   # unknown type: accept if non-empty
    }
}
# Same check against a file on disk (reads only the first bytes).
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

# Download raw bytes trying each mirror until one succeeds.
# $validateName: if set, the response must pass the magic-byte signature check
# for that file name; otherwise the mirror is treated as failed and the next
# one is tried. This filters out HTML error pages and truncated responses.
function Download-Bytes([string]$rel, [bool]$includeCdn, [string]$validateName = $null) {
    foreach ($u in (Get-MirrorUrls $rel $includeCdn)) {
        $wc = $null
        try {
            $wc = New-Object System.Net.WebClient
            $data = $wc.DownloadData($u)
            if (-not $data -or $data.Length -eq 0) {
                Write-Host "    [x]  empty     $u" -ForegroundColor DarkGray; continue
            }
            if ($validateName -and -not (Test-FileSignature $data $validateName)) {
                Write-Host "    [x]  bad sig   $u" -ForegroundColor DarkGray; continue
            }
            Write-Host ("    [ok] {0}  ({1:N0} bytes)" -f $u, $data.Length) -ForegroundColor DarkGray
            return ,$data
        } catch {
            Write-Host "    [x]  fail      $u" -ForegroundColor DarkGray
        } finally {
            if ($wc) { $wc.Dispose() }
        }
    }
    throw "All mirrors failed for: $rel"
}

# Download a file to disk via mirrors (used for large plugins).
# Writes to a .part temp file first and moves it into place only after a full,
# signature-verified download, so an interrupted run never leaves a
# usable-looking but corrupt file at the final path.
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
# Basic sanity check: reject empty responses and HTML error pages.
function Download-Text([string]$rel) {
    $bytes = Download-Bytes $rel $true
    $s = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($s.Length -gt 0 -and $s[0] -eq [char]0xFEFF) { $s = $s.Substring(1) }
    return $s
}

# ================= helpers =================
function Register-ContinueTask {
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command "irm ''' + $SelfUrl + ''' | iex"'
    schtasks.exe /create /tn $TaskName /tr $tr /sc onlogon /rl HIGHEST /f 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "[*] Resume-on-logon task registered ($TaskName)" -ForegroundColor DarkGray }
    else { Write-Host "[WARN] Failed to register resume task. Re-run the command manually after reboot." -ForegroundColor Yellow }
}
function Remove-ContinueTask {
    schtasks.exe /query /tn $TaskName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        schtasks.exe /delete /tn $TaskName /f 2>$null | Out-Null
        Write-Host "[*] Resume task removed." -ForegroundColor DarkGray
    }
}
function Clear-PluginCache {
    if (Test-Path $cacheRoot) {
        Remove-Item $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[*] Cleared cached plugins: $cacheRoot" -ForegroundColor DarkGray
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
    Write-Host "[*] Caching offline plugins to: $plugPath" -ForegroundColor Yellow
    Write-Host "    (large files; verified-cached ones are skipped)" -ForegroundColor DarkGray
    foreach ($f in $plugFiles) {
        $target = Join-Path $plugPath $f
        # Skip only when an existing cached file passes the magic-byte check.
        # Partial / corrupt / error-page files fail the check and get re-fetched.
        if (Test-Path $target) {
            if (Test-FileSignatureOnDisk $target $f) {
                Write-Host "    skip (verified): $f" -ForegroundColor DarkGray; continue
            }
            Write-Host "    re-download (bad cache): $f" -ForegroundColor Yellow
            Remove-Item $target -Force -ErrorAction SilentlyContinue
        }
        Write-Host "    downloading: $f" -ForegroundColor DarkGray
        Download-ToFile "client/$plugDir/$f" $target $false   # no CDN for big files
    }
}
function Invoke-Setup([string]$script) {
    Write-Host "[*] Fetching setup script online: $script" -ForegroundColor Yellow
    $text = Download-Text "client/$script"
    # In-memory run: original scripts derive plugin dir from their own path,
    # which is empty when run via iex. Redirect it to our plugin cache dir.
    $text = $text.Replace('Split-Path -Parent $MyInvocation.MyCommand.Path', "'$cacheRoot'")
    Write-Host ""
    Write-Host "[*] Launching: $script" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Invoke-Expression $text   # the setup script may call exit; nothing after runs
}

# ================= main =================
Write-Host ""
Write-Host "============== SMBProxy client bootstrap ==============" -ForegroundColor Cyan
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

Write-Host "  OS      : $($os.Caption)"
Write-Host "  Version : $($os.Version)  ($(if($isServer){'Server'}else{'Workstation'}), $arch)"
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
    Write-Host "[UNSUPPORTED] This OS is not in the supported list." -ForegroundColor Red
    Write-Host "  Supported: Win7/8/8.1/10/11, Server 2008R2/2012/2012R2/2016+" -ForegroundColor Red
    Write-Host "  Not supported: Server 2008(non-R2) / Vista / XP" -ForegroundColor Red
    Remove-ContinueTask
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

Write-Host "  Script  : $script (run in memory)" -ForegroundColor Green
Write-Host "  Deps    : $(if($depsReady){'ready'}else{'need install (plugins)'})" -ForegroundColor Green
Write-Host "  SMB     : $(if($smbDisabled){'disabled (port ready)'}else{'not handled'})" -ForegroundColor Green
Write-Host ""

$rebootBanner = {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " [RESUME ARMED] The setup script will ask you to reboot." -ForegroundColor Yellow
    Write-Host " Reboot as prompted; it will auto-continue after logon." -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
}

try {
    if ($needsPlugin -and -not $depsReady) {
        Write-Host "[STAGE A] Install system dependencies (SHA-2 / .NET 4.8 / WMF 5.1)" -ForegroundColor Magenta
        Ensure-Plugins $plugDir $plugFiles
        Register-ContinueTask
        & $rebootBanner
        Invoke-Setup $script
    }
    elseif (-not $smbDisabled) {
        Write-Host "[STAGE B] Disable native SMB (445) and fast startup" -ForegroundColor Magenta
        Register-ContinueTask
        & $rebootBanner
        Invoke-Setup $script
    }
    else {
        Write-Host "[STAGE C] Environment ready, entering config menu" -ForegroundColor Magenta
        Remove-ContinueTask
        Clear-PluginCache
        Invoke-Setup $script
    }
}
catch {
    Write-Host ""
    Write-Host "[ERROR] Execution failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        If this is a network issue, just re-run the command (cache is reused)." -ForegroundColor DarkGray
}
