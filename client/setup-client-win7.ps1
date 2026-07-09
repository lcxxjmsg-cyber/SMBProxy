<#
.SYNOPSIS
    SMBProxy - Windows 7 (v4.5 - 双模式)
.DESCRIPTION
    每条线路独立 KM-TEST Loopback Adapter (SetupAPI 自动创建, 免重启)。
    WMI + netsh 操作, schtasks 计划任务, 含离线依赖管理。

    提供两种占用 445 端口的方案:
      [1] 禁用系统驱动模式 (稳定) - 禁用 srvnet/smbdevice/LanmanServer,
          445 端口彻底释放, 引擎直接监听 10.10.10.x:445。需重启一次。
          副作用: 本机 Windows 文件共享 (SMB/CIFS) 完全不可用。
      [2] 无副作用兼容模式 (推荐) - 将 srvnet 及其依赖服务改为手动启动,
          引擎开机抢先绑好 10.10.10.x:445, 再拉起系统 SMB (只能绑物理网卡)。
          即装即用无需重启, 本机文件共享照常可用。

    注意: Win7 需 WMF 5.1 + .NET 4.8 + SHA-2 补丁, 脚本自动检测并从 win7plug 安装。
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
$ModePath = "$ToolboxDir\mode.txt"

$os = Get-WmiObject Win32_OperatingSystem
if (-not ($os.Version -like "6.1.*") -or $os.ProductType -ne 1) {
    Write-Host "[错误] 本脚本仅适用于 Windows 7, 当前: $($os.Caption)" -ForegroundColor Red; pause; exit 1
}
Write-Host "[系统] $($os.Caption) — Win7 模式" -ForegroundColor Cyan

$osArchWmi = (Get-WmiObject Win32_OperatingSystem).OSArchitecture
$is32Bit = ($osArchWmi -match "32")
if ($is32Bit) { Write-Host "[信息] 32 位系统, 仅支持单线路" -ForegroundColor Yellow }

# === 模式标记 ===
function Get-Mode { if (Test-Path $ModePath) { try { (Get-Content $ModePath -Raw -ea Stop).Trim() } catch { $null } } else { $null } }
function Set-Mode($m) {
    if (-not (Test-Path $ToolboxDir)) { New-Item -ItemType Directory $ToolboxDir -Force | Out-Null }
    Set-Content $ModePath $m -Force -Encoding ASCII
}

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

# === 依赖安装 (Win7 需 SHA-2 / .NET 4.8 / WMF 5.1) ===
function Ensure-Dependencies {
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
            Write-Host "[重要] 全部依赖已安装, 请重启后重新运行" -ForegroundColor Yellow; pause; exit 1
        } else { Start-Process "https://www.microsoft.com/en-us/download/details.aspx?id=54616"; pause; exit 1 }
    }
}
Ensure-Dependencies

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
function Repair-Config {
    $old = @(Read-Config); $new = @()
    foreach($x in $old){
        if($x.IP -is [array]){ Write-Host "[修复] 删除IP数组污染线路: $($x.IP -join ',')" -ForegroundColor Yellow; continue }
        try {
            $ip = [System.Net.IPAddress]::Parse([string]$x.IP)
            if($ip.AddressFamily -eq "InterNetwork" -and $x.Id -and $x.Domain -and $x.Port){ $x.IP = [string]$x.IP; $new += $x }
            else { Write-Host "[修复] 删除字段异常线路" -ForegroundColor Yellow }
        } catch { Write-Host "[修复] 删除非法IP配置: $($x.IP)" -ForegroundColor Yellow }
    }
    if($new.Count -ne $old.Count){ Save-Config $new }
    return @($new)
}
function Get-NextIP {
    $lines = @(Read-Config); $used = @($lines | % { $_.IP })
    for ($i = 10; $i -le 254; $i++) { $ip = "10.10.10.$i"; if ($used -notcontains $ip) { return $ip } }
    return $null
}
function New-LineId { $l = @(Read-Config); $m = 0; foreach ($x in $l) { $n = 0; if ([int]::TryParse($x.Id, [ref]$n) -and $n -gt $m) { $m = $n } }; return [string]($m + 1) }

# === 一端一网卡 (WMI + netsh) + SetupAPI 自动创建 ===
function Get-AdapterById($id) {
    Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.NetConnectionID -eq "SMBProxy_$id" } | Select -First 1
}
function Rename-Adapter-Netsh($o, $n) { netsh interface set interface name="$o" newname="$n" 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }
function Enable-AdapterFn($id) {
    $na = Get-AdapterById $id; if ($na -and $na.NetConnectionStatus -ne 2) { try { $na.Enable() | Out-Null } catch {}; Start-Sleep -Seconds 1 }
}

# SetupAPI (P/Invoke) 程序化创建回环网卡: 无 GUI、无外部 exe、无联网、免重启。
$script:LoopbackTypeLoaded = $false
function Initialize-LoopbackType {
    if ($script:LoopbackTypeLoaded) { return $true }
    $code = @'
using System;
using System.Runtime.InteropServices;
public static class SMBProxyLoopback {
    const int SPDRP_HARDWAREID  = 0x00000001;
    const int DIF_REGISTERDEVICE= 0x00000019;
    const int DICD_GENERATE_ID  = 0x00000001;
    const int INSTALLFLAG_FORCE = 0x00000001;
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr h);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiCreateDeviceInfo(IntPtr h, string name, ref Guid cls, string desc, IntPtr parent, int flags, ref SP_DEVINFO_DATA d);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiSetDeviceRegistryProperty(IntPtr h, ref SP_DEVINFO_DATA d, int prop, byte[] buf, int size);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiCallClassInstaller(int fn, IntPtr h, ref SP_DEVINFO_DATA d);
    [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr parent, string hwid, string inf, int flags, out bool reboot);
    static Guid NET = new Guid("4d36e972-e325-11ce-bfc1-08002be10318");
    public static bool Install(string hwid, string inf, out bool reboot) {
        reboot = false; Guid cls = NET;
        IntPtr h = SetupDiCreateDeviceInfoList(ref cls, IntPtr.Zero);
        if (h == (IntPtr)(-1)) throw new Exception("CreateDeviceInfoList: " + Marshal.GetLastWin32Error());
        try {
            SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
            d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiCreateDeviceInfo(h, "NET", ref cls, null, IntPtr.Zero, DICD_GENERATE_ID, ref d))
                throw new Exception("CreateDeviceInfo: " + Marshal.GetLastWin32Error());
            byte[] hb = System.Text.Encoding.Unicode.GetBytes(hwid + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(h, ref d, SPDRP_HARDWAREID, hb, hb.Length))
                throw new Exception("SetHardwareID: " + Marshal.GetLastWin32Error());
            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, h, ref d))
                throw new Exception("RegisterDevice: " + Marshal.GetLastWin32Error());
            bool rb;
            if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, INSTALLFLAG_FORCE, out rb))
                throw new Exception("UpdateDriver: " + Marshal.GetLastWin32Error());
            reboot = rb; return true;
        } finally { SetupDiDestroyDeviceInfoList(h); }
    }
    const int DIGCF_ALLCLASSES = 0x00000004;
    const int DIF_REMOVE       = 0x00000005;
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SetupDiGetClassDevs(IntPtr ClassGuid, string Enumerator, IntPtr hwndParent, int Flags);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr h, int index, ref SP_DEVINFO_DATA d);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiGetDeviceInstanceId(IntPtr h, ref SP_DEVINFO_DATA d, System.Text.StringBuilder id, int size, out int required);
    // 按设备实例ID (PNPDeviceID) 卸载设备。找到并 DIF_REMOVE。返回是否成功。
    public static bool RemoveByInstanceId(string instanceId) {
        IntPtr h = SetupDiGetClassDevs(IntPtr.Zero, null, IntPtr.Zero, DIGCF_ALLCLASSES);
        if (h == (IntPtr)(-1)) throw new Exception("GetClassDevs: " + Marshal.GetLastWin32Error());
        try {
            SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
            d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            for (int i = 0; SetupDiEnumDeviceInfo(h, i, ref d); i++) {
                System.Text.StringBuilder sb = new System.Text.StringBuilder(512);
                int req;
                if (SetupDiGetDeviceInstanceId(h, ref d, sb, 512, out req)) {
                    if (string.Equals(sb.ToString(), instanceId, StringComparison.OrdinalIgnoreCase)) {
                        bool ok = SetupDiCallClassInstaller(DIF_REMOVE, h, ref d);
                        if (!ok) throw new Exception("DIF_REMOVE: " + Marshal.GetLastWin32Error());
                        return true;
                    }
                }
                d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            }
            return false;
        } finally { SetupDiDestroyDeviceInfoList(h); }
    }
}
'@
    try { Add-Type -TypeDefinition $code -ErrorAction Stop; $script:LoopbackTypeLoaded = $true; return $true }
    catch { Write-Host "[信息] SetupAPI 加载失败, 将回退其他方式: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $false }
}
# 用 SetupAPI 创建回环网卡并命名 SMBProxy_$id (WMI 定位)。成功返回 Index, 失败 $null。
function New-LoopbackViaSetupApi($id) {
    if (-not (Initialize-LoopbackType)) { return $null }
    $inf = "$env:windir\inf\netloop.inf"
    if (-not (Test-Path $inf)) { return $null }
    $before = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | % { $_.PNPDeviceID })
    if (Test-Path "$env:windir\system32\pnputil.exe") { & pnputil.exe /add-driver $inf 2>&1 | Out-Null }
    $reboot = $false
    try { [void][SMBProxyLoopback]::Install('*MSLOOP', $inf, [ref]$reboot) }
    catch { Write-Host "[信息] SetupAPI 创建失败: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $null }
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $all = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue)
        $new = $all | Where-Object { ($before -notcontains $_.PNPDeviceID) -and $_.NetConnectionID -and $_.NetConnectionID -notlike "SMBProxy_*" } | Select -First 1
        if ($new) {
            Rename-Adapter-Netsh $new.NetConnectionID "SMBProxy_$id" | Out-Null
            $na = Get-AdapterById $id
            if ($na) { Enable-AdapterFn $id; Write-Host "[OK] 已自动创建回环网卡 SMBProxy_$id (SetupAPI, 免重启)" -ForegroundColor Green; return $na.Index }
        }
        if (Get-AdapterById $id) { return (Get-AdapterById $id).Index }
    }
    return $null
}
function Create-AdapterForLine($id) {
    $na = Get-AdapterById $id; if ($na) { Enable-AdapterFn $id; return $na.Index }
    # 复用现有空闲 Loopback
    $match = Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | Where-Object {
        ($_.Description -like "*Loopback*" -or $_.Description -like "*环回*" -or $_.Description -like "*KM-TEST*") -and
        $_.NetConnectionID -notlike "Loopback Pseudo-Interface*" -and $_.NetConnectionID -notlike "SMBProxy_*" -and $_.NetConnectionID
    } | Select -First 1
    if ($match) {
        Write-Host "[信息] 复用 Loopback: $($match.NetConnectionID) -> SMBProxy_$id" -ForegroundColor DarkCyan
        Rename-Adapter-Netsh $match.NetConnectionID "SMBProxy_$id" | Out-Null
        $na = Get-AdapterById $id; if ($na) { Enable-AdapterFn $id; return $na.Index }
    }
    # SetupAPI 自动创建 (免重启)
    Write-Host "[信息] 正在自动创建回环网卡 (SetupAPI)..." -ForegroundColor Cyan
    $idx = New-LoopbackViaSetupApi $id
    if ($idx) { return $idx }
    # 兜底: 手动向导
    Write-Host "`n============================================================" -ForegroundColor Yellow
    Write-Host "  [手动操作] 自动创建失败, 为线路 $id 手动创建 SMBProxy_${id}:" -ForegroundColor Yellow
    Write-Host "  1. 弹出窗口点 [下一步]" -ForegroundColor White
    Write-Host "  2. [安装我手动从列表选择的硬件] -> [下一步]" -ForegroundColor White
    Write-Host "  3. [网络适配器] -> [下一步]" -ForegroundColor White
    Write-Host "  4. 厂商 [Microsoft], [Microsoft KM-TEST Loopback Adapter]" -ForegroundColor White
    Write-Host "  5. [下一步] -> 完成 -> 回本窗口按任意键" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Yellow
    $snap = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | % { $_.PNPDeviceID })
    Start-Process hdwwiz.exe; pause
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $all = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue)
        $new = $all | Where-Object { ($snap -notcontains $_.PNPDeviceID) -and $_.NetConnectionID -and $_.NetConnectionID -notlike "SMBProxy_*" } | Select -First 1
        if ($new) { Write-Host "[信息] 发现: $($new.NetConnectionID)" -ForegroundColor DarkCyan; Rename-Adapter-Netsh $new.NetConnectionID "SMBProxy_$id" | Out-Null; break }
        if (Get-AdapterById $id) { break }
    }
    $na = Get-AdapterById $id
    if ($na) { Enable-AdapterFn $id; Write-Host "[OK] SMBProxy_$id 就绪" -ForegroundColor Green; return $na.Index }
    Write-Host "[错误] 创建失败" -ForegroundColor Red; return $null
}
function Remove-AdapterForLine($id) {
    $na = Get-AdapterById $id; if (-not $na) { return }
    $pnp = $na.PNPDeviceID
    netsh interface ip delete address name="SMBProxy_$id" addr=all 2>$null | Out-Null
    # 优先 SetupAPI 卸载设备 (Win7 通用); 失败再退 pnputil / 禁用
    $removed = $false
    if ($pnp -and (Initialize-LoopbackType)) {
        try { $removed = [SMBProxyLoopback]::RemoveByInstanceId($pnp) } catch {}
    }
    if (-not $removed -and $pnp -and (Test-Path "$env:windir\system32\pnputil.exe")) {
        try { & pnputil.exe /remove-device "$pnp" 2>&1 | Out-Null; if (-not (Get-AdapterById $id)) { $removed = $true } } catch {}
    }
    if (-not $removed) { try { $na.Disable() | Out-Null } catch {} }
    Start-Sleep -Seconds 1
    if (-not (Get-AdapterById $id)) { Write-Host "[OK] SMBProxy_$id 已移除" -ForegroundColor Green }
    else { Write-Host "  [提示] 如设备未自动删除, 请在设备管理器中: 右键 SMBProxy_$id -> 卸载设备" -ForegroundColor Yellow }
}
function Add-AdapterIP($id, $ip) {
    $c = netsh interface ip show addresses "SMBProxy_$id" 2>$null | Out-String
    if ($c -match [regex]::Escape($ip)) { return }
    netsh interface ip add address name="SMBProxy_$id" addr=$ip mask=255.255.255.0 2>&1 | Out-Null
}
function Remove-AdapterIP($id) {
    netsh interface ip delete address name="SMBProxy_$id" addr=all 2>$null | Out-Null
}

# === 防火墙逐条 (netsh) ===
function Setup-Firewall {}
function Add-Firewall($id, $ip) { netsh advfirewall firewall add rule name="$FwPrefix-$id" dir=in action=allow protocol=TCP localport=$LocalPort localip=$ip | Out-Null }
function Remove-Firewall($id) { netsh advfirewall firewall delete rule name="$FwPrefix-$id" 2>$null | Out-Null }
function Remove-FirewallAll { $l=@(Read-Config);foreach($x in $l){netsh advfirewall firewall delete rule name="$FwPrefix-$($x.Id)" 2>$null|Out-Null} }

# === SMB (禁用模式) ===
function Test-SmbDisabled { $s=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -ea SilentlyContinue; return ($s -and $s.Start -eq 4) }
function Disable-SmbAndFastBoot {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 4 -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\smbdevice" -Name "Start" -Value 4 -Force -ea SilentlyContinue
    Set-Service LanmanServer -StartupType Disabled; try { & cmd /c "sc stop LanmanServer" 2>&1 | Out-Null } catch {}
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

# === 兼容模式: 依赖链改手动 + 引擎抢先绑445 + 引擎再启服务 ===
# Win7 服务名容错: srvnet / srv2 / srv / LanmanServer (存在才处理, 不存在忽略)
$CompatServices = @('LanmanServer','srv2','srv','srvnet')
function Test-ServiceExists($name) { return [bool](Get-Service -Name $name -ea SilentlyContinue) }
function Set-ServiceStart([string]$name, [string]$startType) {
    if (-not (Test-ServiceExists $name)) { return $true }   # 不存在视为无需处理
    & cmd /c "sc config $name start= $startType" 2>$null | Out-Null
    $want = if ($startType -eq 'demand') { 3 } elseif ($startType -eq 'auto') { 2 } else { -1 }
    $cur = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name "Start" -ea SilentlyContinue).Start
    return ($cur -eq $want)
}
function Enable-CompatMode {
    $failed = @()
    foreach ($svc in $CompatServices) { if (-not (Set-ServiceStart $svc 'demand')) { $failed += $svc } }
    & cmd /c "sc config smbdevice start= demand" 2>$null | Out-Null
    Disable-FastBoot
    # 只有 srvnet/LanmanServer 是关键, 其它失败不阻断
    $critical = @($failed | Where-Object { $_ -eq 'srvnet' -or $_ -eq 'LanmanServer' })
    if ($critical.Count -gt 0) { throw "关键服务未能改为手动: $($critical -join ', ') (请确认管理员权限)" }
}
function Restore-CompatMode {
    foreach ($svc in @('srvnet','srv','srv2','LanmanServer')) { Set-ServiceStart $svc 'auto' | Out-Null }
    & cmd /c "sc config smbdevice start= auto" 2>$null | Out-Null
    try { Start-Service srvnet -ea SilentlyContinue } catch {}
    try { Start-Service LanmanServer -ea SilentlyContinue } catch {}
}
function Test-CompatConfigured {
    foreach ($svc in @('srvnet','LanmanServer')) {
        $s = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name "Start" -ea SilentlyContinue).Start
        if ($s -ne 3) { return $false }
    }
    return $true
}
function Disable-FastBoot {
    $hb=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ea SilentlyContinue
    if(-not$hb -or $hb.HiberbootEnabled -ne 0){Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Force}
}

# === 进程 & 计划任务 (WMI + schtasks) ===
function Get-EngineProcess { Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ea SilentlyContinue | Where-Object { $_.CommandLine -like "*$EnginePath*" } }
function Stop-Engine { $p=Get-EngineProcess;foreach($x in $p){try{Stop-Process -Id $x.ProcessId -Force -ea SilentlyContinue}catch{}};if($p){Start-Sleep -Milliseconds 800};$retry=0;while((Get-EngineProcess) -and $retry -lt 5){Start-Sleep -Milliseconds 500;$retry++} }
function Start-Engine { Stop-Engine;$l=@(Read-Config);if($l.Count -eq 0){return};Write-EngineScript;Setup-Task;Start-Process powershell.exe -Arg "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`"" -WindowStyle Hidden }
function Setup-Task {
    $a="powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`""
    cmd /c "schtasks /create /tn `"$TaskName`" /tr `"$a`" /sc onstart /ru SYSTEM /rl HIGHEST /delay 0000:05 /f 2>&1"|Out-Null
}
function Remove-Task { $c=cmd /c "schtasks /query /tn `"$TaskName`" /fo csv /nh 2>nul" 2>$null;if($LASTEXITCODE -eq 0){cmd /c "schtasks /delete /tn `"$TaskName`" /f 2>nul" 2>$null|Out-Null} }

# === 引擎 ===
function Write-EngineScript {
    $compatFlag = if ((Get-Mode) -eq 'compat') { '$true' } else { '$false' }
    $h=@"
`$ConfigPath='$ConfigPath';`$LogPath='$LogPath';`$LocalPort=$LocalPort;`$CompatMode=$compatFlag
"@
    $b=@'
$ErrorActionPreference="SilentlyContinue"
try{ Add-Type -AssemblyName System.ServiceProcess -ErrorAction SilentlyContinue }catch{}
try{ [void][System.Reflection.Assembly]::LoadWithPartialName('System.ServiceProcess') }catch{}
function Write-Log($m){$l="[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$m;try{Add-Content $LogPath $l -Encoding UTF8}catch{}}
function DNS($d){try{$ar=[System.Net.Dns]::BeginGetHostAddresses($d,$null,$null);if(-not$ar.AsyncWaitHandle.WaitOne(5000)){return $null};$a=[System.Net.Dns]::EndGetHostAddresses($ar);$v6=$a|?{$_.AddressFamily -eq'InterNetworkV6'}|select -First 1;if($v6){return @{IP=$v6.IPAddressToString;Family=$v6.AddressFamily}};$v4=$a|?{$_.AddressFamily -eq'InterNetwork'}|select -First 1;if($v4){return @{IP=$v4.IPAddressToString;Family=$v4.AddressFamily}}}catch{};return $null}
function Pump($a,$b){try{$as=$a.GetStream();$bs=$b.GetStream();$t=$as.CopyToAsync($bs,65536);$cb={param($x)try{$a.GetStream().Close()}catch{}try{$a.Close()}catch{}try{$b.GetStream().Close()}catch{}try{$b.Close()}catch{}}.GetNewClosure();$t.ContinueWith([Action[Threading.Tasks.Task]]$cb)|Out-Null}catch{try{$a.Close()}catch{}try{$b.Close()}catch{}}}
function Start-SystemSmb{try{Start-Service srvnet -ea SilentlyContinue}catch{};try{Start-Service LanmanServer -ea SilentlyContinue}catch{};Write-Log("[系统SMB] 已启动 srvnet + LanmanServer (本机共享恢复)")}
function Test-Bind($ip){$t=$null;try{$t=New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($ip),$LocalPort);$t.Start();$t.Stop();return $true}catch{return $false}finally{if($t){try{$t.Stop()}catch{}}}}
function Stop-Svc($name){try{& cmd /c "sc stop $name" 2>&1 | Out-Null}catch{}}
# 逐个发停止请求 (异步, 不逐个等待; 由外层 Stop-SystemSmb 轮询 Test-Bind 判定是否已释放)。
# 顺序: 依赖 srvnet 的服务在前, srvnet 在后。不存在的服务 sc 静默跳过。
# 用 .NET ServiceController 停服务并阻塞等待到 Stopped (不交互、不挂起; 避免 net stop 在无人值守窗口挂死)。
# 关键: 不用 net stop(会在隐藏窗口挂起), 不用 Stop-Service -Force(PS4有"集合已修改"bug)。
# 按依赖树顺序逐个停: 依赖者在前, srvnet 在最后。
# 停止一个服务: 先递归停它的所有依赖者(ServiceController.Stop 不级联, 必须手动先停依赖者), 再停自己。阻塞等待。
function Stop-OneSvc($name,$timeoutSec){
    try{
        $sc=New-Object System.ServiceProcess.ServiceController($name)
        $sc.Refresh()
        if($sc.Status -eq 'Stopped'){return $true}
        # 先停所有依赖本服务的服务 (递归)
        foreach($dep in $sc.DependentServices){
            if($dep.Status -ne 'Stopped'){ Stop-OneSvc $dep.ServiceName $timeoutSec | Out-Null }
        }
        try{$sc.Refresh(); if($sc.Status -ne 'Stopped'){$sc.Stop()} }catch{Write-Log("[停服务] $name Stop()异常: $($_.Exception.Message)")}
        try{$sc.WaitForStatus('Stopped',[TimeSpan]::FromSeconds($timeoutSec))}catch{Write-Log("[停服务] $name 等待Stopped超时")}
        $sc.Refresh()
        if($sc.Status -ne 'Stopped'){Write-Log("[停服务] $name 停止后状态=$($sc.Status)")}
        return ($sc.Status -eq 'Stopped')
    }catch{return $true}  # 服务不存在等, 视为无需处理
}
# 检查 srvnet 是否已停
# 用 sc query 判 srvnet 是否已停 (不依赖 ServiceController 程序集, 最可靠)
function Test-SrvnetStopped{ $q=& cmd /c "sc query srvnet" 2>&1; return ($q -match 'STATE\s*:\s*1\s' -or $q -match '1060') }
# 多轮尝试停整条 SMB 链, 直到 srvnet 停掉 (ServiceController.Stop 不级联, 时序上偶尔需多轮补停; 最多 6 轮)。
function Get-SvcStatusStr{ $r=@(); foreach($s in @('Browser','LanmanServer','srv','srv2','srvnet')){ try{$sc=New-Object System.ServiceProcess.ServiceController($s);$sc.Refresh();$r+="$s=$($sc.Status)"}catch{$r+="$s=NA"} }; return ($r -join ' ') }
function Stop-SmbChain{
    for($pass=0; $pass -lt 6; $pass++){
        foreach($svc in @('HomeGroupListener','Browser','LanmanServer','srv','srv2','srvnet')){ Stop-OneSvc $svc 15 | Out-Null }
        Write-Log("[停链] 第$($pass+1)轮后: $(Get-SvcStatusStr)")
        if(Test-SrvnetStopped){ Write-Log("[停链] srvnet已停, 退出停链"); return }
        Start-Sleep -Milliseconds 800
    }
    Write-Log("[停链] 6轮后 srvnet 仍未停")
}
# 踢掉本机入站 SMB 会话与打开文件, 释放 srvnet 句柄 (否则本机被别人连着共享时 srvnet 停不掉)
# 停止 LanmanServer(ServiceController)本身即会强制关闭所有入站 SMB 会话, 故此处无需再用 net session
# (net session 在无人值守 SYSTEM 窗口可能挂起, 已弃用)。保留空函数以兼容调用点。
function Kick-SmbSessions{ }
function Stop-SystemSmb($probeIp){
    Kick-SmbSessions
    Stop-SmbChain
    $deadline=(Get-Date).AddSeconds(50)
    while((Get-Date) -lt $deadline){
        if(-not $probeIp){Start-Sleep -Milliseconds 500;break}
        if(Test-Bind $probeIp){Write-Log("[系统SMB] 已停止, 445已释放 (可抢占)");return $true}
        Kick-SmbSessions
        Stop-SmbChain
        Start-Sleep -Seconds 1
    }
    if($probeIp -and -not (Test-Bind $probeIp)){
        $bindErr='';try{$tt=New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($probeIp),$LocalPort);$tt.Start();$tt.Stop()}catch{$bindErr=$_.Exception.Message};if($tt){try{$tt.Stop()}catch{}}
        $ns='';try{$ns=(& cmd /c "netstat -ano" 2>&1 | Select-String ":445\s" | Select-Object -First 3) -join ' | '}catch{}
        Write-Log("[严重] 抢占失败! srvnet状态: $(if(Test-SrvnetStopped){'Stopped'}else{'Running'}); 绑${probeIp}:445异常: $bindErr; 445占用: $ns");return $false
    }
    Write-Log("[系统SMB] 已停止 (准备抢占445)");return $true
}
Write-Log "===== SMBProxy v4.5 ====="
try{ $osc=(Get-WmiObject Win32_OperatingSystem).Caption; Write-Log("[环境] OS=$osc; PS=$($PSVersionTable.PSVersion); 模式=$(if($CompatMode){'兼容'}else{'禁用'}); 端口=$LocalPort") }catch{}
$L=@{};$lastCheck=(Get-Date).AddDays(-1);$lastLogClean=Get-Date;$smbStarted=$false
while($true){try{$now=Get-Date
    if(($now-$lastCheck).TotalSeconds -ge 10){
        $cfg=@()
        try{$raw=Get-Content $ConfigPath -Raw -ErrorAction Stop;$obj=$raw|ConvertFrom-Json;if($obj -is [System.Array]){$cfg=@($obj)}else{$cfg=@($obj)}}catch{Write-Log("[配置读取失败] $($_.Exception.Message)")}
        $live=@($cfg|%{$_.IP})
        foreach($ip in @($L.Keys)){if($ip -notin $live){try{$L[$ip].Listener.Stop()}catch{};$L.Remove($ip);Write-Log("[下线] $ip")}}
        if($CompatMode -and $cfg.Count -gt 0){
            $anyUnbound=$false;foreach($line in $cfg){if($line -and $line.IP -and -not $L.ContainsKey($line.IP)){$anyUnbound=$true;break}}
            if($anyUnbound){
                $probe=$null;foreach($line in $cfg){if($line -and $line.IP -and -not($line.IP -is [array])){$probe=([string]$line.IP).Trim();break}}
                $grabbed=Stop-SystemSmb $probe;$smbStarted=$false
                if(-not $grabbed){$lastCheck=Get-Date;Start-Sleep -Seconds 2;continue}
            }
        }
        foreach($line in $cfg){
            if(-not$line -or -not$line.IP){continue}
            if($line.IP -is [array]){Write-Log("[忽略异常IP数组] $($line.IP -join ',')");continue}
            $ipText=([string]$line.IP).Trim()
            try{$check=[System.Net.IPAddress]::Parse($ipText);if($check.AddressFamily -ne "InterNetwork"){continue}}catch{Write-Log("[忽略非法配置IP] $ipText");continue}
            if(-not$L.ContainsKey($line.IP)){
                # 确保回环网卡 IP 已就绪 (开机时 IP 可能未持久化恢复), 否则绑 445 会报"地址无效"
                $adp="SMBProxy_$($line.Id)"; $cur=& cmd /c "netsh interface ip show addresses `"$adp`"" 2>&1 | Out-String
                if($cur -notmatch [regex]::Escape($ipText)){ & cmd /c "netsh interface ip add address name=`"$adp`" addr=$ipText mask=255.255.255.0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Write-Log("[补绑IP] $ipText -> $adp") }
                $ln=$null;for($r=0;$r -lt 3;$r++){try{$tmp=New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($line.IP),$LocalPort);$tmp.Start();$ln=$tmp;break}catch{try{if($tmp){$tmp.Stop()}}catch{};$tmp=$null;$ln=$null;if($r -lt 2){Start-Sleep -Seconds 2}}}
                if($ln){$L[$line.IP]=@{Listener=$ln;Line=$line;Endpoint=$null;LastResolve=(Get-Date).AddDays(-1)};Write-Log("[上线] {0}:{1} -> {2}:{3}" -f $line.IP,$LocalPort,$line.Domain,$line.Port)}else{Write-Log("[监听失败] $ipText 三次重试后仍无法绑定, 稍后重试")}
            }
        }$lastCheck=Get-Date
        if($CompatMode -and -not $smbStarted -and $cfg.Count -gt 0){
            $boundAll=$true;foreach($line in $cfg){if($line -and $line.IP -and -not $L.ContainsKey($line.IP)){$boundAll=$false;break}}
            if($boundAll){Start-SystemSmb;$smbStarted=$true}
        }
    }
    if(($now-$lastLogClean).TotalHours -ge 1){try{if((Get-Item $LogPath -ea Stop).Length -gt 5MB){$keep=@(Get-Content $LogPath -ErrorAction Stop -Tail 500);$hdr="[{0}] [日志滚动] 超5MB, 已保留最近500行" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss");Set-Content $LogPath ($hdr,$keep) -Encoding UTF8}}catch{};$lastLogClean=Get-Date}
    foreach($ip in @($L.Keys)){$e=$L[$ip];if(($now-$e.LastResolve).TotalSeconds -ge 60){$ep=DNS $e.Line.Domain;if($ep){$e.Endpoint=$ep};$e.LastResolve=Get-Date;break}}
    foreach($ip in @($L.Keys)){$e=$L[$ip];$hasPending=$false;try{$hasPending=$e.Listener.Pending()}catch{continue};if(-not$hasPending){continue};if(-not$e.Endpoint){continue};$c=$e.Listener.AcceptTcpClient()
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
    $success = $false
    $mode = Get-Mode
    $isCompat = ($mode -eq 'compat')
    try {
        Write-Host "[1/4] 创建虚拟网卡..." -ForegroundColor Cyan
        $ifIdx = Create-AdapterForLine $id; if (-not $ifIdx) { throw "网卡创建失败" }
        Write-Host "[2/4] 绑定虚拟IP..." -ForegroundColor Cyan
        Add-AdapterIP $id $ip
        Write-Host "[3/4] 添加防火墙规则..." -ForegroundColor Cyan
        Add-Firewall $id $ip
        Write-Host "[4/4] 保存配置..." -ForegroundColor Cyan
        $l=@(Read-Config);$l+=@{Id=$id;IP=$ip;Domain=$domain;Port=$port;State="active"};Save-Config $l
        $success = $true
        Write-Host "[OK] 线路已添加: $id  $ip  SMBProxy_$id  $domain`:$port" -ForegroundColor Green
    } catch {
        Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[回滚] 正在清理残留..." -ForegroundColor Yellow
        Remove-AdapterIP $id; Remove-Firewall $id; Remove-AdapterForLine $id
        if ($isCompat) { try { Start-Service srvnet -ea SilentlyContinue; Start-Service LanmanServer -ea SilentlyContinue } catch {} }
        Write-Host "[完成] 原配置未被污染" -ForegroundColor Yellow
    }
    if ($success) { Start-Engine }
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
    $mode = Get-Mode
    $l = @(Read-Config); foreach ($x in $l) { Remove-AdapterForLine $x.Id }
    $remains = @(Get-WmiObject Win32_NetworkAdapter -ea SilentlyContinue | Where-Object { $_.NetConnectionID -like "SMBProxy_*" })
    if ($remains.Count -gt 0) {
        Write-Host "`n  [提示] 以下网卡未能自动删除, 请在设备管理器中手动操作:" -ForegroundColor Yellow
        foreach ($r in $remains) { Write-Host "    右键 $($r.NetConnectionID) -> 卸载设备" -ForegroundColor Gray }
    }
    if ($mode -eq 'compat') {
        Write-Host "[兼容模式] 还原 srvnet/LanmanServer 为自动启动..." -ForegroundColor Cyan
        Restore-CompatMode
    } else {
        Restore-Smb
    }
    Start-Sleep -Seconds 1
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
    $mode = Get-Mode
    $modeText = if ($mode -eq 'compat') { "无副作用兼容模式 (系统 SMB 保留)" } elseif ($mode -eq 'disable') { "禁用系统驱动模式" } else { "未设置" }
    $modeColor = if ($mode -eq 'compat') { "Green" } elseif ($mode -eq 'disable') { "Yellow" } else { "Gray" }
    Write-Host "  模式: $modeText" -ForegroundColor $modeColor
    $procs = Get-EngineProcess
    if ($procs) { Write-Host "  引擎: 运行中 (PID: $($procs[0].ProcessId))" -ForegroundColor Green }
    else { Write-Host "  引擎: 已停止" -ForegroundColor Yellow }
    $l = @(Read-Config)
    Write-Host "`n  ID   Adapter          VirtualIP        Domain:Port" -ForegroundColor DarkCyan
    Write-Host "  ----  ───────────────  ──────────────   ──────────────────" -ForegroundColor DarkCyan
    if ($l.Count -eq 0) { Write-Host "  (暂无线路)" -ForegroundColor Gray }
    else { foreach ($x in $l) { Write-Host ("  {0,-5} SMBProxy_{0,-8} {1,-16} {2}:{3}" -f $x.Id, $x.IP, $x.Domain, $x.Port) -ForegroundColor White } }
    Write-Host "`n  线路: $($l.Count)" -ForegroundColor Gray; Write-Host ""
    Write-Host "[1] 添加线路" -ForegroundColor Green
    Write-Host "[2] 删除线路" -ForegroundColor Yellow
    Write-Host "[3] 查看日志" -ForegroundColor Cyan
    Write-Host "[4] 完全卸载" -ForegroundColor Red
    Write-Host "[5] 重启引擎" -ForegroundColor Gray
    Write-Host "[0] 退出" -ForegroundColor Gray
}

# === 模式选择 (首次运行) ===
function Show-ModeChooser {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " [首次运行] 请选择工作模式" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " [2] 无副作用兼容模式 (推荐)" -ForegroundColor Cyan
    Write-Host "     即装即用, 无需重启。" -ForegroundColor Gray
    Write-Host "     本机 Windows 文件共享照常可用, 不受任何影响。" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [1] 禁用系统驱动模式" -ForegroundColor Green
    Write-Host "     需要重启一次。" -ForegroundColor Gray
    Write-Host "     本机 Windows 文件共享将被禁用 (卸载后可恢复)。" -ForegroundColor Gray
    Write-Host ""
    Write-Host " [3] 退出安装" -ForegroundColor Gray
    Write-Host ""
    Write-Host " 以上修改均可通过菜单 [4] 完全卸载 恢复原状。" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Yellow
}

# === 入口 ===
Repair-Config | Out-Null
$mode = Get-Mode
$smbDisabled = Test-SmbDisabled

if (-not $smbDisabled -and $mode -ne 'compat') {
    Show-ModeChooser
    $choice = Read-Host "请选择 (默认 2)"
    if (-not $choice) { $choice = "2" }
    switch ($choice) {
        "1" {
            Write-Host "`n[禁用系统驱动模式] 即将禁用 srvnet/smbdevice/LanmanServer..." -ForegroundColor Yellow
            Set-Mode 'disable'
            Disable-SmbAndFastBoot
        }
        "2" {
            Write-Host "`n[无副作用兼容模式] 正在配置 (srvnet 及依赖改手动启动)..." -ForegroundColor Yellow
            Set-Mode 'compat'
            try { Enable-CompatMode } catch { Write-Host "[错误] 兼容模式配置失败: $($_.Exception.Message)" -ForegroundColor Red; pause; exit 1 }
            $mode = 'compat'
            Write-Host "[无副作用兼容模式] 已启用。系统 SMB 服务保留, 物理网卡共享可用。" -ForegroundColor Green
            Write-Host "  接下来在菜单中 [1] 添加线路即可 (无需重启)。" -ForegroundColor Gray
            Start-Sleep -Seconds 2
        }
        default { Write-Host "已退出安装。" -ForegroundColor Gray; exit 0 }
    }
}

# 禁用模式: 445 必须彻底干净
if ($mode -ne 'compat') {
    $portCheck = cmd /c "netstat -ano" 2>$null | Select-String "LISTENING" | Select-String ":$($LocalPort)\s"
    if ($portCheck) {
        $engProcs = Get-EngineProcess
        $isOwn = $false
        foreach ($ep in $engProcs) { if ($portCheck -match $ep.ProcessId) { $isOwn = $true; break } }
        if ($isOwn) { Write-Host "[信息] 检测到残留引擎, 正在清理..." -ForegroundColor Yellow; Stop-Engine }
        else {
            Write-Host "`n==========================================================" -ForegroundColor Red
            Write-Host " [错误] 端口 $LocalPort 仍被占用! 是否已重启电脑?" -ForegroundColor Red
            Write-Host $portCheck -ForegroundColor Gray
            Write-Host "==========================================================" -ForegroundColor Red; pause; exit 1
        }
    }
}

# 恢复已有线路的网卡 IP / 防火墙
$l = @(Read-Config)
$hasAdapter = $false
foreach ($x in $l) {
    $na = Get-AdapterById $x.Id
    if ($na) { Add-AdapterIP $x.Id $x.IP; Add-Firewall $x.Id $x.IP; $hasAdapter = $true }
    else { Write-Host "[警告] 线路 $($x.Id) 的网卡不存在, 请删除后重新添加" -ForegroundColor Yellow }
}
if ($mode -eq 'compat' -and $hasAdapter) {
    if (-not (Test-CompatConfigured)) { try { Enable-CompatMode } catch { Write-Host "[警告] 兼容模式服务配置失败: $($_.Exception.Message)" -ForegroundColor Yellow } }
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
