<#
.SYNOPSIS
    SMBProxy - SMB 安全传输开关 (SMB Encryption Toggle)
.DESCRIPTION
    一个简洁的工具，用于开启或关闭 Windows SMB 服务的加密传输功能。
    附带详细的 SMB 各版本安全特性说明与兼容性注意事项。

    === SMB 版本简史 ===

    SMB 1.0 (CIFS)     — Windows 2000 / XP
      无加密，无预认证。存在 EternalBlue / WannaCry 漏洞。
      已被微软官方建议禁用，Win10 1709+ 默认不安装。

    SMB 2.0            — Windows Vista / Server 2008
      引入请求复合、更大缓冲区、持久句柄。有签名但默认不强制。
      无加密。

    SMB 2.1            — Windows 7 / Server 2008 R2
      引入客户端不透明锁、大 MTU 支持。无加密。

    SMB 3.0            — Windows 8 / Server 2012
      引入 SMB Encryption (AES-CCM)、多通道、透明故障转移、
      VSS 远程备份。加密仅支持 AES-128-CCM。

    SMB 3.0.2          — Windows 8.1 / Server 2012 R2
      小幅改进，安全特性与 3.0 基本一致。

    SMB 3.1.1          — Windows 10 / Server 2016+
      引入预认证完整性 (Pre-Auth Integrity)、
      更强的加密算法 (AES-128-GCM, AES-256-GCM)。
      这是目前最安全的 SMB 版本。

    === SMB Encryption 注意事项 ===

    1. 加密需要双方均支持 SMB 3.0+
       - 服务端开加密后，SMB 2.x 及以下客户端将无法连接
       - 包括旧 NAS、旧 Linux Samba(<4.1)、XP/Vista
       - 如果你的网络中有旧设备，先确认它们是否支持 SMB 3.0

    2. 性能影响
       - AES 硬件加速 (AES-NI) 可大幅降低 CPU 开销
       - 千兆网络下软件加密约损失 15-30% 吞吐量
       - 10GbE 网络建议使用支持 AES-NI 的 CPU
       - 纯内网环境且信任网络时，可考虑不开加密

    3. 与 SMB 签名的关系
       - 加密开启后 SMB 签名自动包含 (无需额外配置)
       - 加密 > 签名 > 无保护

    4. 对现有连接的影响
       - 修改后仅对新连接生效，已建立的连接不受影响
       - 建议在维护窗口操作，避免中断正在传输的文件

    5. 非 Windows 客户端兼容性
       - Linux Samba 4.1+ 支持 SMB 3.0 加密
       - macOS 10.10+ 支持 SMB 3.0 加密
       - iOS/Android 第三方客户端视 App 而定

    TL;DR:
      - 纯 Win10+ 环境 → 开加密，用 SMB 3.1.1
      - 有旧设备混用   → 关加密，至少禁用 SMB 1.0
      - 有 NAS/Linux   → 确认 Samba 版本 >= 4.1

    === 相关命令参考 ===

    Get-SmbServerConfiguration                      # 查看完整配置
    Get-SmbConnection                               # 查看当前连接的 SMB 版本
    Set-SmbServerConfiguration -EnableSMB1Protocol $false   # 禁用 SMB 1.0
    Set-SmbServerConfiguration -EncryptData $true           # 强制加密
    Set-SmbServerConfiguration -EncryptData $false          # 关闭加密

.NOTES
    需要管理员权限。
    仅适用于 Windows Server 2012+ / Windows 8+。
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

function Show-Header {
    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     SMB 安全传输开关 (Encryption Toggle)          " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "--- 当前 SMB 安全状态 ---" -ForegroundColor DarkCyan
    try {
        $conf = Get-SmbServerConfiguration -ErrorAction Stop

        if ($conf.EncryptData) {
            Write-Host "  [ON]  SMB Encryption (加密传输已开启)" -ForegroundColor Green
        } else {
            Write-Host "  [OFF] SMB Encryption (加密传输已关闭)" -ForegroundColor Yellow
        }

        if (-not $conf.EnableSMB1Protocol) {
            Write-Host "  [OK]  SMB 1.0 已禁用 (安全)" -ForegroundColor Green
        } else {
            Write-Host "  [!!] SMB 1.0 仍开启 - 强烈建议禁用!" -ForegroundColor Red
        }

        if ($conf.EnableSMB2Protocol) {
            Write-Host "  [ON]  SMB 2.0+ 已开启" -ForegroundColor Green
        } else {
            Write-Host "  [!!] SMB 2.0+ 已关闭 - 这会导致 SMB 完全不可用!" -ForegroundColor Red
        }

        if ($conf.RequireSecuritySignature) {
            Write-Host "  [ON]  SMB 签名强制要求" -ForegroundColor Green
        } else {
            Write-Host "  [OFF] SMB 签名未强制 (加密开启时自动包含签名)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  [错误] 无法读取 SMB 配置: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        $connections = @(Get-SmbConnection -ErrorAction SilentlyContinue |
            Where-Object { $_.Dialect -match "3\.|2\." } |
            Sort-Object Dialect -Unique)
        if ($connections.Count -gt 0) {
            Write-Host ""
            Write-Host "--- 当前活跃 SMB 连接版本 ---" -ForegroundColor DarkCyan
            foreach ($c in $connections) {
                $color = if ($c.Dialect -match "3\.1") { "Green" }
                    elseif ($c.Dialect -match "3\.0") { "Cyan" }
                    elseif ($c.Dialect -match "2\.") { "Yellow" }
                    else { "Red" }
                Write-Host "  $($c.Dialect) -> $($c.ServerName)" -ForegroundColor $color
            }
        } else {
            Write-Host ""
            Write-Host "  (当前无活跃 SMB 连接)" -ForegroundColor Gray
        }
    } catch {}
    Write-Host ""
}

do {
    Show-Header
    Show-Status

    Write-Host "[1] 开启 SMB Encryption (推荐 - 需要 SMB 3.0+ 客户端)" -ForegroundColor Green
    Write-Host "[2] 关闭 SMB Encryption (兼容旧设备 - 至少禁用 SMB 1.0)" -ForegroundColor Yellow
    Write-Host "[3] 重新显示帮助信息" -ForegroundColor Cyan
    Write-Host "[4] 退出" -ForegroundColor Gray

    $choice = Read-Host "`r`n请选择 (1-4)"

    switch ($choice) {
        "1" {
            Write-Host ""
            Write-Host "正在开启 SMB Encryption..." -ForegroundColor Cyan
            Write-Host "====================================================" -ForegroundColor Yellow
            Write-Host "  注意: 开启后只有 SMB 3.0+ 的客户端才能连接!" -ForegroundColor Yellow
            Write-Host "  旧版 Windows (XP/Vista/7)、旧 NAS、旧 Samba" -ForegroundColor Yellow
            Write-Host "  可能无法连接。请确认你的网络环境后再操作。" -ForegroundColor Yellow
            Write-Host "====================================================" -ForegroundColor Yellow
            $confirm = Read-Host "`r`n确认开启? 输入 YES 继续"
            if ($confirm -eq "YES") {
                try {
                    Set-SmbServerConfiguration -EncryptData $true -Force
                    Write-Host ""
                    Write-Host "[OK] SMB Encryption 已开启" -ForegroundColor Green
                    Write-Host "  客户端须支持 SMB 3.0+ (Win8 / Server 2012+)" -ForegroundColor Gray
                    Write-Host "  SMB 3.1.1 使用 AES-256-GCM, SMB 3.0 使用 AES-128-CCM" -ForegroundColor Gray
                } catch {
                    Write-Host "[错误] 操作失败: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "已取消" -ForegroundColor Gray
            }
            pause
        }
        "2" {
            Write-Host ""
            Write-Host "正在关闭 SMB Encryption..." -ForegroundColor Cyan
            Write-Host "====================================================" -ForegroundColor Yellow
            Write-Host "  关闭后 SMB 数据将以明文传输。" -ForegroundColor Yellow
            Write-Host "  如果你的网络中有不可信链路 (如公网/WiFi)," -ForegroundColor Yellow
            Write-Host "  建议保持加密开启。" -ForegroundColor Yellow
            Write-Host "  至少确保 SMB 1.0 已被禁用!" -ForegroundColor Yellow
            Write-Host "====================================================" -ForegroundColor Yellow
            $confirm = Read-Host "`r`n确认关闭? 输入 YES 继续"
            if ($confirm -eq "YES") {
                try {
                    Set-SmbServerConfiguration -EncryptData $false -Force
                    Write-Host ""
                    Write-Host "[OK] SMB Encryption 已关闭" -ForegroundColor Yellow
                    $s1 = (Get-SmbServerConfiguration).EnableSMB1Protocol
                    if ($s1) {
                        Write-Host "  [!!] 检测到 SMB 1.0 仍开启, 强烈建议禁用!" -ForegroundColor Red
                        Write-Host "  运行: Set-SmbServerConfiguration -EnableSMB1Protocol `$false -Force" -ForegroundColor White
                    }
                } catch {
                    Write-Host "[错误] 操作失败: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "已取消" -ForegroundColor Gray
            }
            pause
        }
        "3" {
            Get-Help -Full $MyInvocation.MyCommand.Path
            pause
        }
        "4" { exit }
    }
} while ($true)
