import AVFoundation
import CoreImage
import CoreML
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
        return String(format: "%d:%02d", total / 60, total % 60)
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

/// 动态模糊：把相邻几个补帧采样按权重叠起来，模拟快门拖影
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
        var r = eotf(Float(r8) / 255)
        var g = eotf(Float(g8) / 255)
        var b = eotf(Float(b8) / 255)
        let y = max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
        let amount = Float(min(1, max(0, strength)))
        let u = min(1, max(0, (y - 0.70) / 0.30))
        let knee = u * u * (3 - 2 * u)
        let mapped = y + amount * 0.30 * knee * knee
        let gain = y > 1e-6 ? mapped / y : 1
        r *= gain * 0.75; g *= gain * 0.75; b *= gain * 0.75
        let (r2020, g2020, b2020) = rec709To2020(r, g, b)
        return (hlgOETF(r2020), hlgOETF(g2020), hlgOETF(b2020))
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
        let blurSamples = max(1, settings.blurSamples)
        let totalOut = max(1, settings.expectedFrames)
        let outFps = max(1.0, settings.outFps)

        var outIndex = 0
        var audioFinished = false
        var cancelled = false
        var prevBuf: [UInt8]?
        var prevCG: CGImage?
        var lastBuf: [UInt8]?
        var scratch = [UInt8](repeating: 0, count: tw * th * 4)
        var accum = [UInt8](repeating: 0, count: tw * th * 4)

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
            onFrame(outIndex, totalOut)
        }

        func emit(_ a: [UInt8], _ b: [UInt8], t: Float,
                  flow: FlowField?, flowScale: Float) throws {
            if blurSamples <= 1 {
                FrameOps.synthesize(a: a, b: b, w: tw, h: th,
                                    flow: flow, flowScale: flowScale, t: t, out: &scratch)
                try writeFrame(scratch)
                return
            }
            let spread = 0.35 / Float(max(2, perPair))
            for j in 0..<blurSamples {
                let offset = (Float(j) - (Float(blurSamples) - 1) * 0.5) * spread
                let tj = min(1, max(0, t + offset))
                FrameOps.synthesize(a: a, b: b, w: tw, h: th,
                                    flow: flow, flowScale: flowScale, t: tj, out: &scratch)
                if j == 0 {
                    accum = scratch
                } else {
                    FrameOps.average(into: &accum, from: scratch, weight: 1.0 / Float(j + 1))
                }
            }
            try writeFrame(accum)
        }

        func pumpAudio() {
            guard !audioFinished, let audioIn, let audioOut else { return }
            while audioIn.isReadyForMoreMediaData {
                if let sample = audioOut.copyNextSampleBuffer() {
                    audioIn.append(sample)
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
                let needsInterp = perPair > 1 || blurSamples > 1
                let flow: FlowField? = needsInterp && prevCG != nil
                    ? FrameOps.flow(from: prevCG!, to: cg)
                    : nil
                let flowScale: Float = flow.map { Float(tw) / Float($0.w) } ?? 1
                for j in 0..<perPair {
                    let t = Float(j) / Float(perPair)
                    try emit(prev, buf, t: t, flow: flow, flowScale: flowScale)
                    if control.cancelled { break }
                }
            }

            prevBuf = buf
            prevCG = cg
            lastBuf = buf

            if control.cancelled {
                cancelled = true
                break
            }
        }

        if !cancelled, let last = lastBuf {
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

        onFrame(max(outIndex, 1), max(outIndex, 1))
        return Report(frames: outIndex, outputURL: dest)
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
        return Pix.rgba(finalCG, width: tw, height: th)
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
    @Published var hdrEnabled = false
    @Published var hdrIntensity: Double = 0.65
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var notice: String?
    @Published var outputURL: URL?
    @Published var outputLabel: String = ""
    @Published var framesDone: Int = 0
    @Published var framesTotal: Int = 0

    private var models: [ModelKind: MLModel] = [:]
    private var control: RunControl?
    private var task: Task<Void, Never>?

    private let capLongEdge = 3840
    private let capPixels = 8_300_000

    init() {
        loadModels()
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
        let blurSamples = blur.samples

        var capEdge = capLongEdge
        var capPix = capPixels
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
            capEdge = min(capEdge, 1920)
            capPix = min(capPix, 2_100_000)
            notes.append("HLG/BT.2020 10-bit 输出，设备编码兼容性以真机验证为准")
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

        var aiEdge = min(1280, max(384, Int((Double(max(tw, th)) / 4.0).rounded())))
        if aiEdge > max(w0, h0) { aiEdge = max(w0, h0) }

        let outFps = max(1.0, min(240.0, clip.fps * Double(factor)))
        let srcFrames = max(1, Int((clip.duration * clip.fps).rounded()))
        let frames = srcFrames * perPair

        if mode == .ai {
            let perFrame = Double(aiEdge * aiEdge) / (192.0 * 192.0)
            let aiSeconds = perFrame * 0.045 * Double(srcFrames)
            if aiSeconds > 60 {
                notes.append(String(format: "AI 模式光推理就要 %.0f 分钟，建议先剪短或用快速放大", aiSeconds / 60))
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
        guard let clip, !isRunning else { return }
        let p = plan(for: clip)
        let settings = VideoSettings(targetWidth: p.width,
                                     targetHeight: p.height,
                                     useAI: mode == .ai,
                                     aiLongEdge: p.aiLongEdge,
                                     duration: clip.duration,
                                     outFps: p.outFps,
                                     samplesPerPair: p.samplesPerPair,
                                     blurSamples: blur.samples,
                                     keepAudio: p.keepAudio,
                                     expectedFrames: p.frames,
                                      hdrEnabled: hdrEnabled,
                                      hdrIntensity: hdrIntensity)
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
        status = startStatus()
        outputURL = nil
        outputLabel = ""
        notice = p.note

        let source = clip.url
        let totalOut = p.frames

        task = Task { [weak self] in
            let result: Result<VideoRenderer.Report, Error> = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let report = try VideoRenderer.render(
                            source: source,
                            dest: dest,
                            settings: settings,
                            box: box,
                            control: ctl,
                            onFrame: { done, total in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    self.framesDone = done
                                    self.framesTotal = max(total, totalOut)
                                    self.progress = min(0.995, Double(done) / Double(max(1, total)))
                                    if self.progress > 0.02 {
                                        self.status = "\(self.startStatus()) \(done) / \(max(total, totalOut)) 帧"
                                    }
                                }
                            },
                            onNotice: { message in
                                Task { @MainActor [weak self] in
                                    self?.notice = message
                                }
                            }
                        )
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
            switch result {
            case .success(let report):
                self.progress = 1
                self.outputURL = report.outputURL
                let outAttrs = try? FileManager.default.attributesOfItem(atPath: report.outputURL.path)
                let bytes = (outAttrs?[.size] as? NSNumber)?.intValue ?? 0
                let mb = max(1, bytes / 1_048_576)
                self.outputLabel = "\(p.width) × \(p.height) · \(report.frames) 帧 · \(mb) MB"
                self.status = "完成"
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
        if blur != .off { parts.append("动态模糊 \(blur.title)") }
        if hdrEnabled { parts.append("SDR→HLG \(Int(hdrIntensity * 100))%") }
        return parts.joined(separator: " + ")
    }

    func pause() {
        guard isRunning else { return }
        control?.setPaused(true)
        isPaused = true
        status = "已暂停"
    }

    func resume() {
        guard isRunning else { return }
        control?.setPaused(false)
        isPaused = false
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
}
