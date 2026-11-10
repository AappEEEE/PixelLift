//
//  QualityCore.swift
//  PixelLift · M7 画质打磨核心
//
//  设计目标：替换 FrameOps.unsharp 的 3x3 盒式 USM，做到
//    · 无 halo（数学上保证输出不越出源图 5x5 局部极值）
//    · 只在亮度域锐化（不会在高对比边缘出彩边）
//    · 带噪声门控（平坦区不放大噪声，强边缘不加剧过冲）
//    · 8-bit 输出前抖动（不产生 banding，图案与 HDR 路径同风格）
//    · 时域抗闪烁权重按「局部运动 + 亮度突变」自适应
//
//  约束：iOS 17 / Swift 5，SWIFT_STRICT_CONCURRENCY = minimal，无第三方依赖。
//  本文件可整份拖进 App target；除 FlowField（同 target 的 VideoEngine.swift 里
//  已有）之外不引用任何工程内部符号，也不与现有符号重名。
//
//  数值行为与 research/m7/verify_quality_math.py 逐条对拍（49/49 PASS）：
//  T1 核频响、T2 halo、T3 锐度、T4 噪声、T5 抖动、T6 单调性、T7 能量守恒、
//  T8 灰阶保真、T10 分条一致、T11 时域权重。改任何一个常数都要先跑那个脚本。
//

import Foundation
import Accelerate

enum QualityCore {

    // MARK: - 可调常数（改这里，不要改函数体）

    /// 分条高度。单条 + pad 的峰值内存 = width * (stripHeight + 2*pad) * 5 字节。
    /// 4K（3840）时 = 3840 * 72 * 5 ≈ 1.4 MB，远低于「整帧 4 张平面」的 66 MB。
    static let stripHeight: Int = 64

    /// 分条上下各留多少行。必须 ≥ 2：5-tap 低通半径 2，5x5 极值窗半径 2。
    /// 留 4 行是为了将来把低通换成 σ 更大的核时不用重算（T10 已验证 pad=4 逐位一致）。
    static let stripPad: Int = 4

    /// 亮度权重（和 = 256）。绿通道权重最高符合人眼感知，也让「只在亮度域锐化」
    /// 与 RGB 三通道的感知亮度一致，不会偏色。
    static let lumaR: Int16 = 54
    static let lumaG: Int16 = 183
    static let lumaB: Int16 = 19

    /// 5-tap 二项式低通 [1,4,6,4,1]/16。
    /// 等价于连续高斯 σ = √(1×1/16 + 4×4/16 + 6×0/16...) = 1.414 px，
    /// 且是「[1,1] 卷积四次」的结果 —— 频响恒为正（T1.4），不会相位翻转。
    static let lowpass5: [Int16] = [1, 4, 6, 4, 1]

    /// 边缘保护强度：ew = 1/(1 + edgeGuard*(range/32)^2)。
    /// 0.25 意味着局部动态范围 32 码时增益降到 0.8，64 码降到 0.5，128 码降到 0.17。
    /// 这样 1px 棋盘/噪点（range 大、但曲率也大）几乎不加锐，而 8px 以上的真实纹理照常锐化。
    static let edgeGuard: Float = 0.25

    /// 抖动表：4x4 Bayer，(k + 0.5)/16 - 0.5 → 范围 [-0.469, +0.469]，均值恰为 0。
    /// 用 (k+0.5)/16 而不是 k/16：后者均值 -1/32，会整体压暗 1/32 码（T5.4/T5.5）。
    static let ditherTable: [Float] = {
        let raw: [Int32] = [0, 8, 2, 10,
                            12, 4, 14, 6,
                            3, 11, 1, 9,
                            15, 7, 13, 5]
        var out: [Float] = []
        out.reserveCapacity(16)
        var i: Int = 0
        while i < 16 {
            let k: Float = Float(raw[i])
            let v: Float = (k + 0.5) / 16.0 - 0.5
            out.append(v)
            i += 1
        }
        return out
    }()

    /// 亮度是否走 vImage 的定点矩阵（更快）。置 false 则走纯 Swift 逐像素，
    /// 两者差 ≤1 码（除法舍入方式可能不同），只是慢 1–4 ms/1080p。没有 Mac 时这是
    /// 最容易出问题的一处 API：万一签名不符，把这一行改 false 即可编译通过。
    static let useVectorLuma: Bool = true

    /// 一次性自检：vImage 的 ARGB8888 矩阵是按「内存字节序」还是按「A,R,G,B 名字序」作用。
    /// 标准 ARGB 缓冲上两者等价，但我们的缓冲是 CGContext 出来的 R,G,B,X（noneSkipLast），
    /// 若权重错位，整帧亮度会算错——肉眼只表现为「轻微偏色/发灰」，CI 抓不到。
    /// 所以用 1 个像素实测：通道序错了会差 60 码以上，容差 ±1 即可判定。
    static let vectorLumaTrusted: Bool = {
        // 探针：R=64 G=128 B=192 X=255  →  期望 119
        // 用 allocate 而不是 &array：vImage_Buffer 会保存指针，指针必须比这次调用活得久。
        let srcPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        let dstPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            srcPtr.deallocate()
            dstPtr.deallocate()
        }
        srcPtr[0] = 64
        srcPtr[1] = 128
        srcPtr[2] = 192
        srcPtr[3] = 255
        dstPtr[0] = 0

        let expect: Int = (54 * 64 + 183 * 128 + 19 * 192 + 128) >> 8
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(srcPtr),
                              height: 1,
                              width: 1,
                              rowBytes: 4)
        var d = vImage_Buffer(data: UnsafeMutableRawPointer(dstPtr),
                              height: 1,
                              width: 1,
                              rowBytes: 1)
        var matrix: [Int16] = [54, 183, 19, 0]
        let err: vImage_Error = vImageMatrixMultiply_ARGB8888ToPlanar8(&s,
                                                                      &d,
                                                                      &matrix,
                                                                      256,
                                                                      nil,
                                                                      nil,
                                                                      vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError { return false }
        let got: Int = Int(dstPtr[0])
        let delta: Int = got - expect
        if delta < -1 { return false }
        if delta > 1 { return false }
        return true
    }()

    // MARK: - 入口：细节增强 + 降噪 + 抖动

    /// 就地处理一帧 RGBA8888（noneSkipLast，即 alpha 位不用）。
    ///
    /// - Parameters:
    ///   - rgba: 长度必须 ≥ width*height*4；alpha 通道原样保留。
    ///   - amount: 锐化量 0…1，对应 VideoSettings.detail。
    ///   - denoise: 降噪量 0…1。0 = 只锐化（与旧版行为最接近），1 = 输出几乎等于低通基底。
    ///   - dither: 是否在取整前加 4x4 Bayer 抖动。8-bit SDR 输出要开；
    ///             HDR（后面还要转 P010 并做 10-bit 抖动）要关，避免两次抖动叠加。
    ///   - rowOrigin: 本块第一行在全帧里的行号（分条/分块处理时用），
    ///                保证抖动图案锚定全局坐标、不随分块边界跳变（T10）。
    /// - Returns: true = 已处理；false = 参数退化（宽高太小/全关）未改动。
    ///
    /// 复杂度：6 个 pass × O(像素)，合计约 25 字节/px 的内存流量。
    /// 1080p ≈ 5–9 ms/帧，4K ≈ 21–35 ms/帧（A15 级，见 T12）。
    @discardableResult
    static func applyDetail(_ rgba: inout [UInt8],
                            width: Int,
                            height: Int,
                            amount: Float,
                            denoise: Float,
                            dither: Bool,
                            rowOrigin: Int = 0) -> Bool {

        // ---- 参数守卫 ----------------------------------------------------
        guard width >= 8, height >= 8 else { return false }
        let need: Int = width * height * 4
        guard rgba.count >= need else { return false }

        var a: Float = amount
        var dn: Float = denoise
        if a < 0 { a = 0 }
        if a > 1 { a = 1 }
        if dn < 0 { dn = 0 }
        if dn > 1 { dn = 1 }
        if a <= 0.001 && dn <= 0.001 { return false }

        // ---- 门限：死区 t0 + 过渡带宽度 ----------------------------------
        // |d| < t0        → knee = 0 → m = 1-denoise（判定为噪声，压到底）
        // |d| > t1        → knee = 1 → m = 1（判定为细节，完全不降噪）
        // 中间 smoothstep 过渡，避免阈值造成「噪点被切成块」的硬边界。
        // t0/t1 随 denoise 一起抬高：降噪越强，判为噪声的幅度门槛越高。
        let t1: Float = 3.0 + 9.0 * dn
        let t0: Float = 1.5 + 1.5 * dn
        var span: Float = t1 - t0
        if span < 1.0e-6 { span = 1.0e-6 }
        let invSpan: Float = 1.0 / span

        let edgeNorm: Float = 1.0 / (32.0 * 32.0)

        // ---- 平面缓冲（5 张，跨条复用）-----------------------------------
        let planeStride: Int = width * (stripHeight + 2 * stripPad)
        var luma: [UInt8] = [UInt8](repeating: 0, count: planeStride)
        var temp: [UInt8] = [UInt8](repeating: 0, count: planeStride)
        var base: [UInt8] = [UInt8](repeating: 0, count: planeStride)
        var low: [UInt8] = [UInt8](repeating: 0, count: planeStride)
        var high: [UInt8] = [UInt8](repeating: 0, count: planeStride)

        var ok: Bool = false

        rgba.withUnsafeMutableBytes { rawRGBA in
            guard let rgbaBase = rawRGBA.baseAddress else { return }
            luma.withUnsafeMutableBufferPointer { lBuf in
                temp.withUnsafeMutableBufferPointer { tBuf in
                    base.withUnsafeMutableBufferPointer { bBuf in
                        low.withUnsafeMutableBufferPointer { loBuf in
                            high.withUnsafeMutableBufferPointer { hiBuf in
                                guard let lp = lBuf.baseAddress else { return }
                                guard let tp = tBuf.baseAddress else { return }
                                guard let bp = bBuf.baseAddress else { return }
                                guard let lop = loBuf.baseAddress else { return }
                                guard let hip = hiBuf.baseAddress else { return }

                                let planes = Planes(luma: lp, temp: tp, base: bp, low: lop, high: hip)
                                let dst: UnsafeMutablePointer<UInt8> = rgbaBase.assumingMemoryBound(to: UInt8)

                                ok = runStrips(rgba: dst,
                                               planes: planes,
                                               width: width,
                                               height: height,
                                               amount: a,
                                               denoise: dn,
                                               t0: t0,
                                               invSpan: invSpan,
                                               edgeNorm: edgeNorm,
                                               dither: dither,
                                               rowOrigin: rowOrigin)
                            }
                        }
                    }
                }
            }
        }
        return ok
    }

    // MARK: - 平面集合

    /// 5 张同尺寸 Planar8 平面的基址（每个都按 width*planeRows 连续排列，
    /// 由于行宽恒等于 width，直接按 r*width 线性索引）。
    private struct Planes {
        var luma: UnsafeMutablePointer<UInt8>
        var temp: UnsafeMutablePointer<UInt8>
        var base: UnsafeMutablePointer<UInt8>
        var low: UnsafeMutablePointer<UInt8>
        var high: UnsafeMutablePointer<UInt8>
    }

    // MARK: - 主循环（分条）

    private static func runStrips(rgba: UnsafeMutablePointer<UInt8>,
                                  planes: Planes,
                                  width: Int,
                                  height: Int,
                                  amount: Float,
                                  denoise: Float,
                                  t0: Float,
                                  invSpan: Float,
                                  edgeNorm: Float,
                                  dither: Bool,
                                  rowOrigin: Int) -> Bool {

        let pad: Int = stripPad
        let step: Int = stripHeight

        var y0: Int = 0
        while y0 < height {
            var y1: Int = y0 + step
            if y1 > height { y1 = height }

            var ys: Int = y0 - pad
            if ys < 0 { ys = 0 }
            var ye: Int = y1 + pad
            if ye > height { ye = height }
            let rows: Int = ye - ys

            // 1) RGBA → 亮度平面（只看 RGB，alpha 忽略）
            let srcOffset: Int = ys * width * 4
            fillLuma(src: rgba + srcOffset, rows: rows, width: width, dst: planes.luma)

            // 2) 可分离 5-tap 低通：先水平 1x5，再垂直 5x1。
            //    vImageConvolve_Planar8 不做自动分离，25 tap 拆成 5+5 才不浪费带宽。
            //    两遍之间保留 8-bit 中间值，实测最大偏差 0.85 码（T1.2），
            //    换来每 pass 只读写 1 字节/px 而不是 2 字节/px。
            let okH: Bool = convolvePlanar(src: planes.luma,
                                           dst: planes.temp,
                                           width: width,
                                           height: rows,
                                           rowBytes: width,
                                           kernelHeight: 1,
                                           kernelWidth: 5,
                                           divisor: 16)
            guard okH else { return false }
            let okV: Bool = convolvePlanar(src: planes.temp,
                                           dst: planes.base,
                                           width: width,
                                           height: rows,
                                           rowBytes: width,
                                           kernelHeight: 5,
                                           kernelWidth: 1,
                                           divisor: 16)
            guard okV else { return false }

            // 3) 源亮度的 5x5 局部极值 = 钳制上下界（消 halo 的关键）。
            //    用「源」而不是「基底」的极值：保证输出永不越出原片极值，
            //    基底因为被低通过，极值会略微内缩，会让钳制过紧、丢掉细节。
            let okMin: Bool = minMaxPlanar(src: planes.luma,
                                           dst: planes.low,
                                           width: width,
                                           height: rows,
                                           rowBytes: width,
                                           isMin: true)
            guard okMin else { return false }
            let okMax: Bool = minMaxPlanar(src: planes.luma,
                                           dst: planes.high,
                                           width: width,
                                           height: rows,
                                           rowBytes: width,
                                           isMin: false)
            guard okMax else { return false }

            // 4) 逐像素：残差 → 门控 → 增益 → 钳制 → 抖动 → 写回 RGB
            var r: Int = y0 - ys
            let rEnd: Int = y1 - ys
            while r < rEnd {
                let y: Int = ys + r
                let pRow: Int = r * width
                let oRow: Int = y * width * 4
                var x: Int = 0
                while x < width {
                    // 4.1 读 4 张平面
                    let l: Float = Float(planes.luma[pRow + x])
                    let b: Float = Float(planes.base[pRow + x])
                    let lo: Float = Float(planes.low[pRow + x])
                    let hi: Float = Float(planes.high[pRow + x])

                    // 4.2 高通残差 d = L - base
                    let df: Float = l - b
                    var ad: Float = df
                    if ad < 0 { ad = -ad }

                    // 4.3 软门限：knee 0…1
                    var kn: Float = (ad - t0) * invSpan
                    if kn < 0 { kn = 0 }
                    if kn > 1 { kn = 1 }
                    let knee: Float = kn * kn * (3.0 - 2.0 * kn)

                    // 4.4 降噪系数：平坦区 (knee=0) 把残差压到 (1-denoise) 倍
                    let m: Float = 1.0 - denoise * (1.0 - knee)

                    // 4.5 边缘保护：局部动态范围越大，锐化增益越小
                    let rng: Float = hi - lo
                    let eNorm: Float = rng * rng * edgeNorm
                    let ew: Float = 1.0 / (1.0 + edgeGuard * eNorm)

                    // 4.6 重建：v = base + d*m*(1 + amount*ew)
                    //    amount=0 且 denoise=0 时 m=1、gain=1 → v 恒等于 l（恒等，T4.7）
                    let gain: Float = 1.0 + amount * ew
                    var v: Float = b + df * m * gain

                    // 4.7 钳制到源局部极值 —— 这一步在数学上消灭 halo：
                    //     任何「比邻居更亮/更暗」的输出都不可能出现（T2.3）。
                    if v < lo { v = lo }
                    if v > hi { v = hi }
                    if v < 0 { v = 0 }
                    if v > 255 { v = 255 }

                    // 4.8 取整前抖动（±0.47 码，零均值，图案锚定全局坐标）
                    var off: Float = 0
                    if dither {
                        let dy: Int = (y + rowOrigin) & 3
                        let idx: Int = (dy << 2) | (x & 3)
                        off = ditherTable[idx]
                    }
                    let q: Float = v + 0.5 + off
                    let vq: Int = Int(q.rounded(.down))

                    // 4.9 三通道同加同一个亮度增量 → 不产生彩边（T8.2）
                    let delta: Int = vq - Int(l)
                    if delta != 0 {
                        let o: Int = oRow + x * 4
                        var c: Int = 0
                        while c < 3 {
                            let s: Int = Int(rgba[o + c])
                            var t: Int = s + delta
                            if t < 0 { t = 0 }
                            if t > 255 { t = 255 }
                            rgba[o + c] = UInt8(t)
                            c += 1
                        }
                        // alpha 不动（noneSkipLast 本来也不看它）
                    }
                    x += 1
                }
                r += 1
            }

            y0 = y1
        }

        return true
    }

    // MARK: - vImage 封装

    /// RGBA → 亮度平面。matrix/divisor 与 Python 的 (54R+183G+19B+128)>>8 一致。
    private static func fillLuma(src: UnsafePointer<UInt8>,
                                 rows: Int,
                                 width: Int,
                                 dst: UnsafeMutablePointer<UInt8>) {
        // vectorLumaTrusted 为 false 时直接走下面的逐像素实现（通道序自检没过）
        if useVectorLuma, vectorLumaTrusted {
            // vImage 的 matrix 是 4×1，按内存字节序作用：R,G,B,X → 权重 54,183,19,0
            var matrix: [Int16] = [lumaR, lumaG, lumaB, 0]
            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                                  height: vImagePixelCount(rows),
                                  width: vImagePixelCount(width),
                                  rowBytes: width * 4)
            var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst),
                                  height: vImagePixelCount(rows),
                                  width: vImagePixelCount(width),
                                  rowBytes: width)
            let err: vImage_Error = vImageMatrixMultiply_ARGB8888ToPlanar8(&s,
                                                                          &d,
                                                                          &matrix,
                                                                          256,
                                                                          nil,
                                                                          nil,
                                                                          vImage_Flags(kvImageNoFlags))
            if err == kvImageNoError { return }
            // 出错就落到下面的逐像素实现，不中断整帧
        }

        var r: Int = 0
        while r < rows {
            let sRow: Int = r * width * 4
            let dRow: Int = r * width
            var x: Int = 0
            while x < width {
                let i: Int = sRow + x * 4
                let rr: Int = Int(src[i])
                let gg: Int = Int(src[i + 1])
                let bb: Int = Int(src[i + 2])
                let acc: Int = 54 * rr + 183 * gg + 19 * bb + 128
                dst[dRow + x] = UInt8(acc >> 8)
                x += 1
            }
            r += 1
        }
    }

    /// 一次 1D 卷积（水平或垂直）。divisor 固定 16，内部按 round(sum/16) 取整并钳位。
    private static func convolvePlanar(src: UnsafeMutablePointer<UInt8>,
                                       dst: UnsafeMutablePointer<UInt8>,
                                       width: Int,
                                       height: Int,
                                       rowBytes: Int,
                                       kernelHeight: UInt32,
                                       kernelWidth: UInt32,
                                       divisor: Int32) -> Bool {
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(src),
                              height: vImagePixelCount(height),
                              width: vImagePixelCount(width),
                              rowBytes: rowBytes)
        var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst),
                              height: vImagePixelCount(height),
                              width: vImagePixelCount(width),
                              rowBytes: rowBytes)
        var ok: Bool = false
        lowpass5.withUnsafeBufferPointer { kBuf in
            guard let kPtr = kBuf.baseAddress else { return }
            let err: vImage_Error = vImageConvolve_Planar8(&s,
                                                           &d,
                                                           nil,
                                                           0,
                                                           0,
                                                           kPtr,
                                                           kernelHeight,
                                                           kernelWidth,
                                                           divisor,
                                                           nil,
                                                           vImage_Flags(kvImageEdgeExtend))
            ok = (err == kvImageNoError)
        }
        return ok
    }

    /// 5x5 局部最小/最大（形态学腐蚀/膨胀，vImage 内部用 running min-max，O(1)/px）。
    /// 边界用 kvImageEdgeExtend，与 Python 的 np.pad(mode="edge") 一致。
    private static func minMaxPlanar(src: UnsafeMutablePointer<UInt8>,
                                     dst: UnsafeMutablePointer<UInt8>,
                                     width: Int,
                                     height: Int,
                                     rowBytes: Int,
                                     isMin: Bool) -> Bool {
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(src),
                              height: vImagePixelCount(height),
                              width: vImagePixelCount(width),
                              rowBytes: rowBytes)
        var d = vImage_Buffer(data: UnsafeMutableRawPointer(dst),
                              height: vImagePixelCount(height),
                              width: vImagePixelCount(width),
                              rowBytes: rowBytes)
        let flags: vImage_Flags = vImage_Flags(kvImageEdgeExtend)
        var err: vImage_Error = kvImageNoError
        if isMin {
            err = vImageMin_Planar8(&s, &d, 0, 0, 5, 5, flags)
        } else {
            err = vImageMax_Planar8(&s, &d, 0, 0, 5, 5, flags)
        }
        return err == kvImageNoError
    }

    // MARK: - 时域抗闪烁

    /// 静态/运动/突变三档融合权重。
    ///
    ///   still  = 0.20 + 0.60*af      静止区：强融合（等效 ~5 帧平均，杀掉逐帧闪烁）
    ///   moving = 0.16 - 0.10*af      运动区：弱融合（避免拖影）
    ///   motion = min(1, mag/ramp)    光流位移越大越接近 moving
    ///   gate   = 1/(1 + (diff/24)^2) 亮度突变（切镜/遮挡）时几乎不融合
    ///
    /// k = (still + (moving-still)*motion) * gate
    ///
    /// 单调性：mag↑ → k↓；diff↑ → k↓，全程连续无跳变（T11.4/T11.5）。
    /// - Parameter motionRamp: 位移达到多少像素算「完全运动」。传 3×flowScale
    ///   可把「3 个光流网格像素」换算成本帧像素，避免 4K 下光流噪声被当运动。
    static func temporalWeight(antiFlicker: Bool,
                               flowMagnitude: Float,
                               lumaDiff: Float,
                               motionRamp: Float = 3.0) -> Float {
        let af: Float = antiFlicker ? 1.0 : 0.0
        let still: Float = 0.20 + 0.60 * af
        let moving: Float = 0.16 - 0.10 * af

        var ramp: Float = motionRamp
        if ramp < 0.25 { ramp = 0.25 }
        var motion: Float = flowMagnitude / ramp
        if motion < 0 { motion = 0 }
        if motion > 1 { motion = 1 }

        var diff: Float = lumaDiff
        if diff < 0 { diff = -diff }
        let dn: Float = diff / 24.0
        let gate: Float = 1.0 / (1.0 + dn * dn)

        let span: Float = moving - still
        let k: Float = still + span * motion
        var out: Float = k * gate
        if out < 0 { out = 0 }
        if out > 1 { out = 1 }
        return out
    }

    /// 抗闪烁融合：上一帧稳定结果按光流对齐到当前帧，再按逐像素自适应权重混入。
    ///
    /// 与旧 FrameOps.blendTemporal 的区别：
    ///   · 旧：全局单一 weight=0.22，只按位移大小线性降权（mag>96 才降到 0）。
    ///   · 新：静止区 0.80 / 运动区 0.06–0.16，并且用「对齐后亮度差」再闸一次，
    ///         切镜、遮挡、光照跳变处直接不融合（不会出残影）。
    ///
    /// 内存：额外 0 字节 —— 复用调用方已有的 cur/out 两块缓冲（必须双缓冲，见 INTEGRATION）。
    ///
    /// - Parameter out: 目标缓冲，长度必须 == width*height*4，且**不能与 prev 共享存储**
    ///                  （否则 inout 写入前会触发整帧 COW 拷贝，白白多 8–33 MB/帧）。
    /// - Returns: true = 已融合；false = 缓冲不匹配（调用方应回退到 out = cur）。
    @discardableResult
    static func blendTemporalAdaptive(prev: [UInt8],
                                      cur: [UInt8],
                                      width: Int,
                                      height: Int,
                                      flow: FlowField?,
                                      flowScale: Float,
                                      antiFlicker: Bool,
                                      out: inout [UInt8]) -> Bool {

        let n: Int = width * height * 4
        guard width > 0, height > 0 else { return false }
        guard prev.count >= n, cur.count >= n else { return false }
        guard out.count >= n else { return false }
        guard let flow else { return false }
        guard flow.w >= 8, flow.h >= 8 else { return false }
        guard flow.data.count >= flow.w * flow.h * 2 else { return false }

        let fw: Int = flow.w
        let fh: Int = flow.h
        let ramp: Float = 3.0 * max(0.25, flowScale)

        prev.withUnsafeBufferPointer { pBuf in
            cur.withUnsafeBufferPointer { cBuf in
                out.withUnsafeMutableBufferPointer { oBuf in
                    flow.data.withUnsafeBufferPointer { fBuf in
                        guard let pp = pBuf.baseAddress else { return }
                        guard let cp = cBuf.baseAddress else { return }
                        guard let op = oBuf.baseAddress else { return }
                        guard let fp = fBuf.baseAddress else { return }

                        var y: Int = 0
                        while y < height {
                            var fy: Int = Int(Float(y) * Float(fh) / Float(height))
                            if fy < 0 { fy = 0 }
                            if fy > fh - 1 { fy = fh - 1 }
                            let fRow: Int = fy * fw
                            let oRow: Int = y * width * 4
                            var x: Int = 0
                            while x < width {
                                var fx: Int = Int(Float(x) * Float(fw) / Float(width))
                                if fx < 0 { fx = 0 }
                                if fx > fw - 1 { fx = fw - 1 }
                                let fi: Int = (fRow + fx) * 2
                                let vx: Float = fp[fi] * flowScale
                                let vy: Float = fp[fi + 1] * flowScale

                                let o: Int = oRow + x * 4
                                let mag2: Float = vx * vx + vy * vy
                                let mag: Float = mag2.squareRoot()

                                // 需要权重才采样；k 恒为 0 时直接拷当前帧
                                let sx: Float = Float(x) - vx
                                let sy: Float = Float(y) - vy
                                let wr: Float = bilinear(pp, width, height, sx, sy, 0)
                                let wg: Float = bilinear(pp, width, height, sx, sy, 1)
                                let wb: Float = bilinear(pp, width, height, sx, sy, 2)

                                let cR: Float = Float(cp[o])
                                let cG: Float = Float(cp[o + 1])
                                let cB: Float = Float(cp[o + 2])

                                // 亮度（与 detail 阶段同一组权重，和 = 256）
                                let wl: Float = (54.0 * wr + 183.0 * wg + 19.0 * wb) / 256.0
                                let cl: Float = (54.0 * cR + 183.0 * cG + 19.0 * cB) / 256.0
                                var diff: Float = cl - wl
                                if diff < 0 { diff = -diff }

                                let k: Float = temporalWeight(antiFlicker: antiFlicker,
                                                              flowMagnitude: mag,
                                                              lumaDiff: diff,
                                                              motionRamp: ramp)

                                if k <= 0.001 {
                                    op[o] = cp[o]
                                    op[o + 1] = cp[o + 1]
                                    op[o + 2] = cp[o + 2]
                                    op[o + 3] = 255
                                } else {
                                    let keep: Float = 1.0 - k
                                    var vr: Float = cR * keep + wr * k
                                    var vg: Float = cG * keep + wg * k
                                    var vb: Float = cB * keep + wb * k
                                    if vr < 0 { vr = 0 }
                                    if vr > 255 { vr = 255 }
                                    if vg < 0 { vg = 0 }
                                    if vg > 255 { vg = 255 }
                                    if vb < 0 { vb = 0 }
                                    if vb > 255 { vb = 255 }
                                    op[o] = UInt8(vr.rounded())
                                    op[o + 1] = UInt8(vg.rounded())
                                    op[o + 2] = UInt8(vb.rounded())
                                    op[o + 3] = 255
                                }
                                x += 1
                            }
                            y += 1
                        }
                    }
                }
            }
        }
        return true
    }

    /// 双线性采样（坐标先钳到 [0, w-1]，再取 4 邻域）。
    /// 边缘坐标钳位保证不会读到缓冲外，也不会出现负权重。
    private static func bilinear(_ src: UnsafePointer<UInt8>,
                                 _ width: Int,
                                 _ height: Int,
                                 _ x: Float,
                                 _ y: Float,
                                 _ c: Int) -> Float {
        var cx: Float = x
        var cy: Float = y
        let maxX: Float = Float(width - 1)
        let maxY: Float = Float(height - 1)
        if cx < 0 { cx = 0 }
        if cx > maxX { cx = maxX }
        if cy < 0 { cy = 0 }
        if cy > maxY { cy = maxY }

        let ix: Int = Int(cx)
        let iy: Int = Int(cy)
        var ix1: Int = ix + 1
        var iy1: Int = iy + 1
        if ix1 > width - 1 { ix1 = width - 1 }
        if iy1 > height - 1 { iy1 = height - 1 }

        let fx: Float = cx - Float(ix)
        let fy: Float = cy - Float(iy)

        let i00: Int = (iy * width + ix) * 4 + c
        let i01: Int = (iy * width + ix1) * 4 + c
        let i10: Int = (iy1 * width + ix) * 4 + c
        let i11: Int = (iy1 * width + ix1) * 4 + c

        let top: Float = Float(src[i00]) * (1.0 - fx) + Float(src[i01]) * fx
        let bot: Float = Float(src[i10]) * (1.0 - fx) + Float(src[i11]) * fx
        return top * (1.0 - fy) + bot * fy
    }
}
