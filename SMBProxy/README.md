# SMBProxy

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**突破运营商 445 端口封锁，从任何网络安全访问你的远程 SMB 共享。**

公网 445 端口普遍被 ISP 封禁，而 Windows 的 `\\` UNC 路径语法不支持指定端口号。SMBProxy 通过**服务端 netsh 端口转发 + 客户端虚拟回环网卡代理**打通全链路，让远程 SMB 像本地文件夹一样直接挂载。

---

## 目录

- [架构总览](#架构总览)
- [核心原理对比](#核心原理对比)
- [兼容性](#兼容性)
  - [服务端](#服务端)
  - [客户端](#客户端)
  - [Server 版](#server-版)
- [快速开始](#快速开始)
  - [服务端](#1-服务端)
  - [客户端](#2-客户端)
  - [非 Windows 客户端](#3-非-windows-客户端)
- [客户端引擎特性 v3.1](#客户端引擎特性-v31)
- [脚本功能](#脚本功能)
- [常见问题](#常见问题)
- [手动卸载](#手动卸载)
  - [服务端](#服务端手动卸载)
  - [客户端](#客户端手动卸载)
- [项目结构](#项目结构)
- [License](#license)

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

## 核心原理对比

| | 服务端 | 客户端 |
|------|--------|--------|
| **技术** | `netsh portproxy` (内核级) | PowerShell 数据泵 (用户态) |
| **入口** | `[::]:1445` / `0.0.0.0:1445` | 虚拟回环网卡 `SMBProxy` → `10.10.10.10:445` |
| **出口** | 转发到 `127.0.0.1:445` | 转发到远程 `域名:1445` |
| **网卡** | 无需额外配置 | 独立虚拟网卡 (Microsoft KM-TEST Loopback Adapter)，与物理网卡完全隔离 |
| **持久化** | 注册表 `HKLM\...\PortProxy` | 计划任务 `SMBForword_Client_Core` |
| **进程** | 零进程 (内核 NAT) | 1 个 `powershell.exe` (SYSTEM) |
| **重启** | 规则不丢失 | 开机自启 |
| **IPv4/IPv6** | 手动选择 (单栈/双栈) | DNS 自动检测 (优先 IPv6，回退 IPv4) |
| **DDNS 刷新** | 不需要 (直连本地) | 每 10 秒自动重解析 |
| **系统兼容** | XP ~ Win11 | Win7 ~ Win11 / Server 2008 R2 ~ 2025 |

---

## 兼容性

### 服务端

| 系统 | 脚本 | 状态 |
|------|------|------|
| Windows 10 / 11 | `server/setup-server.ps1` | ✅ 完美 |
| Windows 8 / 8.1 | `server/setup-server.ps1` | ✅ 完美 |
| Windows 7 | `server/setup-server.ps1` | ✅ 完美 |
| Windows Vista | `server/setup-server.ps1` | ✅ 可用 |
| Windows Server 2016 / 2019 / 2022 / 2025 | `server/setup-server.ps1` | ✅ 完美 |
| Windows Server 2012 / 2012 R2 | `server/setup-server.ps1` | ✅ 完美 |
| Windows Server 2008 R2 | `server/setup-server.ps1` | ✅ 完美 |
| Windows XP (需 PS 2.0) | `server/setup-server.ps1` | ⚠️ `netsh advfirewall` 不存在，需手动添加防火墙规则 |

### 客户端

| 系统 | 脚本 | 状态 |
|------|------|------|
| Windows 10 / 11 | `client/setup-client-win10-11.ps1` | ✅ 完美 (目标平台) |
| Windows 8 / 8.1 | `client/setup-client-win8-1.ps1` | ✅ 支持 |
| Windows 7 (需 WMF 5.1 + .NET 4.8) | `client/setup-client-win7.ps1` | ✅ 支持 (含离线插件自动安装) |

### Server 版

| 系统 | 脚本 | 状态 |
|------|------|------|
| Server 2016 / 2019 / 2022 / 2025 | `client/setup-client-2016++.ps1` | ✅ 完美 |
| Server 2012 / 2012 R2 | `client/setup-client-2012-r2.ps1` | ✅ 支持 |
| Server 2008 R2 (需 WMF 5.1 + .NET 4.8) | `client/setup-client-2008r2.ps1` | ✅ 支持 (含离线插件自动安装) |
| Server 2008 (非 R2) | 不支持 | ❌ NT 6.0 内核，无法安装 WMF 5.1 |
| Windows XP / Vista | 不支持 | ❌ 缺少 NetAdapter / ScheduledTasks / CIM 等系统模块 |

> **服务端与客户端不能在同一台机器上运行** — 服务端需要 `srvnet` + `LanmanServer` 开启以提供 SMB 共享，客户端需要禁用它们以释放 445 端口。

---

## 快速开始

> **所有脚本必须以管理员权限运行。** 右键 PowerShell → **以管理员身份运行**，然后执行：
> ```powershell
> Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
> ```
> 或直接启动时绕过执行策略 (Server 或 Client 均适用)：
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\setup-server.ps1
> powershell -ExecutionPolicy Bypass -File .\setup-client-win10-11.ps1
> ```
> 如果遇到 `无法加载文件 ... 未进行数字签名` 或 `PSSecurityException` 错误，右键脚本文件 → **属性** → 勾选 **解除锁定** → 确定。

### 1. 服务端

右键 `server/setup-server.ps1` → **以管理员身份运行** → 选 `[1]`。

```
请输入公网监听端口号 (1-65535, 建议 1445): 1445

请选择你的公网 IP 类型:
  [1] IPv4
  [2] IPv6
  [3] 双栈 (同时添加)
你的选择 (1/2/3): 2
```

验证：

```
类型       监听地址:端口          目标地址:端口
--------   ------------------   ------------------------------
v6tov6     [::]:1445             [::1]:445
```

> 规则写入注册表，关闭窗口或重启均不丢失。

### 2. 客户端

右键对应系统的脚本 → **以管理员身份运行**。

**首次使用需要两步：**

**第一步 — 安装虚拟回环网卡 (仅一次)：**

首次运行选 `[1]` 时，脚本会自动弹出 `hdwwiz.exe` 硬件安装向导，按以下步骤操作：

1. 点 **[下一步]**
2. 选择 **[安装我手动从列表选择的硬件]** → **[下一步]**
3. 选择 **[网络适配器]** → **[下一步]**
4. 厂商选 **[Microsoft]**，型号选 **[Microsoft KM-TEST Loopback Adapter]**
5. **[下一步]** → **[下一步]** → **完成**
6. 回到脚本窗口按任意键，脚本将自动接管该网卡并重命名为 `SMBProxy`

> 此操作仅需一次，之后脚本会自动检测并接管该网卡。

**Win7 / Server 2008 R2 特别注意：**  
这两个系统缺少基础组件。脚本会自动检测并按顺序安装：
1. SHA-2 签名补丁 (KB4490628 + KB4474419)
2. .NET Framework 4.8
3. WMF 5.1 (PowerShell 5.1)

前提文件可提前下载到对应插件目录 (`win7plug` / `2008r2plug`) 实现离线安装，无需联网。

**第二步 — 常规安装：**

首次运行还会检测到 `srvnet` 未禁用，自动处理并**要求重启**。重启后重新运行脚本，选 `[1]`：

```
输入远程DDNS域名 (例如: mynas.dns.com): home.coldnight.top
输入远程端口号 (直接回车使用: 1445):
```

脚本自动完成：

1. 清理残留引擎进程 (避免误报端口占用)
2. 禁用本机 SMB 驱动 (`srvnet`) 释放 445 端口
3. 关闭 Windows 快速启动：`HiberbootEnabled = 0` (只关混合关机，不动休眠功能，避免重启后 445 端口仍被占用)
4. 接管虚拟回环网卡 `SMBProxy` 并绑定 IP `10.10.10.10/32`
5. 添加本机防火墙规则 (仅限 `10.10.10.10:445`)
6. DNS 预检，确认域名可解析
7. 部署核心引擎到 `C:\ProgramData\SMBForword\`
8. 注册计划任务 → 开机自启 → 崩溃自动重启 → 不限运行时长
9. 立即启动引擎

看到 `[状态] 引擎已启动, 端口监听正常` 后：

```
Win+R → \\10.10.10.10 → 回车
或 文件管理器地址栏 → \\10.10.10.10\共享名
```

### 3. 非 Windows 客户端

> **前提**: 服务端已运行 `server/setup-server.ps1`，防火墙已放行目标端口。

#### Linux

```bash
# 安装 cifs-utils
sudo apt install cifs-utils          # Debian/Ubuntu
sudo yum install cifs-utils          # CentOS/RHEL

# 挂载 (支持指定端口)
sudo mount -t cifs //域名:端口/共享名 /mnt/smb \
  -o username=用户名,password=密码,vers=3.0

# 文件管理器连接 (GNOME/KDE)
smb://域名:端口/
```

#### macOS

```
Finder → 前往 → 连接服务器 (⌘K)
输入: smb://域名:端口/共享名

# 或命令行挂载
mount_smbfs //用户名@域名:端口/共享名 /Volumes/挂载点
```

#### Android

以下文件管理器支持自定义 SMB 端口：
- Solid Explorer (推荐)
- Material Files (开源)
- CIFS Document Provider
- CX 文件管理器

添加 SMB 时直接填入域名和端口即可。

#### iOS / iPadOS

以下 App 支持自定义 SMB 端口：
- FileBrowser Pro / FileBrowser GO (推荐)
- FE File Explorer Pro
- Documents by Readdle
- Owlfiles

在 App 中添加 SMB 连接时填写域名和端口。

#### 排障

- 确保服务端防火墙已放行目标端口
- 确保两端连通性 (`ping -6 域名` 测试 IPv6 / `ping 域名` 测试 IPv4)
- 运营商可能封禁非标准端口，优先选 1445 / 8445 等
- 某些家用路由器需要额外设置 IPv6 防火墙放行

---

## 客户端引擎特性 v3.1

| 特性 | 说明 |
|------|------|
| **虚拟回环网卡** | 使用 Microsoft KM-TEST Loopback Adapter，创建独立虚拟网卡 `SMBProxy`，与 WiFi / 以太网 / 手机热点等物理网卡完全隔离，不受任何网络切换影响 |
| **异步数据泵** | `Stream.CopyToAsync` .NET 原生异步 IO，不逐连接创建 PowerShell Runspace，消除长期运行下的句柄 / 线程泄漏 |
| **IPv4/IPv6 自动** | DNS 解析后自动选择连接协议 (优先 IPv6，回退 IPv4)，无需手动指定网络类型 |
| **DDNS 自动刷新** | 每 10 秒自动重解析域名，IP 变更后新连接几乎即时生效 |
| **DNS 自愈** | DNS 解析失败时自动重试 (最多 30 次，每次间隔 5 秒)，适应开机时网络未就绪或 DDNS 延迟生效的场景 |
| **崩溃自愈** | 引擎内部 `try/catch` 包裹主循环，任何异常记录日志并 2 秒后自动恢复；计划任务层面自动重启作为兜底 |
| **执行时限关闭** | 显式关闭 Windows 计划任务默认 72 小时执行时限，避免引擎被计划任务强制终止 |
| **快速启动关闭** | 自动设置 `HiberbootEnabled = 0` 关闭 Windows 快速启动 (混合关机)，确保重启后 `srvnet` 驱动完整重载，445 端口彻底释放。注意：只关快速启动，不动休眠功能 (`powercfg /h off`)，不影响 `hiberfil.sys` |
| **残留进程清理** | 每次运行自动清理自身旧引擎进程，避免重复运行脚本时误报 445 端口被占用 |
| **防火墙精准放行** | 仅放行 `10.10.10.10:445` 入站流量，不暴露物理网卡的其他接口 |
| **日志记录** | 完整日志写入 `engine.log`，超 5MB 自动截断，菜单内可直接查看最近 50 行 |

---

## 脚本功能

### server/setup-server.ps1

| 菜单 | 操作 |
|------|------|
| `[1]` 添加转发 | 选择端口 + IPv4 / IPv6 / 双栈 → netsh portproxy + 防火墙 |
| `[2]` 删除转发 | 表格展示当前规则 → 按端口删除 + 清理防火墙 |
| `[3]` 查看规则 | 解析 `netsh portproxy dump` 格式化表格展示 |
| `[4]` 退出 | 规则保留在系统中 |

### client/setup-client-*.ps1 (客户端 & Server 版)

| 菜单 | 操作 |
|------|------|
| `[1]` 安装 / 更新 | 首次引导安装虚拟回环网卡 → 禁用 srvnet → 关闭快速启动 (HiberbootEnabled=0) → 绑定虚拟 IP → 防火墙 → 部署引擎 → 计划任务 → 启动 |
| `[2]` 停止并恢复 | 移除计划任务 → 杀进程 → 删虚拟 IP → 删防火墙规则 → 移除虚拟回环网卡 → 恢复 SMB 驱动 → 恢复 LanmanServer 服务 |
| `[3]` 查看日志 | 显示最近 50 行引擎运行日志 |
| `[4]` 退出 | 引擎继续后台运行 |

---

## 常见问题

**Q: 为什么不能改成 `\\127.0.0.1` 直接用？**

A: Windows `srvnet.sys` 内核对 127.x 回环地址的 SMB 连接有严格限制，触发错误 64 "指定的网络名不再可用" 或错误 67 "找不到网络名"。虚拟局域网 IP `10.10.10.10` 绕过了这个限制。

**Q: 虚拟回环网卡 `SMBProxy` 和物理网卡是什么关系？**

A: 完全独立，互不影响。`SMBProxy` 是一个纯软件层面的虚拟网卡 (Microsoft KM-TEST Loopback Adapter)，通过 `hdwwiz` 手动安装。它绑定了 `10.10.10.10/32`，前缀 `/32` 等于子网掩码 `255.255.255.255`，不创建新子网路由，不改变默认网关。无论你用 WiFi、插网线还是手机热点上网，`SMBProxy` 都不受影响，反之亦然。**出站流量走的是你默认的物理网卡，`SMBProxy` 仅用于接收本地 SMB 请求。**

**Q: `10.10.10.10` 会断网或影响现有网络吗？**

A: 不会。`/32` 掩码不创建子网路由，不改变默认网关。除非你的局域网恰好是 `10.10.10.x` 网段，此时可手动修改脚本开头的 `$VirtualIP` 变量为其他私有 IP。

**Q: 客户端装完后关掉脚本窗口还能用吗？**

A: 能。实际跑的是后台计划任务引擎进程，独立于交互式安装窗口。重启也依然自启。

**Q: 客户端装完本机还能对外 SMB 共享吗？**

A: 不能。客户端禁用了 `srvnet` 驱动释放 445。选 `[2]` 停止代理 + 重启即可恢复。

**Q: 服务端重启后规则还在吗？**

A: 在。`netsh portproxy` 写入 `HKLM\SYSTEM\CurrentControlSet\Services\PortProxy`，系统启动自动加载。

**Q: DDNS IP 变了怎么办？**

A: 引擎每 10 秒自动重解析域名一次。检测到 IP 变更后新连接几乎即时生效，无需任何手动操作。

**Q: 客户端网络切换 (比如从 WiFi 切到手机热点) 需要重启引擎吗？**

A: 不需要。`SMBProxy` 虚拟网卡与物理网络无关，`\\10.10.10.10` 始终可访问。DDNS 每 10 秒自动刷新，新网络恢复连通性后几乎即时生效。也可以直接重新运行脚本选 `[1]` 即时更新。

**Q: 这个项目提供内网穿透 / 端口映射吗？**

A: **不提供。** SMBProxy 不是内网穿透工具 (如 frp / ngrok / ZeroTier)。它的工作前提是**服务端已经具备公网可达的 IP 地址** (IPv4 或 IPv6)，并且你拥有一个指向该 IP 的 DDNS 域名。如果服务端在 NAT / CG-NAT / 无公网 IP 的内网中，你需要先用端口映射、DMZ、UPnP 或 IPv6 防火墙放行等方式让服务端的某个端口从公网可达，然后 SMBProxy 才能工作。

简单说：**SMBProxy 解决的是"SMB 不能改端口"的问题，不是"没有公网 IP"的问题。**

**Q: 重启电脑后提示"仍需重启"怎么办？**

A: 这是 Windows **快速启动 (Fast Startup)** 导致的经典死循环。

**根本原因：**

Windows 快速启动使用"混合关机"——关机时把内核会话写入 `hiberfil.sys`，下次开机直接恢复，跳过完整的驱动初始化过程。所以：

1. 脚本设置 `srvnet` 注册表 `Start = 4` (禁用驱动)
2. 你关机 (混合关机)，系统把「srvnet 仍在运行」的内核状态保存到 `hiberfil.sys`
3. 你开机，Windows 从 `hiberfil.sys` 恢复旧状态——`srvnet` 依然加载着
4. 445 端口仍然被占用，脚本再提示你重启
5. 循环……

**脚本的解决方案：**

脚本自动将注册表 `HiberbootEnabled` 设为 `0`，**只关闭快速启动，不动休眠功能**。下次开机时 Windows 将执行真正的冷启动，完整加载一遍所有驱动，`srvnet = 4` (禁用) 才能生效。

> **重要**：只关 `HiberbootEnabled`，不会删除 `hiberfil.sys`，不会影响手动休眠 (`shutdown /h`)。你完全可以保留休眠功能，这跟 SMB 没任何关系。

**如果依然有问题：**

- 确保使用了 `shutdown /r /t 0` 来重启（完整重启），而非通过开始菜单"关机"再手动开机
- 关机时按住 `Shift` 键再点"关机"，强制执行完全关机

**Q: 安全性？**

A: 代理仅做 TCP 透明转发，不存储凭据。建议服务端启用 SMB 加密：

```powershell
Set-SmbServerConfiguration -EncryptData $true -Force
```

---

## 手动卸载

### 服务端手动卸载

在服务端管理员 PowerShell 中执行：

```powershell
# 删转发规则 (替换 1445 为你的实际端口)
netsh interface portproxy delete v4tov4 listenport=1445
netsh interface portproxy delete v6tov6 listenport=1445

# 删防火墙规则 (替换端口号)
netsh advfirewall firewall delete rule name="SMB-Proxy-Port-1445"
```

### 客户端手动卸载

在客户端管理员 PowerShell 中执行：

```powershell
# 移除计划任务
Unregister-ScheduledTask -TaskName "SMBForword_Client_Core" -Confirm:$false

# 杀进程
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*SMBForword*" } | ForEach-Object { Stop-Process $_.ProcessId -Force }

# 删虚拟 IP + 防火墙 + 恢复 SMB
Remove-NetIPAddress -IPAddress 10.10.10.10 -Confirm:$false
Remove-NetFirewallRule -DisplayName "SMBForword-Client-Local-445" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\srvnet" -Name "Start" -Value 3
Set-Service -Name LanmanServer -StartupType Automatic
Start-Service -Name LanmanServer

# 删虚拟回环网卡
Get-NetAdapter -Name "SMBProxy" -ErrorAction SilentlyContinue | ForEach-Object {
    $pnp = Get-PnpDevice -InstanceId $_.PnPDeviceID -ErrorAction SilentlyContinue
    if ($pnp) {
        Disable-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false
        Remove-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false
    }
}

# 删文件
Remove-Item -Path "C:\ProgramData\SMBForword" -Recurse -Force
```

---

## 项目结构

```
SMBProxy/
├── README.md
├── server/
│   └── setup-server.ps1              # 服务端 (WinXP ~ Win11 / Server 全系列)
**客户端 (client/)**

| 脚本 | 适用系统 | 说明 |
|------|---------|------|
| `setup-client-win10-11.ps1` | Win10 / Win11 | 主力平台 |
| `setup-client-win8-1.ps1` | Win8 / Win8.1 | — |
| `setup-client-win7.ps1` | Win7 | 含离线插件 (win7plug) |
| `setup-client-2016++.ps1` | Server 2016 / 2019 / 2022 / 2025 | Server 版 |
| `setup-client-2012-r2.ps1` | Server 2012 / 2012 R2 | Server 版 |
| `setup-client-2008r2.ps1` | Server 2008 R2 | 含离线插件 (2008r2plug) |

**插件目录**

| 目录 | 内容 | 用途 |
|------|------|------|
| `client/win7plug/` | SHA-2 补丁 / .NET 4.8 / WMF 5.1 | Win7 x86+x64 离线安装 |
| `client/2008r2plug/` | SHA-2 补丁 / .NET 4.8 / WMF 5.1 | Server 2008 R2 x64 离线安装 |

**内核对照**

| 内核 | 客户端 OS | 对应 Server |
|---|---|---|
| NT 10.0 | Win10 / Win11 | Server 2016 / 2019 / 2022 / 2025 |
| NT 6.3 | Win8.1 | Server 2012 R2 |
| NT 6.2 | Win8 | Server 2012 |
| NT 6.1 | Win7 | Server 2008 R2 |
| NT 6.0 | Vista / Server 2008 | ❌ 不支持 |

---

## License

MIT
