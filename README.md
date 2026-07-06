# SMBProxy

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**突破运营商 445 端口封锁，从任何网络安全访问你的远程 SMB 共享。**

公网 445 端口普遍被 ISP 封禁，而 Windows 的 `\\` UNC 路径语法不支持指定端口号。SMBProxy 通过**服务端 netsh 端口转发 + 客户端虚拟回环网卡代理**打通全链路，让远程 SMB 像本地文件夹一样直接挂载。

---

## 目录

- [架构总览](#架构总览)
- [SMB 跨平台兼容](#smb-跨平台兼容)
- [系统兼容性](#系统兼容性)
  - [服务端](#服务端)
  - [客户端](#客户端)
  - [Server 版](#server-版)
- [快速开始](#快速开始)
  - [服务端](#1-服务端)
  - [客户端](#2-客户端)
  - [非 Windows 客户端](#3-非-windows-客户端)
- [客户端引擎特性 v3.1](#客户端引擎特性-v31)
- [常见问题](#常见问题)
- [手动卸载](#手动卸载)
  - [服务端](#服务端手动卸载)
  - [客户端](#客户端手动卸载)

---

## 架构总览

```
                        SMBProxy 数据流 (IPv6 示例)

   客户端 (访问方)                                    服务端 (SMB 主机)
   ┌──────────────────────────┐                    ┌──────────────────────────┐
   │                          │                    │                          │
   │   explorer / net use     │                    │      SMB 服务 (smbd)     │
   │   \\10.10.10.10\共享      │                    │      127.0.0.1:445        │
   │          │               │                    │      [::1]:445            │
   │          ▼               │                    │           ↑              │
   │   虚拟回环网卡            │                    │           │              │
   │   SMBProxy               │                    │      netsh portproxy     │
   │   10.10.10.10/32         │                    │      [::]:1445            │
   │   (Microsoft KM-TEST     │──── 公网 IPv6 ────→│      0.0.0.0:1445         │
   │    Loopback Adapter)     │   DDNS 域名:1445    │           ↑              │
   │          │               │                    │           │              │
   │          ▼               │                    │      防火墙 放行 1445      │
   │   PowerShell 数据泵       │                    │           ↑              │
   │   (Stream.CopyToAsync)   │                    │      公网 IP + DDNS       │
   │   10.10.10.10:445        │                    │                          │
   │          ↑               │                    │                          │
   │          │               │                    └──────────────────────────┘
   │   计划任务 SYSTEM         │
   │   开机自启               │
   │   崩溃自动重启           │
   └──────────────────────────┘

   ┌──────────────────── 关键技术 ────────────────────────┐
   │                                                       │
   │  为什么用 10.10.10.10 而不是 127.0.0.1 ?             │
   │  Windows srvnet.sys 内核对 127.x 回环地址的 SMB      │
   │  连接有严格限制，会触发错误 64 / 67。                 │
   │                                                       │
   │  为什么用独立虚拟回环网卡而不是绑定物理网卡？         │
   │  物理网卡 IP 会随网络环境 (WiFi / 以太网 / 热点)      │
   │  变化，且可能与局域网 IP 段冲突。使用 Microsoft        │
   │  KM-TEST Loopback Adapter 创建独立虚拟网卡             │
   │  SMBProxy，/32 掩码完全隔离，不影响任何物理网络。      │
   │                                                       │
   └───────────────────────────────────────────────────────┘
```

```
                   非 Windows 客户端 (零配置)

   Linux  : mount -t cifs //your-ddns.com:1445/share /mnt -o user=xxx
   macOS  : mount_smbfs //user@your-ddns.com:1445/share /Volumes/mnt
   Android: Solid Explorer / Material Files → 直接填 域名:1445
   iOS    : FileBrowser Pro / FE File Explorer → 直接填 域名:1445

   这些平台原生支持 SMB 自定义端口, 无需客户端脚本。
```

---

## SMB 跨平台兼容

> 以下表格仅反映各平台对 SMB 协议的原生支持情况，与脚本本身的系统兼容性无关。

### SMB 客户端 (访问方 / 挂载远程共享)

| 平台 | 原生 SMB | 支持自定义端口 | 建议方案 |
|------|---------|:---:|------|
| **Windows 10/11** | File Explorer (`\\host`) | ❌ | Client 脚本 → `\\10.10.10.10` |
| **macOS** | Finder (`smb://host:port`) | ✅ | 原生直连：`smb://域名:端口` |
| **Linux (GNOME/KDE)** | Nautilus / Dolphin (`smb://host:port`) | ✅ | 原生直连 |
| **Android** | 无原生 SMB | ❌ | Solid Explorer / Material Files + 自定义端口 |
| **iOS / iPadOS** | Files App (`smb://host`) | ❌ | FileBrowser Pro / FE File Explorer + 自定义端口 |

### SMB 服务端 (提供方 / 对外共享)

| 平台 | SMB 服务 | 支持改端口 | 建议方案 |
|------|---------|:---:|------|
| **Windows 10/11** | LanmanServer | ❌ | `server/setup-server.ps1` → netsh portproxy |
| **macOS** | smbd | ✅ | 改 `/etc/smb.conf` → `smb ports = 1445` |
| **Linux** | Samba (smbd) | ✅ | 改 `/etc/samba/smb.conf` → `smb ports = 1445` |
| **Android** | 第三方 App | ✅ | 极少作为服务端 |
| **iOS / iPadOS** | 不支持 | ❌ | — |

---

## 系统兼容性

### 服务端

| 系统 | 脚本 | 状态 |
|------|------|------|
| Windows 10 / 11 | `server/setup-server.ps1` | ✅ |
| Windows 8 / 8.1 | `server/setup-server.ps1` | ✅ |
| Windows 7 | `server/setup-server.ps1` | ✅ |
| Windows Server 2016 / 2019 / 2022 / 2025 | `server/setup-server.ps1` | ✅ |
| Windows Server 2012 / 2012 R2 | `server/setup-server.ps1` | ✅ |
| Windows Server 2008 R2 | `server/setup-server.ps1` | ✅ |
| Windows Vista | `server/setup-server.ps1` | ✅ |
| Windows XP (需 PS 2.0) | `server/setup-server.ps1` | ⚠️ 需手动防火墙 |

### 客户端

| 系统 | 脚本 | 状态 |
|------|------|------|
| Windows 10 / 11 | `client/setup-client-win10-11.ps1` | ✅ |
| Windows 8 / 8.1 | `client/setup-client-win8-1.ps1` | ✅ |
| Windows 7 (需 WMF 5.1 + .NET 4.8) | `client/setup-client-win7.ps1` | ✅ |

### Server 版

| 系统 | 脚本 | 状态 |
|------|------|------|
| Server 2016 / 2019 / 2022 / 2025 | `client/setup-client-2016++.ps1` | ✅ |
| Server 2012 / 2012 R2 | `client/setup-client-2012-r2.ps1` | ✅ |
| Server 2008 R2 (需 WMF 5.1 + .NET 4.8) | `client/setup-client-2008r2.ps1` | ✅ |
| Server 2008 (非 R2) | 不支持 | ❌ NT 6.0，无法安装 WMF 5.1 |
| Windows XP / Vista | 不支持 | ❌ 缺少 NetAdapter / CIM 等系统模块 |

> 服务端与客户端不能在同一台机器上运行。

---

## 快速开始

**管理员 PowerShell** 执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1        # 服务端
powershell -ExecutionPolicy Bypass -File .\setup-client-win10-11.ps1  # 客户端
```

### 1. 服务端

运行 `server/setup-server.ps1`，选 `[1]`：

```
请输入公网监听端口号 (1-65535, 建议 1445): 1445

请选择你的公网 IP 类型:
  [1] IPv4
  [2] IPv6
  [3] 双栈 (同时添加)
你的选择 (1/2/3): 2
```

### 2. 客户端

运行对应系统的脚本，选 `[1]`。

首次使用会弹出 `hdwwiz.exe` 硬件安装向导，按提示安装 Microsoft KM-TEST Loopback Adapter（仅需一次）。之后脚本自动完成：禁用 SMB 驱动 → 绑定虚拟 IP → 防火墙 → 部署引擎 → 计划任务。

Win7 / Server 2008 R2 需额外安装依赖（SHA-2 / .NET 4.8 / WMF 5.1），脚本自动检测安装。可将离线包预先放入 `win7plug` / `2008r2plug` 目录。

安装完成后：

```
Win+R → \\10.10.10.10 → 回车
```

### 3. 非 Windows 客户端

服务端已运行即可，无需脚本。

#### Linux

```bash
sudo apt install cifs-utils          # Debian/Ubuntu
sudo yum install cifs-utils          # CentOS/RHEL

sudo mount -t cifs //域名:端口/共享名 /mnt/smb \
  -o username=用户名,password=密码,vers=3.0

# 文件管理器: smb://域名:端口/
```

#### macOS

```
Finder → ⌘K → smb://域名:端口/共享名

# 或命令行:
mount_smbfs //用户名@域名:端口/共享名 /Volumes/mnt
```

#### Android

- Solid Explorer (推荐)
- Material Files (开源)
- CIFS Document Provider
- CX File Explorer

#### iOS / iPadOS

- FileBrowser Pro / FileBrowser GO (推荐)
- FE File Explorer Pro
- Documents by Readdle
- Owlfiles

#### Troubleshooting

- 确保服务端防火墙已放行目标端口
- `ping -6 域名` 测试 IPv6 / `ping 域名` 测试 IPv4
- 运营商可能封禁非标准端口，优先选 1445 / 8445

---

## 客户端引擎特性 v3.1

| 特性 | 说明 |
|------|------|
| **虚拟回环网卡** | Microsoft KM-TEST Loopback Adapter + `SMBProxy`，与物理网卡完全隔离 |
| **异步数据泵** | `Stream.CopyToAsync` .NET 原生异步 IO，消除句柄/线程泄漏 |
| **IPv4/IPv6 自动** | DNS 解析后自动选择 (优先 IPv6，回退 IPv4) |
| **DDNS 自动刷新** | 每 10 秒重解析域名，IP 变更即时生效 |
| **DNS 自愈** | 解析失败自动重试 (最多 30 次 / 5s 间隔) |
| **崩溃自愈** | 引擎 `try/catch` + 计划任务自动重启，双重兜底 |
| **执行时限关闭** | 关闭计划任务 72h 默认时限，避免引擎被强杀 |
| **快速启动关闭** | `HiberbootEnabled = 0`，确保重启后 445 端口彻底释放 |
| **残留进程清理** | 自动清理自身旧进程，避免误报端口占用 |
| **防火墙精准放行** | 仅放行 `10.10.10.10:445`，不暴露物理网卡 |
| **日志记录** | `engine.log`，超 5MB 自动截断，菜单内可查看 |

---

## 常见问题

**Q: 为什么不能改成 `\\127.0.0.1` 直接用？**

A: Windows `srvnet.sys` 内核对 127.x 回环地址的 SMB 连接有严格限制，触发错误 64 / 67。`10.10.10.10` 绕过了这个限制。

**Q: 虚拟网卡 `SMBProxy` 和物理网卡是什么关系？**

A: 完全独立。它是纯软件层面的虚拟网卡，`/32` 掩码不创建子网路由，不改变默认网关。出站流量走默认物理网卡，`SMBProxy` 仅接收本地 SMB 请求。

**Q: `10.10.10.10` 会断网或影响现有网络吗？**

A: 不会。除非局域网恰好是 `10.10.10.x` 网段，此时可修改脚本开头的 `$VirtualIP` 变量。

**Q: 客户端装完后关掉脚本窗口还能用吗？**

A: 能。实际跑的是后台计划任务进程，独立于安装窗口。重启自启。

**Q: 客户端装完本机还能对外 SMB 共享吗？**

A: 不能。客户端禁用了 `srvnet`。选 `[2]` 停止代理 + 重启即可恢复。

**Q: 服务端重启后规则还在吗？**

A: 在。`netsh portproxy` 写入注册表，系统启动自动加载。

**Q: DDNS IP 变了怎么办？**

A: 引擎每 10 秒自动重解析。检测到变更后新连接即时生效。

**Q: 这个项目提供内网穿透 / 端口映射吗？**

A: **不提供。** SMBProxy 不是 frp/ngrok/ZeroTier。前提是服务端已有公网可达 IP + DDNS 域名。**它解决的是 "SMB 不能改端口" 的问题，不是 "没有公网 IP" 的问题。**

**Q: 重启后提示"仍需重启"？**

A: Windows 快速启动导致——混合关机把内核状态保存到 `hiberfil.sys`，开机恢复后 `srvnet` 依然加载。脚本自动设置 `HiberbootEnabled = 0` 关闭快速启动（只关混合关机，不动休眠功能）。如果还不行，用 `shutdown /r /t 0` 重启，或关机时按住 `Shift`。

**Q: 安全性？**

A: TCP 透明转发，不存储凭据。建议服务端启用 SMB 加密：

```powershell
Set-SmbServerConfiguration -EncryptData $true -Force
```

---

## 手动卸载

### 服务端手动卸载

```powershell
netsh interface portproxy delete v4tov4 listenport=1445
netsh interface portproxy delete v6tov6 listenport=1445
netsh advfirewall firewall delete rule name="SMB-Proxy-Port-1445"
```

### 客户端手动卸载

```powershell
Unregister-ScheduledTask -TaskName "SMBForword_Client_Core" -Confirm:$false
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*SMBForword*" } | ForEach-Object { Stop-Process $_.ProcessId -Force }

Remove-NetIPAddress -IPAddress 10.10.10.10 -Confirm:$false
Remove-NetFirewallRule -DisplayName "SMBForword-Client-Local-445" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 3
Set-Service -Name LanmanServer -StartupType Automatic
Start-Service -Name LanmanServer

Get-NetAdapter -Name "SMBProxy" -ErrorAction SilentlyContinue | ForEach-Object {
    $pnp = Get-PnpDevice -InstanceId $_.PnPDeviceID -ErrorAction SilentlyContinue
    if ($pnp) { Disable-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false }
}

Remove-Item -Path "C:\ProgramData\SMBForword" -Recurse -Force
```
