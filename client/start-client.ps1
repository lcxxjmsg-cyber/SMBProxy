<#
    SMBProxy 客户端一键引导脚本 (start-client.ps1)

    职责:
      1. 自动提权 (UAC) 到管理员
      2. 判定 Windows 版本 → 分流到对应 setup-client 脚本
      3. 安装脚本"在线获取 + 内存执行" (iex, 不落地磁盘)
      4. Win7 / 2008R2 所需离线插件缓存到固定临时目录, 供带重启的安装流程使用
      5. 智能续跑: 安装过程需要 1~3 次重启, 通过登录自启计划任务自动接续
      6. 环境判定: 依赖 / SMB 状态判断当前处于哪个阶段
      7. 全流程结束 (环境就绪) 后: 移除自启任务 + 清理缓存插件

    阶段模型:
      A. 依赖未装 (仅 Win7/2008R2)  → 缓存插件 → 注册续跑任务 → 运行安装(装依赖) → 提示重启
      B. 依赖已装 / SMB 未禁用       → 注册续跑任务 → 运行安装(禁 SMB) → 提示重启
      C. 依赖已装 / SMB 已禁用(就绪) → 移除续跑任务 → 清理插件 → 运行安装(进入菜单)

    用法:
      irm https://raw.githubusercontent.com/lcxxjmsg-cyber/SMBProxy/main/client/start-client.ps1 | iex
#>

# ============ 配置区 ============
$GitHubUser   = 'lcxxjmsg-cyber'
$GitHubRepo   = 'SMBProxy'
$GitHubBranch = 'main'
# ================================

$RawBase   = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/client"
$StartUrl  = "$RawBase/start-client.ps1"
$TaskName  = 'SMBProxy_ClientBootstrap'
$cacheRoot = Join-Path $env:TEMP 'SMBProxy'   # 插件缓存 (含重启, 故保留至就绪后清理)

# ---- 强制 TLS 1.2 (GitHub 要求) ----
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- 提权: 若非管理员则以管理员身份重新拉起 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[*] 正在请求管理员权限..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-Command',
            "irm $StartUrl | iex"
        )
    } catch {
        Write-Host "[错误] 提权被取消或失败, 无法继续。" -ForegroundColor Red
    }
    return
}

# ================= 工具函数 =================
function Register-ContinueTask {
    # 登录时自动续跑: 省略 /ru → 以当前登录用户交互式运行(免密码);
    # /rl HIGHEST → 提升权限, 重启后免 UAC 自动继续
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command "irm ' + $StartUrl + ' | iex"'
    schtasks.exe /create /tn $TaskName /tr $tr /sc onlogon /rl HIGHEST /f 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "[*] 已注册重启续跑任务 ($TaskName)" -ForegroundColor DarkGray }
    else { Write-Host "[警告] 续跑任务注册失败, 重启后请手动再次运行本命令。" -ForegroundColor Yellow }
}
function Remove-ContinueTask {
    $q = schtasks.exe /query /tn $TaskName 2>$null
    if ($LASTEXITCODE -eq 0) {
        schtasks.exe /delete /tn $TaskName /f 2>$null | Out-Null
        Write-Host "[*] 已移除重启续跑任务" -ForegroundColor DarkGray
    }
}
function Clear-PluginCache {
    if (Test-Path $cacheRoot) {
        Remove-Item $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[*] 已清理缓存插件: $cacheRoot" -ForegroundColor DarkGray
    }
}
function Test-SmbDisabled {
    # srvnet Start=4 表示"禁用 SMB + 关快速启动"阶段已完成
    $s = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ea SilentlyContinue
    return ($s -and $s.Start -eq 4)
}
function Test-DepsReady {
    # 仅 Win7/2008R2 需要: SHA-2 补丁 + .NET 4.5+ + WMF 5.1(PS>=5)
    if (-not (Get-HotFix -Id KB4490628 -ea SilentlyContinue)) { return $false }
    if (-not (Get-HotFix -Id KB4474419 -ea SilentlyContinue)) { return $false }
    $net = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ea SilentlyContinue
    if (-not $net -or $net.Release -lt 378389) { return $false }
    if ($PSVersionTable.PSVersion.Major -lt 5) { return $false }
    return $true
}
function Get-File($url, $dest) {
    Write-Host "    下载 $([IO.Path]::GetFileName($dest)) ..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}
function Ensure-Plugins($plugDir, $plugFiles) {
    $plugPath = Join-Path $cacheRoot $plugDir
    New-Item -ItemType Directory -Path $plugPath -Force | Out-Null
    Write-Host "[*] 缓存离线插件到: $plugPath" -ForegroundColor Yellow
    Write-Host "    (文件较大, 请耐心等待; 已缓存的将跳过)" -ForegroundColor DarkGray
    foreach ($f in $plugFiles) {
        $target = Join-Path $plugPath $f
        if ((Test-Path $target) -and ((Get-Item $target).Length -gt 0)) {
            Write-Host "    已存在 $f, 跳过" -ForegroundColor DarkGray; continue
        }
        Get-File "$RawBase/$plugDir/$([Uri]::EscapeDataString($f))" $target
    }
}
function Invoke-Setup($script) {
    # 在线获取安装脚本文本, 修正脚本目录使其插件路径指向缓存目录, 内存执行 (不落地)
    Write-Host "[*] 在线获取安装脚本: $script" -ForegroundColor Yellow
    $text = Invoke-RestMethod -Uri "$RawBase/$([Uri]::EscapeDataString($script))" -UseBasicParsing
    $text = $text.Replace('Split-Path -Parent $MyInvocation.MyCommand.Path', "'$cacheRoot'")
    Write-Host ""
    Write-Host "[*] 启动: $script" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Invoke-Expression $text   # 注意: 安装脚本内部可能 exit, 之后代码不再执行
}

# ================= 主流程 =================
Write-Host ""
Write-Host "==================== SMBProxy 客户端引导 ====================" -ForegroundColor Cyan
Write-Host ""

# ---- 判定操作系统 ----
$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
if (-not $os) { $os = Get-WmiObject Win32_OperatingSystem }

$verParts = ($os.Version -split '\.')
$major    = [int]$verParts[0]
$minor    = [int]$verParts[1]
$isServer = ($os.ProductType -ne 1)   # 1=工作站, 2/3=服务器
$is64     = [Environment]::Is64BitOperatingSystem
$arch     = if ($is64) { 'x64' } else { 'x86' }

Write-Host "  系统名称 : $($os.Caption)"
Write-Host "  版本号   : $($os.Version)  ($(if($isServer){'服务器'}else{'工作站'}), $arch)"
Write-Host ""

# ---- 分流表 ----
$script    = $null
$plugDir   = $null
$plugFiles = @()

switch ($major) {
    10 {
        if ($isServer) { $script = 'setup-client-2016++.ps1' }   # Server 2016/2019/2022/2025
        else           { $script = 'setup-client-win10-11.ps1' } # Windows 10 / 11
    }
    6 {
        switch ($minor) {
            3 { if ($isServer) { $script = 'setup-client-2012-r2.ps1' } else { $script = 'setup-client-win8-1.ps1' } } # 8.1 / 2012 R2
            2 { if ($isServer) { $script = 'setup-client-2012-r2.ps1' } else { $script = 'setup-client-win8-1.ps1' } } # 8   / 2012
            1 {
                if ($isServer) { $script = 'setup-client-2008r2.ps1'; $plugDir = '2008r2plug' }  # Server 2008 R2
                else           { $script = 'setup-client-win7.ps1';   $plugDir = 'win7plug'   }  # Windows 7
            }
            0 { $script = $null }   # Vista / Server 2008(非R2) 不支持
        }
    }
    default { $script = $null }
}

if (-not $script) {
    Write-Host "[不支持] 当前系统不在支持列表中。" -ForegroundColor Red
    Write-Host "         支持: Win7/8/8.1/10/11, Server 2008R2/2012/2012R2/2016+" -ForegroundColor Red
    Write-Host "         不支持: Server 2008(非R2) / Vista / XP" -ForegroundColor Red
    Remove-ContinueTask   # 万一残留, 一并清除
    return
}

# ---- 插件清单 (按架构) ----
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

# ---- 环境判定 ----
$needsPlugin = [bool]$plugDir
$depsReady   = if ($needsPlugin) { Test-DepsReady } else { $true }
$smbDisabled = Test-SmbDisabled

Write-Host "  匹配脚本 : $script (在线执行, 不落地)" -ForegroundColor Green
Write-Host "  依赖状态 : $(if($depsReady){'已就绪'}else{'待安装 (需插件)'})" -ForegroundColor Green
Write-Host "  SMB 状态 : $(if($smbDisabled){'已禁用 (端口就绪)'}else{'未处理'})" -ForegroundColor Green
Write-Host ""

$rebootBanner = {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " [续跑已就绪] 本阶段完成后安装脚本会提示重启。" -ForegroundColor Yellow
    Write-Host " 请按其提示重启电脑, 重启并登录后将自动继续下一步。" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
}

try {
    if ($needsPlugin -and -not $depsReady) {
        # ---- 阶段 A: 安装依赖 (需插件, 之后重启) ----
        Write-Host "[阶段 A] 安装系统依赖 (SHA-2 / .NET 4.8 / WMF 5.1)" -ForegroundColor Magenta
        Ensure-Plugins $plugDir $plugFiles
        Register-ContinueTask
        & $rebootBanner
        Invoke-Setup $script
    }
    elseif (-not $smbDisabled) {
        # ---- 阶段 B: 禁用 SMB (之后重启) ----
        Write-Host "[阶段 B] 禁用系统 445 服务并关闭快速启动" -ForegroundColor Magenta
        Register-ContinueTask
        & $rebootBanner
        Invoke-Setup $script
    }
    else {
        # ---- 阶段 C: 环境就绪, 进入菜单 (无需重启) ----
        Write-Host "[阶段 C] 环境已就绪, 进入配置菜单" -ForegroundColor Magenta
        Remove-ContinueTask   # 全流程结束, 关闭自启
        Clear-PluginCache     # 依赖已装, 清理缓存插件
        Invoke-Setup $script
    }
}
catch {
    Write-Host ""
    Write-Host "[错误] 执行失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       如为下载/网络问题, 重试本命令即可 (已缓存内容不会重复下载)。" -ForegroundColor DarkGray
}
