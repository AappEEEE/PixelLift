import CoreImage
import CoreML
import Foundation
import ImageIO
import Photos
import UIKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG（无损）" : "JPEG（体积小）" }
    var ext: String { rawValue == "png" ? "png" : "jpg" }
}

enum ModelKind: String, CaseIterable, Identifiable {
    case photo
    case anime

    var id: String { rawValue }
    var title: String { self == .photo ? "照片 / 实拍" : "动漫 / 插画" }
    var resource: String { self == .photo ? "RealESRGANGeneral" : "RealESRGANAnime" }
}

@MainActor
final class UpscaleEngine: ObservableObject {
    // MARK: - 对外状态

    @Published var inputPreview: UIImage?
    @Published var outputPreview: UIImage?
    @Published var status = "选择一张图片开始"
    @Published var progress: Double = 0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var outputURL: URL?
    @Published var inputSizeLabel = "—"
    @Published var notice: String?
    @Published var modelState = "检测中…"

    // MARK: - 内部

    private var sourceCG: CGImage?
    private var task: Task<Void, Never>?
    private var pauseFlag = false
    private var cancelFlag = false
    private var models: [ModelKind: MLModel] = [:]

    /// AI 4x 推理的输入上限（长边）。超出则先降采样，避免 4x 输出爆内存。
    private let aiInputMaxEdge = 1024
    private let aiInputMaxPixels = 1_048_576
    /// 最终导出上限
    private let maxOutEdge = 8192
    private let maxOutPixels = 24_000_000
    /// 模型固定输入尺寸与边缘重叠（33 层 3x3 卷积 → 感受野足够）
    private let tileEdge = 256
    private let tilePad = 32

    init() {
        loadModels()
    }

    private func loadModels() {
        var loaded: [String] = []
        for kind in ModelKind.allCases {
            guard let url = Bundle.main.url(forResource: kind.resource, withExtension: "mlmodelc") else { continue }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            cfg.allowLowPrecisionAccumulationOnGPU = true
            if let m = try? MLModel(contentsOf: url, configuration: cfg) {
                models[kind] = m
                loaded.append(kind.title)
            }
        }
        if loaded.isEmpty {
            modelState = "⚠️ 未找到 AI 模型，将退化为高质量插值"
        } else {
            modelState = "已加载：" + loaded.joined(separator: "、")
        }
    }

    // MARK: - 载入

    func load(data: Data) async {
        guard !isRunning else { return }
        guard let ui = UIImage(data: data) else {
            notice = "无法解码这张图片"
            return
        }
        let cg = Self.normalized(ui)
        sourceCG = cg
        inputPreview = ui
        outputPreview = nil
        outputURL = nil
        progress = 0
        notice = nil
        if let cg {
            inputSizeLabel = "\(cg.width) × \(cg.height)"
            status = "已就绪 · 原始 \(cg.width) × \(cg.height)"
        } else {
            status = "解码失败"
        }
    }

    /// 把 UIImage 的 EXIF 方向烘焙进像素，避免推理后方向错乱
    private static func normalized(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let w = image.size.width * image.scale
        let h = image.size.height * image.scale
        guard w > 0, h > 0 else { return image.cgImage }
        UIGraphicsBeginImageContextWithOptions(CGSize(width: w, height: h), false, 1)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        let out = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()
        return out ?? image.cgImage
    }

    // MARK: - 计算目标尺寸

    struct Plan {
        var targetWidth: Int
        var targetHeight: Int
        var aiLongEdge: Int
        var note: String?
    }

    func plan(scale: Double, customWidth: Int?) -> Plan {
        guard let cg = sourceCG else {
            return Plan(targetWidth: 0, targetHeight: 0, aiLongEdge: 0, note: nil)
        }
        let w0 = cg.width, h0 = cg.height
        var tw = Int((Double(w0) * scale).rounded())
        var th = Int((Double(h0) * scale).rounded())
        if let cw = customWidth, cw >= 16 {
            tw = cw
            th = max(1, Int((Double(h0) * Double(cw) / Double(w0)).rounded()))
        }

        var notes: [String] = []
        if tw > maxOutEdge || th > maxOutEdge || tw * th > maxOutPixels {
            let edgeScale = min(Double(maxOutEdge) / Double(max(tw, th)), 1)
            let pixScale = (Double(maxOutPixels) / Double(tw * th)).squareRoot()
            let k = min(edgeScale, pixScale)
            tw = max(1, Int(Double(tw) * k))
            th = max(1, Int(Double(th) * k))
            notes.append("已限制到 \(tw)×\(th)（单图上限 \(maxOutEdge)px / 24MP）")
        }

        // AI 推理的输入长边
        var aiEdge = min(aiInputMaxEdge, max(w0, h0))
        if w0 * h0 > aiInputMaxPixels {
            let k = (Double(aiInputMaxPixels) / Double(w0 * h0)).squareRoot()
            aiEdge = min(aiEdge, Int(Double(max(w0, h0)) * k))
        }
        if aiEdge < max(w0, h0) {
            notes.append("原图较大，AI 先按长边 \(aiEdge)px 重建再缩放到目标尺寸")
        }
        return Plan(targetWidth: tw, targetHeight: th, aiLongEdge: aiEdge, note: notes.isEmpty ? nil : notes.joined(separator: "；"))
    }

    // MARK: - 开始 / 暂停 / 取消

    func start(scale: Double, customWidth: Int?, format: ExportFormat, kind: ModelKind) {
        guard let cg = sourceCG, !isRunning else { return }
        let p = plan(scale: scale, customWidth: customWidth)
        guard p.targetWidth > 0 else { return }
        notice = p.note
        isRunning = true
        isPaused = false
        pauseFlag = false
        cancelFlag = false
        progress = 0
        outputURL = nil
        status = "准备中…"

        task = Task { [weak self] in
            await self?.run(cg: cg, plan: p, format: format, kind: kind)
        }
    }

    func pause() {
        guard isRunning else { return }
        pauseFlag = true
        isPaused = true
        status = "已暂停"
    }

    func resume() {
        guard isRunning, isPaused else { return }
        pauseFlag = false
        isPaused = false
        status = "继续处理…"
    }

    func cancel() {
        cancelFlag = true
        pauseFlag = false
        isPaused = false
        task?.cancel()
        isRunning = false
        status = "已取消"
    }

    // MARK: - 主流程

    private func run(cg: CGImage, plan p: Plan, format: ExportFormat, kind: ModelKind) async {
        let started = Date()
        defer { isRunning = false }

        var aiInput = cg
        if max(cg.width, cg.height) > p.aiLongEdge {
            aiInput = Self.resized(cg, longEdge: p.aiLongEdge) ?? cg
        }
        let w = aiInput.width, h = aiInput.height
        status = "AI 重建中…（\(w)×\(h) → \(w * 4)×\(h * 4)）"

        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgbx.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return Self.render(aiInput, into: base, width: w, height: h)
        }
        guard ok else {
            status = "像素读取失败"
            return
        }

        let model = models[kind] ?? models[.photo]
        let outW = w * 4, outH = h * 4
        var out = [UInt8](repeating: 255, count: outW * outH * 4)

        if let model {
            let step = tileEdge - tilePad * 2
            let cols = Int(ceil(Double(w) / Double(step)))
            let rows = Int(ceil(Double(h) / Double(step)))
            let total = max(1, cols * rows)
            var done = 0

            for row in 0..<rows {
                for col in 0..<cols {
                    if cancelFlag { status = "已取消"; return }
                    while pauseFlag {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        if cancelFlag { status = "已取消"; return }
                    }
                    let ox = col * step, oy = row * step
                    do {
                        try inferTile(model: model, src: &rgbx, srcW: w, srcH: h,
                                      ox: ox, oy: oy, dst: &out, dstW: outW, dstH: outH)
                    } catch {
                        notice = "AI 推理失败：\(error.localizedDescription)，已退化为插值"
                        out = [UInt8](repeating: 255, count: outW * outH * 4)
                        rgbx.withUnsafeBytes { raw in
                            _ = Self.blitBilinear(from: raw.baseAddress!, w: w, h: h, to: &out, dw: outW, dh: outH)
                        }
                        break
                    }
                    done += 1
                    progress = 0.85 * Double(done) / Double(total)
                    if done % max(1, total / 12) == 0 || done == total {
                        status = "AI 重建 \(done)/\(total) 块"
                    }
                }
                if cancelFlag { status = "已取消"; return }
            }
        } else {
            rgbx.withUnsafeBytes { raw in
                _ = Self.blitBilinear(from: raw.baseAddress!, w: w, h: h, to: &out, dw: outW, dh: outH)
            }
            progress = 0.85
        }

        guard !cancelFlag else { status = "已取消"; return }

        status = "重采样到 \(p.targetWidth)×\(p.targetHeight)…"
        guard let aiCG = Self.makeCGImage(from: out, width: outW, height: outH) else {
            status = "输出图像生成失败"
            return
        }
        let finalCG = Self.resampled(aiCG, width: p.targetWidth, height: p.targetHeight) ?? aiCG
        progress = 0.95

        guard let url = Self.write(finalCG, format: format) else {
            status = "写文件失败"
            return
        }
        outputURL = url
        outputPreview = UIImage(contentsOfFile: url.path)
        progress = 1
        let secs = Date().timeIntervalSince(started)
        status = String(format: "完成 · %d×%d · %.1f 秒", finalCG.width, finalCG.height, secs)
    }

    // MARK: - 单块推理

    private func inferTile(model: MLModel, src: inout [UInt8], srcW: Int, srcH: Int,
                           ox: Int, oy: Int, dst: inout [UInt8], dstW: Int, dstH: Int) throws {
        let t = tileEdge, pad = tilePad
        let count = 3 * t * t
        let arr = try MLMultiArray(shape: [NSNumber(value: 1), NSNumber(value: 3),
                                           NSNumber(value: t), NSNumber(value: t)],
                                   dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: count)

        src.withUnsafeBufferPointer { s in
            for c in 0..<3 {
                let cOff = c * t * t
                for y in 0..<t {
                    var sy = oy - pad + y
                    if sy < 0 { sy = 0 }
                    if sy >= srcH { sy = srcH - 1 }
                    let rowOff = sy * srcW
                    for x in 0..<t {
                        var sx = ox - pad + x
                        if sx < 0 { sx = 0 }
                        if sx >= srcW { sx = srcW - 1 }
                        let idx = (rowOff + sx) * 4 + c
                        p[cOff + y * t + x] = Float(s[idx]) / 255.0
                    }
                }
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)])
        let result = try model.prediction(from: provider)
        guard let o = result.featureValue(for: "output")?.multiArrayValue else {
            throw NSError(domain: "PixelLift", code: 1, userInfo: [NSLocalizedDescriptionKey: "输出为空"])
        }

        let ot = t * 4
        let oCount = 3 * ot * ot
        let dtype = o.dataType
        let usable = (ot - pad * 2 * 4)

        func sample(_ c: Int, _ y: Int, _ x: Int) -> UInt8 {
            let i = c * ot * ot + y * ot + x
            switch dtype {
            case .float32:
                let q = o.dataPointer.bindMemory(to: Float.self, capacity: oCount)
                return UInt8(max(0, min(255, (q[i] * 255).rounded())))
            case .float16:
                let q = o.dataPointer.bindMemory(to: UInt16.self, capacity: oCount)
                return UInt8(max(0, min(255, (Float(Float16(bitPattern: q[i])) * 255).rounded())))
            case .double:
                let q = o.dataPointer.bindMemory(to: Double.self, capacity: oCount)
                return UInt8(max(0, min(255, (q[i] * 255).rounded())))
            default:
                return UInt8(max(0, min(255, (o[i].floatValue * 255).rounded())))
            }
        }

        dst.withUnsafeMutableBufferPointer { d in
            for y in 0..<usable {
                let dy = oy * 4 + pad * 4 + y
                if dy < 0 || dy >= dstH { continue }
                for x in 0..<usable {
                    let dx = ox * 4 + pad * 4 + x
                    if dx < 0 || dx >= dstW { continue }
                    let di = (dy * dstW + dx) * 4
                    let sy = y + pad * 4
                    let sx = x + pad * 4
                    d[di] = sample(0, sy, sx)
                    d[di + 1] = sample(1, sy, sx)
                    d[di + 2] = sample(2, sy, sx)
                    d[di + 3] = 255
                }
            }
        }
    }

    // MARK: - 像素工具

    private static func render(_ cg: CGImage, into base: UnsafeMutableRawPointer, width: Int, height: Int) -> Bool {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    private static func blitBilinear(from p: UnsafeRawPointer, w: Int, h: Int,
                                     to dst: inout [UInt8], dw: Int, dh: Int) -> Bool {
        let s = p.bindMemory(to: UInt8.self, capacity: w * h * 4)
        dst.withUnsafeMutableBufferPointer { d in
            for y in 0..<dh {
                let sy = min(h - 1, y * h / dh)
                for x in 0..<dw {
                    let sx = min(w - 1, x * w / dw)
                    let si = (sy * w + sx) * 4
                    let di = (y * dw + x) * 4
                    d[di] = s[si]
                    d[di + 1] = s[si + 1]
                    d[di + 2] = s[si + 2]
                    d[di + 3] = 255
                }
            }
        }
        return true
    }

    private static func makeCGImage(from buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = buffer
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    private static func resized(_ cg: CGImage, longEdge: Int) -> CGImage? {
        let w = cg.width, h = cg.height
        let k = Double(longEdge) / Double(max(w, h))
        let nw = max(1, Int(Double(w) * k)), nh = max(1, Int(Double(h) * k))
        return resampled(cg, width: nw, height: nh)
    }

    /// 高质量（高插值质量）缩放，走 CGContext，不依赖 CoreImage 的 extent 行为
    private static func resampled(_ cg: CGImage, width: Int, height: Int) -> CGImage? {
        if width == cg.width && height == cg.height { return cg }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func write(_ cg: CGImage, format: ExportFormat) -> URL? {
        let name = "PixelLift-\(Int(Date().timeIntervalSince1970)).\(format.ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let type = format == .png ? "public.png" : "public.jpeg"
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    // MARK: - 保存到相册

    func saveToPhotos() async {
        guard let url = outputURL, let img = UIImage(contentsOfFile: url.path) else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            notice = "没有相册写入权限，请在系统设置里打开"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }
            notice = "已保存到相册"
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
        }
    }
}
