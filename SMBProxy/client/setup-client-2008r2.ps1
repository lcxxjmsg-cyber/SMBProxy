<#
.SYNOPSIS
     SMB 端口转发 - Windows Server 2008 R2 专用版 (v3.1-server)
.DESCRIPTION
      针对 Windows Server 2008 R2 SP1 (64位) 的完整兼容版本。
      核心功能与 Win10/11 版完全一致。因为 2008 R2 缺少 NetAdapter / ScheduledTasks /
      CIM / DnsClient 等模块, 本脚本全部替换为 WMI + netsh + schtasks。
      
      前置依赖 (脚本自动检测安装):
        - .NET Framework 4.8
        - WMF 5.1 (PowerShell 5.1)
        - SHA-2 签名支持补丁 (KB4490628 / KB4474419)
     [Server 2012/2012 R2 请使用 setup-server-2012.ps1]
     [Server 2016+ 请使用 setup-server-2016plus.ps1]
#>

# === PS 2.0 兼容: 内置 pause 不存在 ===
function global:pause { $null = Read-Host "按 Enter 键继续..." }

# === 管理员权限检测 (兼容 PS 2.0, 不用 #Requires) ===
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[错误] 请以管理员身份运行此脚本" -ForegroundColor Red
    pause
    exit 1
}

$ErrorActionPreference = "Stop"

# === 本地插件目录 (存放 .NET 和 WMF 离线安装包, 与 Win7 共用) ===
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginDir = "$ScriptDir\2008r2plug"

# === 系统版本检测 ===
$os = Get-WmiObject Win32_OperatingSystem
$is2008R2 = ($os.Version -like "6.1.*")
if (-not $is2008R2) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [错误] 此脚本仅适用于 Windows Server 2008 R2" -ForegroundColor Red
    Write-Host "  当前系统版本: $($os.Caption) ($($os.Version))" -ForegroundColor Yellow
    Write-Host "  Server 2012+ 请使用 setup-server-2012.ps1" -ForegroundColor Yellow
    Write-Host "  Server 2016+ 请使用 setup-server-2016plus.ps1" -ForegroundColor Yellow
    Write-Host "====================================================" -ForegroundColor Red
    pause
    exit 1
}
Write-Host "[系统] 检测到 $($os.Caption) — 使用 Server 2008 R2 模式" -ForegroundColor Cyan

# === 自动启用 TLS 1.2 (Win7 默认禁用, 需手动打开 Schannel 开关) ===
function Enable-Tls12 {
    # 在 Schannel 中启用 TLS 1.2 (客户端)
    $p = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    Set-ItemProperty -Path $p -Name "DisabledByDefault" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $p -Name "Enabled" -Value 1 -Type DWord -Force
    # 启用 TLS 1.1 作为备用
    $p = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client"
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    Set-ItemProperty -Path $p -Name "DisabledByDefault" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $p -Name "Enabled" -Value 1 -Type DWord -Force
    # 让 .NET/OS 使用 TLS 1.2
    # SchUseStrongCrypto: CLR 2.0/4.0 强制使用系统 Schannel 设置
    # SystemDefaultTlsVersions: .NET 4.7+ 使用系统默认 TLS 版本
    $netPaths = @(
        "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
        "HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727"
    )
    foreach ($np in $netPaths) {
        Set-ItemProperty -Path $np -Name "SchUseStrongCrypto" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $np -Name "SystemDefaultTlsVersions" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    # WinHTTP 默认安全协议 (bitsadmin 下载时需要)
    $winHttpPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"
    )
    foreach ($wp in $winHttpPaths) {
        if (-not (Test-Path $wp)) { New-Item -Path $wp -Force | Out-Null }
        Set-ItemProperty -Path $wp -Name "DefaultSecureProtocols" -Value 0x00000A80 -Type DWord -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "[系统] 正在启用 TLS 1.2 支持..." -ForegroundColor Cyan
try {
    Enable-Tls12
    Write-Host "[OK] TLS 1.2 已启用 (即时生效)" -ForegroundColor Green
} catch {
    Write-Host "[警告] TLS 1.2 启用失败: $($_.Exception.Message)" -ForegroundColor Yellow
}

# === 统一下载函数 (绕过 Win7 .NET 3.5 的 TLS/证书限制) ===
function Download-File {
    param($Urls, $DestPath)
    if ($Urls -is [string]) { $Urls = @($Urls) }
    if (Test-Path $DestPath) { Remove-Item $DestPath -Force }

    foreach ($Url in $Urls) {
        # 方法1: MSXML2 ServerXMLHTTP (走 WinHTTP, 跳过证书校验)
        $msxmlProgIDs = @("MSXML2.ServerXMLHTTP.6.0", "MSXML2.ServerXMLHTTP.3.0", "MSXML2.ServerXMLHTTP")
        foreach ($progID in $msxmlProgIDs) {
            try {
                $http = New-Object -ComObject $progID -ErrorAction Stop
                $http.setOption(2, 13056)
                $http.open("GET", $Url, $false)
                $http.setTimeouts(30000, 30000, 30000, 30000)
                $http.send()
                if ($http.status -eq 200) {
                    [System.IO.File]::WriteAllBytes($DestPath, $http.responseBody)
                    return $true
                }
            } catch {}
        }
        # 方法2: bitsadmin 备用
        $dlCmd = "bitsadmin /transfer DL `"$Url`" `"$DestPath`""
        cmd /c $dlCmd 2>&1 | Out-Null
        if (Test-Path $DestPath) { return $true }
    }
    return $false
}

# === 0. SHA-2 签名支持 (Win7 不原生支持 SHA-256 签名,
#     不装这个后续 .NET 4.8 和 WMF 5.1 的安装包都无法运行) ===
Write-Host "[系统] 检查 SHA-2 签名支持..." -ForegroundColor Cyan
$osArch = (Get-WmiObject Win32_OperatingSystem).OSArchitecture
$is64Bit = ($osArch -match "64")

$kbsNeeded = @()
if (-not (Get-HotFix -Id KB4490628 -ErrorAction SilentlyContinue)) {
    $kbsNeeded += @{ KB="KB4490628"; Desc="服务栈更新(双签名兼容)" }
}
if (-not (Get-HotFix -Id KB4474419 -ErrorAction SilentlyContinue)) {
    $kbsNeeded += @{ KB="KB4474419"; Desc="SHA-2 签名支持" }
}

if ($kbsNeeded.Count -gt 0) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [必须先装] SHA-2 签名支持补丁 (否则 .NET/WMF 无法安装)" -ForegroundColor Red
    foreach ($k in $kbsNeeded) { Write-Host "  - 需要 $($k.KB) ($($k.Desc))" -ForegroundColor Yellow }
    Write-Host "====================================================" -ForegroundColor Red

    $choice = Read-Host "是否从本地安装缺少的补丁? [Y] 是 [N] 手动下载 (默认Y)"
    if ($choice -eq "" -or $choice -eq "Y" -or $choice -eq "y") {
        $allOk = $true
        foreach ($k in $kbsNeeded) {
            $localMsu = Get-ChildItem $PluginDir -Filter "*$($k.KB)*.msu" -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-Host "`n正在安装 $($k.KB) ($($k.Desc))..." -ForegroundColor Cyan
            if ($localMsu) {
                $installer = "$env:TEMP\$($localMsu.Name)"
                Write-Host "  [本地] 发现 $($localMsu.Name)" -ForegroundColor DarkCyan
                Copy-Item $localMsu.FullName $installer -Force
            } else {
                Write-Host "  [错误] 未找到 $($k.KB) 的 .msu 文件, 请下载后放入:" -ForegroundColor Red
                Write-Host "          $PluginDir" -ForegroundColor White
                Write-Host "  下载: https://www.catalog.update.microsoft.com/Search.aspx?q=$($k.KB)" -ForegroundColor Gray
                $allOk = $false
                continue
            }
            Write-Host "  正在安装 (静默模式)..." -ForegroundColor DarkCyan
            $result = Start-Process -FilePath "wusa.exe" -ArgumentList "`"$installer`" /quiet /norestart" -Wait -PassThru
            if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010) {
                Write-Host "  [OK] $($k.KB) 安装完成" -ForegroundColor Green
            } else {
                Write-Host "  [警告] $($k.KB) 返回码: $($result.ExitCode)" -ForegroundColor Yellow
            }
        }
        if (-not $allOk) {
            Write-Host "[提示] 请下载上述补丁文件放入 2008r2plug 目录后重新运行" -ForegroundColor Yellow
            pause
            exit 1
        }
        Write-Host "[OK] SHA-2 补丁已安装, 继续检查下一项..." -ForegroundColor Green
    } else {
        Write-Host "`n请从以下地址下载并安装补丁后重新运行:" -ForegroundColor Yellow
        foreach ($k in $kbsNeeded) {
            Start-Process "https://www.catalog.update.microsoft.com/Search.aspx?q=$($k.KB)"
        }
        pause
        exit 1
    }
}
Write-Host "[OK] SHA-2 签名支持已就绪" -ForegroundColor Green

# === 前提条件检查 (顺序重要: .NET 必须在 WMF 5.1 之前安装) ===

# 1. 先检查 .NET Framework 4.5+ (WMF 5.1 的前置依赖, 必须先装)
$netKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue
if (-not $netKey -or $netKey.Release -lt 378389) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [前提条件] 需要 .NET Framework 4.5 或更高版本" -ForegroundColor Red
    Write-Host "  WMF 5.1 依赖 .NET 4.5+, 必须先安装此项" -ForegroundColor Yellow
    Write-Host "====================================================" -ForegroundColor Red

    $choice = Read-Host "是否自动下载并安装 .NET 4.8? [Y] 是 [N] 手动下载 (默认Y)"
    if ($choice -eq "" -or $choice -eq "Y" -or $choice -eq "y") {
        $localInstaller = "$PluginDir\ndp48-web.exe"
        $installer = "$env:TEMP\ndp48-web.exe"
        $needDownload = $true
        if (Test-Path $localInstaller) {
            Write-Host "  [本地] 发现 $localInstaller, 跳过下载" -ForegroundColor DarkCyan
            Copy-Item $localInstaller $installer -Force
            $needDownload = $false
        }
        if ($needDownload) {
            Write-Host "`n正在下载 .NET Framework 4.8 Web 安装程序, 请稍候..." -ForegroundColor Cyan
        }
        try {
            if ($needDownload) {
                $netUrls = @(
                    "https://go.microsoft.com/fwlink/?linkid=2088631",
                    "https://download.visualstudio.microsoft.com/download/pr/2d6bb6b2-226a-4baa-bdec-798822606ff1/8494001c276a4b96804cde7829c04d7f/ndp48-web.exe"
                )
                if (-not (Download-File -Urls $netUrls -DestPath $installer)) {
                    throw "下载失败, 请检查网络连接或手动下载"
                }
                Write-Host "  [OK] 下载完成" -ForegroundColor Green
            }
            Write-Host "  正在安装 (静默模式, 可能需要几分钟)..." -ForegroundColor DarkCyan
            $result = Start-Process -FilePath $installer -ArgumentList "/q /norestart" -Wait -PassThru
            if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010) {
                Write-Host "  [OK] .NET Framework 4.8 安装完成" -ForegroundColor Green
            } else {
                Write-Host "  [警告] 安装返回码: $($result.ExitCode)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  [错误] 下载或安装失败: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  请手动下载: https://dotnet.microsoft.com/download/dotnet-framework/net48" -ForegroundColor White
        }
    } else {
        Write-Host "`n请手动下载并安装 .NET Framework 4.8:" -ForegroundColor Yellow
        Write-Host "  https://dotnet.microsoft.com/download/dotnet-framework/net48" -ForegroundColor White
        Start-Process "https://dotnet.microsoft.com/download/dotnet-framework/net48"
        pause
        exit 1
    }
    Write-Host "[OK] .NET 已安装, 继续检查下一项..." -ForegroundColor Green
}

# 2. 再检查 PowerShell 5.1 / WMF 5.1 (依赖 .NET 4.5+)
$psVersionOK = ($PSVersionTable.PSVersion.Major -ge 5)
if (-not $psVersionOK) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [前提条件] 需要 PowerShell 5.1 (WMF 5.1)" -ForegroundColor Red
    Write-Host "  当前版本: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "====================================================" -ForegroundColor Red

    $choice = Read-Host "是否自动下载并安装 WMF 5.1? [Y] 是 [N] 手动下载 (默认Y)"
    if ($choice -eq "" -or $choice -eq "Y" -or $choice -eq "y") {
        Write-Host "`n正在准备安装 WMF 5.1 ..." -ForegroundColor Cyan
        $osArch = (Get-WmiObject Win32_OperatingSystem).OSArchitecture
        if ($osArch -match "64") {
            $msuName = "Win7AndW2K8R2-KB3191566-x64.msu"
            $zipName = "Win7AndW2K8R2-KB3191566-x64.zip"
            $wmfUrl = "https://download.microsoft.com/download/6/F/5/6F5FF66C-6775-42B0-86C4-47D41F2DA187/Win7AndW2K8R2-KB3191566-x64.msu"
        } else {
            $msuName = "Win7-KB3191566-x86.msu"
            $zipName = "Win7-KB3191566-x86.zip"
            $wmfUrl = "https://download.microsoft.com/download/6/F/5/6F5FF66C-6775-42B0-86C4-47D41F2DA187/Win7-KB3191566-x86.msu"
        }
        $localMsu = "$PluginDir\$msuName"
        $localZip = "$PluginDir\$zipName"
        $installer = "$env:TEMP\$msuName"
        $needDownload = $true

        # 1) 本地已有解压好的 .msu
        if (Test-Path $localMsu) {
            Write-Host "  [本地] 发现 $localMsu, 跳过下载" -ForegroundColor DarkCyan
            Copy-Item $localMsu $installer -Force
            $needDownload = $false
        }
        # 2) 本地有 .zip, 自动解压提取 .msu
        elseif (Test-Path $localZip) {
            Write-Host "  [本地] 发现 $localZip, 正在解压..." -ForegroundColor DarkCyan
            $extractDir = "$env:TEMP\wmf_extract"
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            try {
                $shell = New-Object -ComObject Shell.Application
                $zip = $shell.NameSpace($localZip)
                $dest = $shell.NameSpace($extractDir)
                $dest.CopyHere($zip.Items(), 16)
                # 等待解压完成
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Milliseconds 500
                    $extracted = Get-ChildItem $extractDir -Filter "*.msu" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($extracted) { break }
                }
                if ($extracted) {
                    Copy-Item $extracted.FullName $localMsu -Force
                    Copy-Item $extracted.FullName $installer -Force
                    Write-Host "  [OK] 已解压 $msuName 到本地插件目录" -ForegroundColor Green
                    $needDownload = $false
                }
            } catch {}
            if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        }

        # 3) 本地没有, 尝试下载
        if ($needDownload) {
            Write-Host "  本地未找到, 正在下载..." -ForegroundColor DarkCyan
        }
        try {
            if ($needDownload) {
                if (-not (Download-File -Urls @($wmfUrl) -DestPath $installer)) {
                    throw "下载失败, 请检查网络连接或手动下载"
                }
                Write-Host "  [OK] 下载完成" -ForegroundColor Green
            }
            Write-Host "  正在安装 (静默模式)..." -ForegroundColor DarkCyan
            $result = Start-Process -FilePath "wusa.exe" -ArgumentList "`"$installer`" /quiet /norestart" -Wait -PassThru
            if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010) {
                Write-Host "  [OK] WMF 5.1 安装完成" -ForegroundColor Green
            } else {
                Write-Host "  [警告] 安装返回码: $($result.ExitCode)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  [错误] 下载或安装失败: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  请手动下载: https://www.microsoft.com/en-us/download/details.aspx?id=54616" -ForegroundColor White
            Write-Host "  或将下载的 .msu/.zip 放入: $PluginDir" -ForegroundColor White
        }
    } else {
        Write-Host "`n请手动下载并安装 WMF 5.1:" -ForegroundColor Yellow
        Write-Host "  https://www.microsoft.com/en-us/download/details.aspx?id=54616" -ForegroundColor White
        Start-Process "https://www.microsoft.com/en-us/download/details.aspx?id=54616"
    }
    Write-Host "[重要] 全部前置依赖已安装, 请重启电脑后重新运行此脚本" -ForegroundColor Yellow
    pause
    exit 1
}

$TaskName = "SMBForword_Client_Core"
if (-not $env:ProgramData) { $PSToolboxPath = "C:\ProgramData\SMBForword" } else { $PSToolboxPath = "$env:ProgramData\SMBForword" }
$CoreScriptPath = "$PSToolboxPath\SMBForword_Core.ps1"
$ConfigPath = "$PSToolboxPath\config.json"
$LogPath = "$PSToolboxPath\engine.log"
$LocalPort = 445
$VirtualIP = "10.10.10.10"
$FirewallRuleName = "SMBForword-Client-Local-445"
$AdapterName = "SMBProxy"

# === 通用辅助函数 ===
function Get-WmiAdapter {
    param([string]$Name)
    if ($Name) {
        return Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.NetConnectionID -eq $Name } | Select-Object -First 1
    }
    return $null
}

function Get-WmiAdapterByDesc {
    param([string]$Pattern)
    return Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object {
        ($_.Description -like $Pattern) -and $_.NetConnectionID
    } | Select-Object -First 1
}

function Show-Menu {
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     SMB 端口转发 - Server 菜单 (v3.1-2008R2)     " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  入口地址: \\$VirtualIP" -ForegroundColor Green
    Write-Host ""

    $taskResult = cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [状态] 后台任务: 已安装" -ForegroundColor Green
        $proc = Get-CoreEngineProcess
        if ($proc) {
            Write-Host "  [状态] 核心引擎: 运行中 (PID: $($proc.ProcessId))" -ForegroundColor Green
        } else {
            Write-Host "  [状态] 核心引擎: 已停止" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [状态] 后台任务: 未安装" -ForegroundColor Gray
    }
    Write-Host ""

    Write-Host "[1] 安装/更新 远程代理 (首次使用选这个)" -ForegroundColor Green
    Write-Host "[2] 停止代理并恢复本机SMB" -ForegroundColor Yellow
    Write-Host "[3] 查看运行日志 (排障用)" -ForegroundColor Cyan
    Write-Host "[4] 退出" -ForegroundColor Gray
}

# === 进程辅助函数 ===
function Get-CoreEngineProcess {
    Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$CoreScriptPath*" }
}

function Stop-CoreEngine {
    $procs = Get-CoreEngineProcess
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($procs) { Start-Sleep -Milliseconds 500 }
}

# === 虚拟网卡: Win7 使用 WMI + netsh, 与 Win10 版本功能一致 ===

function Install-ForwardSMBAdapter {
    # 辅助: 用 netsh 重命名网卡
    function Set-AdapterName {
        param($OldName, $NewName)
        if (-not $OldName -or $OldName -eq $NewName) { return $true }
        $result = netsh interface set interface name="$OldName" newname="$NewName" 2>&1
        return ($LASTEXITCODE -eq 0)
    }

    # 检查已存在的 forwardSMB
    $existing = Get-WmiAdapter -Name $AdapterName
    if ($existing) {
        if ($existing.NetConnectionStatus -ne 2) {
            Write-Host "[信息] 虚拟网卡 $AdapterName 未启用, 正在启用..." -ForegroundColor DarkCyan
            $result = $existing.Enable()
            Start-Sleep -Seconds 1
            $existing = Get-WmiAdapter -Name $AdapterName
            if ($existing -and $existing.NetConnectionStatus -eq 2) {
                Write-Host "[OK] 已启用" -ForegroundColor Green
            } else {
                Write-Host "[警告] 启用可能未生效, 请检查设备管理器" -ForegroundColor Yellow
            }
        }
        return $existing.Index
    }

    # --- 多方法搜索未命名的 Loopback 网卡 ---
    $foundName = $null
    $foundIndex = $null

    # 方法A: WMI 按描述搜索 (语言无关: Loopback / 环回 / KM-TEST)
    $match = Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object {
        ($_.Description -like "*Loopback*" -or $_.Description -like "*环回*" -or $_.Description -like "*KM-TEST*") -and
        $_.NetConnectionID -notlike "Loopback Pseudo-Interface*" -and
        $_.NetConnectionID -ne $AdapterName -and
        $_.NetConnectionID
    } | Select-Object -First 1
    if ($match) { $foundName = $match.NetConnectionID; $foundIndex = $match.Index }

    if ($foundName) {
        Write-Host "[信息] 检测到 Loopback 网卡: $foundName" -ForegroundColor DarkCyan
        if (Set-AdapterName -OldName $foundName -NewName $AdapterName) {
            Write-Host "[OK] 已重命名为 $AdapterName" -ForegroundColor Green
            $na = Get-WmiAdapter -Name $AdapterName
            if ($na) {
                if ($na.NetConnectionStatus -ne 2) {
                    Write-Host "[信息] 虚拟网卡 $AdapterName 未启用, 正在启用..." -ForegroundColor DarkCyan
                    $na.Enable() | Out-Null
                    Start-Sleep -Seconds 1
                }
                return $na.Index
            }
            if ($foundIndex) { return $foundIndex }
        }
        Write-Host "[警告] 自动重命名失败, 请手动在设备管理器中重命名为 '$AdapterName' 后重新运行" -ForegroundColor Yellow
        pause; exit 1
    }

    # 首次安装: 引导用户手动操作 (仅需一次)
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  首次使用需要手动安装 Microsoft Loopback Adapter (仅此一次):" -ForegroundColor Yellow
    Write-Host "  1. 在弹出的窗口中点 [下一步]" -ForegroundColor White
    Write-Host "  2. 选择 [安装我手动从列表选择的硬件] → [下一步]" -ForegroundColor White
    Write-Host "  3. 选 [网络适配器] → [下一步]" -ForegroundColor White
    Write-Host "  4. 厂商选 [Microsoft], 型号选 [Microsoft Loopback Adapter]" -ForegroundColor White
    Write-Host "     (Win7 的型号名称不含 KM-TEST, 如同时有 KM-TEST 也选它)" -ForegroundColor Gray
    Write-Host "  5. [下一步] → [下一步] → 完成" -ForegroundColor White
    Write-Host "  6. 回到本窗口按任意键, 脚本将自动接管该网卡" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Yellow

    # 保存安装前的多数据源快照
    $snapWMI = @(Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue | ForEach-Object { $_.GUID })
    $snapNetsh = netsh interface show interface 2>$null | Out-String

    Start-Process hdwwiz.exe
    pause

    # 轮询寻找新创建的 Loopback 网卡
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1

        $allWMI = @(Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue)
        $newWMI = $allWMI | Where-Object { ($snapWMI -notcontains $_.GUID) -and ($_.NetConnectionID -ne $AdapterName) -and $_.NetConnectionID } | Select-Object -First 1
        if ($newWMI) {
            Write-Host "[信息] 发现新网卡: $($newWMI.NetConnectionID) ($($newWMI.Description))" -ForegroundColor DarkCyan
            if (Set-AdapterName -OldName $newWMI.NetConnectionID -NewName $AdapterName) {
                Write-Host "[OK] 虚拟网卡 $AdapterName 创建成功" -ForegroundColor Green
                $na = Get-WmiAdapter -Name $AdapterName
                if ($na) { return $na.Index }
                return $newWMI.Index
            }
        }

        if (Get-WmiAdapter -Name $AdapterName) { break }
    }

    # 已成功注册的检查
    $na = Get-WmiAdapter -Name $AdapterName
    if ($na) {
        Write-Host "[OK] 虚拟网卡 $AdapterName 已就绪" -ForegroundColor Green
        return $na.Index
    }

    # 兜底: netsh 文本对比 + PnP 设备查询
    $nowNetsh = netsh interface show interface 2>$null | Out-String
    if ($nowNetsh -ne $snapNetsh) {
        Write-Host "[信息] netsh 检测到接口变更, 但自动接管失败" -ForegroundColor Yellow
        Write-Host "  请手动在设备管理器中将新出现的网卡重命名为 '$AdapterName'" -ForegroundColor White
        Write-Host "  然后重新运行本脚本" -ForegroundColor White
        pause; exit 1
    }

    $pnp = Get-WmiObject Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -like "*Loopback*" -or $_.Name -like "*环回*" -or
         $_.Name -like "*KM-TEST*" -or $_.Name -like "*MSLOOP*")
    } | Select-Object -First 1
    if ($pnp) {
        Write-Host "[信息] PnP 检测到设备: $($pnp.Name)" -ForegroundColor Yellow
        Write-Host "  但无法通过脚本自动配置, 请手动在设备管理器中重命名为 '$AdapterName'" -ForegroundColor White
        Write-Host "  然后重新运行本脚本" -ForegroundColor White
        pause; exit 1
    }

    Write-Host "[错误] 未检测到新创建的 Loopback 网卡, 请确认安装是否成功" -ForegroundColor Red
    pause; exit 1
}

function Remove-ForwardSMBAdapter {
    $adapter = Get-WmiAdapter -Name $AdapterName
    if (-not $adapter) {
        Write-Host "[信息] 未找到虚拟网卡 $AdapterName" -ForegroundColor Gray
        return
    }

    Write-Host "正在移除虚拟网卡 $AdapterName ..." -ForegroundColor Yellow

    # 移除该网卡上的 IP
    Write-Host "  移除虚拟IP..." -ForegroundColor DarkCyan
    netsh interface ip delete address name="$AdapterName" addr=$VirtualIP 2>$null | Out-Null

    # 禁用网卡
    Write-Host "  禁用网卡..." -ForegroundColor DarkCyan
    try {
        $result = $adapter.Disable()
        if ($result.ReturnValue -eq 0) {
            Write-Host "[OK] 虚拟网卡 $AdapterName 已禁用" -ForegroundColor Green
        } else {
            Write-Host "[警告] 禁用返回码: $($result.ReturnValue)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[警告] 禁用异常: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Win7 WMI 不支持直接卸载硬件, 引导用户手动操作
    Write-Host "  如需彻底删除, 请在设备管理器中右键 '$AdapterName' 选择卸载" -ForegroundColor Gray
}

# === 本机防火墙: Win7 全部使用 netsh advfirewall ===

function Add-LocalFirewallRule {
    Write-Host "正在配置本机防火墙放行规则 (仅限 ${VirtualIP}:${LocalPort})..." -ForegroundColor DarkCyan

    # 先尝试删除再添加 (netsh 无原生 exist 判定, 避免语言依赖)
    netsh advfirewall firewall delete rule name="$FirewallRuleName" 2>$null | Out-Null
    $result = netsh advfirewall firewall add rule name="$FirewallRuleName" dir=in action=allow protocol=TCP localport=$LocalPort localip=$VirtualIP 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] 防火墙规则添加成功" -ForegroundColor Green
    } else {
        Write-Host "[警告] 防火墙规则添加失败: $result" -ForegroundColor Yellow
    }
}

function Remove-LocalFirewallRule {
    netsh advfirewall firewall delete rule name="$FirewallRuleName" 2>$null | Out-Null
}

# === 设置虚拟IP并释放445端口 ===
function Check-And-Fix-Environment {
    Write-Host "`n[环境检查] 清理残留的核心引擎进程..." -ForegroundColor Cyan
    Stop-CoreEngine

    Write-Host "`n[环境检查] 检查本机445端口环境..." -ForegroundColor Cyan

    $srvnet = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ErrorAction SilentlyContinue
    $lanman = Get-Service -Name LanmanServer -ErrorAction SilentlyContinue

    $srvnetDisabled = ($srvnet -and $srvnet.Start -eq 4)
    $lanmanNotAuto = ($lanman -and $lanman.StartType -ne "Automatic")

    if (-not $srvnetDisabled -or ($lanman -and -not $lanmanNotAuto)) {
        Write-Host "检测到本机SMB驱动或LanmanServer正在占用445端口" -ForegroundColor Yellow
        Write-Host "正在禁用本地服务以释放445端口..." -ForegroundColor DarkCyan

        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 4
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 4 -ErrorAction SilentlyContinue
        Set-Service -Name LanmanServer -StartupType Disabled
        try { Stop-Service -Name LanmanServer -Force } catch {}

        $hiberboot = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ErrorAction SilentlyContinue
        if (-not $hiberboot -or $hiberboot.HiberbootEnabled -ne 0) {
            Write-Host "正在关闭 Windows 快速启动 (避免重启后 445 端口仍被占用)..." -ForegroundColor DarkCyan
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -ErrorAction SilentlyContinue
            Write-Host "[OK] 快速启动已关闭, 下次重启将完整重载驱动" -ForegroundColor Green
        } else {
            Write-Host "[OK] 快速启动已关闭 (HiberbootEnabled = 0)" -ForegroundColor Green
        }

        Write-Host "`n==========================================================" -ForegroundColor Red
        Write-Host " [重要] 本机SMB驱动已禁用!" -ForegroundColor Yellow
        Write-Host " 由于Windows内核限制, 必须[重启电脑]后生效" -ForegroundColor Yellow
        Write-Host " 重启后请重新运行此脚本, 选择 [1] 继续安装" -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Red
        pause
        exit
    }

    Write-Host "`n[环境检查] 部署虚拟网卡 ($AdapterName) 并绑定 IP ($VirtualIP)..." -ForegroundColor Cyan
    $ifIndex = Install-ForwardSMBAdapter

    # 检查 IP 是否已绑定 (用 netsh 文本匹配, 语言无关)
    $ipCheck = netsh interface ip show addresses "$AdapterName" 2>$null | Out-String
    $hasIP = ($ipCheck -match [regex]::Escape($VirtualIP))
    if (-not $hasIP) {
        # 清理可能残留在其他网卡上的旧 IP
        netsh interface ip delete address "$AdapterName" addr=$VirtualIP 2>$null | Out-Null

        Write-Host "正在将 $VirtualIP 绑定到网卡: $AdapterName" -ForegroundColor DarkCyan
        $addResult = netsh interface ip add address name="$AdapterName" addr=$VirtualIP mask=255.255.255.255 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[错误] 绑定IP失败: $addResult" -ForegroundColor Red
            # 尝试其他方式
            $addResult2 = netsh interface ipv4 add address name="$AdapterName" addr=$VirtualIP mask=255.255.255.255 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[错误] IPv4 绑定也失败: $addResult2" -ForegroundColor Red
            }
        }
        Write-Host "[OK] 虚拟IP $VirtualIP 已绑定" -ForegroundColor Green
    } else {
        Write-Host "[OK] 虚拟IP $VirtualIP 已激活" -ForegroundColor Green
    }

    $inUse = netstat -ano | Select-String "LISTENING" | Select-String ":${LocalPort}\s"
    if ($inUse) {
        Write-Host "[错误] 445端口仍被占用! 是否已重启电脑?" -ForegroundColor Red
        Write-Host $inUse
        pause; exit 1
    }

    Write-Host "`n[环境检查] 配置本机防火墙..." -ForegroundColor Cyan
    Add-LocalFirewallRule

    Write-Host "[OK] 环境就绪, 可以建立代理桥接" -ForegroundColor Green
}

# === 生成后台核心引擎脚本 (与 Win10/11 版完全一致) ===
function Write-CoreEngineScript {
    $header = @"
`$ConfigPath = '$ConfigPath'
`$LogPath = '$LogPath'
`$LocalPort = $LocalPort
`$VirtualIP = '$VirtualIP'
"@

    $body = @'
$ErrorActionPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
        $logFile = Get-Item $LogPath -ErrorAction SilentlyContinue
        if ($logFile -and $logFile.Length -gt 5MB) {
            Set-Content -Path $LogPath -Value $line -Encoding UTF8
        }
    } catch {}
}

function Resolve-RemoteEndpoint {
    param([string]$Domain)
    $results = @()
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Domain)
        $v6 = $addrs | Where-Object { $_.AddressFamily -eq "InterNetworkV6" } | Select-Object -First 1
        if ($v6) { $results += @{ IP = $v6.IPAddressToString; Family = "InterNetworkV6" } }
        $v4 = $addrs | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
        if ($v4) { $results += @{ IP = $v4.IPAddressToString; Family = "InterNetwork" } }
    } catch {
        Write-Log ("[DNS] GetHostAddresses({0}) 异常: {1}" -f $Domain, $_.Exception.Message)
        # Win7 无 Resolve-DnsName, 仅依赖 GetHostAddresses 重试
    }
    return $results
}

function Start-Pump {
    param($srcClient, $dstClient)
    try {
        $srcStream = $srcClient.GetStream()
        $dstStream = $dstClient.GetStream()
        $task = $srcStream.CopyToAsync($dstStream, 65536)
        $continuation = {
            param($t)
            try { $srcClient.Close() } catch {}
            try { $dstClient.Close() } catch {}
        }.GetNewClosure()
        $task.ContinueWith([Action[System.Threading.Tasks.Task]]$continuation) | Out-Null
    } catch {
        try { $srcClient.Close() } catch {}
        try { $dstClient.Close() } catch {}
    }
}

Write-Log "===== 核心引擎启动 ====="

$conf = $null
for ($i = 0; $i -lt 10; $i++) {
    if (Test-Path $ConfigPath) {
        try { $conf = Get-Content $ConfigPath -Raw | ConvertFrom-Json; break } catch {}
    }
    Start-Sleep -Seconds 2
}
if (-not $conf) { Write-Log "配置文件读取失败, 引擎退出"; exit 1 }

$Domain = $conf.Domain
$RPort = [int]$conf.Port

$endpoints = @()
for ($i = 0; $i -lt 30; $i++) {
    $endpoints = @(Resolve-RemoteEndpoint -Domain $Domain)
    if ($endpoints.Count -gt 0) { break }
    Write-Log ("[DNS] 解析({0})尚未成功, 5秒后重试 ({1}/30)" -f $Domain, ($i + 1))
    Start-Sleep -Seconds 5
}
if ($endpoints.Count -eq 0) { Write-Log ("多次DNS解析({0})均失败(开机时网络可能还未就绪), 引擎退出, 等待下次计划任务重启" -f $Domain); exit 1 }
$endpointLog = ($endpoints | ForEach-Object { "{0}({1})" -f $_.IP, ($_.Family -replace "InterNetworkV6","V6" -replace "InterNetwork","V4") }) -join ", "
Write-Log ("DNS解析成功: {0} -> [{1}]" -f $Domain, $endpointLog)

$server = $null
for ($i = 0; $i -lt 10; $i++) {
    try {
        $server = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($VirtualIP), $LocalPort)
        $server.Start()
        break
    } catch {
        Write-Log ("监听 {0}:{1} 失败: {2}, 5秒后重试" -f $VirtualIP, $LocalPort, $_.Exception.Message)
        $server = $null
        Start-Sleep -Seconds 5
    }
}
if (-not $server) { Write-Log "多次尝试仍无法监听端口, 引擎退出"; exit 1 }
Write-Log ("已开始监听 {0}:{1}" -f $VirtualIP, $LocalPort)

$lastResolve = Get-Date
$resolveIntervalSec = 10
$activeIndex = 0

while ($true) {
    try {
        if (((Get-Date) - $lastResolve).TotalSeconds -ge $resolveIntervalSec) {
            $newEndpoints = @(Resolve-RemoteEndpoint -Domain $Domain)
            if ($newEndpoints.Count -gt 0) {
                $oldIPs = ($endpoints | ForEach-Object { $_.IP }) -join ","
                $newIPs = ($newEndpoints | ForEach-Object { $_.IP }) -join ","
                if ($oldIPs -ne $newIPs) {
                    Write-Log ("检测到DDNS地址变更: [{0}] -> [{1}]" -f $oldIPs, $newIPs)
                    $endpoints = $newEndpoints
                    $activeIndex = 0
                }
            }
            $lastResolve = Get-Date
        }

        if (-not $server.Pending()) {
            Start-Sleep -Milliseconds 200
            continue
        }

        $client = $server.AcceptTcpClient()
        $remote = $null
        $startIdx = $activeIndex
        for ($try = 0; $try -lt $endpoints.Count; $try++) {
            $idx = ($startIdx + $try) % $endpoints.Count
            $ep = $endpoints[$idx]
            try {
                $ipAddr = [System.Net.IPAddress]::Parse($ep.IP)
                $remote = New-Object System.Net.Sockets.TcpClient($ipAddr.AddressFamily)
                $remote.Connect($ipAddr, $RPort)
                $activeIndex = $idx
                break
            } catch {
                Write-Log ("连接 {0}({1}):{2} 失败: {3}" -f $ep.IP, ($ep.Family -replace "InterNetworkV6","V6" -replace "InterNetwork","V4"), $RPort, $_.Exception.Message)
                if ($remote) { try { $remote.Close() } catch {} }
                $remote = $null
            }
        }
        if (-not $remote) {
            Write-Log ("所有地址均无法连接, 丢弃此客户端连接")
            $client.Close()
            continue
        }

        Write-Log ("新连接已建立 -> {0}:{1} ({2})" -f $endpoints[$activeIndex].IP, $RPort, ($endpoints[$activeIndex].Family -replace "InterNetworkV6","V6" -replace "InterNetwork","V4"))
        Start-Pump -srcClient $client -dstClient $remote
        Start-Pump -srcClient $remote -dstClient $client
    } catch {
        Write-Log ("主循环异常: {0}" -f $_.Exception.Message)
        Start-Sleep -Seconds 2
    }
}
'@

    $fullCode = $header + "`r`n" + $body
    Set-Content -Path $CoreScriptPath -Value $fullCode -Encoding UTF8
}

# === 菜单1: 引导安装 ===
function Install-Client-Proxy {
    Check-And-Fix-Environment

    Write-Host "`n[配置] 远程服务器信息..." -ForegroundColor Cyan

    $defaultDomain = ""
    $defaultPort = "1445"
    if (Test-Path $ConfigPath) {
        try {
            $conf = Get-Content $ConfigPath | ConvertFrom-Json
            $defaultDomain = $conf.Domain
            $defaultPort = $conf.Port
        } catch {}
    }

    if ($defaultDomain) {
        $inputDomain = Read-Host "输入远程DDNS域名 (直接回车使用: $defaultDomain)"
    } else {
        $inputDomain = Read-Host "输入远程DDNS域名 (例如: mynas.dns.com)"
    }
    if (-not $inputDomain) { $inputDomain = $defaultDomain }
    if (-not $inputDomain) { Write-Host "域名不能为空!" -ForegroundColor Red; pause; return }

    Write-Host "`n[DNS预检] 正在解析域名: $inputDomain ..." -ForegroundColor Cyan
    $dnsOK = $false
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($inputDomain)
        $v6 = $addrs | Where-Object { $_.AddressFamily -eq "InterNetworkV6" } | Select-Object -First 1
        $v4 = $addrs | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
        if ($v6) { Write-Host "[DNS预检] 解析成功 (IPv6): $($v6.IPAddressToString)" -ForegroundColor Green; $dnsOK = $true }
        if ($v4) { Write-Host "[DNS预检] 解析成功 (IPv4): $($v4.IPAddressToString)" -ForegroundColor Green; $dnsOK = $true }
    } catch {}
    if (-not $dnsOK) {
        Write-Host "[DNS预检] 警告: 无法解析域名 '$inputDomain', 请确认域名正确且DDNS已生效" -ForegroundColor Yellow
        Write-Host "  引擎将在后台持续重试DNS解析, 若DDNS稍后生效可自动恢复" -ForegroundColor Gray
        Write-Host "  若域名本身错误, 请重新运行安装并输入正确域名" -ForegroundColor Gray
    }

    $inputPort = Read-Host "`n输入远程端口号 (直接回车使用: $defaultPort)"
    if (-not $inputPort) { $inputPort = $defaultPort }
    $portNum = 0
    if (-not ([int]::TryParse($inputPort, [ref]$portNum) -and $portNum -ge 1 -and $portNum -le 65535)) {
        Write-Host "端口号无效 (必须是 1-65535 之间的整数), 已取消" -ForegroundColor Red; pause; return
    }

    if (-not (Test-Path $PSToolboxPath)) { New-Item -ItemType Directory -Path $PSToolboxPath | Out-Null }
    @{ Domain = $inputDomain; Port = $portNum } | ConvertTo-Json | Set-Content $ConfigPath

    Write-Host "`n[部署] 正在写入后台核心引擎..." -ForegroundColor Cyan
    Write-CoreEngineScript

    # === 计划任务: Win7 使用 schtasks (不支持崩溃自动重启) ===
    Write-Host "`n[任务] 创建系统自启任务..." -ForegroundColor Cyan
    Write-Host "[信息] Server 2008 R2 计划任务不支持崩溃自动重启, 依赖引擎内部自愈" -ForegroundColor Gray

    $taskAction = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$CoreScriptPath`""
    $schtasksResult = cmd /c "schtasks /create /tn `"$TaskName`" /tr `"$taskAction`" /sc onstart /ru SYSTEM /rl HIGHEST /delay 00:20 /f 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[错误] 创建计划任务失败: $schtasksResult" -ForegroundColor Red
        Write-Host "  请尝试以管理员身份手动创建" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] 计划任务已创建 (开机延迟 20s 自启)" -ForegroundColor Green
    }

    Stop-CoreEngine
    Start-Process -FilePath "powershell.exe" -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$CoreScriptPath`"" -WindowStyle Hidden

    $check = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $check = netstat -ano | Select-String "${VirtualIP}:${LocalPort}"
        if ($check) { break }
    }

    Write-Host "`n=====================================================" -ForegroundColor Green
    Write-Host "  客户端代理配置完成!" -ForegroundColor Green
    Write-Host "  远程目标: [$inputDomain]:$inputPort" -ForegroundColor White

    if ($check) {
        Write-Host "  [状态] 引擎已启动, 端口监听正常" -ForegroundColor Green
    } else {
        Write-Host "  [警告] 端口未检测到监听, 请用菜单 [3] 查看日志排查原因: $LogPath" -ForegroundColor Yellow
    }

    Write-Host "  使用方法 (绕过回环限制):" -ForegroundColor Green
    Write-Host "     Win+R 打开运行, 输入: \\$VirtualIP" -ForegroundColor Yellow
    Write-Host "     或在文件管理器地址栏输入: \\$VirtualIP\共享名" -ForegroundColor Yellow
    Write-Host "=====================================================" -ForegroundColor Green
    pause
}

# === 菜单2: 停止并清理 ===
function Remove-And-Restore {
    Write-Host "`n正在停止代理进程并移除计划任务..." -ForegroundColor Yellow

    $taskExists = cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null
    if ($LASTEXITCODE -eq 0) {
        cmd /c "schtasks /delete /tn `"$TaskName`" /f 2>nul" 2>$null | Out-Null
        Write-Host "[OK] 计划任务已移除" -ForegroundColor Green
    }

    Stop-CoreEngine
    Write-Host "[OK] 代理进程已终止" -ForegroundColor Green

    Write-Host "正在移除虚拟IP ($VirtualIP)..." -ForegroundColor Yellow
    netsh interface ip delete address name="$AdapterName" addr=$VirtualIP 2>$null | Out-Null

    Write-Host "正在移除虚拟网卡 ($AdapterName)..." -ForegroundColor Yellow
    Remove-ForwardSMBAdapter

    Write-Host "正在移除防火墙规则..." -ForegroundColor Yellow
    Remove-LocalFirewallRule

    Write-Host "正在恢复Windows默认SMB服务..." -ForegroundColor Yellow
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 3
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 3 -ErrorAction SilentlyContinue
    Set-Service -Name LanmanServer -StartupType Automatic
    try { Start-Service -Name LanmanServer } catch {}

    if (Test-Path $PSToolboxPath) { Remove-Item -Path $PSToolboxPath -Recurse -Force }

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  已成功恢复Windows默认SMB设置!" -ForegroundColor Green
    Write-Host "  [提示] 建议[重启电脑]以使所有更改完全生效" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Green
    pause
}

# === 菜单3: 查看日志 ===
function Show-EngineLog {
    Write-Host "`n=== 最近日志: $LogPath ===" -ForegroundColor Cyan
    if (Test-Path $LogPath) {
        Get-Content -Path $LogPath -Tail 50
    } else {
        Write-Host "(暂无日志, 引擎可能从未成功运行过, 请先执行 [1] 安装)" -ForegroundColor Gray
    }
    Write-Host ""
    pause
}

# === 主循环 ===
do {
    Show-Menu
    $choice = Read-Host "`n请选择操作 (1-4)"
    switch ($choice) {
        "1" { Install-Client-Proxy }
        "2" { Remove-And-Restore }
        "3" { Show-EngineLog }
        "4" { exit }
    }
} while ($true)
