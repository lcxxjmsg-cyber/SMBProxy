# SMBProxy

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**突破运营商 445 端口封锁，从任何网络安全访问你的远程 SMB 共享。**

公网 445 端口普遍被 ISP 封禁，而 Windows 的 `\\` UNC 路径语法不支持指定端口号。SMBProxy 通过**服务端 netsh 端口转发 + 客户端虚拟回环网卡代理**打通全链路，让远程 SMB 像本地文件夹一样直接挂载。

---

## 目录

- [架构总览](#架构总览)
- [系统兼容性](#系统兼容性)
- [SMB 跨平台原生支持](#smb-跨平台原生支持)
- [快速开始](#快速开始)
- [客户端引擎特性 v4.5](#客户端引擎特性-v45)
- [常见问题](#常见问题)
- [手动卸载](#手动卸载)

---

## 架构总览

```
                        SMBProxy 数据流

   客户端 (访问方)                                    服务端 (SMB 主机)
   ┌──────────────────────────┐                    ┌──────────────────────────┐
   │                          │                    │                          │
   │   explorer / net use     │                    │      SMB 服务 (smbd)     │
   │   \\10.10.10.10\共享      │                    │      127.0.0.1:445        │
   │          │               │                    │           ↑              │
   │          ▼               │                    │           │              │
   │   虚拟回环网卡            │                    │      netsh portproxy     │
   │   SMBProxy_N             │                    │      0.0.0.0:1445         │
   │   10.10.10.x/24          │──── 公网 IP ──────→│           ↑              │
   │   (KM-TEST Loopback)     │   DDNS 域名:1445    │           │              │
   │          │               │                    │      防火墙 放行 1445      │
   │          ▼               │                    │           ↑              │
   │   PowerShell 引擎 (单线程) │                    │      公网 IP + DDNS       │
   │   TCP 数据泵              │                    │                          │
   │   10.10.10.x:445          │                    └──────────────────────────┘
   │          ↑               │
   │   计划任务 SYSTEM         │
   │   开机自启 · 崩溃重试     │
   └──────────────────────────┘

   ┌──────────────────── 关键技术 ────────────────────────┐
   │                                                       │
   │  为什么用 10.10.10.x 而不是 127.0.0.1 ?              │
   │  Windows srvnet.sys 内核对 127.x 回环地址的 SMB      │
   │  连接有严格限制，会触发错误 64 / 67。                 │
   │                                                       │
   │  为什么用独立虚拟回环网卡而不是绑定物理网卡？         │
   │  物理网卡 IP 会随网络环境变化，且可能与局域网 IP      │
   │  段冲突。KM-TEST Loopback Adapter 创建独立虚拟        │
   │  网卡，/24 子网完全隔离，不影响任何物理网络。         │
   │                                                       │
   │  引擎为什么是单线程？                                  │
   │  DNS 解析 / 连接处理在主循环中串行，数据传输通过      │
   │  CopyToAsync 异步 IO 交给内核，不占用主线程。         │
   │  单线程规避了 ThreadPool + PowerShell 脚本块的        │
   │  进程级崩溃风险，在 Win11 25H2 上实测稳定。           │
   │                                                       │
   └───────────────────────────────────────────────────────┘
```

---

## 系统兼容性

### 服务端 (一台即可)

| 系统 | 脚本 | 状态 |
|------|------|------|
| Windows 10 / 11 | `server/setup-server.ps1` | ✅ |
| Windows 8 / 8.1 | `server/setup-server.ps1` | ✅ |
| Windows 7 | `server/setup-server.ps1` | ✅ |
| Windows Server 2016+ | `server/setup-server.ps1` | ✅ |
| Windows Server 2012 / R2 | `server/setup-server.ps1` | ✅ |
| Windows Server 2008 R2 | `server/setup-server.ps1` | ✅ |
| Windows Vista | `server/setup-server.ps1` | ✅ |
| Windows XP (需 PS 2.0) | `server/setup-server.ps1` | ⚠️ 需手动防火墙 |

### 客户端

| 系统 | 脚本 | 状态 |
|------|------|------|
| Windows 10 / 11 | `client/setup-client-win10-11.ps1` | ✅ |
| Windows 8 / 8.1 | `client/setup-client-win8-1.ps1` | ✅ |
| Windows 7 (需 WMF 5.1 + .NET 4.8) | `client/setup-client-win7.ps1` | ✅ |
| Server 2016 / 2019 / 2022 / 2025 | `client/setup-client-2016++.ps1` | ✅ |
| Server 2012 / 2012 R2 | `client/setup-client-2012-r2.ps1` | ✅ |
| Server 2008 R2 (需 WMF 5.1 + .NET 4.8) | `client/setup-client-2008r2.ps1` | ✅ |
| Server 2008 (非 R2) | — | ❌ NT 6.0, 无法安装 WMF 5.1 |
| Windows XP / Vista | — | ❌ 缺少 NetAdapter / CIM 等系统模块 |

> 服务端与客户端不能在同一台机器上运行。

---

## SMB 跨平台原生支持

> 以下表格反映各平台对 SMB 协议的原生支持情况。不支持自定义端口的平台需借助 SMBProxy 客户端脚本。

### 访问远程 SMB (客户端)

| 平台 | 原生 SMB | 支持自定义端口 | 建议方案 |
|------|---------|:---:|------|
| **Windows 10/11** | ✅ 资源管理器 (`\\host`) | ❌ | SMBProxy 客户端 → `\\10.10.10.10` |
| **Windows 8/8.1** | ✅ 资源管理器 (`\\host`) | ❌ | SMBProxy 客户端 → `\\10.10.10.10` |
| **Windows 7** | ✅ 资源管理器 (`\\host`) | ❌ | SMBProxy 客户端 → `\\10.10.10.10` |
| **macOS** | ✅ Finder (`smb://host:port`) | ✅ | 原生直连：`smb://域名:端口` |
| **Linux (GNOME/KDE)** | ✅ Nautilus / Dolphin (`smb://host:port`) | ✅ | 原生直连或 `mount -t cifs` |
| **Android** | ❌ | — | Solid Explorer / Material Files / CX File Explorer |
| **iOS / iPadOS** | ✅ (Files App, iOS 13+) | ❌ (仅标准 445) | FileBrowser Pro / FE File Explorer |

### 提供 SMB 共享 (服务端)

| 平台 | SMB 服务 | 支持改端口 | 建议方案 |
|------|---------|:---:|------|
| **Windows 10/11** | LanmanServer | ❌ | `server/setup-server.ps1` → netsh portproxy |
| **macOS** | smbd | ✅ | 改 `/etc/smb.conf` → `smb ports = 1445` |
| **Linux** | Samba (smbd) | ✅ | 改 `/etc/samba/smb.conf` → `smb ports = 1445` |
| **Android** | 第三方 App | ✅ | 极少作为服务端 |
| **iOS / iPadOS** | 不支持 | ❌ | — |

---

## 快速开始

**管理员 PowerShell** 执行：

```powershell
# 服务端
powershell -ExecutionPolicy Bypass -File .\server\setup-server.ps1

# 客户端 (选对应系统)
powershell -ExecutionPolicy Bypass -File .\client\setup-client-win10-11.ps1
```

### 1. 服务端

选 `[1]` 添加端口转发规则，输入公网监听端口（建议 1445），选择 IP 版本。

### 2. 客户端

选 `[1]` 添加线路，输入远程 DDNS 域名和端口。

首次使用会弹出 `hdwwiz.exe` 硬件安装向导：
1. 下一步 → 安装我手动从列表选择的硬件
2. 网络适配器 → 厂商 Microsoft → **Microsoft KM-TEST 环回适配器**
3. 完成 → 回到 PowerShell 窗口按任意键

脚本自动完成：网卡重命名 → 绑定虚拟 IP → 防火墙 → 部署引擎 → 计划任务。

Win7 / 2008 R2 需额外依赖 (SHA-2 / .NET 4.8 / WMF 5.1)，脚本自动检测安装。

安装完成后：

```
Win+R → \\10.10.10.10 → 回车
```

多线路映射时 IP 依次为 `10.10.10.10`、`10.10.10.11`、`10.10.10.12` ...

### 3. 非 Windows 客户端

服务端已运行即可，无需脚本，直接连接 `域名:端口`。

#### Linux

```bash
# 挂载
sudo mount -t cifs //域名:端口/共享名 /mnt -o user=用户名,vers=3.0

# 文件管理器直接访问
# Nautilus / Dolphin 地址栏输入: smb://域名:端口/
```

#### macOS

```
Finder → ⌘K → smb://域名:端口/共享名

# 或命令行:
mount_smbfs //用户名@域名:端口/共享名 /Volumes/挂载点
```

#### Android

Android 无原生 SMB 客户端，需安装第三方 App：

| App | 说明 |
|-----|------|
| Solid Explorer | 付费，体验最佳 |
| Material Files | 开源免费 |
| CX File Explorer | 免费，支持 SMB |
| CIFS Document Provider | 系统级挂载 |

连接方式：添加 SMB 服务器 → 填 `域名` + `端口` + 凭据。

#### iOS / iPadOS

iOS Files App 仅支持标准 445 端口，需第三方 App：

| App | 说明 |
|-----|------|
| FileBrowser Pro / GO | 推荐 |
| FE File Explorer Pro | 支持自定义端口 |
| Owlfiles | 支持 SMB |
| Documents by Readdle | 支持 SMB |

连接方式：添加 SMB 连接 → 填 `域名:端口` + 凭据。

---

## 客户端引擎特性 v4.5

| 特性 | 说明 |
|------|------|
| **虚拟回环网卡** | 每条线路独立 KM-TEST Loopback Adapter (`SMBProxy_N`)，与物理网卡完全隔离 |
| **异步数据泵** | `Stream.CopyToAsync` .NET 原生异步 IO，字节搬运由内核完成，不占用主线程 |
| **IPv4/IPv6 自动** | DNS 解析后自动选择 (优先 IPv6，回退 IPv4) |
| **DNS 异步超时** | `BeginGetHostAddresses` + 5s 超时，断网不卡死引擎 |
| **DDNS 定时刷新** | 每 60s 轮询解析，一轮仅解析一条线路 (break)，避免级联阻塞 |
| **连接超时保护** | `BeginConnect` + 5s 超时，死远程快速释放 |
| **侦听重试机制** | TcpListener 创建失败自动重试 3 次（每次间隔 2s），兼容环回网卡初始化延迟 |
| **Socket 双向清理** | Pump 闭包同时释放双向 TcpClient + NetworkStream，杜绝孤儿连接 |
| **日志滚动** | 每小时检测，超 5MB 自动截断，避免 I/O 争抢 |
| **崩溃自愈** | `try/catch` 双保险 + 计划任务自动重启（SYSTEM 账户，开机自启） |
| **快速启动关闭** | `HiberbootEnabled = 0`，确保重启后 445 端口彻底释放 |
| **线路隔离** | 每条线路独立网卡 + 独立 IP + 独立 Listener，某线路故障不影响其他线路 |
| **配置热加载** | 每 10s 检测 config.json 变更，增删线路无需重启引擎 |
| **防火墙精准放行** | 仅放行 `10.10.10.x:445`，不暴露物理网卡 |
| **残留进程清理** | 自动清理自身旧进程，避免误报端口占用 |

---

## 常见问题

**Q: 为什么不能改成 `\\127.0.0.1` 直接用？**

A: Windows `srvnet.sys` 内核对 127.x 回环地址的 SMB 连接有严格限制，触发错误 64 / 67。`10.10.10.10` 绕过了这个限制。

**Q: 虚拟网卡 `SMBProxy_N` 和物理网卡是什么关系？**

A: 完全独立。纯软件虚拟网卡，`/24` 子网不创建路由，不改变默认网关。出站走物理网卡，`SMBProxy_N` 仅接收本地 SMB 请求。

**Q: `10.10.10.x` 会断网或影响现有网络吗？**

A: 不会。除非局域网恰好是 `10.10.10.x` 网段，此时可修改脚本中的 IP 段。

**Q: 客户端装完后关掉脚本窗口还能用吗？**

A: 能。实际跑的是后台计划任务进程，独立于安装窗口。重启自启，崩溃自动重试。

**Q: 客户端装完本机还能对外 SMB 共享吗？**

A: 不能。客户端禁用了 `srvnet`。选 `[4]` 完全卸载 + 重启即可恢复。

**Q: 服务端重启后规则还在吗？**

A: 在。`netsh portproxy` 写入注册表，系统启动自动加载。

**Q: DDNS IP 变了怎么办？**

A: 引擎每 60s 自动重解析。单次解析带 5s 超时保护，变更后新连接即时生效。

**Q: 某条线路的远程 NAS 挂了，会影响其他线路吗？**

A: 不影响。每条线路独立网卡 + 独立 Listener，DNS 解析和连接均有超时兜底。挂了的线路只是暂时不可用，恢复后自动重连。

**Q: 这个项目提供内网穿透 / 端口映射吗？**

A: **不提供。** SMBProxy 不是 frp/ngrok/ZeroTier。前提是服务端已有公网可达 IP + DDNS 域名。**它解决的是 "SMB 不能改端口" 的问题，不是 "没有公网 IP" 的问题。**

**Q: 安全性？**

A: TCP 透明转发，不存储凭据。建议服务端启用 SMB 加密：

```powershell
Set-SmbServerConfiguration -EncryptData $true -Force
```

---

## 手动卸载

### 服务端

```powershell
netsh interface portproxy delete v4tov4 listenport=1445
netsh interface portproxy delete v6tov6 listenport=1445
netsh advfirewall firewall delete rule name="SMB-Proxy-Port-1445"
```

### 客户端

在脚本菜单中选 `[4]` 完全卸载，或手动执行：

```powershell
# 停止引擎 & 删除计划任务
Unregister-ScheduledTask -TaskName "SMBProxy_Engine" -Confirm:$false
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*engine.ps1*" } | % { Stop-Process $_.ProcessId -Force }

# 移除所有 SMBProxy 网卡 IP
Get-NetAdapter -Name "SMBProxy_*" | Get-NetIPAddress -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false

# 移除防火墙规则
Get-NetFirewallRule -DisplayName "SMBProxy-*" | Remove-NetFirewallRule

# 恢复 SMB 服务
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 3 -Force
Set-Service LanmanServer -StartupType Automatic
Start-Service LanmanServer

# 清理程序目录
Remove-Item "C:\ProgramData\SMBProxy" -Recurse -Force
```
