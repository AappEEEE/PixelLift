# M6 动态模糊 · 集成说明

本文档给出把 `research/m6/MotionBlurCore.swift` 接进 PixelLift 的**逐字对照补丁**。
全部改动都只涉及三个文件：新增 `App/MotionBlurCore.swift`，改 `App/VideoEngine.swift`、
`App/VideoView.swift`。缩进统一 4 空格，old snippet 是仓库当前内容（含原有的空格瑕疵，
照抄即可精确命中）。

行号是写入本文档时的快照（`App/VideoEngine.swift` 共 1667 行），snippet 内容才是匹配依据。

---

## 0. 新增文件

把 `research/m6/MotionBlurCore.swift` 复制成 `App/MotionBlurCore.swift`。

`project.yml` 的 sources 已经包含 `App` 目录，XcodeGen 会自动捡到，不需要改工程文件。

它对外只暴露四样东西：

| 符号 | 用途 |
| --- | --- |
| `enum ShutterAngle` | 快门角 90/180/270/360，UI Picker 直接用 |
| `enum BlurQuality` | 采样预算 4/10/20，UI Picker 直接用 |
| `MotionBlurCore.makePlan(...)` | 由角度 + perPair + 预算算出固定参数 |
| `MotionBlurCore.compose(...)` | 在曝光窗内做线性光时间积分 |

依赖同 target 已有的 `FlowField` 与 `FrameOps.synthesize`，没有任何新框架、没有新增 import
（只要 `Foundation`）。

---

## 1. `App/VideoEngine.swift`

### 1.1 `enum BlurMode`（约 L93-113）：三档 → 开关

**old**

```swift
enum BlurMode: String, CaseIterable, Identifiable {
    case off
    case soft
    case strong

    var id: String { rawValue }
    var samples: Int {
        switch self {
        case .off: return 1
        case .soft: return 3
        case .strong: return 5
        }
    }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .soft: return "轻"
        case .strong: return "强"
        }
    }
}
```

**new**

```swift
enum BlurMode: String, CaseIterable, Identifiable {
    case off
    case on

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .on: return "开启"
        }
    }
}
```

> 为什么删掉 `samples`：样本数不再是一个用户看得到的档位，而是由快门角（决定窗宽）
> 与光流幅值（决定每块要几次采样）共同算出来的。UI 上"轻/强"这种说法对真实快门没有意义 ——
> 真实相机只有快门角这一个旋钮。

### 1.2 `struct VideoSettings`（约 L115-129）：换字段

**old**

```swift
struct VideoSettings: Sendable {
    var targetWidth: Int
    var targetHeight: Int
    var useAI: Bool
    var aiLongEdge: Int
    var duration: Double
    var outFps: Double
    var samplesPerPair: Int
    var blurSamples: Int
    var keepAudio: Bool
    var expectedFrames: Int
    var hdrEnabled: Bool
    var hdrIntensity: Double
    var detail: Double
}
```

**new**

```swift
struct VideoSettings: Sendable {
    var targetWidth: Int
    var targetHeight: Int
    var useAI: Bool
    var aiLongEdge: Int
    var duration: Double
    var outFps: Double
    var samplesPerPair: Int
    /// 快门角，0 表示关闭动态模糊。单位：度。
    var shutterAngle: Double
    /// 平均每像素采样数上限（成本闸门）。
    var blurSampleBudget: Int
    /// 是否在线性光域累积。关掉只是省几个百分点，画质会掉，留作降级开关。
    var blurLinearLight: Bool
    var keepAudio: Bool
    var expectedFrames: Int
    var hdrEnabled: Bool
    var hdrIntensity: Double
    var detail: Double
}
```

### 1.3 `VideoEngine` 的发布属性（约 L1100-1110）

**old**

```swift
    @Published var blur: BlurMode = .off
```

**new**

```swift
    @Published var blur: BlurMode = .off
    @Published var shutterAngle: ShutterAngle = .deg180
    @Published var blurQuality: BlurQuality = .standard
```

> 如果 `@Published var blur` 附近还有别的 `@Published`，把这两行插在 `blur` 后面即可，
> old snippet 只需要命中那一行。

### 1.4 `VideoRenderer.render` 的局部变量（约 L753-754）

**old**

```swift
        let perPair = max(1, settings.samplesPerPair)
        let blurSamples = max(1, settings.blurSamples)
```

**new**

```swift
        let perPair = max(1, settings.samplesPerPair)
        // M6：模糊参数在一对帧内是常量，先算好，逐帧只做相位积分。
        // 窗宽 W = (快门角/360)/perPair，锚定在帧起点，所以 t+W 恒 <= 1。
        let blurPlan: MotionBlurCore.Plan = MotionBlurCore.makePlan(
            angleDegrees: settings.shutterAngle,
            perPair: perPair,
            sampleBudget: settings.blurSampleBudget,
            linearLight: settings.blurLinearLight,
            adaptive: true)
        let blurOn: Bool = blurPlan.enabled
```

### 1.5 新增线性光累积缓冲（约 L764-766）

**old**

```swift
        var scratch = [UInt8](repeating: 0, count: tw * th * 4)
        var accum = [UInt8](repeating: 0, count: tw * th * 4)
        var stable = [UInt8](repeating: 0, count: tw * th * 4)
```

**new**

```swift
        var scratch = [UInt8](repeating: 0, count: tw * th * 4)
        var accum = [UInt8](repeating: 0, count: tw * th * 4)
        var stable = [UInt8](repeating: 0, count: tw * th * 4)
        // 线性光累积缓冲：tw*th*3 个 Float，1.4MP 输出约 16.8MB。
        // 首次 compose 时按需扩容，之后一直复用。
        var blurLight: [Float] = []
```

### 1.6 删掉旧的三角权重方案（约 L802-817），并把 `emit` 换掉（约 L819-840）

**old**（这一整段，连同上面的两行注释一起删）

```swift
        // 快门采样：三角权重（中间重、两端轻）比等权平均更像真实快门的连续曝光，
        // 运动物体的拖影过渡更平滑，也不会出现等权平均那种「台阶」。
        let blurPlan: (offsets: [Float], weights: [Float]) = {
            var offsets: [Float] = []
            var weights: [Float] = []
            let spread = 0.40 / Float(max(2, perPair))
            let half = max(1.0, (Float(blurSamples) - 1) * 0.5)
            for j in 0..<blurSamples {
                let x = Float(j) - (Float(blurSamples) - 1) * 0.5
                offsets.append(x * spread)
                weights.append(max(0.08, 1 - abs(x) / (half + 0.5)))
            }
            return (offsets, weights)
        }()
        let blurOffsets = blurPlan.offsets
        let blurWeights = blurPlan.weights

        func emit(_ a: [UInt8], _ b: [UInt8], t: Float,
                  flow: FlowField?, flowScale: Float) throws {
            if blurSamples <= 1 {
                FrameOps.synthesize(a: a, b: b, w: tw, h: th,
                                    flow: flow, flowScale: flowScale, t: t, out: &scratch)
                try writeFrame(scratch)
                return
            }
            var cumulative: Float = 0
            for j in 0..<blurSamples {
                let tj = min(1, max(0, t + blurOffsets[j]))
                FrameOps.synthesize(a: a, b: b, w: tw, h: th,
                                    flow: flow, flowScale: flowScale, t: tj, out: &scratch)
                cumulative += blurWeights[j]
                if j == 0 {
                    accum = scratch
                } else {
                    FrameOps.average(into: &accum, from: scratch, weight: blurWeights[j] / cumulative)
                }
            }
            try writeFrame(accum)
        }
```

**new**

```swift
        // M6 动态模糊：在曝光窗 [t, t+W] 内做加权时间积分，而不是把几帧糊在一起。
        // W = (快门角/360)/perPair，窗口锚定帧起点 => t+W <= 1 恒成立：
        // 不需要第三帧、不需要第二条光流、所有输出帧积分区间等长（无清晰/模糊闪烁）。
        func emit(_ a: [UInt8], _ b: [UInt8], t: Float,
                  flow: FlowField?, flowScale: Float) throws {
            if !blurOn {
                FrameOps.synthesize(a: a, b: b, w: tw, h: th,
                                    flow: flow, flowScale: flowScale, t: t, out: &scratch)
                try writeFrame(scratch)
                return
            }
            MotionBlurCore.compose(a: a, b: b, width: tw, height: th, t: t,
                                   flow: flow, flowScale: flowScale,
                                   plan: blurPlan,
                                   scratchLinear: &blurLight,
                                   out: &accum)
            try writeFrame(accum)
        }
```

### 1.7 光流触发条件（约 L879）

**old**

```swift
                let needsInterp = perPair > 1 || blurSamples > 1
```

**new**

```swift
                let needsInterp = perPair > 1 || blurOn
```

### 1.8 首帧报一次成本（约 L884 之后，紧接 `let flowScale`）

**old**

```swift
                let flowScale: Float = flow.map { Float(tw) / Float($0.w) } ?? 1
```

**new**

```swift
                let flowScale: Float = flow.map { Float(tw) / Float($0.w) } ?? 1

                // 只在第一对帧报一次，让用户/日志看得到实际采样密度。
                if blurOn, outIndex == 0, let flow {
                    let avg: Float = MotionBlurCore.estimateAverageSamples(
                        flow: flow, flowScale: flowScale,
                        width: tw, height: th, plan: blurPlan)
                    let avgText: String = String(format: "%.2f", Double(avg))
                    let degText: String = "\(Int(settings.shutterAngle))"
                    onNotice("动态模糊 " + degText + "° · 平均 " + avgText + " 次采样/像素")
                }
```

> 这里刻意用 `%.2f` + `Double` 而不用 `%d`：`%d` 配 Swift 的 `Int` 在 64 位下是未定义行为
> （`Int` 按 64 位传参、`%d` 只读 32 位），小数字"碰巧正确"不代表安全。度数直接用
> 字符串插值拼。

### 1.9 `plan(for:)` 的分辨率上限（约 L1246、L1250-1259）

**old**

```swift
        let blurSamples = blur.samples
```

**new**

```swift
        let blurOn = blur == .on
        let blurBudget = blurQuality.budget
```

**old**

```swift
        if perPair > 1 || blurSamples > 1 {
            capEdge = min(capEdge, 1920)
            capPix = min(capPix, 2_100_000)
            notes.append("补帧/慢动作把输出限制在 1080p 级，否则一帧要几百毫秒")
        }
        if blurSamples > 1 {
            capEdge = min(capEdge, 1440)
            capPix = min(capPix, 1_400_000)
            notes.append("动态模糊是 \(blurSamples) 次合成，输出再降一档")
        }
```

**new**

```swift
        if perPair > 1 || blurOn {
            capEdge = min(capEdge, 1920)
            capPix = min(capPix, 2_100_000)
            notes.append("补帧/慢动作把输出限制在 1080p 级，否则一帧要几百毫秒")
        }
        if blurOn {
            capEdge = min(capEdge, 1440)
            capPix = min(capPix, 1_400_000)
            let deg = Int(shutterAngle.degrees)
            notes.append("动态模糊 \(deg)° 快门、预算 \(blurBudget) 样本/像素，输出再降一档")
        }
```

> 上限保持不变：1440 长边 / 1.4MP。线性光累积缓冲按 1.4MP 算是 16.8MB，
> 加上 4 个 RGBA 缓冲（每张 5.6MB），峰值约 45MB，离 100MB 红线还有一倍余量。
> 如果以后想开 4K 模糊，缓冲会涨到 ~99MB，必须改成条带（tile）处理，这里不做。

### 1.10 两处 `VideoSettings(...)` 构造

`run(resuming:)`（约 L1349-1355）

**old**

```swift
                                     samplesPerPair: p.samplesPerPair,
                                     blurSamples: blur.samples,
                                     keepAudio: p.keepAudio,
                                     expectedFrames: p.frames,
                                      hdrEnabled: hdrEnabled,
                                      hdrIntensity: hdrIntensity,
                                      detail: detail)
```

**new**

```swift
                                     samplesPerPair: p.samplesPerPair,
                                     shutterAngle: blur == .on ? shutterAngle.degrees : 0,
                                     blurSampleBudget: blurQuality.budget,
                                     blurLinearLight: true,
                                     keepAudio: p.keepAudio,
                                     expectedFrames: p.frames,
                                      hdrEnabled: hdrEnabled,
                                      hdrIntensity: hdrIntensity,
                                      detail: detail)
```

> 注意 old snippet 里 `hdrEnabled` / `hdrIntensity` / `detail` 三行比上面多一个空格，
> 那是仓库现状，照抄才能精确命中。

`settings(for:)`（约 L1591-1597）

**old**

```swift
                             samplesPerPair: p.samplesPerPair,
                             blurSamples: blur.samples,
                             keepAudio: p.keepAudio,
                             expectedFrames: p.frames,
                             hdrEnabled: hdrEnabled,
                             hdrIntensity: hdrIntensity,
                             detail: detail)
```

**new**

```swift
                             samplesPerPair: p.samplesPerPair,
                             shutterAngle: blur == .on ? shutterAngle.degrees : 0,
                             blurSampleBudget: blurQuality.budget,
                             blurLinearLight: true,
                             keepAudio: p.keepAudio,
                             expectedFrames: p.frames,
                             hdrEnabled: hdrEnabled,
                             hdrIntensity: hdrIntensity,
                             detail: detail)
```

### 1.11 `startStatus()`（约 L1500）

**old**

```swift
        if blur != .off { parts.append("动态模糊 \(blur.title)") }
```

**new**

```swift
        if blur == .on { parts.append("动态模糊 \(shutterAngle.title)") }
```

### 1.12 `JobStore.key`（约 L1632）

**old**

```swift
            "p\(settings.samplesPerPair)b\(settings.blurSamples)",
```

**new**

```swift
            "p\(settings.samplesPerPair)a\(Int(settings.shutterAngle))m\(settings.blurSampleBudget)l\(settings.blurLinearLight ? "1" : "0")",
```

> 必须改：不同快门角/预算的输出是不一样的，键里不带这些字段会让断点续渲命中错误的分片。
> 改了之后旧的临时分片全部失效（缓存 miss），第一次重跑会从头渲染，这是预期行为。

---

## 2. `App/VideoView.swift`

`motionCard`（约 L241-250）整段替换。

**old**

```swift
            VStack(alignment: .leading, spacing: 6) {
                Text("动态模糊").font(.subheadline)
                Picker("动态模糊", selection: $engine.blur) {
                    ForEach(BlurMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(engine.isRunning)
            }
```

**new**

```swift
            VStack(alignment: .leading, spacing: 6) {
                Text("动态模糊").font(.subheadline)
                Picker("动态模糊", selection: $engine.blur) {
                    ForEach(BlurMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(engine.isRunning)
            }

            if engine.blur == .on {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快门角").font(.subheadline)
                    Picker("快门角", selection: $engine.shutterAngle) {
                        ForEach(ShutterAngle.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(engine.isRunning)

                    Text("180° 是电影标准；360° 等于整帧曝光，拖影最长。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("采样预算", selection: $engine.blurQuality) {
                        ForEach(BlurQuality.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(engine.isRunning)

                    Text("预算 = 平均每像素采样数上限，越高拖影越平滑，耗时近似线性增长。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
```

卡片本身已经有 `.padding(16)` + `.background(...)`，新增的 `VStack` 直接落在卡片里，
不需要再套容器。

---

## 3. `VideoSettings` 字段变更总表

| 字段 | 变更 | 说明 |
| --- | --- | --- |
| `blurSamples: Int` | **删除** | 样本数不再是用户档位，由快门角与光流共同决定 |
| `shutterAngle: Double` | 新增 | 快门角（度），0 = 关闭 |
| `blurSampleBudget: Int` | 新增 | 平均每像素样本数上限（4/10/20） |
| `blurLinearLight: Bool` | 新增 | 线性光累积开关，降级用 |

`VideoSettings` 是 `Sendable` 的结构体，新增三个值类型字段不破坏 Sendable。

---

## 4. 性能预估（1080p 级，A17）

先把成本归一化：设 **T_s = 单次全帧 `FrameOps.synthesize` 的耗时**。
在 A17 单核、`-O`、`UnsafeBufferPointer` 路径下，1080p（约 207 万像素、每像素 6 次
双线性取样）预期 **T_s ≈ 40–70 ms**（仓库现有的 notes 说"补帧一帧要几百毫秒"，
和 perPair=3~4 次合成吻合）。

模糊的额外成本就是 `avgM × T_s`（`avgM` = 平均每像素样本数，由
`MotionBlurCore.estimateAverageSamples` 在首帧报出来）：

| 场景 | avgM | 每输出帧耗时 | 说明 |
| --- | --- | --- | --- |
| 静止画面（三脚架） | 1.00 | ≈ T_s，**0 额外开销** | 全帧 `maxUsed<=1` 走单次合成快路径 |
| θ=180°, perPair=1, 普通手持 | 1.6–2.2 | 64–154 ms | 拖影 ≈ 8 像素 |
| θ=180°, perPair=2（60fps） | 1.3–1.6 | 52–112 ms | 窗宽减半，采样数同步下降 |
| θ=360°, 快速摇镜 | 被压到 10 | 400–700 ms | 成本闸门生效，拖影会有 M 级台阶 |
| 线性光 LUT | — | +5–8% | 两次查表/像素/通道 |

另外每次 `compose` 会重算一次 `BlockPlan`（1.4MP 约 600k 次探测，**2–3 ms**）。
`perPair > 1` 时同一对帧内光流不变，这份表被重复算了 perPair 次 —— 最多 6 ms，
占单帧成本的 2–4%，在预估误差内，所以第一版没有为它加缓存（加缓存需要在
`MotionBlurCore` 里多一个接收 `BlockPlan` 的重载，多一处集成面）。
真机实测若发现 60fps 路径偏慢，把 `perPair` 那层的 `emit` 循环提到
"先算一次 `blockPlan` 再逐帧 `compose`" 即可，接口已经留好。

再加上原本就要付的光流成本（`VNGenerateOpticalFlowRequest`，1080p 输入 ≤960 长边，
**12–18 ms**）。注意：只开模糊不开补帧时，光流从"不需要"变成"需要"，这 12–18ms 是新增的。

上表的 T_s 用的是 **1080p**（2.07MP）口径，而实际输出会被 `plan(for:)` 压到 1.4MP
（1080p 的 68%，T_s 约 27–48 ms），所以表里的绝对数字是**上界**，真机大概率更快。
这也意味着 `plan(for:)` 里那两条 cap 不要放宽 —— 一放宽，成本就按 1/0.68 ≈ 1.47 倍线性上涨。

内存：`blurLight` = 1.4MP × 3 × 4B = **16.8 MB**；加上 `scratch`/`accum`/`stable`/`prevBuf`
各 5.6MB 与源帧，峰值约 **45 MB**，低于 100MB 目标。

---

## 5. 风险清单与降级开关

| # | 风险 | 触发条件 | 表现 | 降级 |
| --- | --- | --- | --- | --- |
| 1 | 光流不准（遮挡边界、快速横移、镜头光晕） | 主体大幅运动 | 拖影里出现"重影"而不是连续拖影 | 快门角降到 90–180°；这是所有光流合成方案的共同上限，`FrameOps.flow` 本身分辨率只有 960 长边 |
| 2 | 成本闸门压采样 | θ=360° + 全屏快摇 | 拖影出现 M 级台阶（48px 位移 / m=10 → 4.8px 一级） | 预算调到 `.fine`；或接受更快但更"碎"的拖影 |
| 3 | 分块边界 | 只在 gate 生效后才可能 | 32px 方块状纹理 | 正常情况下 m 由位移推出、积分分辨率恒为 1px，块边界看不出来；gate 生效时把预算调高 |
| 4 | 首帧分配 16.8MB | 第一次进 compose | 第一帧多掉 10–20ms | 可在 `render` 开头预热：`blurLight = [Float](repeating: 0, count: tw*th*3)` |
| 5 | 暗部噪点被拖影平均 | 高 ISO 夜景 | 拖影区域噪点减少（通常是好事），但静止区域完全不变 | 无需处理 |
| 6 | 内存峰值 | 若有人手改 cap 到 4K | 4K 的 `blurLight` = 99MB，接近 OOM | **不要**提高 1.4MP 上限；真要 4K 必须改成条带处理（本设计未做） |
| 7 | 断点缓存失效 | 升级后第一次渲染 | 全部重新渲染 | 预期行为，不是 bug |
| 8 | `BlurMode` 枚举值变了 | 用户升级 App | 旧的 `@AppStorage` 里若有 "soft"/"strong" 会反序列化失败落回默认 `.off` | 本项目 `blur` 没有持久化，无影响 |
| 9 | 卡片高度跳变 | 打开模糊开关时 | SwiftUI 卡片瞬间变高 | 需要的话在 `motionCard` 外层加 `.animation(.default, value: engine.blur)`，或保持现有无动画 |

### 总开关（出问题时的第一反应）

1. UI 上把「动态模糊」切回**关闭** —— 渲染路径立刻退回单次 `synthesize`，与升级前完全一致。
2. 若怀疑是线性光 LUT：把 1.10 两处的 `blurLinearLight: true` 改成 `false`。
3. 若怀疑内存：把 `plan(for:)` 里模糊分支的 cap 从 `1_400_000` 再降到 `1_000_000`。
4. 彻底回退：删掉 `App/MotionBlurCore.swift`，按本文档反向替换 1.1–1.12。

---

## 6. 应用状态检查（2026-11-11 01:18 实测，供合并时核对）

写完本文档后仓库里已经有人开始合并了，我核对了一遍**当前工作区**（未提交状态）：

已应用且与本文档一致：

- §1.1 `BlurMode` → `.off/.on`（`App/VideoEngine.swift` L93-104），`samples` 已删。
- §1.2 `VideoSettings`：`blurSamples` 已换成 `shutterAngle`(L115) / `blurSampleBudget`(L117) / `blurLinearLight`(L119)。
- §1.3 `@Published shutterAngle` L1104、`@Published blurQuality` L1105。
- §1.4 `blurPlan` + `blurOn` L752-758。
- §1.5 `var blurLight: [Float] = []` L773 + `var reportedBlurCost = false` L774。
- §1.6 `emit` 已改为 `MotionBlurCore.compose(...)`（L809-826），三角权重整段删除。
- §1.7 `let needsInterp = perPair > 1 || blurOn` L865。
- `App/MotionBlurCore.swift` 已放置，SHA256 与 `research/m6/MotionBlurCore.swift`
  完全一致（`CE7A2E53B99036F187E19683D51E2E96DED621C86C836BE77D5950FFB9717FFB`）。

**尚未应用**（因此 `App/` 目前编译不过，共 5 处错误）：

| 位置（当前行号） | 现状 | 症状 | 照本文档 |
| --- | --- | --- | --- |
| L1244 | `let blurSamples = blur.samples` | `BlurMode` 已无 `.samples` | §1.9 |
| L1248 / L1253 / L1256 | 用 `blurSamples > 1` 判分支 | 同上，未定义 | §1.9 |
| L1348 | `blurSamples: blur.samples,` | 参数名不存在，且缺三个新参数 | §1.10 第一处 |
| L1590 | `blurSamples: blur.samples,` | 同上 | §1.10 第二处 |
| L1630 | `"p\(settings.samplesPerPair)b\(settings.blurSamples)"` | `VideoSettings` 已无该成员 | §1.12 |

另外两处非阻塞问题：

1. L877-878 现在是 `String(format: "动态模糊 %d° · 平均 %.2f 次采样/像素", Int(settings.shutterAngle), Double(avg))`。
   `%d` 配 Swift `Int` 在 64 位是未定义行为，请按 §1.8 的写法换成字符串插值拼度数。
2. `App/VideoView.swift` 的 `motionCard`（L241-250）还是旧的三行，**§2 的「快门角 + 采样预算」两个
   Picker 还没加**；现在 `BlurMode.allCases` 只剩 `off/on` 两项，界面能跑但用户没法改快门角。
3. `startStatus()` 里 `parts.append("动态模糊 \(blur.title)")` 现在会显示"动态模糊 开启"，
   建议按 §1.11 改成带角度的写法。

修完上表 5 处 + §2，就可以 push 让 GitHub Actions 编了。

