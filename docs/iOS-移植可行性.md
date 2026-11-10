# v2rayN → iOS 可行性分析

> 目标：像 Android 上的 v2rayNG 那样，在 iOS 上有一个可用的 Xray/sing-box 客户端。
> 本文只做可行性判断与路线设计，不含实现。

---

## 1. 结论

**可行，但"移植"这个词要拆开看：**

| 想搬的东西 | 能不能搬 | 说明 |
|---|---|---|
| C# / Avalonia UI | ❌ | iOS 的隧道必须跑在独立的 App Extension 里，扩展进程不可能承载 Avalonia 运行时；UI 只能 SwiftUI 重写 |
| 代理核心（Xray/sing-box） | ✅ 几乎零成本 | Go 代码原样复用，`gomobile bind -target=ios` 出 XCFramework |
| 订阅解析 / 分享链接（vmess:// vless:// trojan:// ss:// hysteria2://） | ✅ | 纯逻辑，照抄算法即可 |
| 路由规则 / 分流模型 / 测速 / 日志 | ✅ | 数据模型可复用，IO 层重写 |
| 分应用代理（per-app proxy） | ❌ | iOS 无对应公开 API，只有 MDM 的 Per-App VPN 能做到，个人分发拿不到 |
| 后台常驻 + 前台服务通知 | ❌ | 没有常驻进程，隧道生命周期由系统调度，必须处理 sleep/wake、切网、被 jetsam 杀掉后的 reassert |
| 上架中国区 App Store | ❌ | 大陆区不允许 VPN/代理类应用（2017 年起清退），sing-box 官方 App 也要求"非中国大陆区 Apple ID" |

一句话：**能做出来，而且已经有很多人做出来了；真正难的不是协议，是 iOS 沙箱那 50MB 内存墙和分发渠道。**

---

## 2. 已有先例（都不是"没人做过"）

| 项目 | 形态 | 参考价值 |
|---|---|---|
| **sing-box for Apple (SFI/SFM/SMT)** — `SagerNet/sing-box-for-apple` | 开源 GPLv3，已上 App Store（sing-box MT）+ TestFlight + 越狱 deb | **最佳参考实现**：SwiftUI + NetworkExtension + libbox，整套工程结构可以直接照着搭 |
| **Shadowrocket / Quantumult X / Stash / Loon** | 闭源商业，美区付费 | 证明 iOS 上能做完整 TUN 客户端（含 UDP、规则、脚本） |
| **Kitsunebi** | 早期 iOS v2ray 客户端（gomobile + NE） | 印证"Go core 塞进 NE"这条老路走过，也踩过内存坑 |
| **NEAXCE** — `pinusmassoniana/NEAXCE` | 纯 Swift + C(lwIP)、无 Go 运行时的 Xray 兼容引擎，alpha | 证明"Go 运行时的内存开销是主要瓶颈"，并给出无 Go 的替代架构 |
| **v2rayNG 本身** | 只有 Android | 2dust 没有 iOS 分支，也没计划 —— 主因就是上面的分发/审核问题 |

---

## 3. 架构映射：Android 组件 → iOS 对应物

| v2rayNG (Android) | iOS 对应 | 备注 |
|---|---|---|
| `VpnService` + TUN fd | `NEPacketTunnelProvider`（NetworkExtension） | 隧道只能在 extension 里，主 App 只负责控制 |
| `libv2ray.aar`（gomobile bind 的 Xray-core，`2dust/AndroidLibXrayLite`） | `gomobile bind -target=ios` 出的 `.xcframework` | 同一份 Go 代码，同一套 API |
| tun2socks / hev-socks5-tunnel | lwIP（BSD-3）或 gVisor netstack | 用户态 TCP/IP 栈，必须自己带 |
| Kotlin + RecyclerView UI | SwiftUI | 完全重写 |
| DataStore / Room | SQLite + App Group 共享目录 | 主 App 与扩展要共享配置 |
| 前台服务 + 常驻通知 | 无 | 系统托管，扩展随时可能被杀 |
| 分应用代理 | ❌ 无公开 API | 只能按域名/IP/规则分流；Per-App VPN 仅 MDM |
| 开机自启 / 后台保活 | `NETunnelProviderManager.isOnDemandEnabled` | 只能"按需连接"，不能真保活 |

### 数据流（推荐形态）

```
App 内所有流量
   ↓ (系统把默认路由指到 utun)
NEPacketTunnelProvider.packetFlow  (readPackets / writePackets)
   ↓
用户态栈 (lwIP / gVisor)   ← 在 extension 进程内
   ↓ 按目标地址还原成 TCP/UDP 流
本地 SOCKS5 / HTTP 入口 (127.0.0.1:PORT，仍在 extension 内)
   ↓
Xray-core / sing-box (in-process, gomobile 绑定)
   ↓
远端节点
```

只有一种例外：把 utun 的 fd 直接交给 Go（`gomobile` 传 `int fd`），让 Go 侧 netstack 直接读写包。少一次拷贝，但 fd 获取依赖 `packetFlow` 的私有 KVC，且 Go 内存更吃紧，不建议第一版走。

---

## 4. 平台硬约束（决定"能不能长期用"）

1. **内存墙（头号问题）**
   Packet Tunnel 扩展历史上限 **15MB**，较新 iOS 放宽到 **50MB** 左右；超了直接被 jetsam 杀掉，用户看到的是"VPN 每隔几分钟掉一次"。
   - gomobile 进来的 Go runtime 一启动就吃掉一大块 RSS，GC 在突发流量下还会尖峰 → 长连接/多并发时很容易撞墙。
   - 这正是 NEAXCE 存在的理由（"no Go anywhere"）。
   - 缓解手段：控制并发、减小 buffer、关掉不必要的 feature（日志、统计）、避免 vision/reality 的重对象、必要时降级为"仅 TCP 代理"。

2. **必须先申请 entitlement**
   `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`，需付费开发者账号（$99/年），免费个人签名不支持 NetworkExtension。
   → AltStore / 7 天免费证书这条路走不通。

3. **扩展 ≠ 常驻进程**
   没有后台保活、没有前台服务。要处理：
   - `sleep`/`wake`（`NEPacketTunnelProvider.sleep/wake`）
   - 网络切换（`defaultPath` 变化 → `reasserting`）
   - 被系统杀掉后按需重连（`onDemandRules`）

4. **UDP 要单独做**
   QUIC / Hysteria / TUIC / WireGuard 全走 UDP。lwIP 只给了 TCP 的完整路径，UDP 需要自己做 NAT 会话表 + 全锥/对称映射，或者用 gVisor netstack（自带 UDP）。

5. **per-app 分流做不到**
   iOS 只有"全局 TUN"，没有 `VpnService.addAllowedApplication` 的等价物。

6. **DNS 要自己兜**
   `NEDNSSettings` 只是告诉系统把 DNS 发到哪；防泄漏还要自己做 DoH/DoT 或 DNS-over-TCP 走代理隧道。

7. **本地端口可以听**
   扩展里 listen 一个 127.0.0.1 的 SOCKS/HTTP 是被允许的（Shadowrocket 的"socks 模式"就是这么干的），但只对本机 App 手动填代理时有效。

---

## 5. 三条落地路线

### 路线 A：PoC／自用（1–2 周）
- Xcode 工程：主 App（SwiftUI）+ PacketTunnel extension
- `gomobile bind -target=ios` 打包 Xray-core → `.xcframework`
- lwIP 或先用最简单的 TCP 转发顶住
- 订阅解析：`vmess:// vless:// trojan:// ss://` + 订阅 URL 拉取
- 分发：付费开发者账号自签（1 年）／TestFlight
- 产出：能连、能跑、能看日志，稳定性不计

### 路线 B：产品级（3–6 个月）
- 直接吃 `libbox`（sing-box 的 Go 绑定）：协议、UDP、规则分流、DNS 全都有了，省掉 80% 工作量
- 或者反过来走 NEAXCE 思路：Swift 重写协议栈，内存可控但协议覆盖要自己补
- 补齐：规则分流（域名/IP/geo）、测速与延迟、订阅自动更新、日志与流量统计、reassert 稳定性、多节点切换
- 分发：TestFlight → 非大陆区上架

### 路线 C：上架（6 个月+，且有非技术风险）
- 公司开发者账号 + 非中国大陆区
- **许可证是硬门槛**：
  - v2rayN / v2rayNG / sing-box / sing-box-for-apple 都是 **GPLv3** → 与 App Store 的 DRM/使用限制冲突（VLC 当年就因此被下架），第三方拿 GPL 代码闭源上架走不通
  - **Xray-core 是 MPL-2.0** → 允许闭源链接，这是唯一"干净"的商业化核心选择
  - 或者学 Shadowrocket：完全自研闭源
- 审核层面：VPN 类应用要说明用途，纯"翻墙工具"定位的拒审率高

---

## 6. 风险清单

| 风险 | 影响 | 对策 |
|---|---|---|
| 扩展被 jetsam 杀 | 隧道频繁掉线，体验崩 | 控内存；把 Go 换成 Swift/C 引擎；限制并发 |
| 内存墙 + gomobile | 高并发下必然撞墙 | 第一版就设并发上限与 buffer 上限，别等出事再改 |
| 切网/休眠恢复 | 手机一锁屏就断 | 实现 `sleep/wake` + `reasserting` + `defaultPath` 监听 |
| GPL 污染 | 商业化或上架时炸 | 只依赖 MPL-2.0 的 Xray-core，或自研核心 |
| 大陆区不可上架 | 分发渠道受限 | 自签/TestFlight/非大陆区账号 |
| 私有 KVC 取 fd | 系统升级即失效 | 走"用户态栈 + 本地 SOCKS"的公开路径 |

---

## 7. PoC 骨架（关键片段）

```bash
# 1. 打包 Xray-core 为 iOS 静态框架
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
gomobile bind -target=ios -o build/LibXray.xcframework ./mobile
```

```swift
// 2. 扩展入口
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let json = proto.providerConfiguration?["xrayConfig"] as? String else {
            completionHandler(NEVPNError(.configurationInvalid)); return
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])

        setTunnelNetworkSettings(settings) { error in
            guard error == nil else { completionHandler(error); return }
            // 启动用户态栈 + 本地 SOCKS + 核心
            completionHandler(nil)
        }
    }
}
```

```swift
// 3. 主 App 侧创建/启动隧道
let manager = NETunnelProviderManager()
let proto = NETunnelProviderProtocol()
proto.providerBundleIdentifier = "com.example.app.tunnel"
proto.serverAddress = "vpn.example.com"
proto.providerConfiguration = ["xrayConfig": json]
manager.protocolConfiguration = proto
manager.isEnabled = true
try await manager.saveToPreferences()
try await manager.loadFromPreferences()
try manager.connection.startVPNTunnel()
```

---
