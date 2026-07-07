<#
.SYNOPSIS
    SMBProxy - Windows 7 (v4.5 - 一端一网卡版)
.DESCRIPTION
    每条线路独立 KM-TEST Loopback Adapter (SMBProxy_1, SMBProxy_2...)
    WMI + netsh 操作, schtasks 计划任务, 含离线依赖管理。
#>

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[错误] 请以管理员身份运行" -ForegroundColor Red; pause; exit 1
}
$ErrorActionPreference = "Stop"
function global:pause { $null = Read-Host "按 Enter 键继续..." }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginDir = "$ScriptDir\win7plug"
$ToolboxDir = "$env:ProgramData\SMBProxy"
$ConfigPath = "$ToolboxDir\config.json"; $EnginePath = "$ToolboxDir\engine.ps1"; $LogPath = "$ToolboxDir\engine.log"
$TaskName = "SMBProxy_Engine"; $LocalPort = 445; $FwPrefix = "SMBProxy-L7"

$os = Get-WmiObject Win32_OperatingSystem
if (-not ($os.Version -like "6.1.*")) {
    Write-Host "[错误] 仅适用于 Windows 7, 当前: $($os.Caption)" -ForegroundColor Red; pause; exit 1
}
Write-Host "[系统] $($os.Caption) — Win7 模式" -ForegroundColor Cyan

$osArchWmi = (Get-WmiObject Win32_OperatingSystem).OSArchitecture
$is32Bit = ($osArchWmi -match "32")
if ($is32Bit) { Write-Host "[信息] 32 位系统, 仅支持单线路" -ForegroundColor Yellow }

# === TLS 1.2 ===
function Enable-Tls12 {
    $p1 = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
    if (-not (Test-Path $p1)) { New-Item -Path $p1 -Force | Out-Null }
    Set-ItemProperty -Path $p1 -Name "DisabledByDefault" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $p1 -Name "Enabled" -Value 1 -Type DWord -Force
    $p2 = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client"
    if (-not (Test-Path $p2)) { New-Item -Path $p2 -Force | Out-Null }
    Set-ItemProperty -Path $p2 -Name "DisabledByDefault" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $p2 -Name "Enabled" -Value 1 -Type DWord -Force
    foreach ($np in @("HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319","HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727",
                      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319","HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727")) {
        Set-ItemProperty -Path $np -Name "SchUseStrongCrypto" -Value 1 -Type DWord -Force -ea SilentlyContinue
        Set-ItemProperty -Path $np -Name "SystemDefaultTlsVersions" -Value 1 -Type DWord -Force -ea SilentlyContinue
    }
    foreach ($wp in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp",
                      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp")) {
        if (-not (Test-Path $wp)) { New-Item -Path $wp -Force | Out-Null }
        Set-ItemProperty -Path $wp -Name "DefaultSecureProtocols" -Value 0x00000A80 -Type DWord -Force -ea SilentlyContinue
    }
}
Write-Host "[系统] 启用 TLS 1.2..." -ForegroundColor Cyan
try { Enable-Tls12; Write-Host "[OK]" -ForegroundColor Green } catch { Write-Host "[警告] TLS 失败" -ForegroundColor Yellow }

# === 下载函数 ===
function Download-File {
    param($Urls, $DestPath)
    if ($Urls -is [string]) { $Urls = @($Urls) }
    if (Test-Path $DestPath) { Remove-Item $DestPath -Force }
    foreach ($Url in $Urls) {
        foreach ($p in @("MSXML2.ServerXMLHTTP.6.0","MSXML2.ServerXMLHTTP.3.0","MSXML2.ServerXMLHTTP")) {
            try { $h = New-Object -ComObject $p -ea Stop; $h.setOption(2,13056); $h.open("GET",$Url,$false); $h.setTimeouts(30000,30000,30000,30000); $h.send()
                if ($h.status -eq 200) { [System.IO.File]::WriteAllBytes($DestPath,$h.responseBody); return $true } } catch {}
        }
        cmd /c "bitsadmin /transfer DL `"$Url`" `"$DestPath`"" 2>&1 | Out-Null
        if (Test-Path $DestPath) { return $true }
    }
    return $false
}

# === 依赖安装 ===
$kbsNeeded = @()
if (-not (Get-HotFix -Id KB4490628 -ea SilentlyContinue)) { $kbsNeeded += @{ KB="KB4490628"; Desc="服务栈更新" } }
if (-not (Get-HotFix -Id KB4474419 -ea SilentlyContinue)) { $kbsNeeded += @{ KB="KB4474419"; Desc="SHA-2签名" } }
if ($kbsNeeded.Count -gt 0) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [前提] SHA-2 补丁" -ForegroundColor Red; foreach ($k in $kbsNeeded) { Write-Host "  - $($k.KB)" -ForegroundColor Yellow }
    Write-Host "====================================================" -ForegroundColor Red
    $c = Read-Host "从本地安装? [Y] 是 [N] 手动下载 (默认Y)"
    if ($c -eq "" -or $c -eq "Y" -or $c -eq "y") {
        foreach ($k in $kbsNeeded) {
            $msu = @(Get-ChildItem $PluginDir -Filter "*$($k.KB)*.msu" -ea SilentlyContinue)[0]
            if ($msu) { $i="$env:TEMP\$($msu.Name)"; Copy-Item $msu.FullName $i -Force; Start-Process wusa.exe -ArgumentList "`"$i`" /quiet /norestart" -Wait }
            else { Write-Host "[错误] 未找到 $($k.KB), 下载放入 $PluginDir" -ForegroundColor Red; pause; exit 1 }
        }
        Write-Host "[OK] SHA-2 已安装, 继续..." -ForegroundColor Green
    } else { foreach ($k in $kbsNeeded) { Start-Process "https://www.catalog.update.microsoft.com/Search.aspx?q=$($k.KB)" }; pause; exit 1 }
}
$netKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ea SilentlyContinue
if (-not $netKey -or $netKey.Release -lt 378389) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [前提] .NET Framework 4.5+" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    $c = Read-Host "从本地安装 .NET 4.8? [Y] 是 [N] 手动下载 (默认Y)"
    if ($c -eq "" -or $c -eq "Y" -or $c -eq "y") {
        $lo = "$PluginDir\ndp48-web.exe"; $ins = "$env:TEMP\ndp48-web.exe"
        if (Test-Path $lo) { Copy-Item $lo $ins -Force; Write-Host "[本地] 发现安装包" -ForegroundColor DarkCyan }
        elseif (-not (Download-File -Urls @("https://go.microsoft.com/fwlink/?linkid=2088631") -DestPath $ins)) {
            Write-Host "[错误] 下载失败, 放入 $PluginDir" -ForegroundColor Red; pause; exit 1
        }
        Start-Process $ins -ArgumentList "/q /norestart" -Wait; Write-Host "[OK]" -ForegroundColor Green
    } else { Start-Process "https://dotnet.microsoft.com/download/dotnet-framework/net48"; pause; exit 1 }
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " [前提] WMF 5.1 (当前: $($PSVersionTable.PSVersion))" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    $c = Read-Host "从本地安装 WMF 5.1? [Y] 是 [N] 手动下载 (默认Y)"
    if ($c -eq "" -or $c -eq "Y" -or $c -eq "y") {
        $arch = (Get-WmiObject Win32_OperatingSystem).OSArchitecture
        $msuN = if ($arch -match "64") { "Win7AndW2K8R2-KB3191566-x64.msu" } else { "Win7-KB3191566-x86.msu" }
        $zipN = if ($arch -match "64") { "Win7AndW2K8R2-KB3191566-x64.zip" } else { "Win7-KB3191566-x86.zip" }
        $localMsu = "$PluginDir\$msuN"; $localZip = "$PluginDir\$zipN"; $installer = "$env:TEMP\$msuN"
        $found = $false
        if (Test-Path $localMsu) { Copy-Item $localMsu $installer -Force; $found = $true }
        elseif (Test-Path $localZip) {
            $ed = "$env:TEMP\wmf_e"; if (Test-Path $ed) { Remove-Item $ed -Recurse -Force }; New-Item -ItemType Directory $ed -Force | Out-Null
            try { $sh = New-Object -ComObject Shell.Application; $sh.NameSpace($ed).CopyHere($sh.NameSpace($localZip).Items(),16)
                for ($i=0;$i -lt 30;$i++) { Start-Sleep -Milliseconds 500; $ex = @(Get-ChildItem $ed -Filter "*.msu" -ea SilentlyContinue)[0]; if ($ex) { break } }
                if ($ex) { Copy-Item $ex.FullName $installer -Force; $found = $true } } catch {}
            if (Test-Path $ed) { Remove-Item $ed -Recurse -Force }
        }
        if (-not $found) { Write-Host "[错误] 未找到 WMF 5.1, 放入 $PluginDir" -ForegroundColor Red; pause; exit 1 }
        Start-Process wusa.exe -ArgumentList "`"$installer`" /quiet /norestart" -Wait
        Write-Host "[重要] 全部依赖已安装, 请重启" -ForegroundColor Yellow; pause; exit 1
    } else { Start-Process "https://www.microsoft.com/en-us/download/details.aspx?id=54616"; pause; exit 1 }
}

# === 配置读写 ===
function Read-Config {
    if (-not (Test-Path $ConfigPath)) { return @() }
    try {
        $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return @() }
        $data = $raw | ConvertFrom-Json
        if ($data -is [array]) { return @($data) }
        return @($data)
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
    for ($i = 10; $i -le 254; $i++) { $ip = "10.10.10.$i"; if ($used -notcontains $ip) { return $ip } }
    return $null
}
function New-LineId { $l = @(Read-Config); $m = 0; foreach ($x in $l) { $n = 0; if ([int]::TryParse($x.Id, [ref]$n) -and $n -gt $m) { $m = $n } }; return [string]($m + 1) }

# === 一端一网卡 (WMI + netsh) ===
function Get-AdapterById($id) {
    Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.NetConnectionID -eq "SMBProxy_$id" } | Select -First 1
}
function Rename-Adapter-Netsh($o, $n) { netsh interface set interface name="$o" newname="$n" 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }
function Enable-AdapterFn($id) {
    $na = Get-AdapterById $id; if ($na -and $na.NetConnectionStatus -ne 2) { $na.Enable() | Out-Null; Start-Sleep -Seconds 1 }
}
function Create-AdapterForLine($id) {
    $na = Get-AdapterById $id; if ($na) { Enable-AdapterFn $id; return $na.Index }
    $match = Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | Where-Object {
        ($_.Description -like "*Loopback*" -or $_.Description -like "*环回*" -or $_.Description -like "*KM-TEST*") -and
        $_.NetConnectionID -notlike "Loopback Pseudo-Interface*" -and $_.NetConnectionID -notlike "SMBProxy_*" -and $_.NetConnectionID
    } | Select -First 1
    if ($match) {
        Write-Host "[信息] 复用 Loopback: $($match.NetConnectionID) -> SMBProxy_$id" -ForegroundColor DarkCyan
        Rename-Adapter-Netsh $match.NetConnectionID "SMBProxy_$id" | Out-Null
        $na = Get-AdapterById $id; if ($na) { Enable-AdapterFn $id; return $na.Index }
    }
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  为线路 $id 创建 SMBProxy_$id (仅一次):" -ForegroundColor Yellow
    Write-Host "  1. 弹出窗口点 [下一步]" -ForegroundColor White
    Write-Host "  2. [安装我手动从列表选择的硬件] -> [下一步]" -ForegroundColor White
    Write-Host "  3. [网络适配器] -> [下一步]" -ForegroundColor White
    Write-Host "  4. 厂商 [Microsoft], [Microsoft Loopback Adapter]" -ForegroundColor White
    Write-Host "     (若没有则选 [Microsoft KM-TEST Loopback Adapter])" -ForegroundColor Gray
    Write-Host "  5. [下一步] -> [下一步] -> 完成 -> 回本窗口按任意键" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Yellow
    $snap = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | % { $_.PNPDeviceID })
    Start-Process hdwwiz.exe; pause
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $all = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue)
        $new = $all | Where-Object { ($snap -notcontains $_.PNPDeviceID) -and $_.NetConnectionID -and $_.NetConnectionID -notlike "SMBProxy_*" } | Select -First 1
        if ($new) {
            Write-Host "[信息] 发现: $($new.NetConnectionID)" -ForegroundColor DarkCyan
            Rename-Adapter-Netsh $new.NetConnectionID "SMBProxy_$id" | Out-Null; break
        }
        if (Get-AdapterById $id) { break }
    }
    $na = Get-AdapterById $id
    if ($na) { Enable-AdapterFn $id; Write-Host "[OK] SMBProxy_$id 就绪" -ForegroundColor Green; return $na.Index }
    Write-Host "[错误] 创建失败" -ForegroundColor Red; return $null
}
function Remove-AdapterForLine($id) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    netsh interface ip delete address name="SMBProxy_$id" addr=all 2>$null | Out-Null
    try { $na.Disable() | Out-Null } catch {}
    Write-Host "[OK] SMBProxy_$id IP 已移除" -ForegroundColor Green
    Write-Host "  [提示] 如设备未自动删除, 请在设备管理器中:" -ForegroundColor Yellow
    Write-Host "    右键 SMBProxy_$id → 卸载设备 → 确定" -ForegroundColor Gray
}
function Add-AdapterIP($id, $ip) {
    $c = netsh interface ip show addresses "SMBProxy_$id" 2>$null | Out-String
    if ($c -match [regex]::Escape($ip)) { return }
    netsh interface ip add address name="SMBProxy_$id" addr=$ip mask=255.255.255.255 2>&1 | Out-Null
}
function Remove-AdapterIP($id) {
    netsh interface ip delete address name="SMBProxy_$id" addr=all 2>$null | Out-Null
}

# === 防火墙逐条 (netsh) ===
function Setup-Firewall {}
function Add-Firewall($id, $ip) { netsh advfirewall firewall add rule name="$FwPrefix-$id" dir=in action=allow protocol=TCP localport=$LocalPort localip=$ip | Out-Null }
function Remove-Firewall($id) { netsh advfirewall firewall delete rule name="$FwPrefix-$id" 2>$null | Out-Null }
function Remove-FirewallAll { $l=@(Read-Config);foreach($x in $l){netsh advfirewall firewall delete rule name="$FwPrefix-$($x.Id)" 2>$null|Out-Null} }

# === SMB ===
function Test-SmbDisabled { $s=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ea SilentlyContinue; return ($s -and $s.Start -eq 4) }
function Disable-SmbAndFastBoot {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 4 -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 4 -Force -ea SilentlyContinue
    Set-Service LanmanServer -StartupType Disabled; try { Stop-Service LanmanServer -Force -ea SilentlyContinue } catch {}
    $hb=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ea SilentlyContinue
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

# === 进程 (WMI) ===
function Get-EngineProcess { Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ea SilentlyContinue | Where-Object { $_.CommandLine -like "*$EnginePath*" } }
function Stop-Engine { $p=Get-EngineProcess;foreach($x in $p){try{Stop-Process -Id $x.ProcessId -Force -ea SilentlyContinue}catch{}};if($p){Start-Sleep -Milliseconds 800};$retry=0;while((Get-EngineProcess) -and $retry -lt 5){Start-Sleep -Milliseconds 500;$retry++} }
function Start-Engine { Stop-Engine;$l=@(Read-Config);if($l.Count -eq 0){return};Write-EngineScript;Setup-Task;Start-Process powershell.exe -Arg "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`"" -WindowStyle Hidden }
function Setup-Task { $c=cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null;if($LASTEXITCODE -eq 0){return};$a="powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`"";cmd /c "schtasks /create /tn `"$TaskName`" /tr `"$a`" /sc onstart /ru SYSTEM /rl HIGHEST /delay 00:20 /f 2>&1"|Out-Null }
function Remove-Task { $c=cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null;if($LASTEXITCODE -eq 0){cmd /c "schtasks /delete /tn `"$TaskName`" /f 2>nul" 2>$null|Out-Null} }

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
    $ps=Read-Host "输入远程端口号 (默认 1445)";$port=1445;if($ps){[int]::TryParse($ps,[ref]$port)|Out-Null}
    if ($port -lt 1 -or $port -gt 65535) { Write-Host "端口无效" -ForegroundColor Red; return }
    $ip = Get-NextIP; if (-not $ip) { Write-Host "[错误] 无可用 IP" -ForegroundColor Red; return }
    $id=New-LineId
    $ifIdx = Create-AdapterForLine $id; if (-not $ifIdx) { Write-Host "[错误] 网卡创建失败" -ForegroundColor Red; return }
    Add-AdapterIP $id $ip;Add-Firewall $id $ip
    $l=@(Read-Config);$l+=@{Id=$id;IP=$ip;Domain=$domain;Port=$port};Save-Config $l
    Write-Host "[OK] 线路已添加: $id  $ip  SMBProxy_$id  $domain`:$port" -ForegroundColor Green
    Start-Engine
    pause
}
function Remove-Line {
    $l=@(Read-Config);if($l.Count -eq 0){return}
    $id = Read-Host "`n输入要删除的线路 ID"; if (-not $id) { return }
    $m = $l | Where-Object { $_.Id -eq $id }; if (-not $m) { Write-Host "[错误] 未找到 ID: $id" -ForegroundColor Red; return }
    Remove-AdapterForLine $id;Remove-Firewall $id
    $l=@($l|Where-Object{$_.Id -ne $id});Save-Config $l
    Write-Host "[OK] 线路已删除: $id" -ForegroundColor Green
    if ($l.Count -eq 0) { Stop-Engine } else { Start-Engine }
    pause
}
function Full-Uninstall {
    Write-Host "`n正在完全卸载..." -ForegroundColor Yellow; Remove-Task; Stop-Engine; Remove-FirewallAll
    $l = @(Read-Config); foreach ($x in $l) { Remove-AdapterForLine $x.Id }
    $remains = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.NetConnectionID -like "SMBProxy_*" })
    if ($remains.Count -gt 0) {
        Write-Host "`n  [提示] 以下网卡未能自动删除, 请在设备管理器中手动操作:" -ForegroundColor Yellow
        foreach ($r in $remains) { Write-Host "    右键 $($r.NetConnectionID) → 卸载设备 → 确定" -ForegroundColor Gray }
    }
    Restore-Smb; Start-Sleep -Seconds 1
    if (Test-Path $ToolboxDir) { Remove-Item $ToolboxDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $ToolboxDir) { Write-Host "  [提示] 请手动删除: $ToolboxDir" -ForegroundColor Yellow }
    Write-Host "[OK] 卸载完成, 建议重启" -ForegroundColor Green; pause; exit
}

# === 菜单 ===
function Show-Menu {
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     SMBProxy - Windows 7 (v4.5)                   " -ForegroundColor Cyan
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
    Write-Host "[1] 添加线路 (手动创建网卡)" -ForegroundColor Green
    Write-Host "[2] 删除线路 (自动移除网卡)" -ForegroundColor Yellow
    Write-Host "[3] 查看日志" -ForegroundColor Cyan
    Write-Host "[4] 完全卸载" -ForegroundColor Red
    Write-Host "[5] 重启引擎" -ForegroundColor Gray
    Write-Host "[0] 退出" -ForegroundColor Gray
}

# === 入口 ===
# 1. 检查 SMB
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

# 2. 检查 445 端口
$portCheck = cmd /c "netstat -ano" 2>$null | Select-String "LISTENING" | Select-String ":$($LocalPort)\s"
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

# 3. 确保已有线路的网卡 IP 绑定就绪
$l = @(Read-Config)
$hasAdapter = $false
foreach ($x in $l) {
    $na = Get-AdapterById $x.Id
    if ($na) { Add-AdapterIP $x.Id $x.IP; Add-Firewall $x.Id $x.IP; $hasAdapter = $true }
    else { Write-Host "[警告] 线路 $($x.Id) 的网卡不存在, 请删除后重新添加" -ForegroundColor Yellow }
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
