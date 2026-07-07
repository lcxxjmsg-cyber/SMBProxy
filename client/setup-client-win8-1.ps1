<#
.SYNOPSIS
    SMBProxy - Windows 8/8.1 (v4.5 - 一端一网卡版)
.DESCRIPTION
    每条线路独立 KM-TEST Loopback Adapter, 手动创建。
    跳跃子网(/24)彻底隔离路由, 强主机模型下多线路不冲突。
#>

# === 管理员权限检测 ===
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[错误] 请以管理员身份运行此脚本" -ForegroundColor Red; pause; exit 1
}
$ErrorActionPreference = "Stop"

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if (-not $os) { $os = Get-WmiObject Win32_OperatingSystem }
if (-not ($os.Version -like "6.2.*" -or $os.Version -like "6.3.*")) {
    Write-Host "[错误] 仅适用于 Windows 8 / 8.1, 当前: $($os.Caption)" -ForegroundColor Red; pause; exit 1
}
Write-Host "[系统] $($os.Caption) — Win8 模式" -ForegroundColor Cyan

$osArchWmi = Get-WmiObject Win32_OperatingSystem
if (-not $osArchWmi) { $osArchWmi = Get-CimInstance Win32_OperatingSystem }
$is32Bit = ($osArchWmi.OSArchitecture -match "32")
if ($is32Bit) { Write-Host "[信息] 32 位系统, 仅支持单线路" -ForegroundColor Yellow }

$ToolboxDir = "$env:ProgramData\SMBProxy"
$ConfigPath = "$ToolboxDir\config.json"; $EnginePath = "$ToolboxDir\engine.ps1"; $LogPath = "$ToolboxDir\engine.log"
$TaskName = "SMBProxy_Engine"; $LocalPort = 445; $FwPrefix = "SMBProxy-L8"

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { return @() }
    try { $r = Get-Content $ConfigPath -Raw -ea Stop; if (-not $r.Trim()) { return @() }
        $d = $r | ConvertFrom-Json; if ($d -is [array]) { return @($d) }; return @($d)
    } catch { return @() }
}
function Save-Config($C) {
    if (-not (Test-Path $ToolboxDir)) { New-Item -ItemType Directory $ToolboxDir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $C -Depth 2
    $tmp = "$ConfigPath.tmp"
    $json | Set-Content $tmp -Force
    Move-Item $tmp $ConfigPath -Force -ErrorAction SilentlyContinue
}
function Get-NextIP {
    $lines = @(Read-Config); $used = @($lines | % { $_.IP })
    for ($i = 10; $i -le 254; $i++) { $ip = "10.10.10.$i"; if ($ip -notin $used) { return $ip } }
    return $null
}
function New-LineId {
    $lines = @(Read-Config); $max = 0
    foreach ($l in $lines) { $n = 0; if ([int]::TryParse($l.Id, [ref]$n) -and $n -gt $max) { $max = $n } }
    return [string]($max + 1)
}

# === 一端一网卡: 每条线路独立 KM-TEST Loopback Adapter ===
function Get-AdapterById($id) { Get-NetAdapter -Name "SMBProxy_$id" -ErrorAction SilentlyContinue }
function Rename-Adapter($o, $n) {
    try { $na = Get-NetAdapter -Name $o -ea Stop; Rename-NetAdapter -Name $o -NewName $n -ea Stop; return $true } catch {}
    netsh interface set interface name="$o" newname="$n" 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0)
}
function Enable-AdapterFn($id) {
    $na = Get-AdapterById $id; if ($na -and $na.Status -ne "Up") {
        try { Enable-NetAdapter -Name "SMBProxy_$id" -Confirm:$false -ea SilentlyContinue } catch {}
        Start-Sleep -Seconds 1
    }
}
function Create-AdapterForLine($id) {
    # 1) 已存在则复用
    $na = Get-AdapterById $id
    if ($na) { Enable-AdapterFn $id; return $na.InterfaceIndex }

    # 2) 搜索未命名的空闲 Loopback 网卡
    $nl = try { @(Get-NetAdapter -IncludeHidden -ea Stop) } catch { @(Get-NetAdapter -ea SilentlyContinue) }
    $match = $nl | Where-Object {
        ($_.InterfaceDescription -like "*Loopback*" -or $_.InterfaceDescription -like "*环回*") -and
        $_.Name -notlike "Loopback Pseudo-Interface*" -and $_.Name -notlike "SMBProxy_*"
    } | Select-Object -First 1
    if ($match) {
        Write-Host "[信息] 复用现有 Loopback: $($match.Name) -> SMBProxy_$id" -ForegroundColor DarkCyan
        Rename-Adapter $match.Name "SMBProxy_$id" | Out-Null
        $na = Get-AdapterById $id
        if ($na) { Enable-AdapterFn $id; return $na.InterfaceIndex }
    }

    # 3) 手动创建 (hdwwiz)
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  [手动操作] 即将弹出添加硬件向导" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  1. [下一步] -> [安装我手动从列表选择的硬件] -> [下一步]" -ForegroundColor White
    Write-Host "  2. 选 [网络适配器] -> [下一步]" -ForegroundColor White
    Write-Host "  3. 厂商 [Microsoft] -> [Microsoft KM-TEST 环回适配器] -> [下一步]" -ForegroundColor White
    Write-Host "  4. [下一步] -> 完成 -> 回到本窗口按任意键" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Yellow
    $snapIds = @(Get-CimInstance Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'ROOT\\NET' } | % { $_.PNPDeviceID })
    $snapNames = @($nl | Where-Object { $_.InterfaceDescription -like "*Loopback*" -or $_.InterfaceDescription -like "*环回*" } | % { $_.Name })
    Start-Process hdwwiz.exe; pause
    for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1
        $allAdapters = try { @(Get-NetAdapter -IncludeHidden -ea Stop) } catch { @(Get-NetAdapter -ea SilentlyContinue) }
        $found = $allAdapters | Where-Object { ($_.InterfaceDescription -like "*Loopback*" -or $_.InterfaceDescription -like "*环回*") -and $_.Name -notin $snapNames -and $_.Name -notlike "SMBProxy_*" -and $_.Name -notlike "Loopback Pseudo-Interface*" } | Select-Object -First 1
        if ($found) { Rename-Adapter $found.Name "SMBProxy_$id" | Out-Null; Write-Host "[OK] SMBProxy_$id 已创建" -ForegroundColor Green; break }
        $allHw = Get-CimInstance Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'ROOT\\NET' }
        $n3 = $allHw | Where-Object { $_.PNPDeviceID -notin $snapIds -and $_.NetConnectionID -and $_.NetConnectionID -notlike "SMBProxy_*" -and $_.NetConnectionID -notlike "Loopback Pseudo-Interface*" } | Select-Object -First 1
        if ($n3) { Rename-Adapter $n3.NetConnectionID "SMBProxy_$id" | Out-Null; Write-Host "[OK] SMBProxy_$id 已创建" -ForegroundColor Green; break }
        if (Get-AdapterById $id) { break }
    }
    $na = Get-AdapterById $id
    if ($na) { Enable-AdapterFn $id; Write-Host "[OK] SMBProxy_$id 已就绪" -ForegroundColor Green; return $na.InterfaceIndex }
    Write-Host "[错误] 创建失败, 请手动完成" -ForegroundColor Red; return $null
}
function Remove-AdapterForLine($id) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    Get-NetIPAddress -InterfaceIndex $na.InterfaceIndex -ea SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ea SilentlyContinue
    try { $null = pnputil /remove-device $na.PnPDeviceID 2>&1 } catch {}
    Write-Host "[OK] SMBProxy_$id IP 已移除" -ForegroundColor Green
    if (Get-AdapterById $id) {
        Write-Host "  [提示] 网卡可能未完全移除, 请在设备管理器中:" -ForegroundColor Yellow
        Write-Host "    右键 SMBProxy_$id → 卸载设备 → 确定" -ForegroundColor Gray
    }
}
function Add-AdapterIP($id, $ip) {
    $ex = Get-NetIPAddress -IPAddress $ip -ea SilentlyContinue; if ($ex) { return }
    $na = Get-AdapterById $id; if (-not $na) { return }
    New-NetIPAddress -IPAddress $ip -InterfaceIndex $na.InterfaceIndex -AddressFamily IPv4 -PrefixLength 24 -Confirm:$false | Out-Null
}
function Remove-AdapterIP($id) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    Get-NetIPAddress -InterfaceIndex $na.InterfaceIndex -ea SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ea SilentlyContinue
}

# === 防火墙逐条 ===
function Setup-Firewall {}
function Add-Firewall($id, $ip) {
    try { New-NetFirewallRule -DisplayName "$FwPrefix-$id" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $LocalPort -LocalAddress $ip -Profile Any -ErrorAction Stop | Out-Null } catch {}
}
function Remove-Firewall($id) { Remove-NetFirewallRule -DisplayName "$FwPrefix-$id" -ErrorAction SilentlyContinue }
function Remove-FirewallAll {
    $lines = @(Read-Config); foreach ($l in $lines) { Remove-Firewall $l.Id }
}

# === SMB 驱动 ===
function Test-SmbDisabled {
    $s = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ea SilentlyContinue
    return ($s -and $s.Start -eq 4)
}
function Disable-SmbAndFastBoot {
    Write-Host "[系统] 禁用 SMB/445..." -ForegroundColor Yellow
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 4 -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 4 -Force -ea SilentlyContinue
    Set-Service LanmanServer -StartupType Disabled; try { Stop-Service LanmanServer -Force -ea SilentlyContinue } catch {}
    $hb = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ea SilentlyContinue
    if (-not $hb -or $hb.HiberbootEnabled -ne 0) { Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Force }
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " [重要] 请重启电脑后重新运行" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Red; pause; exit 1
}
function Restore-Smb {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 3 -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 3 -Force -ea SilentlyContinue
    Set-Service LanmanServer -StartupType Automatic; try { Start-Service LanmanServer -ea SilentlyContinue } catch {}
}

# === 进程 & 计划任务 ===
function Get-EngineProcess { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ea SilentlyContinue | Where-Object { $_.CommandLine -like "*$EnginePath*" } }
function Stop-Engine { $p = Get-EngineProcess; foreach ($x in $p) { try { Stop-Process -Id $x.ProcessId -Force -ea SilentlyContinue } catch {} }; if ($p) { Start-Sleep -Milliseconds 800 }; $retry = 0; while ((Get-EngineProcess) -and $retry -lt 5) { Start-Sleep -Milliseconds 500; $retry++ } }
function Start-Engine {
    Stop-Engine; $lines = @(Read-Config); if ($lines.Count -eq 0) { return }
    Write-EngineScript; Setup-Task
    Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`"" -WindowStyle Hidden
}
function Setup-Task {
    $c = cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    $a = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`""
    cmd /c "schtasks /create /tn `"$TaskName`" /tr `"$a`" /sc onstart /ru SYSTEM /rl HIGHEST /f 2>&1" | Out-Null
}
function Remove-Task {
    $c = cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null
    if ($LASTEXITCODE -eq 0) { cmd /c "schtasks /delete /tn `"$TaskName`" /f 2>nul" 2>$null | Out-Null }
}

# === 引擎 ===
function Write-EngineScript {
    $h = @"
`$ConfigPath = '$ConfigPath'
`$LogPath = '$LogPath'
`$LocalPort = $LocalPort
"@
    $b = @'
$ErrorActionPreference="SilentlyContinue"
function Write-Log($m){$l="[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$m;try{Add-Content $LogPath $l -Encoding UTF8}catch{}}
function DNS($d){try{$ar=[System.Net.Dns]::BeginGetHostAddresses($d,$null,$null);if(-not$ar.AsyncWaitHandle.WaitOne(5000)){return $null};$a=[System.Net.Dns]::EndGetHostAddresses($ar);$v6=$a|?{$_.AddressFamily -eq'InterNetworkV6'}|select -First 1;if($v6){return @{IP=$v6.IPAddressToString;Family=$v6.AddressFamily}};$v4=$a|?{$_.AddressFamily -eq'InterNetwork'}|select -First 1;if($v4){return @{IP=$v4.IPAddressToString;Family=$v4.AddressFamily}}}catch{};return $null}
function Pump($a,$b){try{$as=$a.GetStream();$bs=$b.GetStream();$t=$as.CopyToAsync($bs,65536);$cb={param($x)try{$a.GetStream().Close()}catch{}try{$a.Close()}catch{}try{$b.GetStream().Close()}catch{}try{$b.Close()}catch{}}.GetNewClosure();$t.ContinueWith([Action[Threading.Tasks.Task]]$cb)|Out-Null}catch{try{$a.Close()}catch{}try{$b.Close()}catch{}}}
Write-Log "===== SMBProxy v4.5 ====="
$L=@{};$lastCheck=(Get-Date).AddDays(-1);$lastLogClean=Get-Date
while($true){try{$now=Get-Date
    if(($now-$lastCheck).TotalSeconds -ge 10){
        $cfg=@()
        try{$raw=Get-Content $ConfigPath -Raw -ErrorAction Stop;$obj=$raw|ConvertFrom-Json;if($obj -is [System.Array]){$cfg=@($obj)}else{$cfg=@($obj)}}catch{Write-Log("[配置读取失败] $($_.Exception.Message)")}
        $live=@($cfg|%{$_.IP})
        foreach($ip in @($L.Keys)){if($ip -notin $live){try{$L[$ip].Listener.Stop()}catch{};$L.Remove($ip);Write-Log("[下线] $ip")}}
        foreach($line in $cfg){
            if(-not$line -or -not$line.IP){continue}
            if($line.IP -is [array]){Write-Log("[忽略异常IP数组] $($line.IP -join ',')");continue}
            $ipText=([string]$line.IP).Trim()
            try{$check=[System.Net.IPAddress]::Parse($ipText);if($check.AddressFamily -ne "InterNetwork"){continue}}catch{Write-Log("[忽略非法配置IP] $ipText");continue}
            if(-not$L.ContainsKey($line.IP)){
                $ln=$null;for($r=0;$r -lt 3;$r++){try{$ln=New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($line.IP),$LocalPort);$ln.Start();break}catch{if($r -lt 2){Start-Sleep -Seconds 2}}}
                if($ln){$L[$line.IP]=@{Listener=$ln;Line=$line;Endpoint=$null;LastResolve=(Get-Date).AddDays(-1)};Write-Log("[上线] {0}:{1} -> {2}:{3}" -f $line.IP,$LocalPort,$line.Domain,$line.Port)}else{Write-Log("[监听失败] $ipText 三次重试后仍无法绑定")}
            }
        }$lastCheck=Get-Date
    }
    if(($now-$lastLogClean).TotalHours -ge 1){try{if((Get-Item $LogPath -ea Stop).Length -gt 5MB){Set-Content $LogPath "[{0}] 日志滚动 - 已截断" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8}}catch{};$lastLogClean=Get-Date}
    foreach($ip in @($L.Keys)){$e=$L[$ip];if(($now-$e.LastResolve).TotalSeconds -ge 60){$ep=DNS $e.Line.Domain;if($ep){$e.Endpoint=$ep};$e.LastResolve=Get-Date;break}}
    foreach($ip in @($L.Keys)){$e=$L[$ip];if(-not$e.Listener.Pending()){continue};if(-not$e.Endpoint){continue};$c=$e.Listener.AcceptTcpClient()
        try{$r=New-Object System.Net.Sockets.TcpClient($e.Endpoint.Family);$ar=$r.BeginConnect($e.Endpoint.IP,$e.Line.Port,$null,$null);if(-not$ar.AsyncWaitHandle.WaitOne(5000)){throw"连接远程超时"};$r.EndConnect($ar);Write-Log("[连接] {0} -> {1}:{2}" -f $e.Line.Domain,$e.Endpoint.IP,$e.Line.Port);Pump $c $r;Pump $r $c}catch{try{$c.Close()}catch{}}
    }
    Start-Sleep -Milliseconds 200
}catch{try{Write-Log("[致命异常] $($_.Exception.Message)")}catch{};Start-Sleep -Seconds 2}}
'@
    if(-not(Test-Path $ToolboxDir)){New-Item -ItemType Directory $ToolboxDir -Force|Out-Null}
    $h + "`r`n" + $b | Set-Content $EnginePath -Force -Encoding UTF8
}

# === 线路增删 ===
function Add-Line {
    if ($is32Bit) { $l = @(Read-Config); if ($l.Count -ge 1) { Write-Host "[限制] 32 位系统仅支持 1 条线路" -ForegroundColor Yellow; pause; return } }
    $domain = Read-Host "`n输入远程 DDNS 域名"; if (-not $domain) { Write-Host "已取消" -ForegroundColor Gray; return }
    $ps = Read-Host "输入远程端口号 (默认 1445)"; $port = 1445; if ($ps) { [int]::TryParse($ps, [ref]$port) | Out-Null }
    if ($port -lt 1 -or $port -gt 65535) { Write-Host "端口无效" -ForegroundColor Red; return }
    $ip = Get-NextIP; if (-not $ip) { Write-Host "[错误] 无可用 IP" -ForegroundColor Red; return }
    $id = New-LineId

    $ifIdx = Create-AdapterForLine $id
    if (-not $ifIdx) { Write-Host "[错误] 网卡创建失败" -ForegroundColor Red; return }
    Add-AdapterIP $id $ip
    Add-Firewall $id $ip

    $lines = @(Read-Config); $lines += @{ Id=$id; IP=$ip; Domain=$domain; Port=$port }; Save-Config $lines
    Write-Host "[OK] 线路已添加: $id  $ip  SMBProxy_$id  $domain`:$port" -ForegroundColor Green
    Start-Engine
    pause
}
function Remove-Line {
    $lines = @(Read-Config); if ($lines.Count -eq 0) { return }
    $id = Read-Host "`n输入要删除的线路 ID"; if (-not $id) { return }
    $m = $lines | Where-Object { $_.Id -eq $id }; if (-not $m) { Write-Host "[错误] 未找到 ID: $id" -ForegroundColor Red; return }
    Remove-AdapterForLine $id
    Remove-Firewall $id
    $lines = @($lines | Where-Object { $_.Id -ne $id }); Save-Config $lines
    Write-Host "[OK] 线路已删除: $id" -ForegroundColor Green
    if ($lines.Count -eq 0) { Stop-Engine } else { Start-Engine }
    pause
}
function Full-Uninstall {
    Write-Host "`n正在完全卸载..." -ForegroundColor Yellow
    Remove-Task; Stop-Engine
    Remove-FirewallAll
    $lines = @(Read-Config); foreach ($l in $lines) { Remove-AdapterForLine $l.Id }
    $remains = @(Get-NetAdapter -Name "SMBProxy_*" -ea SilentlyContinue)
    if ($remains.Count -gt 0) {
        Write-Host "`n  [提示] 以下网卡未能自动删除, 请在设备管理器中手动操作:" -ForegroundColor Yellow
        foreach ($r in $remains) { Write-Host "    右键 $($r.Name) → 卸载设备 → 确定" -ForegroundColor Gray }
    }
    Restore-Smb; Start-Sleep -Seconds 1
    if (Test-Path $ToolboxDir) { Remove-Item $ToolboxDir -Recurse -Force -ea SilentlyContinue }
    if (Test-Path $ToolboxDir) { Write-Host "  [提示] 请手动删除: $ToolboxDir" -ForegroundColor Yellow }
    Write-Host "[OK] 卸载完成, 建议重启" -ForegroundColor Green; pause; exit
}

# === 菜单 ===
function Show-Menu {
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     SMBProxy - Windows 8/8.1 (v4.5)                " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    $procs = Get-EngineProcess
    if ($procs) { Write-Host "  引擎: 运行中 (PID: $($procs[0].ProcessId))" -ForegroundColor Green }
    else { Write-Host "  引擎: 已停止" -ForegroundColor Yellow }
    $lines = @(Read-Config)
    Write-Host "`n  ID   Adapter          VirtualIP        Domain:Port" -ForegroundColor DarkCyan
    Write-Host "  ----  ───────────────  ──────────────   ──────────────────" -ForegroundColor DarkCyan
    if ($lines.Count -eq 0) { Write-Host "  (暂无线路, 按 [1] 添加)" -ForegroundColor Gray }
    else { foreach ($l in $lines) { Write-Host ("  {0,-5} SMBProxy_{0,-8} {1,-16} {2}:{3}" -f $l.Id, $l.IP, $l.Domain, $l.Port) -ForegroundColor White } }
    Write-Host "`n  线路: $($lines.Count)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[1] 添加线路 (引导创建 SMBProxy_N 网卡)" -ForegroundColor Green
    Write-Host "[2] 删除线路 (输入 ID, 自动移除网卡)" -ForegroundColor Yellow
    Write-Host "[3] 查看日志" -ForegroundColor Cyan
    Write-Host "[4] 完全卸载" -ForegroundColor Red
    Write-Host "[5] 重启引擎" -ForegroundColor Gray
    Write-Host "[0] 退出" -ForegroundColor Gray
}

# === 入口 ===
if (-not (Test-SmbDisabled)) {
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " [首次运行] 安装须知" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " 本工具需禁用系统原生 445 端口服务，将产生以下影响:" -ForegroundColor White
    Write-Host "  - 本机 Windows 文件共享 (SMB/CIFS) 将不可用" -ForegroundColor Gray
    Write-Host "  - 其他设备无法通过 \\\\IP 或 \\\\主机名 访问本机共享" -ForegroundColor Gray
    Write-Host "  - 快速启动将被关闭 (确保重启后 445 释放)" -ForegroundColor Gray
    Write-Host "  - 以上所有修改可通过 [4] 完全卸载 恢复原状" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Yellow
    $choice = Read-Host "是否继续? [y/N]"
    if ($choice -ne 'y' -and $choice -ne 'Y') { exit 0 }
    Disable-SmbAndFastBoot
}

$portCheck = netstat -ano | Select-String "LISTENING" | Select-String ":$($LocalPort)\s"
if ($portCheck) {
    $engProcs = Get-EngineProcess
    $isOwn = $false
    foreach ($ep in $engProcs) { if ($portCheck -match $ep.ProcessId) { $isOwn = $true; break } }
    if ($isOwn) {
        Write-Host "[信息] 检测到残留引擎, 正在清理..." -ForegroundColor Yellow
        Stop-Engine
    } else {
        Write-Host "`n==========================================================" -ForegroundColor Red
        Write-Host " [错误] 端口 $LocalPort 仍被占用! 是否已重启电脑?" -ForegroundColor Red
        Write-Host $portCheck -ForegroundColor Gray
        Write-Host "==========================================================" -ForegroundColor Red
        pause; exit 1
    }
}

# 确保所有已有线路的网卡和 IP 就绪
$lines = @(Read-Config)
$hasAdapter = $false
foreach ($l in $lines) {
    $na = Get-AdapterById $l.Id
    if ($na) { Add-AdapterIP $l.Id $l.IP; Add-Firewall $l.Id $l.IP; $hasAdapter = $true }
    else { Write-Host "[警告] 线路 $($l.Id) 的网卡不存在, 请删除后重新添加" -ForegroundColor Yellow }
}
if ($hasAdapter) { Start-Engine }
if (-not (Test-Path $ToolboxDir)) { New-Item -ItemType Directory $ToolboxDir -Force | Out-Null }

do {
    Show-Menu
    $choice = Read-Host "`n请选择 (0-5)"
    switch ($choice) {
        "1" { Add-Line }
        "2" { Remove-Line }
        "3" { Write-Host "`n--- 日志 ---" -ForegroundColor Cyan; if (Test-Path $LogPath) { Get-Content $LogPath -Tail 50 } else { Write-Host "(无日志)" -ForegroundColor Gray }; pause }
        "4" { Full-Uninstall }
        "5" { Write-Host "`n重启引擎..." -ForegroundColor Cyan; Start-Engine; Write-Host "[OK]" -ForegroundColor Green; pause }
        "0" { exit }
    }
} while ($true)
