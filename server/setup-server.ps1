<#
.SYNOPSIS
    SMB 端口转发 - 服务端(SMB主机)
.DESCRIPTION
    将公网端口流量转发到本机SMB(445端口)
    支持 IPv4 / IPv6
    需要以管理员身份运行
#>

#Requires -RunAsAdministrator

function Show-Menu {
    Write-Host @"

============================================
   SMB 端口转发 - 服务端
============================================
  功能: 公网端口流量转发到本机445
  注意: 请确保本机SMB服务已启用

"@ -ForegroundColor Cyan

    Write-Host "  (规则已写入注册表, 关闭脚本/重启后依然有效)" -ForegroundColor DarkGray
    Write-Host "[1] 添加转发规则" -ForegroundColor Green
    Write-Host "[2] 删除转发规则" -ForegroundColor Yellow
    Write-Host "[3] 查看当前转发规则" -ForegroundColor Blue
    Write-Host "[4] 退出" -ForegroundColor Gray
}

function Show-FormattedRules {
    Write-Host "`n=== 当前所有转发规则 ===" -ForegroundColor Blue

    $dump = netsh interface portproxy dump 2>&1 | Out-String
    $lines = $dump -split "`r`n" | Where-Object { $_ -match '^\s*add\s' }

    if (-not $lines) {
        Write-Host "  (暂无规则)" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    $fmt = "{0,-9} {1,-27} {2,-30}"
    Write-Host ($fmt -f "类型", "监听地址:端口", "目标地址:端口") -ForegroundColor White
    Write-Host ($fmt -f "--------", "---------------------------", "------------------------------") -ForegroundColor DarkGray

    foreach ($line in $lines) {
        if ($line -match 'add\s+(\S+)\s+(.*)') {
            $type = $Matches[1]
            $params = $Matches[2]

            $listenAddr = if ($params -match 'listenaddress=(\S+)') { $Matches[1] } elseif ($type -like 'v6to*') { '[::]' } else { '0.0.0.0' }
            $listenPort = if ($params -match 'listenport=(\S+)') { $Matches[1] } else { '-' }
            $connectAddr = if ($params -match 'connectaddress=(\S+)') { $Matches[1] } else { '-' }
            $connectPort = if ($params -match 'connectport=(\S+)') { $Matches[1] } else { '-' }

            $src = "${listenAddr}:${listenPort}"
            $dst = "${connectAddr}:${connectPort}"

            Write-Host ($fmt -f $type, $src, $dst) -ForegroundColor Cyan
        }
    }
    Write-Host ""
}

function Add-Rule {
    Write-Host "`n=== 添加转发规则 ===" -ForegroundColor Green

    do {
        $port = Read-Host "请输入公网监听端口号 (1-65535, 建议 1445)"
        if ($port -match '^\d+$' -and [int]$port -gt 0 -and [int]$port -le 65535) { break }
        Write-Host "端口号无效, 请输入 1-65535 之间的数字" -ForegroundColor Red
    } while ($true)

    Write-Host "`n请选择你的公网 IP 类型:" -ForegroundColor Yellow
    Write-Host "  [1] IPv4 公网地址 (v4tov4)" -ForegroundColor White
    Write-Host "  [2] IPv6 公网地址 (v6tov6)" -ForegroundColor White
    Write-Host "  [3] 双栈 / 不确定 (同时添加 v4 和 v6 规则)" -ForegroundColor White
    do {
        $ipType = Read-Host "你的选择 (1/2/3)"
        if ($ipType -eq '1' -or $ipType -eq '2' -or $ipType -eq '3') { break }
        Write-Host "无效选择, 请输入 1、2 或 3" -ForegroundColor Red
    } while ($true)

    $useV4 = ($ipType -eq '1' -or $ipType -eq '3')
    $useV6 = ($ipType -eq '2' -or $ipType -eq '3')

    $existing = netsh interface portproxy dump | Select-String "listenport=$port"
    if ($existing) {
        Write-Host "`n警告: 端口 $port 已有转发规则:" -ForegroundColor Yellow
        Write-Host $existing -ForegroundColor Yellow
        $overwrite = Read-Host "是否删除旧规则后添加新规则? (y/n)"
        if ($overwrite -eq 'y') {
            if ($useV4) { netsh interface portproxy delete v4tov4 listenport=$port | Out-Null }
            if ($useV6) { netsh interface portproxy delete v6tov6 listenport=$port | Out-Null }
            Write-Host "旧规则已删除" -ForegroundColor Gray
        } else {
            Write-Host "已取消" -ForegroundColor Gray
            return
        }
    }

    if ($useV6) {
        Write-Host "`n正在添加 IPv6 转发: [::]:$port -> [::1]:445 ..." -ForegroundColor Cyan
        netsh interface portproxy add v6tov6 listenport=$port connectaddress=::1 connectport=445
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] v6tov6 规则添加成功" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] v6tov6 添加失败, 请检查是否以管理员运行" -ForegroundColor Red
        }
    }

    if ($useV4) {
        Write-Host "`n正在添加 IPv4 转发: 0.0.0.0:$port -> 127.0.0.1:445 ..." -ForegroundColor Cyan
        netsh interface portproxy add v4tov4 listenport=$port connectaddress=127.0.0.1 connectport=445
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] v4tov4 规则添加成功" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] v4tov4 添加失败, 请检查是否以管理员运行" -ForegroundColor Red
        }
    }

    Write-Host "`n正在添加防火墙入站规则: 允许 TCP $port ..." -ForegroundColor Cyan
    $ruleName = "SMB-Proxy-Port-$port"
    $existingFw = netsh advfirewall firewall show rule name="$ruleName" | Select-String $ruleName
    if ($existingFw) {
        Write-Host "防火墙规则已存在, 跳过" -ForegroundColor Yellow
    } else {
        netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$port | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] 防火墙规则添加成功" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] 防火墙规则添加失败" -ForegroundColor Red
        }
    }

    Show-FormattedRules

    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  服务端配置完成!" -ForegroundColor Green
    if ($useV6) { Write-Host "  IPv6 监听:  [::]:$port  ->  [::1]:445" -ForegroundColor White }
    if ($useV4) { Write-Host "  IPv4 监听:  0.0.0.0:$port  ->  127.0.0.1:445" -ForegroundColor White }
    Write-Host "  公网访问:    your-ddns.com:$port" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "`n客户端连接方式:" -ForegroundColor Yellow
    Write-Host "  Windows  : 运行 setup-client.ps1 (选择对应的IP类型)" -ForegroundColor White
    Write-Host "  Linux    : mount -t cifs //域名:$port/共享名 /mnt -o user=用户名" -ForegroundColor White
    Write-Host "  macOS    : mount_smbfs //用户名@域名:$port/共享名 /Volumes/挂载点" -ForegroundColor White
    Write-Host "  Android  : Solid Explorer (支持自定义端口)" -ForegroundColor White
}

function Remove-Rule {
    Write-Host "`n=== 删除转发规则 ===" -ForegroundColor Yellow
    Show-FormattedRules

    $port = Read-Host "请输入要删除的监听端口号"
    Write-Host "`n选择要删除的规则类型:" -ForegroundColor Yellow
    Write-Host "  [1] IPv4 (v4tov4)" -ForegroundColor White
    Write-Host "  [2] IPv6 (v6tov6)" -ForegroundColor White
    Write-Host "  [3] 两者都删" -ForegroundColor White
    $delType = Read-Host "你的选择 (1/2/3)"

    $ok = $false
    if ($delType -eq '1' -or $delType -eq '3') {
        netsh interface portproxy delete v4tov4 listenport=$port | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "[OK] v4tov4 端口 $port 已删除" -ForegroundColor Green; $ok = $true }
        else { Write-Host "[INFO] v4tov4 端口 $port 无规则" -ForegroundColor Gray }
    }
    if ($delType -eq '2' -or $delType -eq '3') {
        netsh interface portproxy delete v6tov6 listenport=$port | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "[OK] v6tov6 端口 $port 已删除" -ForegroundColor Green; $ok = $true }
        else { Write-Host "[INFO] v6tov6 端口 $port 无规则" -ForegroundColor Gray }
    }
    if (-not $ok) {
        Write-Host "[FAIL] 删除失败或规则不存在" -ForegroundColor Red
    }

    $ruleName = "SMB-Proxy-Port-$port"
    netsh advfirewall firewall delete rule name="$ruleName" 2>$null
    Write-Host "防火墙规则 '$ruleName' 已清理" -ForegroundColor Gray
}

function Show-Rules {
    Show-FormattedRules
}

# === 主菜单 ===
do {
    Show-Menu
    $choice = Read-Host "`n请选择操作"

    switch ($choice) {
        "1" { Add-Rule }
        "2" { Remove-Rule }
        "3" { Show-Rules }
        "4" { break }
        default {
            Write-Host "无效选择, 请重新输入" -ForegroundColor Red
        }
    }
    if ($choice -ne "4") { Write-Host ""; pause }
} while ($choice -ne "4")

Write-Host "`n已退出. 转发规则仍保留在系统中, 重启后依旧有效. 如需删除请重新运行本脚本选[2]" -ForegroundColor DarkGray
