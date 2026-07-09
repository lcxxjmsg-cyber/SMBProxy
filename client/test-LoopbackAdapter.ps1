<#
.SYNOPSIS
    独立测试: 用 SetupAPI (P/Invoke) 程序化创建 KM-TEST 回环网卡, 验证免重启可用性。
.DESCRIPTION
    这是一个隔离的验证脚本, 不改动任何现有脚本。目的是回答两个问题:
      1. 能否纯命令行 (无 GUI、无外部 exe、无联网) 创建回环网卡?
      2. 创建后是否【无需重启】即可绑定 IP 并使用?

    底层调用与 hdwwiz / DevCon 相同的类安装器:
      SetupDiCreateDeviceInfoList -> SetupDiCreateDeviceInfo ->
      SetupDiSetDeviceRegistryProperty(HardwareID) ->
      SetupDiCallClassInstaller(REGISTERDEVICE) ->
      UpdateDriverForPlugAndPlayDevices(netloop.inf, *MSLOOP, FORCE)

    用法 (管理员 PowerShell):
      powershell -ExecutionPolicy Bypass -File .\test-LoopbackAdapter.ps1
      可选参数:
        -Name    要创建的网卡名 (默认 SMBProxy_TEST)
        -TestIp  创建后尝试绑定的测试 IP (默认 10.254.0.1)
        -Cleanup 仅清理: 删除本脚本创建的测试网卡后退出
#>
param(
    [string] $Name   = 'SMBProxy_TEST',
    [string] $TestIp = '10.254.0.1',
    [switch] $Cleanup
)

$ErrorActionPreference = 'Stop'

# ---- 管理员检查 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "[错误] 请以管理员身份运行本脚本。" -ForegroundColor Red; exit 1 }

function Log($m, $c='Gray') { Write-Host $m -ForegroundColor $c }

# ============ P/Invoke: SetupAPI 封装 ============
# 注意: SP_DEVINFO_DATA.cbSize 在 x86/x64 下不同, C# 用 Marshal.SizeOf 动态取, 不写死。
$setupApi = @'
using System;
using System.Runtime.InteropServices;

public static class LoopbackInstaller
{
    const int DIF_REGISTERDEVICE = 0x00000019;
    const int DIF_REMOVE         = 0x00000005;
    const int SPDRP_HARDWAREID   = 0x00000001;
    const int INSTALLFLAG_FORCE  = 0x00000001;
    const int DIGCF_PRESENT      = 0x00000002;
    const int MAX_CLASS_NAME_LEN = 32;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA {
        public int cbSize;
        public Guid ClassGuid;
        public int DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiCreateDeviceInfo(IntPtr DeviceInfoSet, string DeviceName,
        ref Guid ClassGuid, string DeviceDescription, IntPtr hwndParent, int CreationFlags,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiSetDeviceRegistryProperty(IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData, int Property, byte[] PropertyBuffer, int PropertyBufferSize);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiCallClassInstaller(int InstallFunction, IntPtr DeviceInfoSet,
        ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiClassGuidsFromName(string ClassName, byte[] ClassGuidList,
        int ClassGuidListSize, out int RequiredSize);

    [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwndParent, string HardwareId,
        string FullInfPath, int InstallFlags, out bool bRebootRequired);

    // 网络类 GUID: 4d36e972-e325-11ce-bfc1-08002be10318
    static Guid NET_CLASS = new Guid("4d36e972-e325-11ce-bfc1-08002be10318");

    // 创建回环网卡。返回值: reboot 是否需要重启; 抛异常表示失败(带 Win32 错误码)
    public static bool Install(string hwid, string infPath, out bool rebootRequired)
    {
        rebootRequired = false;
        Guid classGuid = NET_CLASS;
        IntPtr devInfo = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (devInfo == (IntPtr)(-1)) throw new Exception("SetupDiCreateDeviceInfoList 失败: " + Marshal.GetLastWin32Error());
        try {
            SP_DEVINFO_DATA dd = new SP_DEVINFO_DATA();
            dd.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiCreateDeviceInfo(devInfo, "NET", ref classGuid, null, IntPtr.Zero, 0x00000001 /*DICD_GENERATE_ID*/, ref dd))
                throw new Exception("SetupDiCreateDeviceInfo 失败: " + Marshal.GetLastWin32Error());

            // 硬件ID 需为双 NULL 结尾的 REG_MULTI_SZ
            byte[] hwidBytes = System.Text.Encoding.Unicode.GetBytes(hwid + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(devInfo, ref dd, SPDRP_HARDWAREID, hwidBytes, hwidBytes.Length))
                throw new Exception("SetupDiSetDeviceRegistryProperty 失败: " + Marshal.GetLastWin32Error());

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, devInfo, ref dd))
                throw new Exception("SetupDiCallClassInstaller(REGISTERDEVICE) 失败: " + Marshal.GetLastWin32Error());

            // 安装驱动 (强制), 使设备立即启动 -> 力求免重启
            bool reboot;
            if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, infPath, INSTALLFLAG_FORCE, out reboot))
            {
                int err = Marshal.GetLastWin32Error();
                // 设备节点已建, 但驱动更新失败
                throw new Exception("UpdateDriverForPlugAndPlayDevices 失败: " + err);
            }
            rebootRequired = reboot;
            return true;
        }
        finally {
            SetupDiDestroyDeviceInfoList(devInfo);
        }
    }
}
'@

# ---- 清理模式 ----
if ($Cleanup) {
    Log "[清理] 查找并移除测试网卡 [$Name] ..." Yellow
    $a = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    if ($a) {
        try { Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -ea SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ea SilentlyContinue } catch {}
        try { $null = pnputil /remove-device $a.PnPDeviceID 2>&1 } catch {}
        Log "[清理] 已尝试移除。若设备管理器仍可见, 请手动卸载。" Green
    } else { Log "[清理] 未找到 [$Name]。" Gray }
    exit 0
}

# ============ 主流程 ============
Log ""
Log "==================== 回环网卡 SetupAPI 创建测试 ====================" Cyan
Log ""

$inf = "$env:windir\inf\netloop.inf"
if (-not (Test-Path $inf)) { Log "[错误] 找不到 $inf (系统缺少回环网卡驱动定义)" Red; exit 1 }
Log "  驱动 INF : $inf"
Log "  硬件 ID  : *MSLOOP"
Log "  目标网卡 : $Name"
Log "  测试 IP  : $TestIp"
Log ""

# 记录创建前已有的回环网卡, 用于事后识别新建的那块
$before = @(Get-NetAdapter -IncludeHidden -ea SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Loopback|环回|KM-TEST' } | Select-Object -ExpandProperty Name)

Log "[1] 加载 SetupAPI P/Invoke ..." Cyan
try { Add-Type -TypeDefinition $setupApi -ErrorAction Stop } catch { Log "[错误] 编译 P/Invoke 失败: $($_.Exception.Message)" Red; exit 1 }

Log "[2] 预装驱动到驱动库 (pnputil, 幂等) ..." Cyan
& pnputil.exe /add-driver $inf 2>&1 | Out-Null

Log "[3] 调用 SetupAPI 创建回环网卡 ..." Cyan
$reboot = $false
$ok = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $ok = [LoopbackInstaller]::Install('*MSLOOP', $inf, [ref]$reboot)
} catch {
    Log "[失败] 创建失败: $($_.Exception.Message)" Red
    Log "       (若为拒绝访问, 确认管理员; 若为其他错误码, 记录后反馈)" Yellow
    exit 1
}
$sw.Stop()
Log "[OK] SetupAPI 调用成功 (返回 $ok), 耗时 $($sw.ElapsedMilliseconds)ms" Green
Log "     API 报告需要重启: $reboot" $(if($reboot){'Yellow'}else{'Green'})

Log "[4] 定位新建的网卡并重命名为 [$Name] ..." Cyan
$newAdapter = $null
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    $now = @(Get-NetAdapter -IncludeHidden -ea SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Loopback|环回|KM-TEST' })
    $new = $now | Where-Object { $_.Name -notin $before -and $_.Name -notlike 'SMBProxy_*' } | Select-Object -First 1
    if (-not $new) { $new = $now | Where-Object { $_.Name -notin $before } | Select-Object -First 1 }
    if ($new) {
        try { Rename-NetAdapter -Name $new.Name -NewName $Name -ea Stop } catch { netsh interface set interface name="$($new.Name)" newname="$Name" 2>&1 | Out-Null }
        $newAdapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
        if ($newAdapter) { break }
    }
    if (Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue) { $newAdapter = Get-NetAdapter -Name $Name; break }
}
if (-not $newAdapter) { Log "[失败] 创建后未能定位到新网卡 (可能需要重启才出现)" Red; exit 1 }
Log "[OK] 网卡已就绪: $Name (状态: $($newAdapter.Status), Index: $($newAdapter.InterfaceIndex))" Green

Log "[5] 关键测试: 免重启绑定 IP $TestIp ..." Cyan
try {
    if ($newAdapter.Status -ne 'Up') { try { Enable-NetAdapter -Name $Name -Confirm:$false -ea SilentlyContinue } catch {}; Start-Sleep -Seconds 2 }
    $ex = Get-NetIPAddress -IPAddress $TestIp -ea SilentlyContinue
    if (-not $ex) { New-NetIPAddress -IPAddress $TestIp -InterfaceIndex $newAdapter.InterfaceIndex -AddressFamily IPv4 -PrefixLength 24 -Confirm:$false | Out-Null }
    $check = Get-NetIPAddress -IPAddress $TestIp -ea SilentlyContinue
    if ($check) { Log "[OK] IP 绑定成功: $TestIp" Green } else { throw "IP 绑定后未查到" }
} catch {
    Log "[失败] IP 绑定失败: $($_.Exception.Message)" Red
    Log "       -> 可能需要重启才能使用该网卡" Yellow
    exit 1
}

Log "[6] 关键测试: 免重启在 $TestIp`:445 上监听 (模拟引擎) ..." Cyan
$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($TestIp), 445)
    $listener.Start()
    Log "[OK] 成功在 $TestIp`:445 监听! (若此机未占445)" Green
    $listener.Stop()
} catch {
    Log "[提示] 445 监听失败: $($_.Exception.Message)" Yellow
    Log "       (如果是 445 被系统 SMB 占用属正常, 不代表网卡有问题)" Gray
} finally { if ($listener) { try { $listener.Stop() } catch {} } }

Log ""
Log "==================== 结论 ====================" Cyan
Log " 网卡创建: 成功 (无 GUI / 无外部 exe / 无联网)" Green
Log " 免重启可用: $(if($newAdapter -and $check){'是 (已绑IP成功)'}else{'需进一步确认'})" $(if($check){'Green'}else{'Yellow'})
Log " API 报告重启: $reboot" $(if($reboot){'Yellow'}else{'Green'})
Log ""
Log " 测试完成。清理测试网卡请运行:" Gray
Log "   powershell -ExecutionPolicy Bypass -File .\test-LoopbackAdapter.ps1 -Cleanup" White
Log ""
