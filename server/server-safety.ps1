<#
.SYNOPSIS
    SMBProxy - SMB 服务端安全配置 (Server Safety)
.DESCRIPTION
    SMB 服务端安全+性能配置。按数字切换开关，按 A 应用，按 R 放弃。
    需管理员权限。 Win8/Server2012+。
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$changes = @{}

function Show-Panel {
    Clear-Host
    $s = Get-SmbServerConfiguration -EA Stop
    Write-Host "`n  SMB 服务端安全配置" -ForegroundColor Cyan
    Write-Host ("  " + ("─" * 64))
    Write-Host "  #   参数                                当前值             切换" -ForegroundColor DarkGray
    Write-Host ("  " + ("─" * 64))

    Item 1  "数据加密 (EncryptData)"              $s.EncryptData              $true  "SMB3.0+ 公网强烈建议"
    Item 2  "拒绝未加密连接"                      $s.RejectUnencryptedAccess  $true  "阻挡不支持加密的客户端"
    Item 3  "要求客户端签名"                      $s.RequireSecuritySignature $true  "加密开后自动强制"
    Item 4  "启用签名"                            $s.EnableSecuritySignature  $true  "允许签名协商"
    Item 5  "SMB 1.0 协议"                        $s.EnableSMB1Protocol       $false "EternalBlue 漏洞, 尽快禁用"
    Item 6  "审计 SMB1 访问"                      $s.AuditSmb1Access          $true  "记录仍使用 SMB1 的设备"
    Item 7  "审计 Guest 登录"                     $s.AuditInsecureGuestLogon  $true  "记录不安全 Guest 连接"
    Item 8  "拒绝旧客户端 (DialectMin=3.0)"       ($s.Smb2DialectMin -ge 3)   $null  "开启后 Win7 无法连入"
    Item 9  "隐藏服务器(网上邻居)"                $s.ServerHidden             $true  "公网建议隐藏"
    Item 10 "用户共享认证"                        $s.EnableAuthenticateUserSharing $null "公网建议关闭"
    Item 11 "可信连接跳过加密"                    $s.DisableSmbEncryptionOnSecureConnection $false "内网可信链路可跳加密省性能"
    Item 12 "多通道 (MultiChannel)"               $s.EnableMultiChannel       $null  "多网卡聚合带宽"
    Item 13 "禁用压缩"                            $s.DisableCompression       $null  "AES-NI 时代加密比压缩更优"
    Write-Host ("  " + ("─" * 64))
    Write-Host ("  加密算法: " + ($s.EncryptionCiphers -join ', ')) -ForegroundColor DarkGray
    $conn = @(Get-SmbConnection -EA SilentlyContinue | ? { $_.Dialect } | Sort Dialect -Unique)
    if ($conn) { Write-Host ("  活跃连接: " + ($conn.Dialect -join ', ')) -ForegroundColor DarkCyan }
    Write-Host ""
    Write-Host "  1-13 切换  |  A 应用  |  R 放弃  |  S 一键加固  |  0 退出" -ForegroundColor Cyan
    if ($changes.Count -gt 0) { Write-Host ("  待应用: " + ($changes.Count) + " 项") -ForegroundColor Magenta }
    Write-Host ""
}

function Item($num, $label, $current, $recommended, $hint) {
    $eff = if ($changes.ContainsKey($label)) { $changes[$label] } else { $current }
    $pen = $changes.ContainsKey($label)
    $display = if ($eff) { "已开启" } else { "已关闭" }
    $star = if ($pen) { " *" } else { "" }
    $op  = if ($eff) { "→ 关闭" } else { "→ 开启" }
    $clr = if ($recommended -eq $null) { "White" } elseif ($eff -eq $recommended) { "Green" } else { "Yellow" }
    Write-Host ("  [{0,2}] {1,-32} {2,-12}{3}   {4}" -f $num, $label, ($display+$star), $op, "") -ForegroundColor $clr
    Write-Host ("       {0}" -f $hint) -ForegroundColor DarkGray
}

function Toggle($param, $current, $newVal) {
    if ($changes.ContainsKey($param)) { $changes.Remove($param) }
    if ((Get-SmbServerConfiguration -EA Stop).$param -ne $newVal) { $changes[$param] = $newVal }
}

function SetRecommended {
    $s = Get-SmbServerConfiguration -EA Stop
    if ($s.EncryptData              -ne $true)  { $changes["EncryptData"]              = $true }
    if ($s.RejectUnencryptedAccess  -ne $true)  { $changes["RejectUnencryptedAccess"]  = $true }
    if ($s.RequireSecuritySignature -ne $true)  { $changes["RequireSecuritySignature"] = $true }
    if ($s.EnableSecuritySignature  -ne $true)  { $changes["EnableSecuritySignature"]  = $true }
    if ($s.EnableSMB1Protocol       -ne $false) { $changes["EnableSMB1Protocol"]       = $false }
    if ($s.AuditSmb1Access          -ne $true)  { $changes["AuditSmb1Access"]          = $true }
    if ($s.AuditInsecureGuestLogon  -ne $true)  { $changes["AuditInsecureGuestLogon"]  = $true }
}

do {
    Show-Panel
    $s = Get-SmbServerConfiguration -EA Stop
    $ch = Read-Host "选择"

    switch -Regex ($ch) {
        "^([1-9]|1[0-3])$" {
            switch ([int]$ch) {
                1  { Toggle "EncryptData"              $s.EncryptData              (-not $s.EncryptData) }
                2  { Toggle "RejectUnencryptedAccess"  $s.RejectUnencryptedAccess  (-not $s.RejectUnencryptedAccess) }
                3  { Toggle "RequireSecuritySignature" $s.RequireSecuritySignature (-not $s.RequireSecuritySignature) }
                4  { Toggle "EnableSecuritySignature"  $s.EnableSecuritySignature  (-not $s.EnableSecuritySignature) }
                5  { Toggle "EnableSMB1Protocol"       $s.EnableSMB1Protocol       (-not $s.EnableSMB1Protocol) }
                6  { Toggle "AuditSmb1Access"          $s.AuditSmb1Access          (-not $s.AuditSmb1Access) }
                7  { Toggle "AuditInsecureGuestLogon"  $s.AuditInsecureGuestLogon  (-not $s.AuditInsecureGuestLogon) }
                8  { Toggle "Smb2DialectMin"           ($s.Smb2DialectMin -ge 3)   ($s.Smb2DialectMin -lt 3) }
                9  { Toggle "ServerHidden"             $s.ServerHidden             (-not $s.ServerHidden) }
                10 { Toggle "EnableAuthenticateUserSharing" $s.EnableAuthenticateUserSharing (-not $s.EnableAuthenticateUserSharing) }
                11 { Toggle "DisableSmbEncryptionOnSecureConnection" $s.DisableSmbEncryptionOnSecureConnection (-not $s.DisableSmbEncryptionOnSecureConnection) }
                12 { Toggle "EnableMultiChannel"       $s.EnableMultiChannel       (-not $s.EnableMultiChannel) }
                13 { Toggle "DisableCompression"       $s.DisableCompression       (-not $s.DisableCompression) }
            }
        }
        "^[Aa]$" {
            if ($changes.Count -eq 0) { Write-Host "  无更改。" -ForegroundColor Gray; Start-Sleep 1; continue }
            Write-Host "`n  即将应用:" -ForegroundColor Cyan
            foreach ($k in $changes.Keys) { Write-Host "    $k = $($changes[$k])" -ForegroundColor Yellow }
            if ((Read-Host "`n  确认? [Y/N]") -ne "Y") { continue }
            $errs = 0
            foreach ($k in $changes.Keys) {
                try {
                    switch ($k) {
                        "EncryptData"              { Set-SmbServerConfiguration -EncryptData $changes[$k] -Force -Confirm:$false -EA Stop }
                        "RejectUnencryptedAccess"  { Set-SmbServerConfiguration -RejectUnencryptedAccess $changes[$k] -Force -Confirm:$false -EA Stop }
                        "RequireSecuritySignature" { Set-SmbServerConfiguration -RequireSecuritySignature $changes[$k] -Force -Confirm:$false -EA Stop }
                        "EnableSecuritySignature"  { Set-SmbServerConfiguration -EnableSecuritySignature $changes[$k] -Force -Confirm:$false -EA Stop }
                        "EnableSMB1Protocol"       { Set-SmbServerConfiguration -EnableSMB1Protocol $changes[$k] -Force -Confirm:$false -EA Stop }
                        "AuditSmb1Access"          { Set-SmbServerConfiguration -AuditSmb1Access $changes[$k] -Force -Confirm:$false -EA Stop }
                        "AuditInsecureGuestLogon"  { Set-SmbServerConfiguration -AuditInsecureGuestLogon $changes[$k] -Force -Confirm:$false -EA Stop }
                        "Smb2DialectMin"           { $v = if ($changes[$k]) { 3 } else { 0 }; Set-SmbServerConfiguration -Smb2DialectMin $v -Force -Confirm:$false -EA Stop }
                        "ServerHidden"             { Set-SmbServerConfiguration -ServerHidden $changes[$k] -Force -Confirm:$false -EA Stop }
                        "EnableAuthenticateUserSharing" { Set-SmbServerConfiguration -EnableAuthenticateUserSharing $changes[$k] -Force -Confirm:$false -EA Stop }
                        "DisableSmbEncryptionOnSecureConnection" { Set-SmbServerConfiguration -DisableSmbEncryptionOnSecureConnection $changes[$k] -Force -Confirm:$false -EA Stop }
                        "EnableMultiChannel"       { Set-SmbServerConfiguration -EnableMultiChannel $changes[$k] -Force -Confirm:$false -EA Stop }
                        "DisableCompression"       { Set-SmbServerConfiguration -DisableCompression $changes[$k] -Force -Confirm:$false -EA Stop }
                    }
                } catch { Write-Host "  [失败] $k : $($_.Exception.Message)" -ForegroundColor Red; $errs++ }
            }
            if ($errs -eq 0) { Write-Host "  [OK] 已应用" -ForegroundColor Green } else { Write-Host "  [警告] $errs 项失败" -ForegroundColor Yellow }
            $changes.Clear()
            Read-Host "`n按 Enter 继续"
        }
        "^[Rr]$" { $changes.Clear() }
        "^[Ss]$" { SetRecommended }
        "^0$"     { exit }
    }
} while ($true)
