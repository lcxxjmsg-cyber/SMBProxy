<#
.SYNOPSIS
     SMB 端口转发客户端 - Windows 8/8.1 专用版 (v3.1-win8)
.DESCRIPTION
     与 setup-client.ps1 (Win10/11 版) 功能相同。NetAdapter / 防火墙 / CIM 模块
     与 Win10 一致, 计划任务改用 schtasks 方案 (Win8 的 ScheduledTasks 模块
     对 RestartCount/ExecutionTimeLimit 等参数存在兼容性不确定性)。
     核心引擎完全一致。
#>

# === 管理员权限检测 (兼容 PS 3.0, 不用 #Requires) ===
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[错误] 请以管理员身份运行此脚本" -ForegroundColor Red
    pause
    exit 1
}

$ErrorActionPreference = "Stop"

# === 系统版本检测 ===
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if (-not $os) { $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue }
$isWin8 = ($os.Version -like "6.2.*" -or $os.Version -like "6.3.*")
if (-not $isWin8) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [错误] 此脚本仅适用于 Windows 8 / 8.1" -ForegroundColor Red
    Write-Host "  当前系统版本: $($os.Caption) ($($os.Version))" -ForegroundColor Yellow
    Write-Host "  Windows 10 / 11 请使用 setup-client.ps1" -ForegroundColor Yellow
    Write-Host "  Windows 7 请使用 setup-client-win7.ps1" -ForegroundColor Yellow
    Write-Host "====================================================" -ForegroundColor Red
    pause
    exit 1
}
Write-Host "[系统] 检测到 $($os.Caption) — 使用 Win8 兼容模式" -ForegroundColor Cyan

$TaskName = "SMBForword_Client_Core"
if (-not $env:ProgramData) { $PSToolboxPath = "C:\ProgramData\SMBForword" } else { $PSToolboxPath = "$env:ProgramData\SMBForword" }
$CoreScriptPath = "$PSToolboxPath\SMBForword_Core.ps1"
$ConfigPath = "$PSToolboxPath\config.json"
$LogPath = "$PSToolboxPath\engine.log"
$LocalPort = 445
$VirtualIP = "10.10.10.10"
$FirewallRuleName = "SMBForword-Client-Local-445"

function Show-Menu {
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     SMB 端口转发 - 客户端菜单 (v3.1-Win8)         " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  入口地址: \\$VirtualIP" -ForegroundColor Green
    Write-Host ""

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
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
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$CoreScriptPath*" }
}

function Stop-CoreEngine {
    $procs = Get-CoreEngineProcess
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($procs) { Start-Sleep -Milliseconds 500 }
}

# === 虚拟网卡 ===
$AdapterName = "SMBProxy"

function Install-ForwardSMBAdapter {
    function Rename-AdapterHelper {
        param($OldName, $NewName)
        try {
            $na = Get-NetAdapter -Name $OldName -ErrorAction SilentlyContinue
            if ($na) { Rename-NetAdapter -Name $OldName -NewName $NewName -ErrorAction Stop; return $true }
        } catch {}
        $result = netsh interface set interface name="$OldName" newname="$NewName" 2>&1
        return ($LASTEXITCODE -eq 0)
    }

    $existing = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Status -ne "Up") {
            try { Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Seconds 1
        }
        return $existing.InterfaceIndex
    }

    $foundName = $null
    $foundIndex = $null

    # Win8.0 可能缺少 -IncludeHidden 参数, try/catch 兜底
    try {
        $naList = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
    } catch {
        $naList = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    }
    $match = $naList | Where-Object {
        ($_.InterfaceDescription -like "*Loopback*" -or $_.InterfaceDescription -like "*环回*") -and
        $_.Name -notlike "Loopback Pseudo-Interface*" -and $_.Name -ne $AdapterName
    } | Select-Object -First 1
    if ($match) { $foundName = $match.Name; $foundIndex = $match.InterfaceIndex }

    if (-not $foundName) {
        $cim = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object {
            ($_.Description -like "*Loopback*" -or $_.Description -like "*环回*" -or $_.Description -like "*KM-TEST*") -and
            $_.NetConnectionID -notlike "Loopback Pseudo-Interface*" -and $_.NetConnectionID -ne $AdapterName -and
            $_.NetConnectionID
        } | Select-Object -First 1
        if ($cim) { $foundName = $cim.NetConnectionID; $foundIndex = $cim.Index }
    }

    if ($foundName) {
        Write-Host "[信息] 检测到 Loopback 网卡: $foundName" -ForegroundColor DarkCyan
        if (Rename-AdapterHelper -OldName $foundName -NewName $AdapterName) {
            Write-Host "[OK] 已重命名为 $AdapterName" -ForegroundColor Green
            $na = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
            if ($na) {
                if ($na.Status -ne "Up") {
                    try { Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                    Start-Sleep -Seconds 1
                }
                return $na.InterfaceIndex
            }
            if ($foundIndex) { return $foundIndex }
        }
        Write-Host "[警告] 自动重命名失败, 请手动在设备管理器中重命名为 '$AdapterName' 后重新运行" -ForegroundColor Yellow
        pause; exit 1
    }

    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  首次使用需要手动安装 Microsoft Loopback Adapter (仅此一次):" -ForegroundColor Yellow
    Write-Host "  1. 在弹出的窗口中点 [下一步]" -ForegroundColor White
    Write-Host "  2. 选择 [安装我手动从列表选择的硬件] → [下一步]" -ForegroundColor White
    Write-Host "  3. 选 [网络适配器] → [下一步]" -ForegroundColor White
    Write-Host "  4. 厂商选 [Microsoft], 型号选 [Microsoft KM-TEST Loopback Adapter]" -ForegroundColor White
    Write-Host "  5. [下一步] → [下一步] → 完成" -ForegroundColor White
    Write-Host "  6. 回到本窗口按任意键, 脚本将自动接管该网卡" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Yellow

    try {
        $snapNA = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | ForEach-Object { $_.InterfaceGuid })
    } catch {
        $snapNA = @(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceGuid })
    }
    $snapCIM = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | ForEach-Object { $_.GUID })
    $snapNetsh = netsh interface show interface 2>$null | Out-String

    Start-Process hdwwiz.exe
    pause

    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1

        try {
            $allNA = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
        } catch {
            $allNA = @(Get-NetAdapter -ErrorAction SilentlyContinue)
        }
        $newNA = $allNA | Where-Object { $_.InterfaceGuid -notin $snapNA -and $_.Name -ne $AdapterName } | Select-Object -First 1
        if ($newNA) {
            Write-Host "[信息] 发现新网卡: $($newNA.Name)" -ForegroundColor DarkCyan
            if (Rename-AdapterHelper -OldName $newNA.Name -NewName $AdapterName) {
                Write-Host "[OK] 虚拟网卡 $AdapterName 创建成功" -ForegroundColor Green
                $na = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
                if ($na) { return $na.InterfaceIndex }
                return $newNA.InterfaceIndex
            }
        }

        if (-not (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue)) {
            $allCIM = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue)
            $newCIM = $allCIM | Where-Object { $_.GUID -notin $snapCIM } | Select-Object -First 1
            if ($newCIM -and $newCIM.NetConnectionID) {
                Write-Host "[信息] CIM 发现新网卡: $($newCIM.NetConnectionID)" -ForegroundColor DarkCyan
                if (Rename-AdapterHelper -OldName $newCIM.NetConnectionID -NewName $AdapterName) {
                    Write-Host "[OK] 虚拟网卡 $AdapterName 创建成功 (CIM→netsh)" -ForegroundColor Green
                    $na = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
                    if ($na) { return $na.InterfaceIndex }
                    return $newCIM.Index
                }
            }
        }

        if (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue) { break }
    }

    $na = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if ($na) {
        Write-Host "[OK] 虚拟网卡 $AdapterName 已就绪" -ForegroundColor Green
        return $na.InterfaceIndex
    }

    $nowNetsh = netsh interface show interface 2>$null | Out-String
    if ($nowNetsh -ne $snapNetsh) {
        Write-Host "[信息] netsh 检测到接口变更, 但自动接管失败" -ForegroundColor Yellow
        Write-Host "  请手动在设备管理器中将新出现的网卡重命名为 '$AdapterName'" -ForegroundColor White
        Write-Host "  然后重新运行本脚本" -ForegroundColor White
        pause; exit 1
    }

    $pnp = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -like "*Loopback*" -or $_.FriendlyName -like "*环回*" -or
        $_.FriendlyName -like "*KM-TEST*" -or $_.FriendlyName -like "*MSLOOP*"
    } | Select-Object -First 1
    if ($pnp) {
        Write-Host "[信息] PnP 检测到设备: $($pnp.FriendlyName)" -ForegroundColor Yellow
        Write-Host "  但无法通过脚本自动配置, 请手动在设备管理器中重命名为 '$AdapterName'" -ForegroundColor White
        Write-Host "  然后重新运行本脚本" -ForegroundColor White
        pause; exit 1
    }

    Write-Host "[错误] 未检测到新创建的 Loopback 网卡, 请确认安装是否成功" -ForegroundColor Red
    pause; exit 1
}

function Remove-ForwardSMBAdapter {
    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    $ifIndex = $null
    $pnpID = $null

    if ($adapter) {
        $ifIndex = $adapter.InterfaceIndex
        $pnpID = $adapter.PnPDeviceID
    } else {
        $cim = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.NetConnectionID -eq $AdapterName
        } | Select-Object -First 1
        if ($cim) {
            $ifIndex = $cim.Index
            $pnpID = $cim.PNPDeviceID
        } else {
            return
        }
    }

    Write-Host "正在移除虚拟网卡 $AdapterName ..." -ForegroundColor Yellow
    try {
        Get-NetIPAddress -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        $pnp = $null
        try { $pnp = Get-PnpDevice -InstanceId $pnpID -ErrorAction Stop } catch {}
        if ($pnp) {
            Disable-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Milliseconds 500
            $null = pnputil /remove-device $pnp.InstanceId 2>&1
            Write-Host "[OK] 虚拟网卡 $AdapterName 已移除" -ForegroundColor Green
        } else {
            Write-Host "[OK] 虚拟网卡 $AdapterName IP 已移除" -ForegroundColor Green
            Write-Host "  (如需彻底删除网卡设备, 请在设备管理器中操作)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "[警告] 移除虚拟网卡失败: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  可在设备管理器中手动删除" -ForegroundColor Gray
    }
}

# === 本机防火墙 ===
function Add-LocalFirewallRule {
    Write-Host "正在配置本机防火墙放行规则 (仅限 ${VirtualIP}:${LocalPort})..." -ForegroundColor DarkCyan
    $existing = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[OK] 防火墙规则已存在" -ForegroundColor Green
        return
    }
    try {
        New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $LocalPort -LocalAddress $VirtualIP -Profile Any | Out-Null
        Write-Host "[OK] 防火墙规则添加成功" -ForegroundColor Green
    } catch {
        Write-Host "[警告] New-NetFirewallRule 失败, 改用 netsh 兜底..." -ForegroundColor Yellow
        netsh advfirewall firewall add rule name="$FirewallRuleName" dir=in action=allow protocol=TCP localport=$LocalPort localip=$VirtualIP | Out-Null
    }
}

function Remove-LocalFirewallRule {
    Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
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

    $hasIP = Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $VirtualIP -ErrorAction SilentlyContinue
    if (-not $hasIP) {
        Get-NetIPAddress -IPAddress $VirtualIP -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -ne $ifIndex } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        $naForDisplay = Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
        if (-not $naForDisplay) {
            $naForDisplay = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Index -eq $ifIndex } | Select-Object -First 1
        }
        $adapterDisplayName = if ($naForDisplay.Name) { $naForDisplay.Name } else { "InterfaceIndex $ifIndex" }
        Write-Host "正在将 $VirtualIP 绑定到网卡: $adapterDisplayName" -ForegroundColor DarkCyan
        New-NetIPAddress -IPAddress $VirtualIP -PrefixLength 32 -InterfaceIndex $ifIndex | Out-Null
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
        try {
            $dnsResult = Resolve-DnsName -Name $Domain -Type AAAA -ErrorAction Stop
            $v6 = $dnsResult | Where-Object { $_.Type -eq "AAAA" } | Select-Object -First 1
            if ($v6) {
                Write-Log ("[DNS] Resolve-DnsName({0}) 备用解析成功(IPv6): {1}" -f $Domain, $v6.IPAddress)
                $results += @{ IP = $v6.IPAddress; Family = "InterNetworkV6" }
            }
        } catch {}
        try {
            $dnsResult = Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop
            $v4 = $dnsResult | Where-Object { $_.Type -eq "A" } | Select-Object -First 1
            if ($v4) {
                Write-Log ("[DNS] Resolve-DnsName({0}) 备用解析成功(IPv4): {1}" -f $Domain, $v4.IPAddress)
                $results += @{ IP = $v4.IPAddress; Family = "InterNetwork" }
            }
        } catch {}
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
        try {
            $dnsR = Resolve-DnsName -Name $inputDomain -ErrorAction Stop
            $v6 = $dnsR | Where-Object { $_.Type -eq "AAAA" } | Select-Object -First 1
            $v4 = $dnsR | Where-Object { $_.Type -eq "A" } | Select-Object -First 1
            if ($v6) { Write-Host "[DNS预检] Resolve-DnsName 解析成功 (IPv6): $($v6.IPAddress)" -ForegroundColor Green; $dnsOK = $true }
            if ($v4) { Write-Host "[DNS预检] Resolve-DnsName 解析成功 (IPv4): $($v4.IPAddress)" -ForegroundColor Green; $dnsOK = $true }
        } catch {}
    }
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

    # === 计划任务: Win8 使用 schtasks (避免 ScheduledTasks 模块兼容性不确定性) ===
    Write-Host "`n[任务] 创建系统自启任务..." -ForegroundColor Cyan
    Write-Host "[信息] 使用 schtasks 方案, 不支持崩溃自动重启, 依赖引擎内部自愈" -ForegroundColor Gray

    $taskAction = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$CoreScriptPath`""
    $schtasksResult = cmd /c "schtasks /create /tn `"$TaskName`" /tr `"$taskAction`" /sc onstart /ru SYSTEM /rl HIGHEST /f 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[错误] 创建计划任务失败: $schtasksResult" -ForegroundColor Red
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

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[OK] 计划任务已移除" -ForegroundColor Green
    }

    Stop-CoreEngine
    Write-Host "[OK] 代理进程已终止" -ForegroundColor Green

    Write-Host "正在移除虚拟IP ($VirtualIP)..." -ForegroundColor Yellow
    Remove-NetIPAddress -IPAddress $VirtualIP -Confirm:$false -ErrorAction SilentlyContinue

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
