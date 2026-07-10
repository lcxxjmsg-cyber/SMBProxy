<#
.SYNOPSIS
    SMBProxy - SMB 客户端安全配置 (Client Safety)
.DESCRIPTION
    SMB 客户端安全+性能配置。按数字切换开关，按 A 应用，按 R 放弃。
    需管理员权限。 Win8/Server2012+。
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$changes = @{}

function Show-Panel {
    Clear-Host
    $c = Get-SmbClientConfiguration -EA Stop
    Write-Host "`n  SMB 客户端安全配置" -ForegroundColor Cyan
    Write-Host ("  " + ("─" * 64))
    Write-Host "  #   参数                                当前值             切换" -ForegroundColor DarkGray
    Write-Host ("  " + ("─" * 64))

    Item 1  "允许不安全 Guest 登录"              $c.EnableInsecureGuestLogons               $false "公网必须禁用, 防匿名访问"
    Item 2  "要求服务端加密"                     $c.RequireEncryption                        $true  "仅连 SMB3 加密服务端"
    Item 3  "阻止 NTLM 认证"                     $c.BlockNTLM                                $null  "强安全环境开启, 旧设备可能断连"
    Item 4  "要求服务端签名"                     $c.RequireSecuritySignature                 $true  "数据完整性, 公网建议"
    Item 5  "启用客户端签名"                     $c.EnableSecuritySignature                  $true  "配合服务端签名使用"
    Item 6  "拒绝旧服务端 (DialectMin=3.0)"      ($c.Smb2DialectMin -ge 3)                   $null  "开启后只连 Win8+ 服务端"
    Item 7  "多通道 (MultiChannel)"              $c.EnableMultiChannel                       $null  "多网卡聚合带宽"
    Item 8  "启用大 MTU"                         $c.EnableLargeMtu                           $null  "提升大文件传输效率"
    Item 9  "禁用压缩"                           $c.DisableCompression                       $null  "AES-NI 加密比 SMB 压缩更优"
    Item 10 "审计 Guest 登录"                    $c.AuditInsecureGuestLogon                  $true  "记录 Guest 连接尝试"
    Item 11 "审计服务端不支持加密"               $c.AuditServerDoesNotSupportEncryption      $true  "发现薄弱服务端"
    Item 12 "审计服务端不支持签名"               $c.AuditServerDoesNotSupportSigning         $true  "发现薄弱服务端"
    Write-Host ("  " + ("─" * 64))
    Write-Host ("  加密算法: " + ($c.EncryptionCiphers -join ', ')) -ForegroundColor DarkGray
    Write-Host ("  会话超时: $($c.SessionTimeout)秒  每服最大连接数: $($c.MaximumConnectionCountPerServer)") -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  1-12 切换  |  A 应用  |  R 放弃  |  S 一键加固  |  0 退出" -ForegroundColor Cyan
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
    if ((Get-SmbClientConfiguration -EA Stop).$param -ne $newVal) { $changes[$param] = $newVal }
}

function SetRecommended {
    $c = Get-SmbClientConfiguration -EA Stop
    if ($c.EnableInsecureGuestLogons               -ne $false) { $changes["EnableInsecureGuestLogons"]               = $false }
    if ($c.RequireEncryption                       -ne $true)  { $changes["RequireEncryption"]                       = $true }
    if ($c.RequireSecuritySignature                -ne $true)  { $changes["RequireSecuritySignature"]                = $true }
    if ($c.EnableSecuritySignature                 -ne $true)  { $changes["EnableSecuritySignature"]                 = $true }
    if ($c.AuditInsecureGuestLogon                 -ne $true)  { $changes["AuditInsecureGuestLogon"]                 = $true }
    if ($c.AuditServerDoesNotSupportEncryption     -ne $true)  { $changes["AuditServerDoesNotSupportEncryption"]     = $true }
    if ($c.AuditServerDoesNotSupportSigning        -ne $true)  { $changes["AuditServerDoesNotSupportSigning"]        = $true }
}

do {
    Show-Panel
    $c = Get-SmbClientConfiguration -EA Stop
    $ch = Read-Host "选择"

    switch -Regex ($ch) {
        "^([1-9]|1[0-2])$" {
            switch ([int]$ch) {
                1  { Toggle "EnableInsecureGuestLogons"            $c.EnableInsecureGuestLogons            (-not $c.EnableInsecureGuestLogons) }
                2  { Toggle "RequireEncryption"                    $c.RequireEncryption                    (-not $c.RequireEncryption) }
                3  { Toggle "BlockNTLM"                            $c.BlockNTLM                            (-not $c.BlockNTLM) }
                4  { Toggle "RequireSecuritySignature"             $c.RequireSecuritySignature             (-not $c.RequireSecuritySignature) }
                5  { Toggle "EnableSecuritySignature"              $c.EnableSecuritySignature              (-not $c.EnableSecuritySignature) }
                6  { Toggle "Smb2DialectMin"                       ($c.Smb2DialectMin -ge 3)               ($c.Smb2DialectMin -lt 3) }
                7  { Toggle "EnableMultiChannel"                   $c.EnableMultiChannel                   (-not $c.EnableMultiChannel) }
                8  { Toggle "EnableLargeMtu"                       $c.EnableLargeMtu                       (-not $c.EnableLargeMtu) }
                9  { Toggle "DisableCompression"                   $c.DisableCompression                   (-not $c.DisableCompression) }
                10 { Toggle "AuditInsecureGuestLogon"              $c.AuditInsecureGuestLogon              (-not $c.AuditInsecureGuestLogon) }
                11 { Toggle "AuditServerDoesNotSupportEncryption"  $c.AuditServerDoesNotSupportEncryption  (-not $c.AuditServerDoesNotSupportEncryption) }
                12 { Toggle "AuditServerDoesNotSupportSigning"     $c.AuditServerDoesNotSupportSigning     (-not $c.AuditServerDoesNotSupportSigning) }
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
                        "EnableInsecureGuestLogons"               { Set-SmbClientConfiguration -EnableInsecureGuestLogons $changes[$k] -Force -Confirm:$false -EA Stop }
                        "RequireEncryption"                       { Set-SmbClientConfiguration -RequireEncryption $changes[$k] -Force -Confirm:$false -EA Stop }
                        "BlockNTLM"                               { Set-SmbClientConfiguration -BlockNTLM $changes[$k] -Force -Confirm:$false -EA Stop }
                        "RequireSecuritySignature"                { Set-SmbClientConfiguration -RequireSecuritySignature $changes[$k] -Force -Confirm:$false -EA Stop }
                        "EnableSecuritySignature"                 { Set-SmbClientConfiguration -EnableSecuritySignature $changes[$k] -Force -Confirm:$false -EA Stop }
                        "Smb2DialectMin"                          { $v = if ($changes[$k]) { 3 } else { 0 }; Set-SmbClientConfiguration -Smb2DialectMin $v -Force -Confirm:$false -EA Stop }
                        "EnableMultiChannel"                      { Set-SmbClientConfiguration -EnableMultiChannel $changes[$k] -Force -Confirm:$false -EA Stop }
                        "EnableLargeMtu"                          { Set-SmbClientConfiguration -EnableLargeMtu $changes[$k] -Force -Confirm:$false -EA Stop }
                        "DisableCompression"                      { Set-SmbClientConfiguration -DisableCompression $changes[$k] -Force -Confirm:$false -EA Stop }
                        "AuditInsecureGuestLogon"                 { Set-SmbClientConfiguration -AuditInsecureGuestLogon $changes[$k] -Force -Confirm:$false -EA Stop }
                        "AuditServerDoesNotSupportEncryption"     { Set-SmbClientConfiguration -AuditServerDoesNotSupportEncryption $changes[$k] -Force -Confirm:$false -EA Stop }
                        "AuditServerDoesNotSupportSigning"        { Set-SmbClientConfiguration -AuditServerDoesNotSupportSigning $changes[$k] -Force -Confirm:$false -EA Stop }
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
