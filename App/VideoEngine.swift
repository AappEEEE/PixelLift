import AVFoundation
import Accelerate
import CoreImage
import CoreML
import CryptoKit
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import Vision
import VideoToolbox

// MARK: - 数据模型

struct VideoClip: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var name: String
    var renderWidth: Int
    var renderHeight: Int
    var duration: Double
    var fps: Double
    var fileMB: Int

    var sizeLabel: String { "\(renderWidth) × \(renderHeight)" }
    var durationLabel: String {
        let total = Int(duration.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
    var fpsLabel: String { String(format: "%.0f fps", fps) }
}

enum VideoMode: String, CaseIterable, Identifiable {
    case fast
    case ai

    var id: String { rawValue }
    var title: String { self == .fast ? "快速放大" : "AI 逐帧超分" }
    var detail: String {
        self == .fast
            ? "CoreGraphics 高质量重采样，几乎实时"
            : "每帧走 Real-ESRGAN 分块推理，慢，但细节最好"
    }
}

/// 补帧：用光流在相邻两帧之间合成中间帧
enum InterpMode: String, CaseIterable, Identifiable {
    case off
    case double
    case quad

    var id: String { rawValue }
    var factor: Int {
        switch self {
        case .off: return 1
        case .double: return 2
        case .quad: return 4
        }
    }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .double: return "×2"
        case .quad: return "×4"
        }
    }
}

/// 慢动作：把时间轴拉长，多出来的采样点全部由光流补出来
enum SlowMode: String, CaseIterable, Identifiable {
    case normal
    case half
    case quarter

    var id: String { rawValue }
    var factor: Double {
        switch self {
        case .normal: return 1
        case .half: return 0.5
        case .quarter: return 0.25
        }
    }
    var title: String {
        switch self {
        case .normal: return "原速"
        case .half: return "0.5×"
        case .quarter: return "0.25×"
        }
    }
}

/// 动态模糊：按快门角在曝光窗内做时间积分（强度由快门角决定，不再分「轻/强」）
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
    /// 降噪量 0…1：只在亮度残差的小幅度区间生效，越大越把噪点压向低频基底。0 = 只锐化。
    var denoise: Double
    /// 逐像素自适应抗闪烁（仅 AI 逐帧超分时生效）。关掉后帧间抖动会明显。
    var antiFlicker: Bool
}

/// MLModel 不是 Sendable，用盒子跨线程传
final class ModelBox: @unchecked Sendable {
    let model: MLModel?
    init(_ model: MLModel?) { self.model = model }
}

/// 输出 BT.2100 HLG / BT.2020 的 10-bit HEVC 视频。映射在编码前的线性光 RGB 上完成。
enum SDRToHDR {
    /// IEC 61966-2-1 sRGB / BT.709 OETF 逆变换（视频帧经 CGColorSpace.sRGB 解码后仍是 gamma 编码值）。
    @inline(__always)
    static func eotf(_ x: Float) -> Float {
        let v = max(0, x)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// HLG OETF（BT.2100）。线性场景值 -> HLG 非线性编码值。
    @inline(__always)
    static func hlgOETF(_ e: Float) -> Float {
        let a: Float = 0.17883277
        let b: Float = 0.28466892
        let c: Float = 0.55991073
        let v = max(0, e)
        return v <= 1.0 / 12.0 ? sqrt(3 * v) : a * log(12 * v - b) + c
    }

    /// Rec.709 primaries -> Rec.2020 primaries，输入输出均为线性 RGB。
    @inline(__always)
    static func rec709To2020(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let rr = 0.627404 * r + 0.329283 * g + 0.043313 * b
        let gg = 0.069097 * r + 0.919540 * g + 0.011362 * b
        let bb = 0.016391 * r + 0.088013 * g + 0.895595 * b
        return (rr, gg, bb)
    }

    /// 变换 Rec.709 SDR RGB8 至 HLG 编码的 Rec.2020 R′G′B′ 分量，可离线数值测试。
    static func convertLinear(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8,
                              strength: Double) -> (Float, Float, Float) {
        let r = eotfTable[Int(r8)]
        let g = eotfTable[Int(g8)]
        let b = eotfTable[Int(b8)]
        let y = max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
        let amount = Float(min(1, max(0, strength)))
        let u = min(1, max(0, (y - 0.70) / 0.30))
        let knee = u * u * (3 - 2 * u)
        let mapped = y + amount * 0.30 * knee * knee
        let gain = (y > 1e-6 ? mapped / y : 1) * 0.75
        let (r2020, g2020, b2020) = rec709To2020(r * gain, g * gain, b * gain)
        return (hlgFast(r2020), hlgFast(g2020), hlgFast(b2020))
    }

    /// 256 个 8-bit 码值对应的线性光，避免逐像素做 pow。
    static let eotfTable: [Float] = (0...255).map { eotf(Float($0) / 255.0) }

    /// HLG OETF 查表（线性光 0…1.5，8192 段 + 线性插值），逐像素比 log/sqrt 快一个数量级。
    private static let hlgTableMax: Float = 1.5
    static let hlgTable: [Float] = {
        let n = 8192
        return (0...n).map { hlgOETF(hlgTableMax * Float($0) / Float(n)) }
    }()

    @inline(__always)
    static func hlgFast(_ e: Float) -> Float {
        let v = max(0, e)
        guard v < hlgTableMax else { return hlgOETF(v) }
        let n = Float(hlgTable.count - 1)
        let pos = v / hlgTableMax * n
        let i = Int(pos)
        let f = pos - Float(i)
        return hlgTable[i] * (1 - f) + hlgTable[i + 1] * f
    }

    /// 将 SDR RGB8 转成 HLG/Rec.2020 10-bit video-range YCbCr，写入 P010 pixel buffer。
    /// P010 存储为 10-bit 左对齐 16-bit words；Y 范围 64…940，Cb/Cr 64…960。
    static func writeP010(_ rgba: [UInt8], width: Int, height: Int,
                          strength: Double, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              rgba.count >= width * height * 4,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / MemoryLayout<UInt16>.stride
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / MemoryLayout<UInt16>.stride
        guard yStride >= width, uvStride >= width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) >= height,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) >= height / 2 else { return false }
        let yPlane = yBase.assumingMemoryBound(to: UInt16.self)
        let uvPlane = uvBase.assumingMemoryBound(to: UInt16.self)
        let dither: (Int, Int) -> Float = { x, y in
            // 固定 4×4 Bayer pattern，幅度约 0.5 个 10-bit code，降低量化色带而不引入时域闪烁。
            let matrix: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
            return (matrix[(y & 3) * 4 + (x & 3)] / 16.0 - 0.5) / 876.0
        }
        @inline(__always) func clamp(_ value: Float, _ low: Float, _ high: Float) -> UInt16 {
            UInt16(min(high, max(low, value)).rounded()) << 6
        }
        @inline(__always) func rgb2020(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let i = (y * width + x) * 4
            return SDRToHDR.convertLinear(rgba[i], rgba[i + 1], rgba[i + 2], strength: strength)
        }
        @inline(__always) func chroma(_ value: Float, _ limit: Float) -> Float {
            min(limit, max(-limit, value))
        }
        for y in 0..<height {
            for x in 0..<width {
                let (rPrime, gPrime, bPrime) = rgb2020(x, y)
                let yPrime = 0.2627 * rPrime + 0.6780 * gPrime + 0.0593 * bPrime
                yPlane[y * yStride + x] = clamp(64 + 876 * yPrime + dither(x, y) * 876, 64, 940)
            }
        }
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                var cb: Float = 0
                var cr: Float = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let (rPrime, gPrime, bPrime) = rgb2020(x + dx, y + dy)
                        let yPrime = 0.2627 * rPrime + 0.6780 * gPrime + 0.0593 * bPrime
                        cb += chroma((bPrime - yPrime) / (2 * (1 - 0.0593)), 0.5)
                        cr += chroma((rPrime - yPrime) / (2 * (1 - 0.2627)), 0.5)
                    }
                }
                let chromaOffset = (y / 2) * uvStride + x
                let u = 512 + 896 * (cb / 4)
                let v = 512 + 896 * (cr / 4)
                uvPlane[chromaOffset] = clamp(u, 64, 960)
                uvPlane[chromaOffset + 1] = clamp(v, 64, 960)
            }
        }
        return true
    }
}

enum VideoRenderError: LocalizedError {
    case noVideoTrack
    case readerSetup
    case writerSetup
    case pixelBuffer
    case cancelledInternally
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频轨道"
        case .readerSetup: return "读取器初始化失败（可能是编码不支持）"
        case .writerSetup: return "写入器初始化失败"
        case .pixelBuffer: return "像素缓冲创建失败"
        case .cancelledInternally: return "已取消"
        case .writeFailed(let m): return m
        }
    }
}

// MARK: - 像素工具

enum Pix {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func cgImage(from buffer: CVImageBuffer) -> CGImage? {
        let ci = CIImage(cvImageBuffer: buffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    static func rgba(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? out : nil
    }

    static func cgImage(rgba buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = buffer
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    static func resized(_ cg: CGImage, width: Int, height: Int) -> CGImage? {
        if cg.width == width && cg.height == height { return cg }
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// 把 CGImage 画进 CVPixelBuffer（输出 BGRA，供编码器直接吃）
    @discardableResult
    static func draw(_ cg: CGImage, into pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
}

// MARK: - 光流补帧

struct FlowField {
    var w: Int
    var h: Int
    var data: [Float]   // 每个像素 2 个分量（dx, dy），单位=光流图层像素
}

enum FrameOps {
    /// 用 Vision 的 dense optical flow 求 a→b 的位移场。
    /// 为控制耗时，先缩到长边 ≤960 再算，位移量在合成时按比例放大。
    static func flow(from a: CGImage, to b: CGImage) -> FlowField? {
        let longEdge = max(a.width, b.width)
        guard longEdge >= 32 else { return nil }
        let k = min(1.0, 960.0 / Double(longEdge))
        let fw = max(24, Int(Double(a.width) * k))
        let fh = max(24, Int(Double(a.height) * k))
        guard let smallA = Pix.resized(a, width: fw, height: fh),
              let smallB = Pix.resized(b, width: fw, height: fh) else { return nil }

        let request = VNGenerateOpticalFlowRequest(targetedCGImage: smallB, options: [:])
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        request.computationAccuracy = .medium
        let handler = VNImageRequestHandler(cgImage: smallA, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNPixelBufferObservation else { return nil }
        let buffer = observation.pixelBuffer

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard w >= 8, h >= 8, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var data = [Float](repeating: 0, count: w * h * 2)
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let i = (y * w + x) * 2
                data[i] = row[x * 2]
                data[i + 1] = row[x * 2 + 1]
            }
        }
        return FlowField(w: w, h: h, data: data)
    }

    /// 双线性取样（RGBx，越界夹取）
    @inline(__always)
    private static func sample(_ src: UnsafeBufferPointer<UInt8>,
                               _ w: Int, _ h: Int,
                               _ x: Float, _ y: Float, _ c: Int) -> Float {
        let cx = min(Float(w - 1), max(0, x))
        let cy = min(Float(h - 1), max(0, y))
        let x0 = Int(cx)
        let y0 = Int(cy)
        let x1 = min(w - 1, x0 + 1)
        let y1 = min(h - 1, y0 + 1)
        let fx = cx - Float(x0)
        let fy = cy - Float(y0)
        let i00 = (y0 * w + x0) * 4 + c
        let i10 = (y0 * w + x1) * 4 + c
        let i01 = (y1 * w + x0) * 4 + c
        let i11 = (y1 * w + x1) * 4 + c
        let top = Float(src[i00]) * (1 - fx) + Float(src[i10]) * fx
        let bottom = Float(src[i01]) * (1 - fx) + Float(src[i11]) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// 合成 t 时刻的中间帧：a 向前推 t，b 向后拉 (1-t)
    static func synthesize(a: [UInt8], b: [UInt8], w: Int, h: Int,
                           flow: FlowField?, flowScale: Float, t: Float,
                           out: inout [UInt8]) {
        let pixelCount = w * h
        guard a.count >= pixelCount * 4, b.count >= pixelCount * 4, out.count >= pixelCount * 4 else { return }
        let oneMinusT = 1 - t

        a.withUnsafeBufferPointer { aBuf in
            b.withUnsafeBufferPointer { bBuf in
                out.withUnsafeMutableBufferPointer { oBuf in
                    if let flow, flow.w >= 8, flow.h >= 8 {
                        flow.data.withUnsafeBufferPointer { fBuf in
                            let fw = flow.w
                            let fh = flow.h
                            for y in 0..<h {
                                let fy = min(fh - 1, Int(Float(y) * Float(fh) / Float(h)))
                                let rowBase = fy * fw
                                for x in 0..<w {
                                    let fx = min(fw - 1, Int(Float(x) * Float(fw) / Float(w)))
                                    let fi = (rowBase + fx) * 2
                                    let vx = fBuf[fi] * flowScale
                                    let vy = fBuf[fi + 1] * flowScale
                                    let ax = Float(x) - t * vx
                                    let ay = Float(y) - t * vy
                                    let bx = Float(x) + oneMinusT * vx
                                    let by = Float(y) + oneMinusT * vy
                                    let o = (y * w + x) * 4
                                    for c in 0..<3 {
                                        let sa = sample(aBuf, w, h, ax, ay, c)
                                        let sb = sample(bBuf, w, h, bx, by, c)
                                        let v = oneMinusT * sa + t * sb
                                        oBuf[o + c] = UInt8(min(255, max(0, v.rounded())))
                                    }
                                    oBuf[o + 3] = 255
                                }
                            }
                        }
                    } else {
                        for i in stride(from: 0, to: pixelCount * 4, by: 4) {
                            for c in 0..<3 {
                                let v = oneMinusT * Float(aBuf[i + c]) + t * Float(bBuf[i + c])
                                oBuf[i + c] = UInt8(min(255, max(0, v.rounded())))
                            }
                            oBuf[i + 3] = 255
                        }
                    }
                }
            }
        }
    }

    /// 抗闪烁时域融合：把上一帧结果按光流对齐到当前帧位置，再按 weight 混入当前帧。
    /// AI 逐帧超分在不同帧之间会给出略微不同的高频细节，混合后高频抖动明显减少；
    /// 位移过大（遮挡/切镜）的位置自动降低权重，避免拖影。
    static func blendTemporal(prev: [UInt8], cur: [UInt8], w: Int, h: Int,
                              flow: FlowField?, flowScale: Float, weight: Float,
                              out: inout [UInt8]) {
        let pixelCount = w * h
        guard prev.count >= pixelCount * 4, cur.count >= pixelCount * 4 else { return }
        if out.count != pixelCount * 4 { out = cur }

        guard let flow, flow.w >= 8, flow.h >= 8, weight > 0 else {
            out = cur
            return
        }
        let fw = flow.w
        let fh = flow.h
        let base = min(1, max(0, weight))
        let maxShift: Float = 96

        prev.withUnsafeBufferPointer { pBuf in
            cur.withUnsafeBufferPointer { cBuf in
                out.withUnsafeMutableBufferPointer { oBuf in
                    flow.data.withUnsafeBufferPointer { fBuf in
                        for y in 0..<h {
                            let fy = min(fh - 1, Int(Float(y) * Float(fh) / Float(h)))
                            let rowBase = fy * fw
                            for x in 0..<w {
                                let fx = min(fw - 1, Int(Float(x) * Float(fw) / Float(w)))
                                let fi = (rowBase + fx) * 2
                                var vx = fBuf[fi] * flowScale
                                var vy = fBuf[fi + 1] * flowScale
                                let mag = (vx * vx + vy * vy).squareRoot()
                                // 遮挡/切镜处光流不可信：位移越大权重越低。
                                let trust = max(0, 1 - mag / maxShift)
                                let k = base * trust
                                let o = (y * w + x) * 4
                                if k <= 0.001 {
                                    oBuf[o] = cBuf[o]
                                    oBuf[o + 1] = cBuf[o + 1]
                                    oBuf[o + 2] = cBuf[o + 2]
                                    oBuf[o + 3] = 255
                                    continue
                                }
                                let sx = Float(x) - vx
                                let sy = Float(y) - vy
                                for c in 0..<3 {
                                    let warped = sample(pBuf, w, h, sx, sy, c)
                                    let v = Float(cBuf[o + c]) * (1 - k) + warped * k
                                    oBuf[o + c] = UInt8(min(255, max(0, v.rounded())))
                                }
                                oBuf[o + 3] = 255
                            }
                        }
                    }
                }
            }
        }
    }

    /// 轻量 USM：等价于 out = src + amount × (src − 3×3 均值)，写成一次卷积在 vImage 里跑。
    /// 纯 Swift 逐像素做 1080p 要几百毫秒一帧，会拖垮「快速放大」的实时感，所以走 Accelerate。
    static func unsharp(_ rgba: inout [UInt8], w: Int, h: Int, amount: Float) {
        guard amount > 0.001, w > 2, h > 2, rgba.count >= w * h * 4 else { return }
        let a = Double(amount)
        let scale = 256.0
        let negValue = (-a / 9.0) * scale
        let centerValue = ((1.0 + a) - a / 9.0) * scale
        let neg: Int16 = Int16(negValue.rounded())
        let center: Int16 = Int16(centerValue.rounded())
        var kernel: [Int16] = [neg, neg, neg, neg, center, neg, neg, neg, neg]
        var background: [UInt8] = [0, 0, 0, 0]
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard let scratch = malloc(raw.count) else { return }
            defer { free(scratch) }
            var src = vImage_Buffer(data: base,
                                    height: vImagePixelCount(h),
                                    width: vImagePixelCount(w),
                                    rowBytes: w * 4)
            var dst = vImage_Buffer(data: scratch,
                                    height: vImagePixelCount(h),
                                    width: vImagePixelCount(w),
                                    rowBytes: w * 4)
            let err = vImageConvolve_ARGB8888(&src, &dst, nil, 0, 0, &kernel, 3, 3, 256,
                                              &background, vImage_Flags(kvImageEdgeExtend))
            if err == kvImageNoError, let out = dst.data {
                memcpy(base, out, raw.count)
            }
        }
    }

    /// out = out * (1 - weight) + src * weight
    static func average(into out: inout [UInt8], from src: [UInt8], weight: Float) {
        let n = min(out.count, src.count)
        guard n > 0 else { return }
        let keep = 1 - weight
        out.withUnsafeMutableBufferPointer { oBuf in
            src.withUnsafeBufferPointer { sBuf in
                for i in stride(from: 0, to: n, by: 4) {
                    for c in 0..<3 {
                        let v = Float(oBuf[i + c]) * keep + Float(sBuf[i + c]) * weight
                        oBuf[i + c] = UInt8(min(255, max(0, v.rounded())))
                    }
                    oBuf[i + 3] = 255
                }
            }
        }
    }
}

// MARK: - 渲染管线（后台线程同步执行）

enum VideoRenderer {
    struct Report: Sendable {
        var frames: Int
        var outputURL: URL
    }

    static func render(source: URL,
                       dest: URL,
                       settings: VideoSettings,
                       box: ModelBox,
                       control: RunControl,
                       timeRange: CMTimeRange? = nil,
                       baseFrames: Int = 0,
                       onFrame: @escaping @Sendable (Int, Int) -> Void,
                       onNotice: @escaping @Sendable (String) -> Void) throws -> Report {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoRenderError.noVideoTrack
        }

        let videoComposition: AVVideoComposition
        do {
            videoComposition = try AVVideoComposition(propertiesOf: asset)
        } catch {
            throw VideoRenderError.readerSetup
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoRenderError.readerSetup
        }
        if let timeRange {
            reader.timeRange = timeRange
        }
        // 分片时解码出的音频仍带源码时间戳，直接写进分片文件会 A/V 不同步、时长错，
        // 所以按片段起点把 PTS 平移到 0。
        let audioOffset = timeRange?.start ?? .zero

        func retimedAudio(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
            guard audioOffset.seconds > 0 else { return buffer }
            var timing = CMSampleTimingInfo()
            timing.duration = CMSampleBufferGetDuration(buffer)
            timing.presentationTimeStamp = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), audioOffset)
            timing.decodeTimeStamp = .invalid
            var output: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                               sampleBuffer: buffer,
                                                               sampleTimingEntryCount: 1,
                                                               sampleTimingArray: &timing,
                                                               sampleBufferOut: &output)
            return status == noErr ? output : nil
        }

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOut.videoComposition = videoComposition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw VideoRenderError.readerSetup }
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        if settings.keepAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOut = out
            }
        }

        try? FileManager.default.removeItem(at: dest)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
        } catch {
            throw VideoRenderError.writerSetup
        }

        let tw = settings.targetWidth
        let th = settings.targetHeight
        // 按 0.08 bit/像素/帧 给码率：1080p60 ≈ 10Mbps，4K30 ≈ 20Mbps。
        // 之前的写法漏乘帧率，4K 只给 6Mbps，画面会被压得很糊。
        let bitsPerPixel = settings.hdrEnabled ? 0.12 : 0.08
        let bitrate = max(8_000_000, Int(Double(tw) * Double(th) * max(1.0, settings.outFps) * bitsPerPixel))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoExpectedSourceFrameRateKey: max(1, Int(settings.outFps.rounded()))
        ]
        if settings.hdrEnabled {
            // P010 输入本身会驱动 Main10；显式写上让编码器别退回 8-bit profile。
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: tw,
            AVVideoHeightKey: th,
            AVVideoCompressionPropertiesKey: compression
        ]
        let pixelFormat = settings.hdrEnabled ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        if settings.hdrEnabled {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
            videoSettings[AVVideoAllowWideColorKey] = true
        } else {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: tw,
                kCVPixelBufferHeightKey as String: th,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(videoIn) else { throw VideoRenderError.writerSetup }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioIn = input
            }
        }

        guard writer.startWriting() else {
            throw VideoRenderError.writeFailed(writer.error?.localizedDescription ?? "写入器启动失败")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw VideoRenderError.readerSetup
        }

        let model = box.model
        if settings.useAI && model == nil {
            onNotice("模型没加载成功，这一单会改用高质量重采样")
        }

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
        let totalOut = max(1, settings.expectedFrames)
        let outFps = max(1.0, settings.outFps)

        var outIndex = 0
        var audioFinished = false
        var cancelled = false
        var prevBuf: [UInt8]?
        var prevCG: CGImage?
        var scratch = [UInt8](repeating: 0, count: tw * th * 4)
        var accum = [UInt8](repeating: 0, count: tw * th * 4)
        // 抗闪烁要用“上一帧的稳定结果”，所以必须双缓冲轮换：
        // 融合时 inout 写到「不是上一帧、也不是当前帧」的那一块，避免触发整帧 COW（4K 每帧白抄 33MB）。
        var stableA = [UInt8](repeating: 0, count: tw * th * 4)
        var stableB = [UInt8](repeating: 0, count: tw * th * 4)
        var stableIsA = true
        var prevStable: [UInt8]?
        var tailBuf: [UInt8]?
        // 线性光累积缓冲：tw*th*3 个 Float，1.4MP 输出约 16.8MB。首次 compose 时按需扩容，之后复用。
        var blurLight: [Float] = []
        var reportedBlurCost = false
        // AI 逐帧超分天然会抖：只在这种模式下做逐像素自适应时域融合（快速放大已经足够稳定）。
        // 关掉「抗闪烁」就彻底不做时域融合，也不再多算一趟光流。
        let temporalOn: Bool = settings.useAI && settings.antiFlicker

        func writeFrame(_ buf: [UInt8]) throws {
            let pts = CMTime(seconds: Double(outIndex) / outFps, preferredTimescale: 600)
            while !videoIn.isReadyForMoreMediaData {
                if control.cancelled { throw VideoRenderError.cancelledInternally }
                if !control.waitIfPaused() { throw VideoRenderError.cancelledInternally }
                Thread.sleep(forTimeInterval: 0.004)
            }
            guard let pool = adaptor.pixelBufferPool else { throw VideoRenderError.pixelBuffer }
            var maybeBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer = maybeBuffer else {
                throw VideoRenderError.pixelBuffer
            }
            if settings.hdrEnabled {
                guard SDRToHDR.writeP010(buf, width: tw, height: th,
                                         strength: settings.hdrIntensity, into: pixelBuffer) else {
                    throw VideoRenderError.pixelBuffer
                }
            } else {
                guard let image = Pix.cgImage(rgba: buf, width: tw, height: th),
                      Pix.draw(image, into: pixelBuffer) else {
                    throw VideoRenderError.pixelBuffer
                }
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw VideoRenderError.writeFailed(writer.error?.localizedDescription ?? "帧写入失败")
            }
            outIndex += 1
            onFrame(baseFrames + outIndex, totalOut)
        }

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

        func pumpAudio() {
            guard !audioFinished, let audioIn, let audioOut else { return }
            while audioIn.isReadyForMoreMediaData {
                if let sample = audioOut.copyNextSampleBuffer() {
                    if let shifted = retimedAudio(sample) {
                        audioIn.append(shifted)
                    }
                } else {
                    audioFinished = true
                    audioIn.markAsFinished()
                    break
                }
            }
        }

        while true {
            if control.cancelled {
                cancelled = true
                break
            }
            if !control.waitIfPaused() {
                cancelled = true
                break
            }

            pumpAudio()

            guard let sample = videoOut.copyNextSampleBuffer() else { break }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample),
                  let cg = Pix.cgImage(from: imageBuffer),
                  let buf = makeFrame(cg,
                                      settings: settings,
                                      model: settings.useAI ? model : nil,
                                      control: control,
                                      onNotice: onNotice) else { continue }

            if let prev = prevBuf, prev.count == buf.count {
                let needsInterp = perPair > 1 || blurOn
                let needsFlow = needsInterp || temporalOn
                let flow: FlowField? = needsFlow && prevCG != nil
                    ? FrameOps.flow(from: prevCG!, to: cg)
                    : nil
                let flowScale: Float = flow.map { Float(tw) / Float($0.w) } ?? 1

                // 只在第一对帧报一次，让用户/日志看得到实际采样密度。
                if blurOn, !reportedBlurCost, let flow {
                    reportedBlurCost = true
                    let avg: Float = MotionBlurCore.estimateAverageSamples(
                        flow: flow, flowScale: flowScale,
                        width: tw, height: th, plan: blurPlan)
                    onNotice("动态模糊 \(Int(settings.shutterAngle))° · 平均 "
                             + String(format: "%.2f", Double(avg)) + " 次采样/像素")
                }

                // 当前帧先做逐像素自适应时域融合，再和上一帧合成中间帧；两端都用稳定后的结果，时间轴不乱。
                var outBuf = buf
                if temporalOn, let prevStable {
                    var blended = false
                    if stableIsA {
                        blended = QualityCore.blendTemporalAdaptive(
                            prev: prevStable, cur: buf, width: tw, height: th,
                            flow: flow, flowScale: flowScale,
                            antiFlicker: settings.antiFlicker, out: &stableA)
                        if !blended { stableA = buf }
                    } else {
                        blended = QualityCore.blendTemporalAdaptive(
                            prev: prevStable, cur: buf, width: tw, height: th,
                            flow: flow, flowScale: flowScale,
                            antiFlicker: settings.antiFlicker, out: &stableB)
                        if !blended { stableB = buf }
                    }
                    outBuf = stableIsA ? stableA : stableB
                    stableIsA.toggle()
                } else if temporalOn {
                    // 首帧没有可融合的上一帧：当前帧原样成为稳定结果。
                    if stableIsA { stableA = buf } else { stableB = buf }
                    stableIsA.toggle()
                }
                let aBuf = prevStable ?? prev

                for j in 0..<perPair {
                    let t = Float(j) / Float(perPair)
                    try emit(aBuf, outBuf, t: t, flow: flow, flowScale: flowScale)
                    if control.cancelled { break }
                }
                prevStable = outBuf
                tailBuf = outBuf
            } else if temporalOn {
                if stableIsA { stableA = buf } else { stableB = buf }
                stableIsA.toggle()
                prevStable = buf
                tailBuf = buf
            }

            prevBuf = buf
            prevCG = cg
            if tailBuf == nil { tailBuf = buf }

            if control.cancelled {
                cancelled = true
                break
            }
        }

        if !cancelled, let last = tailBuf {
            try writeFrame(last)
        }

        if cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            throw VideoRenderError.cancelledInternally
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoRenderError.writeFailed(reader.error?.localizedDescription ?? "解码中断")
        }

        videoIn.markAsFinished()
        audioIn?.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        if writer.status != .completed {
            throw VideoRenderError.writeFailed(writer.error?.localizedDescription ?? "封装失败")
        }

        onFrame(max(baseFrames + outIndex, 1), max(outIndex, 1))
        return Report(frames: outIndex, outputURL: dest)
    }

    // MARK: 分片渲染 + 拼接（M5）

    /// 每片覆盖的源时间长度（秒）。20 秒在「中断损失」和「拼接开销」之间比较平衡。
    static let segmentSeconds: Double = 20

    static func segmentCount(duration: Double) -> Int {
        guard duration > 0 else { return 1 }
        return max(1, Int(ceil(duration / segmentSeconds)))
    }

    static func framesPerSegment(outFps: Double) -> Int {
        max(1, Int((segmentSeconds * outFps).rounded()))
    }

    /// 分片渲染：每片单独编码成 mp4，已完成的片直接跳过，最后用 composition 拼接。
    static func renderSegmented(source: URL,
                                dest: URL,
                                settings: VideoSettings,
                                box: ModelBox,
                                control: RunControl,
                                sessionDir: URL,
                                doneSegments: Set<Int>,
                                totalSegments: Int,
                                onFrame: @escaping @Sendable (Int, Int) -> Void,
                                onSegment: @escaping @Sendable (Int, Int) -> Void,
                                onNotice: @escaping @Sendable (String) -> Void) throws -> Report {
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        var urls: [URL] = []
        let fpsPerSegment = framesPerSegment(outFps: settings.outFps)

        for seg in 0..<totalSegments {
            let url = sessionDir.appendingPathComponent(String(format: "seg-%04d.mp4", Int32(seg)))
            urls.append(url)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if doneSegments.contains(seg), exists { continue }

            let start = CMTime(seconds: Double(seg) * segmentSeconds, preferredTimescale: 600)
            let duration = CMTime(seconds: segmentSeconds, preferredTimescale: 600)
            _ = try render(source: source,
                           dest: url,
                           settings: settings,
                           box: box,
                           control: control,
                           timeRange: CMTimeRange(start: start, duration: duration),
                           baseFrames: seg * fpsPerSegment,
                           onFrame: onFrame,
                           onNotice: onNotice)
            onSegment(seg, totalSegments)
        }

        if urls.count == 1, let only = urls.first {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: only, to: dest)
        } else {
            try stitch(urls, dest: dest)
        }
        return Report(frames: settings.expectedFrames, outputURL: dest)
    }

    /// 用 AVMutableComposition 把分片按顺序接起来。passthrough 不重编码，
    /// 所以必须是同一编码参数的分片；HEVC 8-bit 与 HEVC Main10 各自内部一致即可。
    static func stitch(_ urls: [URL], dest: URL) throws {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoRenderError.writerSetup
        }
        let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var appended = 0

        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let v = asset.tracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: v.timeRange.duration)
            do {
                try vTrack.insertTimeRange(range, of: v, at: cursor)
            } catch {
                throw VideoRenderError.writeFailed("第 \(appended + 1) 片拼接失败：\(error.localizedDescription)")
            }
            if let a = asset.tracks(withMediaType: .audio).first, let aTrack {
                try? aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: a.timeRange.duration),
                                            of: a, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
            appended += 1
        }
        guard appended > 0 else { throw VideoRenderError.writeFailed("没有可拼接的分片") }

        try? FileManager.default.removeItem(at: dest)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoRenderError.writerSetup
        }
        export.outputURL = dest
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = false
        export.timeRange = CMTimeRange(start: .zero, duration: cursor)
        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()
        guard export.status == .completed else {
            throw VideoRenderError.writeFailed(export.error?.localizedDescription ?? "分片拼接失败")
        }
    }

    /// 解码来的一帧 → 目标尺寸的 RGBx 缓冲（AI 模式下中间先做一次 4× 重建）
    private static func makeFrame(_ cg: CGImage,
                                  settings: VideoSettings,
                                  model: MLModel?,
                                  control: RunControl,
                                  onNotice: @escaping @Sendable (String) -> Void) -> [UInt8]? {
        let tw = settings.targetWidth
        let th = settings.targetHeight
        let finalCG: CGImage
        if let model {
            let srcW = cg.width
            let srcH = cg.height
            let k = Double(settings.aiLongEdge) / Double(max(srcW, srcH))
            let aiW = max(16, Int(Double(srcW) * k))
            let aiH = max(16, Int(Double(srcH) * k))
            let aiInput = Pix.resized(cg, width: aiW, height: aiH) ?? cg
            guard let rgba = Pix.rgba(aiInput, width: aiInput.width, height: aiInput.height) else { return nil }
            let upscaled: [UInt8]? = TileEngine.upscale(
                model: model,
                rgbx: rgba,
                width: aiInput.width,
                height: aiInput.height,
                control: control,
                onProgress: { _, _ in },
                onFallback: { message in onNotice(message) }
            )
            guard let upscaled,
                  let aiCG = Pix.cgImage(rgba: upscaled, width: aiInput.width * 4, height: aiInput.height * 4) else {
                return nil
            }
            finalCG = Pix.resized(aiCG, width: tw, height: th) ?? aiCG
        } else {
            finalCG = Pix.resized(cg, width: tw, height: th) ?? cg
        }
        guard var out = Pix.rgba(finalCG, width: tw, height: th) else { return nil }
        // M7 画质：亮度域保边锐化 + 边缘自适应降噪 + 8-bit 抖动。
        // HDR 要关掉抖动，后面 writeP010 还会做一次 10-bit 抖动，两次叠加会形成规则纹理。
        if settings.detail > 0.001 || settings.denoise > 0.001 {
            QualityCore.applyDetail(&out, width: tw, height: th,
                                    amount: Float(settings.detail),
                                    denoise: Float(settings.denoise),
                                    dither: !settings.hdrEnabled)
        }
        return out
    }
}

// MARK: - 引擎

@MainActor
final class VideoEngine: ObservableObject {
    @Published var clip: VideoClip?
    @Published var mode: VideoMode = .fast
    @Published var scale: Double = 2
    @Published var modelKind: ModelKind = .photo
    @Published var interp: InterpMode = .off
    @Published var slow: SlowMode = .normal
    @Published var blur: BlurMode = .off
    @Published var shutterAngle: ShutterAngle = .deg180
    @Published var blurQuality: BlurQuality = .standard
    @Published var hdrEnabled = false
    @Published var hdrIntensity: Double = 0.65
    @Published var detail: Double = 0.25
    /// 降噪：0 = 只锐化；0.3 大概能把中等 ISO 的噪声压掉三分之一而不糊边缘。
    @Published var denoise: Double = 0.30
    /// 抗闪烁：AI 逐帧超分时按光流 + 亮度差逐像素决定融合多少。
    @Published var antiFlicker = true
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var notice: String?
    @Published var outputURL: URL?
    @Published var outputLabel: String = ""
    @Published var framesDone: Int = 0
    @Published var framesTotal: Int = 0
    @Published var etaSeconds: Double?

    private var runStart: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    /// 实际有效运行时长：扣掉中途暂停的时间，否则暂停越久 ETA 越离谱。
    private func effectiveElapsed() -> TimeInterval? {
        guard let start = runStart else { return nil }
        var elapsed = Date().timeIntervalSince(start) - pausedTotal
        if let pausedAt { elapsed -= Date().timeIntervalSince(pausedAt) }
        return max(0, elapsed)
    }

    /// 把剩余秒数格式化成一行提示；数据不足时返回空串。
    static func etaText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return " · 剩余 \(total / 3600) 时 " + String(format: "%02d", (total % 3600) / 60) + " 分"
        }
        if total >= 60 {
            return " · 剩余 \(total / 60) 分 " + String(format: "%02d", total % 60) + " 秒"
        }
        return " · 剩余 \(total) 秒"
    }
    private var models: [ModelKind: MLModel] = [:]
    private var control: RunControl?
    private var task: Task<Void, Never>?

    private let capLongEdge = 3840
    private let capPixels = 8_300_000

    init() {
        loadModels()
        JobStore.pruneStale()
    }

    private func loadModels() {
        for kind in ModelKind.allCases {
            guard let url = Bundle.main.url(forResource: kind.resource, withExtension: "mlmodelc") else { continue }
            if let model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()) {
                models[kind] = model
            }
        }
    }

    // MARK: 载入

    func load(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let copyName = "video-\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(copyName)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            notice = "读取视频失败：\(error.localizedDescription)"
            return
        }

        let asset = AVURLAsset(url: dest)
        guard let track = asset.tracks(withMediaType: .video).first else {
            notice = "这个文件里没有视频轨道"
            return
        }
        var size = track.naturalSize.applying(track.preferredTransform)
        size = CGSize(width: abs(size.width), height: abs(size.height))
        if size.width < 2 || size.height < 2 {
            size = track.naturalSize
        }
        let duration = CMTimeGetSeconds(asset.duration)
        let fps = max(1.0, min(240.0, Double(track.nominalFrameRate)))
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        clip = VideoClip(url: dest,
                         name: url.lastPathComponent,
                         renderWidth: Int(size.width.rounded()),
                         renderHeight: Int(size.height.rounded()),
                         duration: duration.isFinite ? duration : 0,
                         fps: fps,
                         fileMB: max(1, bytes / 1_048_576))
        outputURL = nil
        outputLabel = ""
        progress = 0
        framesDone = 0
        framesTotal = 0
        status = ""
        notice = nil
    }

    func clear() {
        guard !isRunning else { return }
        clip = nil
        outputURL = nil
        outputLabel = ""
        progress = 0
        status = ""
        notice = nil
    }

    // MARK: 尺寸规划

    struct VideoPlan: Sendable {
        var width: Int
        var height: Int
        var aiLongEdge: Int
        var samplesPerPair: Int
        var outFps: Double
        var frames: Int
        var keepAudio: Bool
        var note: String?
    }

    func plan(for clip: VideoClip) -> VideoPlan {
        let w0 = clip.renderWidth
        let h0 = clip.renderHeight
        var tw = Int((Double(w0) * scale).rounded())
        var th = Int((Double(h0) * scale).rounded())

        var notes: [String] = []
        let factor = interp.factor
        let slowFactor = slow.factor
        let perPair = max(1, Int((Double(factor) / slowFactor).rounded()))
        let blurOn = blur == .on
        let blurBudget = blurQuality.budget

        var capEdge = capLongEdge
        var capPix = capPixels
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

        let edgeScale = min(Double(capEdge) / Double(max(tw, th)), 1)
        let pixScale = (Double(capPix) / Double(max(1, tw * th))).squareRoot()
        let k = min(edgeScale, pixScale)
        if k < 0.999 {
            tw = max(2, Int(Double(tw) * k))
            th = max(2, Int(Double(th) * k))
            tw -= tw % 2
            th -= th % 2
            notes.append("已限制到 \(tw)×\(th)")
        }

        if hdrEnabled {
            // HDR 不再额外降分辨率：P010 单帧缓冲只有同尺寸 BGRA 的一半（4K 约 12MB），
            // 真正的瓶颈是 AI 推理与逐像素换算，不是编码器。上限沿用 4K / 830 万像素。
            notes.append("HLG/BT.2020 10-bit 输出，上限 4K / 830 万像素；设备编码兼容性以真机验证为准")
        }

        if hdrEnabled {
            let evenW = tw - tw % 2
            let evenH = th - th % 2
            if evenW != tw || evenH != th {
                tw = max(2, evenW)
                th = max(2, evenH)
                notes.append("为 P010 色度采样将尺寸调整为偶数：\(tw)×\(th)")
            }
        }

        // AI 输入尽量贴近原片分辨率：4× 重建后再缩到目标尺寸等于超采样，比「先缩小再重建」锐利得多。
        // 代价是缓冲变大，所以按 4× 输出不超过 24MP 反推允许的长边。
        var aiEdge = min(2048, max(w0, h0))
        let aspect = Double(h0) / Double(max(1, w0))
        let budgetPixels = 24_000_000.0
        while aiEdge > 320 {
            let outPixels = Double(aiEdge * 4) * Double(aiEdge * 4) * aspect
            if outPixels <= budgetPixels { break }
            aiEdge = Int(Double(aiEdge) * 0.92)
        }
        if aiEdge > max(w0, h0) { aiEdge = max(w0, h0) }

        let outFps = max(1.0, min(240.0, clip.fps * Double(factor)))
        let srcFrames = max(1, Int((clip.duration * clip.fps).rounded()))
        let frames = srcFrames * perPair

        if mode == .ai {
            let perFrame = Double(aiEdge * aiEdge) / (192.0 * 192.0)
            let aiSeconds = perFrame * 0.045 * Double(srcFrames)
            if aiSeconds > 60 {
                notes.append("AI 输入长边 \(aiEdge)px，光推理约 " + String(format: "%.0f", aiSeconds / 60) + " 分钟，建议先剪短或用快速放大")
            }
        }
        if frames > 5400 {
            notes.append("预计输出 \(frames) 帧，可能要很久，建议先剪短或降低补帧倍率")
        }

        let keepAudio = slowFactor > 0.999
        if !keepAudio {
            notes.append("慢动作要拉长时间轴，这一单不带原音轨")
        }

        return VideoPlan(width: tw, height: th,
                         aiLongEdge: aiEdge,
                         samplesPerPair: perPair,
                         outFps: outFps,
                         frames: frames,
                         keepAudio: keepAudio,
                         note: notes.isEmpty ? nil : notes.joined(separator: "；"))
    }

    // MARK: 运行

    func start() {
        run(resuming: false)
    }

    /// 继续上次没做完的分片任务（App 重启后也能接着跑）。
    func resumePendingJob() {
        run(resuming: true)
    }

    func run(resuming: Bool) {
        guard let clip, !isRunning else { return }
        let p = plan(for: clip)
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
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelLift-video-\(Int(Date().timeIntervalSince1970)).mp4")
        let box = ModelBox(models[modelKind] ?? models[.photo])
        let ctl = RunControl()
        control = ctl
        isRunning = true
        isPaused = false
        progress = 0
        framesDone = 0
        framesTotal = p.frames
        etaSeconds = nil
        runStart = Date()
        pausedAt = nil
        pausedTotal = 0
        status = startStatus()
        outputURL = nil
        outputLabel = ""
        notice = p.note

        let source = clip.url
        let totalOut = p.frames

        // HDR 走单条输出：分片拼接走 passthrough，10-bit HLG 的元数据在拼接时容易丢，
        // 宁可不提供续传也不让画质退化。SDR 才分片。
        let segments = hdrEnabled ? 1 : VideoRenderer.segmentCount(duration: clip.duration)
        let jobKey = JobStore.key(source: source, settings: settings)
        let sessionDir = JobStore.dir(for: jobKey)
        var done: Set<Int> = []
        if resuming, segments > 1 {
            done = Set(JobStore.load(key: jobKey)?.done ?? [])
        } else if segments > 1 {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        if segments > 1 {
            JobStore.save(JobRecord(key: jobKey,
                                    sourcePath: source.path,
                                    width: settings.targetWidth,
                                    height: settings.targetHeight,
                                    outFps: settings.outFps,
                                    hdr: settings.hdrEnabled,
                                    totalSegments: segments,
                                    done: Array(done).sorted(),
                                    createdAt: Date().timeIntervalSince1970))
        }
        let startDone = done

        task = Task { [weak self] in
            let result: Result<VideoRenderer.Report, Error> = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let onFrame: @Sendable (Int, Int) -> Void = { doneFrames, total in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.framesDone = doneFrames
                                self.framesTotal = max(total, totalOut)
                                self.progress = min(0.995, Double(doneFrames) / Double(max(1, totalOut)))
                                if let elapsed = self.effectiveElapsed(), doneFrames > 2, elapsed > 0.5 {
                                    let perFrame = elapsed / Double(doneFrames)
                                    let remaining = perFrame * Double(max(0, max(total, totalOut) - doneFrames))
                                    self.etaSeconds = remaining
                                }
                                if self.progress > 0.02 {
                                    let tail = VideoEngine.etaText(self.etaSeconds)
                                    self.status = "\(self.startStatus()) \(doneFrames) / \(max(total, totalOut)) 帧\(tail)"
                                }
                            }
                        }
                        let onNotice: @Sendable (String) -> Void = { message in
                            Task { @MainActor [weak self] in
                                self?.notice = message
                            }
                        }
                        let report: VideoRenderer.Report
                        if segments > 1 {
                            report = try VideoRenderer.renderSegmented(
                                source: source,
                                dest: dest,
                                settings: settings,
                                box: box,
                                control: ctl,
                                sessionDir: sessionDir,
                                doneSegments: startDone,
                                totalSegments: segments,
                                onFrame: onFrame,
                                onSegment: { index, total in
                                    JobStore.markDone(key: jobKey, segment: index)
                                    Task { @MainActor [weak self] in
                                        self?.status = "\(self?.startStatus() ?? "") 分片 \(index + 1) / \(total) 完成"
                                    }
                                },
                                onNotice: onNotice)
                        } else {
                            report = try VideoRenderer.render(
                                source: source,
                                dest: dest,
                                settings: settings,
                                box: box,
                                control: ctl,
                                onFrame: onFrame,
                                onNotice: onNotice)
                        }
                        cont.resume(returning: .success(report))
                    } catch {
                        cont.resume(returning: .failure(error))
                    }
                }
            }

            guard let self else { return }
            self.isRunning = false
            self.isPaused = false
            self.control = nil
            self.runStart = nil
            self.etaSeconds = nil
            switch result {
            case .success(let report):
                self.progress = 1
                self.outputURL = report.outputURL
                let outAttrs = try? FileManager.default.attributesOfItem(atPath: report.outputURL.path)
                let bytes = (outAttrs?[.size] as? NSNumber)?.intValue ?? 0
                let mb = max(1, bytes / 1_048_576)
                self.outputLabel = "\(p.width) × \(p.height) · \(report.frames) 帧 · \(mb) MB"
                self.status = "完成"
                if segments > 1 {
                    JobStore.clear(key: jobKey)
                    try? FileManager.default.removeItem(at: sessionDir)
                }
            case .failure(let error):
                self.progress = 0
                self.status = ""
                if let renderError = error as? VideoRenderError, case .cancelledInternally = renderError {
                    self.notice = "已取消"
                } else {
                    self.notice = error.localizedDescription
                }
            }
        }
    }

    private func startStatus() -> String {
        var parts: [String] = []
        parts.append(mode == .ai ? "AI 逐帧超分" : "解码 + 重采样")
        if interp != .off { parts.append("补帧 \(interp.title)") }
        if slow != .normal { parts.append("慢动作 \(slow.title)") }
        if blur == .on { parts.append("动态模糊 \(shutterAngle.title)") }
        if detail > 0.001 { parts.append("细节 \(Int(detail * 100))%") }
        if denoise > 0.001 { parts.append("降噪 \(Int(denoise * 100))%") }
        if mode == .ai && antiFlicker { parts.append("抗闪烁") }
        if hdrEnabled { parts.append("SDR→HLG \(Int(hdrIntensity * 100))%") }
        return parts.joined(separator: " + ")
    }

    func pause() {
        guard isRunning else { return }
        control?.setPaused(true)
        isPaused = true
        pausedAt = Date()
        status = "已暂停"
    }

    func resume() {
        guard isRunning else { return }
        control?.setPaused(false)
        isPaused = false
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        status = startStatus()
    }

    func cancel() {
        control?.cancel()
        status = "正在停止…"
    }

    func reset() {
        guard !isRunning else { return }
        outputURL = nil
        outputLabel = ""
        progress = 0
        status = ""
        framesDone = 0
        etaSeconds = nil
        runStart = nil
    }

    // MARK: 保存

    func saveToPhotos() async {
        guard let url = outputURL else {
            notice = "还没有生成视频"
            return
        }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            notice = "没有相册写入权限，请在系统设置里打开"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            notice = "已保存视频到相册"
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 断点续传

    /// 当前素材 + 当前设置是否存在未完成的分片任务。
    func pendingJobSummary(for clip: VideoClip) -> String? {
        let key = JobStore.key(source: clip.url, settings: settings(for: clip))
        guard let record = JobStore.load(key: key),
              !record.done.isEmpty,
              record.done.count < record.totalSegments else { return nil }
        let minutes = Double(record.done.count) * VideoRenderer.segmentSeconds / 60
        return "上次还剩 \(record.totalSegments - record.done.count) 个分片（已完成约 \(String(format: "%.1f", minutes)) 分钟素材）"
    }

    func discardPendingJob(for clip: VideoClip) {
        let key = JobStore.key(source: clip.url, settings: settings(for: clip))
        JobStore.clear(key: key)
        notice = "已丢弃未完成的分片"
        objectWillChange.send()
    }

    /// 把当前 UI 选择落成一次渲染的参数，供 start() 与断点查询共用。
    private func settings(for clip: VideoClip) -> VideoSettings {
        let p = plan(for: clip)
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
    }
}

// MARK: - 分片任务记录

struct JobRecord: Codable, Sendable {
    var key: String
    var sourcePath: String
    var width: Int
    var height: Int
    var outFps: Double
    var hdr: Bool
    var totalSegments: Int
    var done: [Int]
    var createdAt: Double
}

enum JobStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PixelLiftJobs", isDirectory: true)
    }

    static func dir(for key: String) -> URL {
        root.appendingPathComponent(key, isDirectory: true)
    }

    static func key(source: URL, settings: VideoSettings) -> String {
        let descriptor = [
            source.path,
            "\(settings.targetWidth)x\(settings.targetHeight)",
            String(format: "%.3f", settings.outFps),
            settings.useAI ? "ai\(settings.aiLongEdge)" : "fast",
            "p\(settings.samplesPerPair)a\(Int(settings.shutterAngle))m\(settings.blurSampleBudget)l\(settings.blurLinearLight ? "1" : "0")",
            "q\(Int((settings.detail * 100).rounded()))d\(Int((settings.denoise * 100).rounded()))f\(settings.antiFlicker ? "1" : "0")",
            settings.hdrEnabled ? "hdr" : "sdr",
            // 带上版本号：编码参数/分片格式一变，旧断点就不该被复用（宁可重跑，也不拼出坏文件）。
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
        ].joined(separator: "|")
        return SHA256.hash(data: Data(descriptor.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(24)
            .description
    }

    static func load(key: String) -> JobRecord? {
        let url = dir(for: key).appendingPathComponent("job.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JobRecord.self, from: data)
    }

    /// 清掉超过 7 天没动过的任务目录：分片文件很占空间，放弃的任务不该永久堆在 Documents 里。
    static func pruneStale(days: Double = 7) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let probe = folder.appendingPathComponent("job.json")
            let stamp = (try? fm.attributesOfItem(atPath: probe.path))?[.modificationDate] as? Date
            let when = stamp ?? ((try? fm.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date)
            if let when, when < cutoff {
                try? fm.removeItem(at: folder)
            }
        }
    }

    static func save(_ record: JobRecord) {
        let folder = dir(for: record.key)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: folder.appendingPathComponent("job.json"), options: .atomic)
    }

    static func markDone(key: String, segment: Int) {
        guard var record = load(key: key) else { return }
        if !record.done.contains(segment) {
            record.done.append(segment)
            record.done.sort()
        }
        save(record)
    }

    static func clear(key: String) {
        try? FileManager.default.removeItem(at: dir(for: key))
    }
}
