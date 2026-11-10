import Foundation

// ============================================================================
// PixelLift · M6 动态模糊核心（MotionBlurCore）
// ----------------------------------------------------------------------------
// 目标：把「相机快门在曝光时间内累积的光」在时间轴上重新积分，而不是把几帧糊在一起。
// 本文件是独立新增文件，不含任何全局可变状态，可直接拖进 App target。
//
// 一、快门角 -> 时间窗
//   真实相机：曝光时长 T = (theta/360) / outFps，theta 是快门角。
//   本 App 的合成时间轴把「一对源帧 (a,b)」归一化成 t 属于 [0,1]，
//   这一对被展开成 perPair 个输出帧，所以在输出时间轴上占 perPair/outFps 秒。
//   归一化窗宽：
//       W = T / (perPair / outFps) = (theta / 360) / perPair
//   theta=180 度、perPair=1 => W=0.5（半帧间隔，正是 180 度快门）；
//   perPair=2 => W=0.25。outFps 翻倍时 perPair 同步翻倍，W 自动减半，
//   于是 60fps 输出的拖影长度正好是 30fps 的一半。W 与 fps 无关，只与角度和
//   补帧倍率有关 —— 这是「不和补帧/慢动作重复模糊」的关键。
//
// 二、窗口锚点（关键决策）
//   窗放在 [t, t+W]（锚定帧起点 / 后帘），而不是 [t-W/2, t+W/2]（中心对称）。
//   因为 t 的最大值是 (perPair-1)/perPair，而 W <= 1/perPair（theta<=360），
//   所以 t+W <= 1 恒成立 —— 窗口永远完整落在这一对帧内部：
//     * 不需要第三帧 halo，不需要第二条光流（省掉一整次 VNGenerateOpticalFlow）；
//     * 不会截断，所有输出帧的积分区间等长，没有「清晰/模糊交替」的闪烁；
//     * theta=360 时相邻输出帧的窗首尾相接（[0,W],[W,2W],...）= 100% duty cycle，
//       这正是 360 度快门在 60fps 下应有的样子（曝光连续不断）。
//   代价是整条时间轴有一个恒定相位偏移 W/2 <= 半个输出帧（60fps 时 <=8.3ms），
//   音画同步上完全不可辨，换来的是零额外缓冲、零额外光流。
//
// 三、每像素自适应采样
//   离散采样把连续拖影切成 m 段，段长 = 该像素在窗内的位移 D / m 像素。
//   取 m >= D / stepPixels（stepPixels=1px）即可让积分分辨率达到 1 像素。
//   D 由光流给出：D = |v| * flowScale * W。
//   实现：按 blockSize x blockSize 分块，块内以 4 像素步长探测取 |v| 最大值，
//   得到该块的 m。m=1 的块只用一次采样并直接写字节，完全跳过 sRGB 解码/编码，
//   所以静止区域输出与单次 synthesize 完全一致（零精度损失、零额外开销）。
//   采样位置用分层中点 (i+0.5)/m * W，均匀覆盖整个窗，不做块间抖动：
//   抖动会让相邻块拖影相位不同，反而在快门上看到斜向条纹；m 相同时相位天然对齐。
//
//   为什么块与块之间不会出现「拼块痕迹」：m 是由 D 推出来的，不是质量档位。
//   只要 m 没被成本上限压过，每块的积分分辨率都是 1px，边界两侧输出连续。
//   （被成本上限压过时才可能露块界，见第五节。）
//
// 四、线性光累积
//   sRGB 码值域直接平均 = 先 gamma 平均再解码，结果是拖影变暗、彩边偏色。
//   实测（verify_blur_math.py S3）：单一覆盖率 0.244 时正确值 135.5 码、
//   直接平均 62.3 码，最大偏差 73.2 码。正确做法是先转线性光累积，再编码回 sRGB。
//   这里用两张表：4096 段解码表（域 0..255 码值，线性插值）+ 4096 段编码表
//   （sqrt 索引，等价于在码值域近似均匀，实测最大误差 5e-5 码，256 个码值往返精确）。
//
// 五、权重
//   真实快门是矩形曝光窗，离散化后就是「等权 m 个样本 + 每个样本自身的连续相位插值」。
//   旧实现的三角权重等价于矩形窗再卷一个三角核：等效曝光时长只剩一半
//   （三角积分/峰值 = W/2），模糊量凭空少一半，且拖影两端被 1-|x| 压暗。
//   详见 RESEARCH.md 的实测对比，所以这里改回等权矩形窗。
//
// 六、成本上限
//   sampleBudget 约束「平均每像素样本数」avgM。超出时用一个全局比例因子统一压低
//   所有块的 m：矩形窗积分对任意 m 都无偏，所以模糊量不变，只损失积分精度。
//   这是唯一一处拿画质换时间的地方，且代价可见（长拖影出现 M 级台阶）。
//
// 七、HDR
//   累积发生在 8-bit RGBA 阶段、SDRToHDR.writeP010 之前。不需要改 writeP010。
//
// 复杂度
//   时间 O(W*H*avgM + blocks*probes)，典型 avgM 1.2~3；
//   空间 O(W*H*3) 的 Float 累积缓冲（1080p 约 24.9MB，1.4MP 约 16.8MB）。
//
// 依赖（同 target 已有符号，来源见行内注释）：
//   FlowField            —— App/VideoEngine.swift
//   FrameOps.synthesize  —— App/VideoEngine.swift
// ============================================================================

/// 快门角。真实摄影机用角度描述曝光时长占帧间隔的比例。
/// 180 度 = 半帧曝光（电影标准），360 度 = 整帧曝光（连续不漏光）。
enum ShutterAngle: Double, CaseIterable, Identifiable {
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270
    case deg360 = 360

    var id: Double { rawValue }

    var degrees: Double { rawValue }

    var title: String {
        switch self {
        case .deg90: return "90°"
        case .deg180: return "180°"
        case .deg270: return "270°"
        case .deg360: return "360°"
        }
    }
}

/// 采样预算档位：约束平均每像素采样数（avgM），直接决定每帧耗时。
enum BlurQuality: Int, CaseIterable, Identifiable {
    case lite = 4
    case standard = 10
    case fine = 20

    var id: Int { rawValue }

    var budget: Int { rawValue }

    var title: String {
        switch self {
        case .lite: return "省电"
        case .standard: return "标准"
        case .fine: return "精细"
        }
    }
}

enum MotionBlurCore {

    // MARK: - 参数与结果类型

    /// 一次渲染固定的模糊参数（每对帧算一次，不随帧变化）。
    struct Plan {
        /// 是否启用。快门角为 0 或窗宽退化时为 false，调用方退回单次合成。
        var enabled: Bool
        /// 归一化窗宽 W = (theta/360)/perPair，单位是「一对帧的相位」。
        var phaseWidth: Float
        /// 单块样本数硬上限，防止极端光流把单块拖到几百次。
        var maxSamples: Int
        /// 平均每像素样本数上限（成本闸门）。<=0 表示不设限。
        var sampleBudget: Float
        /// 积分分辨率：块内每 stepPixels 像素位移取一个样本。
        var stepPixels: Float
        /// 分块边长。
        var blockSize: Int
        /// 是否在线性光域累积。false 时退回码值域直接平均（仅用于对比/降级）。
        var linearLight: Bool
        /// 是否按块自适应。false 时所有块都用 maxSamples（更慢，仅用于对比）。
        var adaptive: Bool
    }

    /// 分块采样计划 + 光流采样映射表，供 compose 直接复用，避免重复建表。
    struct BlockPlan {
        var blocksX: Int
        var blocksY: Int
        var blockSize: Int
        /// 每块样本数（与 blocksX*blocksY 同序）。
        var samples: [Int32]
        /// 输出 x -> 光流列号。
        var colMap: [Int32]
        /// 输出 y -> 光流行号。
        var rowMap: [Int32]
        /// 成本闸门作用后的平均样本数。
        var averageSamples: Float
        /// 实际用到的最大块样本数。==1 时整帧可以直接单次合成。
        var maxUsed: Int
    }

    // MARK: - 建计划

    /// 由快门角与补帧倍率算出窗宽。
    /// - Parameters:
    ///   - angleDegrees: 快门角，0...360。
    ///   - perPair: 一对源帧展开成的输出帧数（= samplesPerPair）。
    ///   - sampleBudget: 平均样本数上限，来自 BlurQuality.budget。
    static func makePlan(angleDegrees: Double,
                         perPair: Int,
                         sampleBudget: Int,
                         linearLight: Bool,
                         adaptive: Bool) -> Plan {
        var angle: Double = angleDegrees
        if !(angle >= 0.0) { angle = 0.0 }
        if angle > 360.0 { angle = 360.0 }

        var pairs: Int = perPair
        if pairs < 1 { pairs = 1 }
        if pairs > 64 { pairs = 64 }

        let raw: Double = angle / 360.0
        let width: Float = Float(raw / Double(pairs))

        var budget: Float = Float(sampleBudget)
        if !(budget >= 1.0) { budget = 4.0 }
        if budget > 32.0 { budget = 32.0 }

        var on: Bool = true
        if angle <= 0.0001 { on = false }
        if width <= 0.00001 { on = false }

        var phaseWidth: Float = 0.0
        if on { phaseWidth = width }

        return Plan(enabled: on,
                    phaseWidth: phaseWidth,
                    maxSamples: 32,
                    sampleBudget: budget,
                    stepPixels: 1.0,
                    blockSize: 32,
                    linearLight: linearLight,
                    adaptive: adaptive)
    }

    // MARK: - 分块计划

    /// 扫描光流，按块算出需要的样本数，并施加成本闸门。
    /// 复杂度 O(blocks * (blockSize/probe)^2 + W + H)。
    static func blockPlan(flow: FlowField,
                          flowScale: Float,
                          width: Int,
                          height: Int,
                          plan: Plan) -> BlockPlan {
        var blockSize: Int = plan.blockSize
        if blockSize < 8 { blockSize = 8 }
        if blockSize > 128 { blockSize = 128 }

        let blocksX: Int = (width + blockSize - 1) / blockSize
        let blocksY: Int = (height + blockSize - 1) / blockSize
        let count: Int = blocksX * blocksY

        var colMap = [Int32](repeating: 0, count: width)
        var rowMap = [Int32](repeating: 0, count: height)

        for x in 0..<width {
            var fx: Int = x * flow.w / width
            if fx > flow.w - 1 { fx = flow.w - 1 }
            if fx < 0 { fx = 0 }
            colMap[x] = Int32(fx)
        }
        for y in 0..<height {
            var fy: Int = y * flow.h / height
            if fy > flow.h - 1 { fy = flow.h - 1 }
            if fy < 0 { fy = 0 }
            rowMap[y] = Int32(fy)
        }

        var need = [Float](repeating: 1.0, count: count)
        var areas = [Float](repeating: 0.0, count: count)
        var totalArea: Float = 0.0

        var probe: Int = 4
        if blockSize < 16 { probe = 2 }

        let fieldW: Int = flow.w
        flow.data.withUnsafeBufferPointer { fPtr in
            for by in 0..<blocksY {
                let y0: Int = by * blockSize
                var y1: Int = y0 + blockSize
                if y1 > height { y1 = height }
                for bx in 0..<blocksX {
                    let x0: Int = bx * blockSize
                    var x1: Int = x0 + blockSize
                    if x1 > width { x1 = width }

                    var best: Float = 0.0
                    var py: Int = y0
                    while py < y1 {
                        let fieldRow: Int = Int(rowMap[py]) * fieldW
                        var px: Int = x0
                        while px < x1 {
                            let fi: Int = (fieldRow + Int(colMap[px])) * 2
                            let vx: Float = fPtr[fi] * flowScale
                            let vy: Float = fPtr[fi + 1] * flowScale
                            let sq: Float = vx * vx + vy * vy
                            let d: Float = sq.squareRoot() * plan.phaseWidth
                            if d > best { best = d }
                            px += probe
                        }
                        py += probe
                    }

                    let idx: Int = by * blocksX + bx
                    let area: Float = Float((x1 - x0) * (y1 - y0))
                    areas[idx] = area
                    totalArea += area

                    if plan.adaptive {
                        var m: Float = 1.0
                        if plan.stepPixels > 0.0001 {
                            let q: Float = best / plan.stepPixels
                            m = q.rounded(.up)
                        }
                        if m < 1.0 { m = 1.0 }
                        need[idx] = m
                    } else {
                        need[idx] = Float(plan.maxSamples)
                    }
                }
            }
        }

        // 成本闸门：平均样本数超过 sampleBudget 时统一按比例压低。
        // 矩形窗积分对任意 m 无偏，所以只损失积分精度，不损失模糊量。
        var weighted: Float = 0.0
        for i in 0..<count {
            weighted += need[i] * areas[i]
        }
        var rawAverage: Float = 1.0
        if totalArea > 0.0001 {
            rawAverage = weighted / totalArea
        }
        var factor: Float = 1.0
        if plan.sampleBudget > 0.0001 && rawAverage > plan.sampleBudget {
            factor = plan.sampleBudget / rawAverage
        }

        var samples = [Int32](repeating: 1, count: count)
        var maxUsed: Int = 1
        var scaledWeighted: Float = 0.0
        for i in 0..<count {
            var mf: Float = need[i] * factor
            if mf < 1.0 { mf = 1.0 }
            var mi: Int = Int(mf.rounded(.down))
            if mi < 1 { mi = 1 }
            if mi > plan.maxSamples { mi = plan.maxSamples }
            samples[i] = Int32(mi)
            if mi > maxUsed { maxUsed = mi }
            scaledWeighted += Float(mi) * areas[i]
        }
        var average: Float = 1.0
        if totalArea > 0.0001 {
            average = scaledWeighted / totalArea
        }

        return BlockPlan(blocksX: blocksX,
                         blocksY: blocksY,
                         blockSize: blockSize,
                         samples: samples,
                         colMap: colMap,
                         rowMap: rowMap,
                         averageSamples: average,
                         maxUsed: maxUsed)
    }

    /// 只估算成本，不渲染。给渲染器报「这一对帧大概要几次合成」用。
    static func estimateAverageSamples(flow: FlowField?,
                                       flowScale: Float,
                                       width: Int,
                                       height: Int,
                                       plan: Plan) -> Float {
        guard let field = flow else { return 1.0 }
        if !plan.enabled { return 1.0 }
        if width < 2 || height < 2 { return 1.0 }
        if field.w < 8 || field.h < 8 { return 1.0 }
        let bp: BlockPlan = blockPlan(flow: field,
                                      flowScale: flowScale,
                                      width: width,
                                      height: height,
                                      plan: plan)
        return bp.averageSamples
    }

    // MARK: - 主入口

    /// 合成「曝光窗 [t, t+W] 的时间积分」并写入 out。
    ///
    /// - Parameters:
    ///   - a: 前一个源帧 RGBA8
    ///   - b: 后一个源帧 RGBA8
    ///   - width/height: 输出尺寸（也等于 a/b 的尺寸）
    ///   - t: 窗起点，调用方传 j/perPair
    ///   - flow: a->b 的光流（可能为 nil，此时退化为单次合成）
    ///   - flowScale: 光流图层像素 -> 输出像素的缩放
    ///   - plan: 由 makePlan 得到
    ///   - scratchLinear: 线性光累积缓冲，长度需 >= width*height*3；首次调用会自动扩容
    ///   - out: 输出 RGBA8，长度需 >= width*height*4；首次调用会自动扩容
    static func compose(a: [UInt8],
                        b: [UInt8],
                        width: Int,
                        height: Int,
                        t: Float,
                        flow: FlowField?,
                        flowScale: Float,
                        plan: Plan,
                        scratchLinear: inout [Float],
                        out: inout [UInt8]) {
        if width < 2 || height < 2 { return }
        let pixelCount: Int = width * height
        let total: Int = pixelCount * 4
        if a.count < total { return }
        if b.count < total { return }
        if out.count < total {
            out = [UInt8](repeating: 0, count: total)
        }

        var phaseStart: Float = t
        if !(phaseStart >= 0.0) { phaseStart = 0.0 }
        if phaseStart > 1.0 { phaseStart = 1.0 }

        // 退化路径统一走单次合成（FrameOps.synthesize 来源：App/VideoEngine.swift）。
        var active: Bool = plan.enabled
        if plan.phaseWidth <= 0.00001 { active = false }
        if !active {
            FrameOps.synthesize(a: a, b: b, w: width, h: height,
                                flow: flow, flowScale: flowScale,
                                t: phaseStart, out: &out)
            return
        }

        guard let field = flow, field.w >= 8, field.h >= 8 else {
            FrameOps.synthesize(a: a, b: b, w: width, h: height,
                                flow: flow, flowScale: flowScale,
                                t: phaseStart, out: &out)
            return
        }

        let bp: BlockPlan = blockPlan(flow: field,
                                      flowScale: flowScale,
                                      width: width,
                                      height: height,
                                      plan: plan)

        // 全帧都只需要 1 个样本：直接走单次合成，省掉整趟分块循环。
        if bp.maxUsed <= 1 {
            FrameOps.synthesize(a: a, b: b, w: width, h: height,
                                flow: flow, flowScale: flowScale,
                                t: phaseStart, out: &out)
            return
        }

        // 累积缓冲：即使关掉线性光也要分配，因为多样本块求和仍然用它。
        let needLinear: Int = pixelCount * 3
        if scratchLinear.count < needLinear {
            scratchLinear = [Float](repeating: 0.0, count: needLinear)
        }

        let w: Int = width
        let h: Int = height
        let fieldW: Int = field.w
        let outRowStride: Int = width * 4
        let linRowStride: Int = width * 3
        let blockSize: Int = bp.blockSize
        let phaseWidth: Float = plan.phaseWidth
        let useLinear: Bool = plan.linearLight
        let maxSamples: Int = plan.maxSamples

        var phaseMid: Float = phaseStart + phaseWidth * 0.5
        if phaseMid > 1.0 { phaseMid = 1.0 }

        a.withUnsafeBufferPointer { aPtr in
            b.withUnsafeBufferPointer { bPtr in
                out.withUnsafeMutableBufferPointer { oPtr in
                    scratchLinear.withUnsafeMutableBufferPointer { sPtr in
                        field.data.withUnsafeBufferPointer { fPtr in
                            for by in 0..<bp.blocksY {
                                let y0: Int = by * blockSize
                                var y1: Int = y0 + blockSize
                                if y1 > h { y1 = h }
                                let blockRowBase: Int = by * bp.blocksX

                                for bx in 0..<bp.blocksX {
                                    let x0: Int = bx * blockSize
                                    var x1: Int = x0 + blockSize
                                    if x1 > w { x1 = w }

                                    var m: Int = Int(bp.samples[blockRowBase + bx])
                                    if m < 1 { m = 1 }
                                    if m > maxSamples { m = maxSamples }

                                    if m <= 1 {
                                        // 单样本块：窗中点取样，逐字节恒等，不走 LUT。
                                        let back: Float = 1.0 - phaseMid
                                        for y in y0..<y1 {
                                            let fieldRow: Int = Int(bp.rowMap[y]) * fieldW
                                            let outRow: Int = y * outRowStride
                                            for x in x0..<x1 {
                                                let fi: Int = (fieldRow + Int(bp.colMap[x])) * 2
                                                let vx: Float = fPtr[fi] * flowScale
                                                let vy: Float = fPtr[fi + 1] * flowScale
                                                let xf: Float = Float(x)
                                                let yf: Float = Float(y)
                                                let ax: Float = xf - phaseMid * vx
                                                let ay: Float = yf - phaseMid * vy
                                                let bxs: Float = xf + back * vx
                                                let bys: Float = yf + back * vy
                                                let o: Int = outRow + x * 4
                                                for c in 0..<3 {
                                                    let sa: Float = sampleTent(aPtr, w, h, ax, ay, c)
                                                    let sb: Float = sampleTent(bPtr, w, h, bxs, bys, c)
                                                    let v: Float = back * sa + phaseMid * sb
                                                    oPtr[o + c] = clampByte(v)
                                                }
                                                oPtr[o + 3] = 255
                                            }
                                        }
                                    } else {
                                        let inv: Float = 1.0 / Float(m)
                                        for s in 0..<m {
                                            let frac: Float = (Float(s) + 0.5) * inv
                                            let ph: Float = phaseStart + phaseWidth * frac
                                            let back: Float = 1.0 - ph
                                            for y in y0..<y1 {
                                                let fieldRow: Int = Int(bp.rowMap[y]) * fieldW
                                                let linRow: Int = y * linRowStride
                                                for x in x0..<x1 {
                                                    let fi: Int = (fieldRow + Int(bp.colMap[x])) * 2
                                                    let vx: Float = fPtr[fi] * flowScale
                                                    let vy: Float = fPtr[fi + 1] * flowScale
                                                    let xf: Float = Float(x)
                                                    let yf: Float = Float(y)
                                                    let ax: Float = xf - ph * vx
                                                    let ay: Float = yf - ph * vy
                                                    let bxs: Float = xf + back * vx
                                                    let bys: Float = yf + back * vy
                                                    let li: Int = linRow + x * 3
                                                    for c in 0..<3 {
                                                        let sa: Float = sampleTent(aPtr, w, h, ax, ay, c)
                                                        let sb: Float = sampleTent(bPtr, w, h, bxs, bys, c)
                                                        let v: Float = back * sa + ph * sb
                                                        var value: Float = v
                                                        if useLinear {
                                                            value = decodeSRGB(v)
                                                        }
                                                        if s == 0 {
                                                            sPtr[li + c] = value
                                                        } else {
                                                            sPtr[li + c] += value
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // 归一化 + 编码回 sRGB 字节
                                        for y in y0..<y1 {
                                            let outRow: Int = y * outRowStride
                                            let linRow: Int = y * linRowStride
                                            for x in x0..<x1 {
                                                let o: Int = outRow + x * 4
                                                let li: Int = linRow + x * 3
                                                for c in 0..<3 {
                                                    let acc: Float = sPtr[li + c]
                                                    var code: Float = acc * inv
                                                    if useLinear {
                                                        let enc: Float = encodeSRGB(code)
                                                        code = enc * 255.0
                                                    }
                                                    oPtr[o + c] = clampByte(code)
                                                }
                                                oPtr[o + 3] = 255
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 采样

    /// 双线性取样，与 FrameOps.sample 同数学形式，但显式 clamp，
    /// 保证越界（光流指向画面外）时不会读到错误位置。
    @inline(__always)
    private static func sampleTent(_ src: UnsafeBufferPointer<UInt8>,
                                   _ w: Int,
                                   _ h: Int,
                                   _ x: Float,
                                   _ y: Float,
                                   _ c: Int) -> Float {
        var cx: Float = x
        var cy: Float = y
        if !(cx >= 0.0) { cx = 0.0 }
        if !(cy >= 0.0) { cy = 0.0 }
        let maxX: Float = Float(w - 1)
        let maxY: Float = Float(h - 1)
        if cx > maxX { cx = maxX }
        if cy > maxY { cy = maxY }

        let x0: Int = Int(cx)
        let y0: Int = Int(cy)
        var x1: Int = x0 + 1
        var y1: Int = y0 + 1
        if x1 > w - 1 { x1 = w - 1 }
        if y1 > h - 1 { y1 = h - 1 }

        let fx: Float = cx - Float(x0)
        let fy: Float = cy - Float(y0)

        let i00: Int = (y0 * w + x0) * 4 + c
        let i10: Int = (y0 * w + x1) * 4 + c
        let i01: Int = (y1 * w + x0) * 4 + c
        let i11: Int = (y1 * w + x1) * 4 + c

        let v00: Float = Float(src[i00])
        let v10: Float = Float(src[i10])
        let v01: Float = Float(src[i01])
        let v11: Float = Float(src[i11])

        let top: Float = v00 + (v10 - v00) * fx
        let bottom: Float = v01 + (v11 - v01) * fx
        return top + (bottom - top) * fy
    }

    // MARK: - sRGB 传输函数

    /// sRGB 电光转换（IEC 61966-2-1）。来源：与 App/VideoEngine.swift 中
    /// SDRToHDR.eotf 同式，此处独立实现，避免跨类型耦合。
    private static func eotfExact(_ v: Float) -> Float {
        if !(v > 0.0) { return 0.0 }
        if v >= 1.0 { return 1.0 }
        if v <= 0.04045 {
            return v / 12.92
        }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    /// sRGB 光电转换（编码）。
    private static func oetfExact(_ y: Float) -> Float {
        if !(y > 0.0) { return 0.0 }
        if y >= 1.0 { return 1.0 }
        if y <= 0.0031308 {
            return y * 12.92
        }
        return 1.055 * pow(y, 1.0 / 2.4) - 0.055
    }

    /// 解码表分段数（即 4097 项）。verify_blur_math.py 的 DECODE_SEGMENTS 必须与此一致。
    static let decodeSegments: Int = 4096
    /// 编码表分段数（sqrt 索引，4097 项）。与 verify_blur_math.py 的 ENCODE_SEGMENTS 一致。
    static let encodeSegments: Int = 4096

    /// 线性光解码表：table[i] = eotf(i / 4096)，i 属于 [0, 4096]。
    /// 一次建表 4097 次 powf，约 0.2ms，之后每像素只是两次查表 + 一次乘加。
    static let decodeTable: [Float] = {
        let n: Int = 4096            // 必须等于 decodeSegments
        var table = [Float](repeating: 0.0, count: n + 1)
        for i in 0...n {
            let v: Float = Float(i) / Float(n)
            table[i] = eotfExact(v)
        }
        return table
    }()

    /// 编码表：table[k] = oetf((k/4096)^2)。
    /// sqrt 索引让码值域上的分辨率近似均匀（暗部不被浪费），
    /// 实测最大误差 5e-5 码，比等距索引好 4 倍。
    static let encodeTable: [Float] = {
        let n: Int = 4096            // 必须等于 encodeSegments
        var table = [Float](repeating: 0.0, count: n + 1)
        for k in 0...n {
            let u: Float = Float(k) / Float(n)
            let y: Float = u * u
            table[k] = oetfExact(y)
        }
        return table
    }()

    /// 码值 [0,255] -> 线性光 [0,1]，线性插值。
    @inline(__always)
    static func decodeSRGB(_ code: Float) -> Float {
        let n: Float = Float(decodeSegments)
        var pos: Float = code * (n / 255.0)
        if !(pos >= 0.0) { pos = 0.0 }
        if pos > n { pos = n }
        var i: Int = Int(pos)
        if i < 0 { i = 0 }
        if i > decodeSegments - 1 { i = decodeSegments - 1 }
        let frac: Float = pos - Float(i)
        let lo: Float = decodeTable[i]
        let hi: Float = decodeTable[i + 1]
        return lo + (hi - lo) * frac
    }

    /// 线性光 [0,1] -> 码值比例 [0,1]。
    @inline(__always)
    static func encodeSRGB(_ linear: Float) -> Float {
        let n: Float = Float(encodeSegments)
        var y: Float = linear
        if !(y >= 0.0) { y = 0.0 }
        if y > 1.0 { y = 1.0 }
        let root: Float = y.squareRoot()
        var pos: Float = root * n
        if !(pos >= 0.0) { pos = 0.0 }
        if pos > n { pos = n }
        var i: Int = Int(pos)
        if i < 0 { i = 0 }
        if i > encodeSegments - 1 { i = encodeSegments - 1 }
        let frac: Float = pos - Float(i)
        let lo: Float = encodeTable[i]
        let hi: Float = encodeTable[i + 1]
        return lo + (hi - lo) * frac
    }

    /// Float -> 字节，四舍五入并饱和，NaN 落到 0（不会 trap）。
    @inline(__always)
    static func clampByte(_ v: Float) -> UInt8 {
        let r: Float = v.rounded()
        if !(r > 0.0) { return 0 }
        if r >= 255.0 { return 255 }
        return UInt8(r)
    }
}
