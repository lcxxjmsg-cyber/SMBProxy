<#
.SYNOPSIS
     SMB 端口转发客户端 - 交互式菜单 (v3.1 - 虚拟IP版 + 稳定性修复)
.DESCRIPTION
     1. 自动创建独立虚拟网卡 SMBProxy + 绑定 IP 10.10.10.10, 绕过 Windows SMB 回环限制
     2. 虚拟网卡与物理网卡完全隔离, 不影响现有网络 (WiFi/以太网/DHCP 均不受干扰)
     3. 彻底解决系统错误67和错误64
     3. 卸载时自动移除虚拟网卡, 不留痕迹
     4. 数据泵引擎改为 .NET 原生异步IO (Stream.CopyToAsync), 不再逐连接创建
        PowerShell Runspace, 消除长期运行下的句柄/线程泄漏
     5. 自愈能力: DNS解析失败重试、DDNS更换IP自动感知、主循环异常自动恢复
     6. 计划任务修复: 显式关闭72小时默认执行时限、崩溃自动重启、开机延迟启动
        避免网络未就绪、以及显式Bypass执行策略避免静默不执行
     7. 完整日志记录 (菜单内可直接查看), 便于排障
     8. 修复"重复运行脚本时误报445端口被占用"的问题(未先清理自身残留进程)
     9. 首次使用引导用户通过 hdwwiz 安装 Microsoft Loopback Adapter (仅一次),
         之后脚本自动接管并重命名为 SMBProxy
    10. 新增本机防火墙放行规则(仅限虚拟IP), 弥补Windows防火墙按程序名过滤导致
        自定义引擎进程被拦截的问题
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
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
    Write-Host "     SMB 端口转发 - 客户端菜单 (v3.1)              " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "  入口地址: \\$VirtualIP" -ForegroundColor Green
    Write-Host ""

    # 检查后台任务状态
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

# === 虚拟网卡: 使用 Windows 内置 Microsoft Loopback Adapter, 与物理网卡完全隔离 ===
$AdapterName = "SMBProxy"

function Install-ForwardSMBAdapter {
    # 辅助: 重命名网卡, Get-NetAdapter 不可用时用 netsh 兜底
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

    # --- 多方法搜索未命名的 Loopback 网卡 ---
    $foundName = $null
    $foundIndex = $null

    # 方法A: Get-NetAdapter -IncludeHidden (含隐藏/未激活适配器)
    $match = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
        ($_.InterfaceDescription -like "*Loopback*" -or $_.InterfaceDescription -like "*环回*") -and
        $_.Name -notlike "Loopback Pseudo-Interface*" -and $_.Name -ne $AdapterName
    } | Select-Object -First 1
    if ($match) { $foundName = $match.Name; $foundIndex = $match.InterfaceIndex }

    # 方法B: CIM/WMI (对 Get-NetAdapter 不可见的适配器)
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

    # 首次安装: 引导用户手动操作 (仅需一次, 之后脚本自动接管)
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  首次使用需要手动安装 Microsoft Loopback Adapter (仅此一次):" -ForegroundColor Yellow
    Write-Host "  1. 在弹出的窗口中点 [下一步]" -ForegroundColor White
    Write-Host "  2. 选择 [安装我手动从列表选择的硬件] → [下一步]" -ForegroundColor White
    Write-Host "  3. 选 [网络适配器] → [下一步]" -ForegroundColor White
    Write-Host "  4. 厂商选 [Microsoft], 型号选 [Microsoft KM-TEST Loopback Adapter]" -ForegroundColor White
    Write-Host "  5. [下一步] → [下一步] → 完成" -ForegroundColor White
    Write-Host "  6. 回到本窗口按任意键, 脚本将自动接管该网卡" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Yellow

    # 保存安装前的多数据源快照
    $snapNA = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceGuid })
    $snapCIM = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | ForEach-Object { $_.GUID })
    $snapNetsh = netsh interface show interface 2>$null | Out-String

    Start-Process hdwwiz.exe
    pause

    # 轮询寻找新创建的 Loopback 网卡
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1

        # 方法1: Get-NetAdapter GUID 快照对比
        $allNA = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue)
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

        # 方法2: CIM/WMI GUID 快照对比
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

    # 已成功注册的检查
    $na = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if ($na) {
        Write-Host "[OK] 虚拟网卡 $AdapterName 已就绪" -ForegroundColor Green
        return $na.InterfaceIndex
    }

    # 兜底: netsh 文本对比 + PnP 设备查询
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
        # CIM/WMI 兜底: Get-NetAdapter 可能看不到此适配器
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
        # 移除该网卡上所有 IP
        Get-NetIPAddress -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        # 通过 PNP 卸载设备
        $pnp = Get-PnpDevice -InstanceId $pnpID -ErrorAction SilentlyContinue
        if ($pnp) {
            Disable-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Milliseconds 500
            $null = pnputil /remove-device $pnp.InstanceId 2>&1
        }
        Write-Host "[OK] 虚拟网卡 $AdapterName 已移除" -ForegroundColor Green
    } catch {
        Write-Host "[警告] 移除虚拟网卡失败: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  可在设备管理器中手动删除" -ForegroundColor Gray
    }
}

# === 本机防火墙: Windows防火墙按"发起监听的程序"过滤, 内置的SMB放行规则只认
#     System/LanmanServer, 不会自动放行我们自建的powershell.exe监听进程,
#     必须显式加一条规则, 且仅放行虚拟IP以避免不必要的暴露面 ===
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
    # 修复: 必须先清理自己上一次留下的引擎进程, 否则下面的端口占用检测会把
    # "自己的旧进程占着10.10.10.10:445" 误判成 "445仍被系统SMB服务占用",
    # 导致重复运行本脚本时总是提示需要重启, 造成"越修越乱"的假象。
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

        # 关闭快速启动: 快速启动使用混合关机(hibernate), 不会完整卸载/重载内核驱动,
        # 导致重启后 srvnet 禁用不生效, 445 端口仍被占用, 出现"明明重启了却还是提示重启"的死循环
        # 注意: 只需关闭 HiberbootEnabled(快速启动), 不需要 powercfg /h off(那会彻底禁用休眠并删除 hiberfil.sys)
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
        # 清理可能残留在其他网卡上的旧 IP (例如之前绑在 WLAN 上的)
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

# === 生成后台核心引擎脚本 ===
function Write-CoreEngineScript {
    $header = @"
`$ConfigPath = '$ConfigPath'
`$LogPath = '$LogPath'
`$LocalPort = $LocalPort
`$VirtualIP = '$VirtualIP'
"@

    # 核心引擎: 绑定到虚拟IP上运行。相较旧版做了以下修复:
    #  - 增加日志, 否则完全无法排障
    #  - DNS解析失败/监听失败自动重试, 不再一次失败就永久退出
    #  - 不再写死只解析IPv6, 自动优先IPv6/回退IPv4, 匹配服务端v4/v6/双栈配置
    #  - 每10秒自动重新解析DDNS, 域名对应公网IP变化后新连接自动生效
    #  - 数据泵改用 Stream.CopyToAsync (.NET原生异步IO), 不再每个连接创建2个
    #    PowerShell Runspace且从不Dispose, 消除长期运行下的句柄/线程泄漏
    #  - 主循环用 try/catch 包裹, 任何异常都会记录日志并在2秒后继续, 而不是
    #    让整个引擎在一次偶发异常后彻底"暴毙"
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
        # 如果 GetHostAddresses 和 Resolve-DnsName 都失败了, $results 为空, 下面会处理
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

    Write-Host "`n[任务] 创建系统自启任务..." -ForegroundColor Cyan
    $Trigger = New-ScheduledTaskTrigger -AtStartup
    # 修复: 开机后延迟启动, 避免网络/DNS尚未就绪导致首次DNS解析必然失败
    try { $Trigger.Delay = "PT20S" } catch {}

    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$CoreScriptPath`""
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    # 修复: 默认的 ExecutionTimeLimit 是72小时, 到点后计划任务会自动杀掉引擎进程
    # 这正是"必须不间断运行却总是不明不白停掉"的一个常见元凶, 这里显式关闭该限制。
    # 同时加上崩溃自动重启作为兜底(引擎自身也有异常恢复逻辑, 双保险)。
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Trigger $Trigger -Action $Action -Principal $Principal -Settings $Settings -Force | Out-Null

    # 结束旧进程并立即启动新引擎(用于当场验证, 便于查看日志排障)
    Stop-CoreEngine
    Start-Process -FilePath "powershell.exe" -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$CoreScriptPath`"" -WindowStyle Hidden

    # 轮询等待引擎完成初始化(含 DNS 解析), 最多等 15 秒
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
