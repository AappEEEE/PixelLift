# PixelLift · M7 画质打磨集成说明

本文给出把 `research/m7/QualityCore.swift` 接进现有工程的**逐字对照补丁**。
所有 old snippet 均从当前仓库原文摘录（行号见每节标题），new snippet 可直接整体替换。
所有代码 4 空格缩进，与现有文件风格一致。

---

## 0. 三分钟上手

1. 把 `research/m7/QualityCore.swift` 拖进 `App/` 目录，Xcode 里勾上 **PixelLift** target 的
   Target Membership（不要勾 Widget/Share Extension，若存在）。
2. 按下面 **E1 → E11** 顺序改。每一处都是独立的 old/new 替换，中途可以编译（新增字段会先报
   "missing argument"，补齐 E3 即可）。
3. 跑一次 GitHub Actions 的 build job；再按第 6 节验收。

> 不改任何已有文件的前提下，`QualityCore.swift` 单独也能编译（只依赖 Foundation + Accelerate，
> 以及同 target 里的 `FlowField`）。所以第一次 CI 可以先只加这个文件，确认它能过编译，再动业务代码。

---

## 1. 改动总览

| # | 文件 | 位置 | 类型 | 说明 |
|---|------|------|------|------|
| E1 | `App/VideoEngine.swift` | `struct VideoSettings` @106-125 | 加 2 个字段 | `denoise` / `antiFlicker` |
| E2 | `App/VideoEngine.swift` | `@Published` 区 @1102-1115 | 加 2 个属性 | 供 UI 绑定，默认值讨论见 E2 |
| E3 | `App/VideoEngine.swift` | @1343、@1587 | 两处构造点 | 必须同时改，否则编译不过 |
| E4 | `App/VideoEngine.swift` | `JobStore.key` @1630-1644 | 追加一段 descriptor | 否则改参数后断点续传会串帧 |
| E5 | `App/VideoEngine.swift` | `makeFrame` 尾部 @1085-1089 | 换掉 USM 调用 | 细节 + 降噪 + 抖动 |
| E6 | `App/VideoEngine.swift` | `render` 局部变量 @768-776 | 改 2 处声明 | 双缓冲 + `qualityTemporal` |
| E7 | `App/VideoEngine.swift` | `render` 主循环 @866、@883-889、@899 | 3 处小改 | 自适应时域融合 |
| E8 | `App/VideoEngine.swift` | `startStatus()` @1503 | 加 2 行 | 状态条显示新参数 |
| E9 | `App/VideoView.swift` | `detailCard` @324-344 | 加 1 个滑杆 + 1 个开关 | 视频侧 UI |
| E10 | `App/UpscaleEngine.swift` | `processItem` 尾部 @525 | 替换 1 行 | 图片侧接入同一套细节/抖动 |
| E11 | `App/ContentView.swift` | `scaleCard` @303-305 后 | 加 1 个滑杆 | 图片侧 UI |
| — | `App/VideoEngine.swift:546` | `FrameOps.unsharp` | **不删** | 留作降级开关（见第 5 节） |

---

## 2. 逐字补丁

### E1 · VideoSettings 加两个字段

`App/VideoEngine.swift:122-125`

**旧**

```swift
    var hdrEnabled: Bool
    var hdrIntensity: Double
    var detail: Double
}
```

**新**

```swift
    var hdrEnabled: Bool
    var hdrIntensity: Double
    var detail: Double
    /// 边缘自适应降噪 0…1。0 = 只锐化（等价 M6 行为），0.3 ≈ 平坦区残差压到 65%。
    var denoise: Double
    /// 抗闪烁：多帧稳定融合。关掉就不算第二条光流，也不做融合（省 ~5–25 ms/帧）。
    var antiFlicker: Bool
}
```

> 字段一定追加在末尾：`VideoSettings` 是 `struct` + 逐成员初始化，插在中间会改变两处调用点的
> 参数顺序，容易漏改。

### E2 · 引擎新增两个 @Published

`App/VideoEngine.swift:1106-1108`

**旧**

```swift
    @Published var hdrEnabled = false
    @Published var hdrIntensity: Double = 0.65
    @Published var detail: Double = 0.25
```

**新**

```swift
    @Published var hdrEnabled = false
    @Published var hdrIntensity: Double = 0.65
    @Published var detail: Double = 0.25
    /// M7：默认 0.30。干净片源 0.15–0.30；手机夜景/高 ISO 0.45–0.70；老压缩片源 0.60–0.80。
    /// 它同时是「锐化门控」：平坦区不锐化，所以调高它不会糊掉真实纹理（T4 已验证）。
    @Published var denoise: Double = 0.30
    /// M7：默认开。静止区融合 0.80、运动区 0.06，切镜处自动断开（T11 已验证）。
    @Published var antiFlicker = true
```

> 为什么默认 `detail` 保持 0.25 不提高：新实现是**零 halo** 的，0.25 的实际观感已经明显强于
> 旧版 0.25（T3：边缘 3.38 px vs 旧 DC 归一 3.45 px，且旧版还压暗 4.6%）。想更锐再往上推，
> 0.5 仍在安全区（T2 钳制后越界恒为 0）。UI 文案建议同步改成"新算法无白边，可放心加到 50%"。

### E3 · 两处构造点补参数

**旧**（`App/VideoEngine.swift:1343-1357`，`run(resuming:)` 内；注意 `hdrEnabled` 那三行本来就比
上面多一个空格，这是现状，不必顺手改）

```swift
        let settings = VideoSettings(targetWidth: p.width,
                                     targetHeight: p.height,
                                     useAI: mode == .ai,
                                     aiLongEdge: p.aiLongEdge,
                                     duration: clip.duration,
                                     outFps: p.outFps,
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

**新**

```swift
        let settings = VideoSettings(targetWidth: p.width,
                                     targetHeight: p.height,
                                     useAI: mode == .ai,
                                     aiLongEdge: p.aiLongEdge,
                                     duration: clip.duration,
                                     outFps: p.outFps,
                                     samplesPerPair: p.samplesPerPair,
                                     shutterAngle: blur == .on ? shutterAngle.degrees : 0,
                                     blurSampleBudget: blurQuality.budget,
                                     blurLinearLight: true,
                                     keepAudio: p.keepAudio,
                                     expectedFrames: p.frames,
                                      hdrEnabled: hdrEnabled,
                                      hdrIntensity: hdrIntensity,
                                      detail: detail,
                                      denoise: denoise,
                                      antiFlicker: antiFlicker)
```

**旧**（`App/VideoEngine.swift:1587-1601`，`settings(for:)` 内）

```swift
        return VideoSettings(targetWidth: p.width,
                             targetHeight: p.height,
                             useAI: mode == .ai,
                             aiLongEdge: p.aiLongEdge,
                             duration: clip.duration,
                             outFps: p.outFps,
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

**新**

```swift
        return VideoSettings(targetWidth: p.width,
                             targetHeight: p.height,
                             useAI: mode == .ai,
                             aiLongEdge: p.aiLongEdge,
                             duration: clip.duration,
                             outFps: p.outFps,
                             samplesPerPair: p.samplesPerPair,
                             shutterAngle: blur == .on ? shutterAngle.degrees : 0,
                             blurSampleBudget: blurQuality.budget,
                             blurLinearLight: true,
                             keepAudio: p.keepAudio,
                             expectedFrames: p.frames,
                             hdrEnabled: hdrEnabled,
                             hdrIntensity: hdrIntensity,
                             detail: detail,
                             denoise: denoise,
                             antiFlicker: antiFlicker)
```

### E4 · 断点续传 key 追加画质段

`App/VideoEngine.swift:1630-1644`

**旧**

```swift
        let descriptor = [
            source.path,
            "\(settings.targetWidth)x\(settings.targetHeight)",
            String(format: "%.3f", settings.outFps),
            settings.useAI ? "ai\(settings.aiLongEdge)" : "fast",
            "p\(settings.samplesPerPair)a\(Int(settings.shutterAngle))m\(settings.blurSampleBudget)l\(settings.blurLinearLight ? "1" : "0")",
            settings.hdrEnabled ? "hdr" : "sdr"
        ].joined(separator: "|")
```

**新**

```swift
        let descriptor = [
            source.path,
            "\(settings.targetWidth)x\(settings.targetHeight)",
            String(format: "%.3f", settings.outFps),
            settings.useAI ? "ai\(settings.aiLongEdge)" : "fast",
            "p\(settings.samplesPerPair)a\(Int(settings.shutterAngle))m\(settings.blurSampleBudget)l\(settings.blurLinearLight ? "1" : "0")",
            settings.hdrEnabled ? "hdr" : "sdr",
            "q\(Int(settings.detail * 100))d\(Int(settings.denoise * 100))f\(settings.antiFlicker ? "1" : "0")"
        ].joined(separator: "|")
```

> **代价**：所有历史 key 都会变，未完成的分片任务无法续传、只能重跑。这是**正确**的行为——
> 原来的 descriptor 里连 `detail` 都没有，改了锐度还会接着用旧参数的中间结果，属于既有 bug。

### E5 · makeFrame 尾部：换掉 USM

`App/VideoEngine.swift:1085-1089`

**旧**

```swift
        guard var out = Pix.rgba(finalCG, width: tw, height: th) else { return nil }
        if settings.detail > 0.001 {
            FrameOps.unsharp(&out, w: tw, h: th, amount: Float(settings.detail))
        }
        return out
```

**新**

```swift
        guard var out = Pix.rgba(finalCG, width: tw, height: th) else { return nil }
        // M7：亮度域保边锐化 + 边缘自适应降噪 + 8-bit 抖动。
        // HDR 路径后面还要转 P010 并做 10-bit 抖动，这里必须关掉，避免两次抖动叠加。
        let wantsDetail: Bool = settings.detail > 0.001 || settings.denoise > 0.001
        if wantsDetail {
            QualityCore.applyDetail(&out,
                                    width: tw,
                                    height: th,
                                    amount: Float(settings.detail),
                                    denoise: Float(settings.denoise),
                                    dither: !settings.hdrEnabled)
        }
        return out
```

### E6 · render 局部变量：双缓冲 + qualityTemporal

**旧**（`App/VideoEngine.swift:768-771`）

```swift
        var scratch = [UInt8](repeating: 0, count: tw * th * 4)
        var accum = [UInt8](repeating: 0, count: tw * th * 4)
        var stable = [UInt8](repeating: 0, count: tw * th * 4)
        var prevStable: [UInt8]?
```

**新**

```swift
        var scratch = [UInt8](repeating: 0, count: tw * th * 4)
        var accum = [UInt8](repeating: 0, count: tw * th * 4)
        // M7：时域融合改成两块独立缓冲乒乓。惰性分配——不开时域就一分钱内存都不占。
        var stableA: [UInt8] = []
        var stableB: [UInt8] = []
        var prevStable: [UInt8]?
```

**旧**（`App/VideoEngine.swift:775-776`）

```swift
        // AI 逐帧超分天然会抖：只在这种模式下做时域融合，快速放大已经足够稳定。
        let temporalWeight: Float = settings.useAI ? 0.22 : 0
```

**新**

```swift
        // M7：时域融合（抗闪烁）。AI 模式默认开；快速放大由用户开关，因为 box 缩放本身也抖。
        // 关闭时既不算光流也不融合，成本与 M6 完全一致。
        let qualityTemporal: Bool = settings.antiFlicker || settings.useAI
```

### E7 · render 主循环：三处小改

**7a · 光流需求**（`App/VideoEngine.swift:866`）

```swift
                let needsFlow = needsInterp || temporalWeight > 0
```

→

```swift
                let needsFlow = needsInterp || qualityTemporal
```

**7b · 融合块**（`App/VideoEngine.swift:883-889`）

**旧**

```swift
                var outBuf = buf
                if temporalWeight > 0, let prevStable {
                    FrameOps.blendTemporal(prev: prevStable, cur: buf, w: tw, h: th,
                                           flow: flow, flowScale: flowScale,
                                           weight: temporalWeight, out: &stable)
                    outBuf = stable
                }
                let aBuf = prevStable ?? prev
```

**新**

```swift
                // M7：写入目标恒为「不是上一帧结果」的那一块。
                // 旧写法 outBuf = stable 之后又 prevStable = outBuf，两块 [UInt8] 共享同一份存储，
                // 下一帧一写就触发整帧 COW 拷贝（4K 每帧白抄 33 MB）。
                var outBuf = buf
                if qualityTemporal, let prevFrame = prevStable {
                    let needBytes: Int = tw * th * 4
                    if stableA.count != needBytes {
                        stableA = [UInt8](repeating: 0, count: needBytes)
                    }
                    if stableB.count != needBytes {
                        stableB = [UInt8](repeating: 0, count: needBytes)
                    }
                    let merged: Bool = QualityCore.blendTemporalAdaptive(prev: prevFrame,
                                                                        cur: buf,
                                                                        width: tw,
                                                                        height: th,
                                                                        flow: flow,
                                                                        flowScale: flowScale,
                                                                        antiFlicker: settings.antiFlicker,
                                                                        out: &stableB)
                    if merged {
                        swap(&stableA, &stableB)
                        outBuf = stableA
                    }
                }
                let aBuf = prevStable ?? prev
```

> `merged == false` 只发生在 `flow == nil`（第一对帧拿不到上一帧 CGImage）时，此时退回
> `outBuf = buf`，与旧行为的 fallback 一致。下面 @897-898 的 `prevStable = outBuf` /
> `lastBuf = outBuf` **保持原样不动**。

**7c · 首帧分支**（`App/VideoEngine.swift:899`）

```swift
            } else if temporalWeight > 0 {
```

→

```swift
            } else if qualityTemporal {
```

> 改完 `temporalWeight` 就没有任何引用了（`grep temporalWeight App/` 应为 0 命中）。
> `FrameOps.blendTemporal` 保留不删，作为降级开关（第 5 节 D4）。

### E8 · 状态条文案

`App/VideoEngine.swift:1503`

**旧**

```swift
        if detail > 0.001 { parts.append("细节 \(Int(detail * 100))%") }
```

**新**

```swift
        if detail > 0.001 { parts.append("细节 \(Int(detail * 100))%") }
        if denoise > 0.001 { parts.append("降噪 \(Int(denoise * 100))%") }
        if antiFlicker { parts.append("抗闪烁") }
```

### E9 · 视频侧 UI：detailCard

`App/VideoView.swift:324-344`

**旧**

```swift
    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("细节增强", systemImage: "wand.and.rays")
                .font(.headline)
            HStack {
                Text("锐度")
                    .font(.caption)
                Slider(value: $engine.detail, in: 0...1, step: 0.05)
                Text("\(Int(engine.detail * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            Text("缩放到目标尺寸后做一遍轻微 USM，把重采样吃掉的高频补回来。0 表示完全不加，20–40% 通常最自然也最安全。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .disabled(engine.isRunning)
    }
```

**新**

```swift
    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("细节增强", systemImage: "wand.and.rays")
                .font(.headline)
            HStack {
                Text("锐度")
                    .font(.caption)
                Slider(value: $engine.detail, in: 0...1, step: 0.05)
                Text("\(Int(engine.detail * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("降噪")
                    .font(.caption)
                Slider(value: $engine.denoise, in: 0...1, step: 0.05)
                Text("\(Int(engine.denoise * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            Toggle("抗闪烁", isOn: $engine.antiFlicker)
                .font(.caption)
            Text("锐化只在亮度通道做，输出被钳在 5×5 邻域极值内，不会出白边；降噪按局部对比度自动避让细节，平坦区压噪、强边不糊。抗闪烁会把静止区多帧融合，快速放大也可开。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .disabled(engine.isRunning)
    }
```

> 整卡 `.disabled(engine.isRunning)` 已经覆盖新加的控件，不需要单独处理。

### E10 · 图片侧接入同一套细节/抖动

**10a · 引擎属性**（`App/UpscaleEngine.swift:272` 之后，@Published 区内）

```swift
    @Published var notice: String?
```

→

```swift
    @Published var notice: String?
    /// M7：图片侧细节增强 0…1。默认 0 = 完全不动原图（零回归风险）。
    @Published var detail: Double = 0
```

**10b · 调用点**（`App/UpscaleEngine.swift:525`）

**旧**

```swift
        let finalCG = Self.resampled(aiCG, width: p.targetWidth, height: p.targetHeight) ?? aiCG
```

**新**

```swift
        let resampledCG = Self.resampled(aiCG, width: p.targetWidth, height: p.targetHeight) ?? aiCG
        let finalCG = Self.detailTuned(resampledCG, amount: detail)
```

**10c · 新增静态方法**（放在 `App/UpscaleEngine.swift:611` 的 `rgbx` 之前即可）

```swift
    /// M7：图片侧的细节增强 + 抖动。与视频侧共用 QualityCore，单帧、无时域。
    /// 复用已有的 rgbx / makeCGImage，避免再写一遍 CGContext 管线。
    private static func detailTuned(_ cg: CGImage, amount: Double) -> CGImage {
        guard amount > 0.001 else { return cg }
        let w = cg.width
        let h = cg.height
        guard w >= 8, h >= 8, var rgba = rgbx(cg, width: w, height: h) else { return cg }
        // 图到图没有时域，但仍要给锐化一个噪声门控：固定 0.25 的轻度降噪，
        // 只作用在低对比平坦区（天空、皮肤、暗部），强边照常锐化（T4）。
        let ok: Bool = QualityCore.applyDetail(&rgba,
                                               width: w,
                                               height: h,
                                               amount: Float(amount),
                                               denoise: 0.25,
                                               dither: true)
        guard ok else { return cg }
        guard let out = makeCGImage(from: rgba, width: w, height: h) else { return cg }
        return out
    }
```

### E11 · 图片侧 UI 滑杆

`App/ContentView.swift:303-305`（`scaleCard` 内最后一段说明文字）

**旧**

```swift
            Text("原生 AI 为 4×。1.5–3× 是 4× 重建后缩回，6×/8× 是重建后再放大。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
```

**新**

```swift
            Text("原生 AI 为 4×。1.5–3× 是 4× 重建后缩回，6×/8× 是重建后再放大。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                Text("细节")
                    .font(.caption)
                Slider(value: $engine.detail, in: 0...1, step: 0.05)
                Text("\(Int(engine.detail * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(engine.isRunning)
```

---

## 3. 性能预估（A15 级，导出管线，非实时预览）

单帧耗时（`QualityCore.applyDetail` 为 6 个 pass、25 字节/px 的内存流量）：

| 阶段 | 1080p | 4K (UHD) | 备注 |
|------|-------|----------|------|
| `applyDetail`（新锐化+降噪+抖动） | 5.2 – 8.6 ms | 20.7 – 34.6 ms | T12 实测模型 |
| `blendTemporalAdaptive`（新融合） | 4 – 7 ms | 16 – 26 ms | 12 B/px + 双线性 4 tap |
| 旧 `unsharp`（3×3 ARGB，参考值） | 1.5 – 2.5 ms | 6 – 10 ms | 已被替换 |
| **净增（相对 M6）** | **+8 – +13 ms** | **+30 – +50 ms** | |

对照：一次 AI 4× 推理 100 – 400 ms/帧，所以本阶段占总耗时的 **2% – 25%**（4K + 抗闪烁取上限）。
一个 30 fps、10 秒的 1080p 导出，净增约 3 – 4 秒；4K 同长度净增 10 – 15 秒。

内存：

| 项 | 1080p | 4K | 说明 |
|----|-------|----|------|
| 分条平面（5 张 × `width` × 72） | 0.4 MB | 1.4 MB | 与整帧 5 平面（66 MB）比可忽略 |
| 乒乓缓冲 ×2 | 16.6 MB | 66 MB | 旧版只有 1 块（`stable`）+ 别名 |
| 净增 | +8.3 MB | +33 MB | 只在时域开启时分配 |

> 单帧峰值仍 ≤ 100 MB 的预算内，但 4K + HDR 同时开会到 60 MB 上下，属于需要盯的区间。
> 若真要压，把 `QualityCore.stripHeight` 从 64 降到 32（分条平面减半，调用次数翻倍，
> 4K 大概 +3 ms/帧）。**不要**去改 `stripPad`，它必须 ≥ 2。

---

## 4. 为什么扔掉旧 USM（给 review 用）

`App/VideoEngine.swift:546` 的 3×3 盒式 USM 有三个可测缺陷（`verify_quality_math.py` T2/T3/T4）：

1. **核和不是 256**：`amount=0.5` 时 `center = 370`、`neg = −14`，`370 − 9×14 = 244`，
   全片被压暗 4.6%（实测亮度增益 ×0.9535）。1.0 时更糟。
2. **halo**：硬阶跃上越界 8 / 10 / 15 / 24 / 28 码（对比度 16 → 200）。这就是文档里
   "再高会出白边" 的真正原因——不是 amount 太大，是核本身会过冲。
3. **无噪声门控**：all-pass，噪声和细节一起放大（∞ 对比度棋盘上多出 34 码）。

新实现的对应指标：越界恒 0、亮度增益 ×1.0000、噪声 σ=3.04 时幅度 ×0.65（denoise=0.6）。

---

## 5. 真机风险与降级开关

### 5.1 编译风险（按可能性排序）

| 风险 | 表现 | 处理 |
|------|------|------|
| `vImageMatrixMultiply_ARGB8888ToPlanar8` 签名不符 | 编译报参数类型 | 把 `QualityCore.useVectorLuma` 改成 `false`，走纯 Swift 亮度提取。数学等价、差 ≤1 码（除法舍入方式不同），慢 1–4 ms/1080p |
| vImage 矩阵的通道序与我们的 R,G,B,X 缓冲不符 | **编译能过、肉眼看只是偏灰** | 已内置 `vectorLumaTrusted` 1 px 自检：通道序错了会差 60 码以上，自检不过自动整帧退回纯 Swift，无感 |
| `vImageMin_Planar8` / `vImageMax_Planar8` 的 `kernelHeight/kernelWidth` 类型 | 编译报 `vImagePixelCount` | 已用 `vImagePixelCount(5)` 显式转换；若仍报，改成 `UInt(5)` |
| `vImageConvolve_Planar8` 的 `divisor` 是 `Int32` | 编译报类型 | 已显式 `Int32(16)` |
| `guard let flow else` 语法 | 需要 Swift 5.7+ | 工程已 iOS 17 / Swift 5.9，没问题；若 CI 用旧工具链改成 `guard let flow = flow else` |
| `swap(&stableA, &stableB)` | 两个必须是 `var` | E6 已声明为 `var`，别改成 `let` |

### 5.2 运行时风险

| 风险 | 现象 | 处理 |
|------|------|------|
| 内存峰值 | 4K + HDR + 抗闪烁 | 关抗闪烁（省 33 MB + 20 ms/帧）；或 `stripHeight = 32` |
| 融合残影 | 快速摇镜/遮挡 | 已由 `gate = 1/(1+(diff/24)^2)` 挡住；若仍见，把 `antiFlicker` 关掉回到 0.20/0.16 |
| 过锐发"塑料感" | 人脸/天空 | 降 `detail` 到 0.15；或把 `QualityCore.edgeGuard` 从 0.25 调到 0.5（更保守） |
| 暗部细节被降噪吃掉 | 夜景 | 降 `denoise` 到 0.15 |

### 5.3 降级开关（从轻到重）

- **D1** `QualityCore.useVectorLuma = false` —— 只影响速度（差 ≤1 码）。
- **D2** `antiFlicker = false` —— 关时域（AI 模式仍走新融合，still 0.20 / moving 0.16）。
- **D3** `denoise = 0` —— 关降噪，只保留零-halo 锐化 + 抖动（仍远好于旧 USM）。
- **D4** 完全回滚：把 E5 换回 `FrameOps.unsharp`，E6/E7 换回 `temporalWeight`。
  `FrameOps.unsharp` 与 `FrameOps.blendTemporal` 都**保留在仓库里**，所以这一步是纯文本回滚，
  不需要恢复任何被删的代码。
- **D5** 整个 `QualityCore.swift` 移出 target —— 所有调用点会一起报错，所以 D4 必须先行。

---

## 6. 验收清单

**编译**（GitHub Actions，`xcodebuild -scheme PixelLift -destination 'generic/platform=iOS' build`）

- [ ] `QualityCore.swift` 单独进 target 能过（先做这一步，隔离风险）
- [ ] E1–E11 全改完能过
- [ ] 无 `the compiler is unable to type-check this expression in reasonable time`
      （所有表达式已拆行；`QualityCore` 里最长的一行是 110 字符）

**数值**（本地，不需要 Mac）

```powershell
cd "D:\AI Projects\v2rayN移植\research\m7"
cmd /c ""C:\Users\ape\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" verify_quality_math.py"
```

应输出 `SUMMARY: 49/49 PASS`。改了 `QualityCore.swift` 里任何一个常数，必须先跑这个脚本。

**肉眼**（真机，同一段 5 秒 1080p 素材）

- [ ] 高对比字幕/窗框：无白边（旧版明显）
- [ ] 天空/墙面渐变：无新色带；静止机位下连续 100 帧无"呼吸"
- [ ] 快速摇镜：无拖影残影
- [ ] 噪点素材：`denoise 0.6` 下颗粒明显减少、边缘不糊
- [ ] 整片亮度与源片一致（不再暗 4.6%）
