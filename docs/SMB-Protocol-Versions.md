# SMB 协议版本与安全传输详解

> 本文详解 SMB（Server Message Block）各版本的能力与安全特性、服务端与客户端跨版本通信的差异，以及如何用一行命令开启/关闭 SMB 加密。
>
> 返回主文档：[README](../README.md)

---

## 目录

- [SMB 版本简史](#smb-版本简史)
- [各版本能力对照表](#各版本能力对照表)
- [各平台支持的 SMB 版本](#各平台支持的-smb-版本)
- [服务端 / 客户端跨版本通信规则](#服务端--客户端跨版本通信规则)
- [SMB Encryption（加密传输）注意事项](#smb-encryption加密传输注意事项)
- [非 Windows 客户端兼容性](#非-windows-客户端兼容性)
- [如何取舍](#如何取舍)
- [一键开关 SMB 加密](#一键开关-smb-加密)
- [常用命令参考](#常用命令参考)

---

## SMB 版本简史

| 版本 | 首次登场 | 关键特性 | 加密 |
|------|---------|---------|:---:|
| **SMB 1.0 (CIFS)** | Windows 2000 / XP | 最初协议。无加密、无预认证。存在 EternalBlue / WannaCry 漏洞。Win10 1709+ 默认不安装，微软建议彻底禁用。 | ❌ |
| **SMB 2.0** | Windows Vista / Server 2008 | 请求复合、更大缓冲区、持久句柄。有签名但默认不强制。 | ❌ |
| **SMB 2.1** | Windows 7 / Server 2008 R2 | 客户端不透明锁、大 MTU 支持。 | ❌ |
| **SMB 3.0** | Windows 8 / Server 2012 | 引入 **SMB Encryption (AES-128-CCM)**、多通道、透明故障转移、VSS 远程备份。 | ✅ AES-128-CCM |
| **SMB 3.0.2** | Windows 8.1 / Server 2012 R2 | 小幅改进，安全特性与 3.0 基本一致。 | ✅ AES-128-CCM |
| **SMB 3.1.1** | Windows 10 / Server 2016+ | 引入**预认证完整性 (Pre-Auth Integrity)**、更强加密 **AES-128-GCM / AES-256-GCM**。目前最安全的版本。 | ✅ AES-128/256-GCM |

---

## 各版本能力对照表

| 能力 | 1.0 | 2.0 | 2.1 | 3.0 | 3.0.2 | 3.1.1 |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| SMB 签名 | 弱 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 加密传输 | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| 预认证完整性 | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 多通道 | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| 已知重大漏洞 | ⚠️ EternalBlue | — | — | — | — | — |
| 安全建议 | **禁用** | 可用 | 可用 | 推荐 | 推荐 | **最推荐** |

---

## 各平台支持的 SMB 版本

> 下表为各平台**原生/内置** SMB 实现所支持的最高协议版本。第三方软件（如 Linux 上更新的 Samba、移动端 App）可能支持更高版本。

### Windows

| 系统 | 内置最高 SMB 版本 |
|------|------|
| Windows XP / Server 2003 | SMB 1.0 (CIFS) |
| Windows Vista / Server 2008 | SMB 2.0 |
| Windows 7 / Server 2008 R2 | SMB 2.1 |
| Windows 8 / Server 2012 | SMB 3.0 |
| Windows 8.1 / Server 2012 R2 | SMB 3.0.2 |
| Windows 10 / 11 / Server 2016 / 2019 / 2022 / 2025 | **SMB 3.1.1** |

> Windows 10 1709+ 默认**不再安装 SMB 1.0**；如仍在用请保持禁用。

### macOS

| 系统 | 内置最高 SMB 版本 |
|------|------|
| macOS 10.9 Mavericks | SMB 2.x（首次将 SMB2 设为默认） |
| macOS 10.10 Yosemite | SMB 3.0（支持加密） |
| macOS 10.12 Sierra ~ 10.14 | SMB 3.0 |
| macOS 10.15 Catalina 及以后（含 11–15） | **SMB 3.1.1** |

> macOS 也保留 SMB 1.0 兼容，但默认协商更高版本；建议不要强制回落到 SMB1。

### Linux（Samba / 内核 CIFS 客户端）

Linux 的 SMB 能力由 **Samba 版本**（服务端/客户端）或**内核 cifs 模块**决定，与发行版本身关系不大——取决于装的 Samba 版本：

| Samba 版本 | 最高 SMB 版本 | 加密 (SMB3) |
|------|------|:---:|
| Samba 3.6 | SMB 2.0 | ❌ |
| Samba 4.0 | SMB 2.1 | ❌ |
| Samba 4.1 | SMB 3.0 | ✅ |
| Samba 4.3 | SMB 3.1.1（早期） | ✅ |
| Samba 4.11+ | **SMB 3.1.1（完整）** | ✅ |

主流发行版**默认仓库**里的 Samba 大致对应：

| 发行版 | 典型 Samba 版本 | 最高 SMB |
|------|------|------|
| Debian 10 / Ubuntu 18.04–20.04 | 4.9–4.11 | 3.1.1 |
| Debian 11 / Ubuntu 22.04 | 4.13–4.15 | 3.1.1 |
| Debian 12 / Ubuntu 24.04 | 4.17–4.19 | 3.1.1 |
| CentOS 7 / RHEL 7 | 4.10 | 3.1.1 |
| CentOS/RHEL 8 / 9、Rocky、Alma | 4.11+ | 3.1.1 |

> 挂载时可用 `mount -t cifs ... -o vers=3.0`（或 `3.1.1`）显式指定版本。较老的 `vers=1.0` 应避免。

### iOS / iPadOS

| 系统 | SMB 支持 |
|------|------|
| iOS / iPadOS 13+（文件 App 原生） | SMB 3.0 / 3.1.1（**仅标准 445 端口**，不支持自定义端口） |
| 第三方 App（FileBrowser、FE File Explorer 等） | 视 App 而定，多数支持 SMB 2/3 且**可自定义端口** |

### Android

Android **无原生 SMB 客户端**，能力完全取决于所用 App：

| App | 典型支持 |
|------|------|
| Solid Explorer / Material Files / CX File Explorer | SMB 2 / 3，可自定义端口 |
| 旧版或简单 App | 可能仅 SMB 1，安全性差，不建议 |

### NAS / 其他

- **群晖 (Synology DSM)、威联通 (QNAP)** 等现代 NAS：基于 Samba，通常支持到 SMB 3.x，可在控制面板调整最低/最高版本。
- **老旧 NAS / 打印服务器**：可能仅支持 SMB 1.0——若服务端强制加密将无法连接。

---

## 服务端 / 客户端跨版本通信规则

SMB 连接建立时，**服务端与客户端会协商出双方都支持的最高版本 (dialect)**。因此实际使用的是「两端各自最高版本的较小者」。

- 两端都是 Win10/Server2016+ → 协商为 **SMB 3.1.1**（最安全，可用 GCM 加密）。
- 一端是 Win8/2012（3.0），另一端是 Win10（3.1.1）→ 协商为 **SMB 3.0**（加密降为 AES-128-CCM）。
- 一端只支持 SMB 2.x（如 Win7、旧 NAS）→ 协商为 **SMB 2.x**，**无法使用加密**。
- 一端只有 SMB 1.0 → 存在安全风险，应禁用。

**关键推论：**

1. **加密要求双方都支持 SMB 3.0+。** 只要有一端最高只到 SMB 2.x，这条连接就无法加密。
2. **服务端一旦强制加密（`EncryptData $true`），所有 SMB 2.x 及以下客户端将被直接拒绝，无法连接。** 包括 Win7 / Vista / XP、旧 NAS、旧版 Linux Samba(<4.1)。
3. 想要最强安全（AES-256-GCM + 预认证完整性），**两端都必须是 Win10 / Server 2016+（SMB 3.1.1）**。

---

## SMB Encryption（加密传输）注意事项

1. **兼容性**
   - 服务端开加密后，SMB 2.x 及以下客户端将无法连接。
   - 包括旧 NAS、旧 Linux Samba(<4.1)、XP/Vista/Win7。
   - 网络中若有旧设备，先确认它们是否支持 SMB 3.0。

2. **性能影响**
   - AES 硬件加速 (AES-NI) 可大幅降低 CPU 开销。
   - 千兆网络下软件加密约损失 15–30% 吞吐量。
   - 10GbE 网络建议使用支持 AES-NI 的 CPU。
   - 纯内网且信任网络时，可考虑不开加密。

3. **与 SMB 签名的关系**
   - 加密开启后 SMB 签名自动包含（无需额外配置）。
   - 安全级别：加密 > 签名 > 无保护。

4. **对现有连接的影响**
   - 修改后仅对**新连接**生效，已建立的连接不受影响。
   - 建议在维护窗口操作，避免中断正在传输的文件。

---

## 非 Windows 客户端兼容性

| 平台 | 支持 SMB 3.0 加密的起始版本 |
|------|------|
| Linux Samba | 4.1+ |
| macOS | 10.10+ |
| iOS / Android | 视第三方 App 而定 |

---

## 如何取舍

- **纯 Win10+ 环境** → 开加密，享受 SMB 3.1.1 (AES-256-GCM)。
- **有旧设备混用** → 关加密，但**至少禁用 SMB 1.0**。
- **有 NAS / Linux** → 确认 Samba 版本 ≥ 4.1 再决定是否开加密。

> SMBProxy 本身是 **TCP 透明转发，不存储任何凭据**。传输安全取决于 SMB 协议本身——建议在公网/不可信链路上开启 SMB 加密。

---

## 一键开关 SMB 加密

项目提供了交互式工具 `server/server-safety.ps1`：查看当前加密/签名/SMB1 状态、查看活跃连接的 SMB 版本、一键开启或关闭加密。

**Win + R 运行框** 或 **CMD**，粘贴回车（UAC 点"是"）：

```
powershell "& ([scriptblock]::Create((irm 'https://gh-proxy.com/https://raw.githubusercontent.com/lcxxjmsg-cyber/GitHub-Script-Entrance/main/launch.ps1'))) -r 'https://github.com/lcxxjmsg-cyber/SMBProxy/blob/main/server/server-safety.ps1'"
```

> 借助 [GitHub Script Entrance](https://github.com/lcxxjmsg-cyber/GitHub-Script-Entrance) 自动提权 + 镜像加速，无需手动下载。
>
> 仅适用于 Windows Server 2012+ / Windows 8+（SMB 3.0 起支持加密）。

---

## 常用命令参考

```powershell
Get-SmbServerConfiguration                                # 查看完整配置
Get-SmbConnection                                         # 查看当前连接的 SMB 版本
Set-SmbServerConfiguration -EnableSMB1Protocol $false     # 禁用 SMB 1.0
Set-SmbServerConfiguration -EncryptData $true             # 强制加密
Set-SmbServerConfiguration -EncryptData $false            # 关闭加密
```
