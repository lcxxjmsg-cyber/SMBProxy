<#
.SYNOPSIS
    SMBProxy - Windows Server 2016/2019/2022/2025 (v4.5 - 一端一网卡版)
.DESCRIPTION
    每条线路独立 KM-TEST Loopback Adapter, 手动创建。
    跳跃子网(/24)彻底隔离路由, 强主机模型下多线路不冲突。
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$ToolboxDir = "$env:ProgramData\SMBProxy"
$ConfigPath = "$ToolboxDir\config.json"; $EnginePath = "$ToolboxDir\engine.ps1"; $LogPath = "$ToolboxDir\engine.log"
$TaskName = "SMBProxy_Engine"; $LocalPort = 445; $FwPrefix = "SMBProxy-W10"

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
    $json | Set-Content $tmp -Force -Encoding UTF8
    Move-Item $tmp $ConfigPath -Force -ErrorAction SilentlyContinue
}

function Repair-Config {
    $old = @(Read-Config)
    $new = @()

    foreach($x in $old){

        # 修复 PowerShell ConvertFrom-Json 导致 IP 数组污染的问题
        if($x.IP -is [array]){
            Write-Host "[修复] 检测到IP数组污染，删除线路: $($x.IP -join ',')" -ForegroundColor Yellow
            continue
        }

        try {
            $ip = [System.Net.IPAddress]::Parse([string]$x.IP)

            if($ip.AddressFamily -eq "InterNetwork" -and
               $x.Id -and
               $x.Domain -and
               $x.Port){

                $x.IP = [string]$x.IP
                $new += $x

            } else {
                Write-Host "[修复] 删除字段异常线路" -ForegroundColor Yellow
            }

        } catch {
            Write-Host "[修复] 删除非法IP配置: $($x.IP)" -ForegroundColor Yellow
        }
    }

    if($new.Count -ne $old.Count){
        Save-Config $new
    }

    return @($new)
}

function Get-NextIP {
    $lines = @(Read-Config); $used = @($lines | % { $_.IP })
    for ($i = 10; $i -le 254; $i++) { $ip = "10.10.10.$i"; if ($ip -notin $used) { return $ip } }
    return $null
}
function New-LineId { $l = @(Read-Config); $m = 0; foreach ($x in $l) { $n = 0; if ([int]::TryParse($x.Id, [ref]$n) -and $n -gt $m) { $m = $n } }; return [string]($m + 1) }

# === 一端一网卡: pnputil 静默创建 KM-TEST Loopback Adapter ===
function Get-AdapterById($id) { Get-NetAdapter -Name "SMBProxy_$id" -ErrorAction SilentlyContinue }
function Create-AdapterForLine($id) {
    $na = Get-AdapterById $id
    if ($na) { if ($na.Status -ne "Up") { try { Enable-NetAdapter -Name "SMBProxy_$id" -Confirm:$false -ea SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }; return $na.InterfaceIndex }

    # 搜索未命名的空闲/禁用 Loopback 网卡 (包括隐藏设备)
    $nl = try { @(Get-NetAdapter -IncludeHidden -ea Stop) } catch { @(Get-NetAdapter -ea SilentlyContinue) }
    $match = $nl | Where-Object {
        ($_.InterfaceDescription -match 'Loopback|环回|KM-TEST') -and
        $_.Name -notlike "SMBProxy_*"
    } | Select-Object -First 1
    if ($match) {
        Write-Host "[信息] 复用现有 Loopback: $($match.Name) -> SMBProxy_$id" -ForegroundColor DarkCyan
        if ($match.Status -eq "Disabled") { try { Enable-NetAdapter -Name $match.Name -Confirm:$false -ea SilentlyContinue } catch {} }
        try { Rename-NetAdapter -Name $match.Name -NewName "SMBProxy_$id" -ea Stop } catch { netsh interface set interface name="$($match.Name)" newname="SMBProxy_$id" 2>&1|Out-Null }
        $na = Get-AdapterById $id; if ($na) { if ($na.Status -ne "Up") { try { Enable-NetAdapter -Name "SMBProxy_$id" -Confirm:$false -ea SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }; return $na.InterfaceIndex }
    }

    # 检查隐藏/禁用的 Loopback 设备 (设备管理器中可见但 NetAdapter 不显示)
    $hiddenPnP = Get-PnpDevice -Class Net -ea SilentlyContinue | Where-Object {
        ($_.FriendlyName -match 'Loopback|环回|KM-TEST') -and
        ($_.Status -eq 'Error' -or $_.Status -eq 'Unknown')
    } | Select-Object -First 1
    if ($hiddenPnP) {
        Write-Host "[信息] 尝试启用隐藏 Loopback 设备..." -ForegroundColor DarkCyan
        try { Enable-PnpDevice -InstanceId $hiddenPnP.InstanceId -Confirm:$false -ea SilentlyContinue; Start-Sleep -Seconds 2 } catch {}
        $na = Get-AdapterById $id; if (-not $na) {
            $nl2 = try { @(Get-NetAdapter -IncludeHidden -ea Stop) } catch { @(Get-NetAdapter -ea SilentlyContinue) }
            $m2 = $nl2 | Where-Object { ($_.InterfaceDescription -match 'Loopback|环回|KM-TEST') -and $_.Name -notlike "SMBProxy_*" } | Select-Object -First 1
            if ($m2) {
                try { Rename-NetAdapter -Name $m2.Name -NewName "SMBProxy_$id" -ea Stop } catch { netsh interface set interface name="$($m2.Name)" newname="SMBProxy_$id" 2>&1|Out-Null }
                $na = Get-AdapterById $id
            }
        }
        if ($na) { if ($na.Status -ne "Up") { try { Enable-NetAdapter -Name "SMBProxy_$id" -Confirm:$false -ea SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }; return $na.InterfaceIndex }
    }

    # 自动创建全部失败, 弹出手动安装向导
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  [手动操作] 即将弹出添加硬件向导" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  1. [下一步] -> [安装我手动从列表选择的硬件] -> [下一步]" -ForegroundColor White
    Write-Host "  2. 选 [网络适配器] -> [下一步]" -ForegroundColor White
    Write-Host "  3. 厂商 [Microsoft] -> [Microsoft KM-TEST 环回适配器] -> [下一步]" -ForegroundColor White
    Write-Host "  4. [下一步] -> 完成 -> 回到本窗口按任意键" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Yellow
    $snapIds = @(Get-CimInstance Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'ROOT\\NET' } | % { $_.PNPDeviceID })
    $snapNames = @($nl | Where-Object { $_.InterfaceDescription -match 'Loopback|环回|KM-TEST' } | % { $_.Name })
    Start-Process hdwwiz.exe; pause
    for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1
        $allAdapters = try { @(Get-NetAdapter -IncludeHidden -ea Stop) } catch { @(Get-NetAdapter -ea SilentlyContinue) }
        $n2 = $allAdapters | Where-Object { ($_.InterfaceDescription -match 'Loopback|环回|KM-TEST') -and $_.Name -notin $snapNames -and $_.Name -notlike "SMBProxy_*" } | Select-Object -First 1
        if ($n2) { try { Rename-NetAdapter -Name $n2.Name -NewName "SMBProxy_$id" -ea Stop } catch { netsh interface set interface name="$($n2.Name)" newname="SMBProxy_$id" 2>&1|Out-Null }; Write-Host "[OK] SMBProxy_$id 已创建" -ForegroundColor Green; break }
        $allHw = Get-CimInstance Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.PNPDeviceID -match 'ROOT\\NET' }
        $n3 = $allHw | Where-Object { $_.PNPDeviceID -notin $snapIds -and $_.NetConnectionID -and $_.NetConnectionID -notlike "SMBProxy_*" } | Select-Object -First 1
        if ($n3) { try { Rename-NetAdapter -Name $n3.NetConnectionID -NewName "SMBProxy_$id" -ea Stop } catch { netsh interface set interface name="$($n3.NetConnectionID)" newname="SMBProxy_$id" 2>&1|Out-Null }; Write-Host "[OK] SMBProxy_$id 已创建" -ForegroundColor Green; break }
        if (Get-AdapterById $id) { break }
    }
    $na = Get-AdapterById $id
    if ($na) { if ($na.Status -ne "Up") { try { Enable-NetAdapter -Name "SMBProxy_$id" -Confirm:$false -ea SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }; return $na.InterfaceIndex }
    Write-Host "[错误] 创建失败" -ForegroundColor Red; return $null
}
function Remove-AdapterForLine($id) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    Get-NetIPAddress -InterfaceIndex $na.InterfaceIndex -ea SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ea SilentlyContinue
    try { $null = pnputil /remove-device $na.PnPDeviceID 2>&1 } catch {}
    Write-Host "[OK] SMBProxy_$id IP 已移除" -ForegroundColor Green
    if (Get-AdapterById $id) { Write-Host "  [提示] 网卡未完全移除, 请在设备管理器中: 右键 SMBProxy_$id -> 卸载设备 -> 确定" -ForegroundColor Yellow }
}
function Add-AdapterIP($id, $ip) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    $ex = Get-NetIPAddress -IPAddress $ip -InterfaceIndex $na.InterfaceIndex -ea SilentlyContinue
    if (-not $ex) { New-NetIPAddress -IPAddress $ip -InterfaceIndex $na.InterfaceIndex -AddressFamily IPv4 -PrefixLength 24 -Confirm:$false | Out-Null }
}
function Remove-AdapterIP($id) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    Get-NetIPAddress -InterfaceIndex $na.InterfaceIndex -ea SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ea SilentlyContinue
}

# === 防火墙逐条 ===
function Setup-Firewall {}
function Add-Firewall($id, $ip) { try { New-NetFirewallRule -DisplayName "$FwPrefix-$id" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $LocalPort -LocalAddress $ip -Profile Any -ea Stop|Out-Null } catch {} }
function Remove-Firewall($id) { Remove-NetFirewallRule -DisplayName "$FwPrefix-$id" -ErrorAction SilentlyContinue }
function Remove-FirewallAll { $l=@(Read-Config);foreach($x in $l){Remove-Firewall $x.Id} }

# === SMB ===
function Test-SmbDisabled { $s=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ea SilentlyContinue; return ($s -and $s.Start -eq 4) }
function Disable-SmbAndFastBoot {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 4 -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 4 -Force -ea SilentlyContinue
    Set-Service LanmanServer -StartupType Disabled; try { Stop-Service LanmanServer -Force -ea SilentlyContinue } catch {}
    $hb=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ea SilentlyContinue
    if(-not$hb -or $hb.HiberbootEnabled -ne 0){Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Force}
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " [重要] 请重启电脑后重新运行" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Red;pause;exit 1
}
function Restore-Smb {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 3 -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 3 -Force -ea SilentlyContinue
    Set-Service LanmanServer -StartupType Automatic; try{Start-Service LanmanServer -ea SilentlyContinue}catch{}
}

# === 进程 & 计划任务 ===
function Get-EngineProcess { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ea SilentlyContinue | Where-Object { $_.CommandLine -like "*$EnginePath*" } }
function Stop-Engine {
    $p = Get-EngineProcess
    foreach ($x in $p) { try { Stop-Process -Id $x.ProcessId -Force -ea SilentlyContinue } catch {} }
    if ($p) { Start-Sleep -Milliseconds 800 }
    $retry = 0
    while ((Get-EngineProcess) -and $retry -lt 5) { Start-Sleep -Milliseconds 500; $retry++ }
}
function Start-Engine { Stop-Engine;$l=@(Read-Config);if($l.Count -eq 0){return};Write-EngineScript;Setup-Task;Start-Process powershell.exe -Arg "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`"" -WindowStyle Hidden }
function Setup-Task {
    if(Get-ScheduledTask -TaskName $TaskName -ea SilentlyContinue){return}
    $a=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`""
    $t=New-ScheduledTaskTrigger -AtStartup;try{$t.Delay="PT20S"}catch{}
    $p=New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Trigger $t -Action $a -Principal $p -Settings $s -Force|Out-Null
}
function Remove-Task { if(Get-ScheduledTask -TaskName $TaskName -ea SilentlyContinue){Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ea SilentlyContinue} }

# === 引擎 ===
function Write-EngineScript {
    $h=@"
`$ConfigPath='$ConfigPath';`$LogPath='$LogPath';`$LocalPort=$LocalPort
"@
    $b=@'
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
    $h+"`r`n"+$b | Set-Content $EnginePath -Force -Encoding UTF8
}

# === 线路 ===
function Add-Line {
    if ($is32Bit) { $l = @(Read-Config); if ($l.Count -ge 1) { Write-Host "[限制] 32 位系统仅支持 1 条线路" -ForegroundColor Yellow; pause; return } }
    $domain = Read-Host "`n输入远程 DDNS 域名"; if (-not $domain) { Write-Host "已取消" -ForegroundColor Gray; return }
    $ps = Read-Host "输入远程端口号 (默认 1445)"; $port = 1445; if ($ps) { [int]::TryParse($ps, [ref]$port) | Out-Null }
    if ($port -lt 1 -or $port -gt 65535) { Write-Host "端口无效" -ForegroundColor Red; return }
    $ip = Get-NextIP; if (-not $ip) { Write-Host "[错误] 无可用 IP" -ForegroundColor Red; return }
    $id = New-LineId
    $success = $false

    try {
        Write-Host "[1/4] 创建虚拟网卡..." -ForegroundColor Cyan
        $ifIdx = Create-AdapterForLine $id
        if(-not $ifIdx){ throw "网卡创建失败" }

        Write-Host "[2/4] 绑定虚拟IP..." -ForegroundColor Cyan
        Add-AdapterIP $id $ip

        $checkIP = Get-NetIPAddress -IPAddress $ip -ErrorAction SilentlyContinue
        if(-not $checkIP){ throw "IP绑定失败" }

        Write-Host "[3/4] 添加防火墙规则..." -ForegroundColor Cyan
        Add-Firewall $id $ip

        Write-Host "[4/4] 保存配置..." -ForegroundColor Cyan
        $l = @(Read-Config)
        $l += @{
            Id = $id
            IP = $ip
            Domain = $domain
            Port = $port
            State = "active"
        }
        Save-Config $l

        $success = $true
        Write-Host "[OK] 线路已添加: $id  SMBProxy_$id  $ip  $domain`:$port" -ForegroundColor Green

    } catch {
        Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[回滚] 正在清理残留..." -ForegroundColor Yellow

        Remove-AdapterIP $id
        Remove-Firewall $id
        Remove-AdapterForLine $id

        Write-Host "[完成] 原配置未被污染" -ForegroundColor Yellow
    }

    if($success){
        Start-Engine
    }

    pause
}
function Remove-Line {
    $l=@(Read-Config);if($l.Count -eq 0){return}
    $id=Read-Host "`n输入要删除的线路 ID";if(-not$id){return}
    $m = $l | Where-Object { $_.Id -eq $id }; if (-not $m) { Write-Host "[错误] 未找到 ID: $id" -ForegroundColor Red; return }
    Remove-AdapterForLine $id; Remove-Firewall $id
    $l = @($l | Where-Object { $_.Id -ne $id }); Save-Config $l
    Write-Host "[OK] 线路已删除: $id" -ForegroundColor Green
    if($l.Count -eq 0){Stop-Engine}else{Start-Engine};pause
}
function Full-Uninstall {
    Write-Host "`n正在完全卸载..." -ForegroundColor Yellow; Remove-Task; Stop-Engine; Remove-FirewallAll
    $l = @(Read-Config); foreach ($x in $l) { Remove-AdapterForLine $x.Id }
    $remains = @(Get-NetAdapter -Name "SMBProxy_*" -ea SilentlyContinue)
    if ($remains.Count -gt 0) { Write-Host "`n  [提示] 以下网卡未能自动删除:" -ForegroundColor Yellow; foreach ($r in $remains) { Write-Host "    右键 $($r.Name) -> 卸载设备" -ForegroundColor Gray } }
    Restore-Smb; Start-Sleep -Seconds 1
    if (Test-Path $ToolboxDir) { Remove-Item $ToolboxDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $ToolboxDir) { Write-Host "  [提示] 请手动删除: $ToolboxDir" -ForegroundColor Yellow }
    Write-Host "[OK] 卸载完成, 建议重启" -ForegroundColor Green; pause; exit
}

# === 菜单 ===
function Show-Menu {
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     SMBProxy - Server 2016/2019/2022/2025 (v4.5)   " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    $procs = Get-EngineProcess
    if ($procs) { Write-Host "  引擎: 运行中 (PID: $($procs[0].ProcessId))" -ForegroundColor Green }
    else { Write-Host "  引擎: 已停止" -ForegroundColor Yellow }
    $l = @(Read-Config)
    Write-Host "`n  ID   Adapter          VirtualIP        Domain:Port" -ForegroundColor DarkCyan
    Write-Host "  ----  ───────────────  ──────────────   ──────────────────" -ForegroundColor DarkCyan
    if ($l.Count -eq 0) { Write-Host "  (暂无线路)" -ForegroundColor Gray }
    else { foreach ($x in $l) { Write-Host ("  {0,-5} SMBProxy_{0,-8} {1,-16} {2}:{3}" -f $x.Id, $x.IP, $x.Domain, $x.Port) -ForegroundColor White } }
    Write-Host "`n  线路: $($l.Count)" -ForegroundColor Gray; Write-Host ""
    Write-Host "[1] 添加线路 (静默创建网卡)" -ForegroundColor Green
    Write-Host "[2] 删除线路 (自动移除网卡)" -ForegroundColor Yellow
    Write-Host "[3] 查看日志" -ForegroundColor Cyan
    Write-Host "[4] 完全卸载" -ForegroundColor Red
    Write-Host "[5] 重启引擎" -ForegroundColor Gray
    Write-Host "[0] 退出" -ForegroundColor Gray
}

# === 入口 ===
Repair-Config | Out-Null
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
        Write-Host " [错误] 端口 $LocalPort 仍被占用! 是否已重启?" -ForegroundColor Red
        Write-Host $portCheck -ForegroundColor Gray
        Write-Host "==========================================================" -ForegroundColor Red; pause; exit 1
    }
}

$osArchWmi = Get-CimInstance Win32_OperatingSystem
$is32Bit = ($osArchWmi.OSArchitecture -match "32")
if ($is32Bit) { Write-Host "[信息] 32 位系统, 仅支持单线路" -ForegroundColor Yellow }

$l = @(Read-Config)
$hasAdapter = $false
foreach ($x in $l) {
    $na = Get-AdapterById $x.Id
    if ($na) { Add-AdapterIP $x.Id $x.IP; Add-Firewall $x.Id $x.IP; $hasAdapter = $true }
    else { Write-Host "[警告] 线路 $($x.Id) 网卡 SMBProxy_$($x.Id) 不存在, 请删除后重新添加" -ForegroundColor Yellow }
}
if ($hasAdapter) { Start-Engine }
if (-not (Test-Path $ToolboxDir)) { New-Item -ItemType Directory $ToolboxDir -Force | Out-Null }

do {
    Show-Menu
    $c = Read-Host "`n请选择 (0-5)"
    switch ($c) {
        "1" { Add-Line }
        "2" { Remove-Line }
        "3" { Write-Host "`n--- 日志 ---" -ForegroundColor Cyan; if (Test-Path $LogPath) { Get-Content $LogPath -Tail 50 } else { Write-Host "(无日志)" -ForegroundColor Gray }; pause }
        "4" { Full-Uninstall }
        "5" { Write-Host "`n重启引擎..." -ForegroundColor Cyan; Start-Engine; Write-Host "[OK]" -ForegroundColor Green; pause }
        "0" { exit }
    }
} while ($true)
