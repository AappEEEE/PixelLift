import CoreImage
import CoreML
import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

// MARK: - 选项

enum ExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG 无损" : "JPEG 较小" }
    var ext: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }
}

enum ModelKind: String, CaseIterable, Identifiable {
    case photo
    case anime

    var id: String { rawValue }
    var title: String { self == .photo ? "照片 / 实拍" : "动漫 / 插画" }
    var resource: String { self == .photo ? "RealESRGANGeneral" : "RealESRGANAnime" }
}

enum ItemState: Equatable {
    case pending, running, done, failed, cancelled

    var label: String {
        switch self {
        case .pending: return "等待"
        case .running: return "处理中"
        case .done: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct WorkItem: Identifiable {
    let id = UUID()
    var name: String
    var source: CGImage
    var thumb: UIImage
    var sourceLabel: String
    var state: ItemState = .pending
    var progress: Double = 0
    var outputURL: URL?
    var outputLabel: String = ""
    var resultThumb: UIImage?
    var message: String?
}

// MARK: - 后台运行的暂停/取消开关

final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _cancelled = false

    func setPaused(_ value: Bool) {
        lock.lock(); _paused = value; lock.unlock()
    }

    func cancel() {
        lock.lock(); _cancelled = true; _paused = false; lock.unlock()
    }

    var paused: Bool {
        lock.lock(); defer { lock.unlock() }; return _paused
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return _cancelled
    }

    /// 暂停时在这里阻塞；返回 false 表示已被取消
    func waitIfPaused() -> Bool {
        while paused {
            if cancelled { return false }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return !cancelled
    }
}

// MARK: - 分块推理（在后台线程执行，不碰 UI，不碰 MainActor）

enum TileEngine {
    /// 模型固定输入边长
    static let tileEdge = 256
    /// 边缘重叠（参与计算但结果丢弃），用于消除块间接缝
    static let tilePad = 32
    /// 相邻块的步进 = 256 - 32*2
    static let step = tileEdge - tilePad * 2

    static func upscale(model: MLModel?,
                        rgbx: [UInt8], width w: Int, height h: Int,
                        control: RunControl,
                        onProgress: @Sendable (Int, Int) -> Void,
                        onFallback: @Sendable (String) -> Void) -> [UInt8]? {
        let outW = w * 4, outH = h * 4
        var out = [UInt8](repeating: 0, count: outW * outH * 4)

        guard let model else {
            blitBilinear(src: rgbx, w: w, h: h, dst: &out, dw: outW, dh: outH)
            onProgress(1, 1)
            return out
        }

        let cols = max(1, Int((Double(w) / Double(step)).rounded(.up)))
        let rows = max(1, Int((Double(h) / Double(step)).rounded(.up)))
        let total = cols * rows
        var done = 0
        var failed = false

        outer: for row in 0..<rows {
            for col in 0..<cols {
                guard control.waitIfPaused() else { return nil }
                if control.cancelled { return nil }
                do {
                    try inferTile(model: model, src: rgbx, srcW: w, srcH: h,
                                  ox: col * step, oy: row * step,
                                  dst: &out, dstW: outW, dstH: outH)
                } catch {
                    onFallback("AI 推理失败：\(error.localizedDescription)，已退化为插值")
                    failed = true
                    break outer
                }
                done += 1
                onProgress(done, total)
            }
        }

        if control.cancelled { return nil }

        if failed {
            var fallback = [UInt8](repeating: 0, count: outW * outH * 4)
            blitBilinear(src: rgbx, w: w, h: h, dst: &fallback, dw: outW, dh: outH)
            return fallback
        }
        return out
    }

    @inline(__always)
    private static func q8(_ v: Float) -> UInt8 {
        let s = v * 255 + 0.5
        if s <= 0 { return 0 }
        if s >= 255 { return 255 }
        return UInt8(s)
    }

    private static func inferTile(model: MLModel,
                                  src: [UInt8], srcW: Int, srcH: Int,
                                  ox: Int, oy: Int,
                                  dst: inout [UInt8], dstW: Int, dstH: Int) throws {
        let t = tileEdge, pad = tilePad
        let count = 3 * t * t
        let arr = try MLMultiArray(shape: [NSNumber(value: 1), NSNumber(value: 3),
                                           NSNumber(value: t), NSNumber(value: t)],
                                   dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: count)

        src.withUnsafeBufferPointer { s in
            guard let base = s.baseAddress else { return }
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
                        p[cOff + y * t + x] = Float(base[(rowOff + sx) * 4 + c]) / 255.0
                    }
                }
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)])
        let result = try model.prediction(from: provider)
        guard let o = result.featureValue(for: "output")?.multiArrayValue else {
            throw NSError(domain: "PixelLift", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "模型输出为空"])
        }

        let ot = t * 4                 // 单块输出边长 1024
        let plane = ot * ot
        let crop = pad * 4             // 单侧丢弃 128 输出像素
        let usable = ot - crop * 2     // 有效 768
        let oCount = 3 * plane

        let raw = o.dataPointer
        let read: (Int) -> Float
        switch o.dataType {
        case .float32:
            let q = raw.bindMemory(to: Float.self, capacity: oCount)
            read = { q[$0] }
        case .float16:
            let q = raw.bindMemory(to: UInt16.self, capacity: oCount)
            read = { Float(Float16(bitPattern: q[$0])) }
        case .double:
            let q = raw.bindMemory(to: Double.self, capacity: oCount)
            read = { Float(q[$0]) }
        default:
            read = { o[$0].floatValue }
        }

        // 定位：块左上角 ox,oy 对应目标像素 (ox*4, oy*4)，去掉单侧 crop 后无缝拼回去
        dst.withUnsafeMutableBufferPointer { d in
            guard let db = d.baseAddress else { return }
            for y in 0..<usable {
                let dy = oy * 4 + y
                if dy >= dstH { break }
                let srcRow = (y + crop) * ot
                var di = (dy * dstW + ox * 4) * 4
                for x in 0..<usable {
                    let dx = ox * 4 + x
                    if dx >= dstW { break }
                    let si = srcRow + x + crop
                    db[di] = q8(read(si))
                    db[di + 1] = q8(read(si + plane))
                    db[di + 2] = q8(read(si + 2 * plane))
                    db[di + 3] = 255
                    di += 4
                }
            }
        }
    }

    static func blitBilinear(src: [UInt8], w: Int, h: Int,
                             dst: inout [UInt8], dw: Int, dh: Int) {
        src.withUnsafeBufferPointer { s in
            guard let sb = s.baseAddress else { return }
            dst.withUnsafeMutableBufferPointer { d in
                guard let db = d.baseAddress else { return }
                for y in 0..<dh {
                    let sy = min(h - 1, y * h / dh)
                    let rowOff = sy * w
                    var di = y * dw * 4
                    for x in 0..<dw {
                        let sx = min(w - 1, x * w / dw)
                        let si = (rowOff + sx) * 4
                        db[di] = sb[si]
                        db[di + 1] = sb[si + 1]
                        db[di + 2] = sb[si + 2]
                        db[di + 3] = 255
                        di += 4
                    }
                }
            }
        }
    }
}

// MARK: - 引擎

@MainActor
final class UpscaleEngine: ObservableObject {
    @Published var items: [WorkItem] = []
    @Published var status = "从相册或「文件」导入图片，可多选"
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var modelState = "检测中…"
    @Published var notice: String?
    @Published var overallProgress: Double = 0
    /// 图片侧的细节锐度（与视频 M7 同一套亮度域保边锐化，默认比视频低一档，照片本身高频更密）。
    @Published var detail: Double = 0.20
    /// 图片侧降噪：只压小幅度残差，用来吃掉手机照片的暗部噪点。
    @Published var denoise: Double = 0.12

    private var models: [ModelKind: MLModel] = [:]
    private var control: RunControl?
    private var task: Task<Void, Never>?

    /// AI 重建输入上限（长边）。2048 是质量与内存的折中：再大 Core ML 分块数会翻倍，收益递减。
    private let aiCapEdge = 2048
    /// AI 输入像素预算。输出缓冲 = 16 倍像素 × 4 字节，240 万像素 → 约 154MB
    private let aiPixelBudget = 2_400_000
    /// 导出上限
    private let maxOutEdge = 8192
    private let maxOutPixels = 24_000_000

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
        modelState = loaded.isEmpty
            ? "⚠️ 未找到 AI 模型，将退化为高质量插值"
            : "已加载：" + loaded.joined(separator: "、")
    }

    // MARK: 导入

    func add(data: Data, name: String, fallbackIndex: Int) {
        guard let ui = UIImage(data: data), let cg = Self.normalized(ui) else {
            notice = "「\(name)」无法解码，已跳过"
            return
        }
        let thumb = Self.thumbnail(cg, maxEdge: 240)
        var item = WorkItem(name: name.isEmpty ? "图片 \(fallbackIndex)" : name,
                            source: cg,
                            thumb: thumb ?? UIImage(),
                            sourceLabel: "\(cg.width) × \(cg.height)")
        item.message = nil
        items.append(item)
        overallProgress = 0
        status = "已导入 \(items.count) 张"
    }

    func removeAll() {
        guard !isRunning else { return }
        items.removeAll()
        overallProgress = 0
        status = "从相册或「文件」导入图片，可多选"
    }

    func remove(id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        overallProgress = 0
    }

    // MARK: 尺寸规划

    struct Plan {
        var targetWidth: Int
        var targetHeight: Int
        var aiLongEdge: Int
        var note: String?
    }

    func plan(for cg: CGImage, scale: Double, customWidth: Int?) -> Plan {
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
            notes.append("已限制到 \(tw)×\(th)（上限 \(maxOutEdge)px / 24MP）")
        }

        var aiEdge = min(aiCapEdge, max(w0, h0))
        let ideal = Int((Double(max(tw, th)) / 4.0).rounded())
        if ideal > aiEdge { aiEdge = min(aiCapEdge, ideal) }

        // 像素预算：4× 输出的 RGB 缓冲 = 输入像素 × 16 × 4 字节，超了就往回收
        func aiPixels(_ edge: Int) -> Double {
            let k = Double(edge) / Double(max(w0, h0))
            return Double(w0) * k * Double(h0) * k
        }
        while aiEdge > 320 && aiPixels(aiEdge) > Double(aiPixelBudget) {
            aiEdge = Int(Double(aiEdge) * 0.93)
        }

        notes.append("AI 在长边 \(aiEdge)px 上重建")
        return Plan(targetWidth: tw, targetHeight: th, aiLongEdge: aiEdge,
                    note: notes.isEmpty ? nil : notes.joined(separator: "；"))
    }

    // MARK: 开始 / 暂停 / 取消

    func start(scale: Double, customWidth: Int?, format: ExportFormat, kind: ModelKind) {
        guard !isRunning else { return }
        let pending = items.contains { $0.state != .done }
        guard pending else {
            notice = "没有待处理的图片"
            return
        }
        let ctl = RunControl()
        control = ctl
        isRunning = true
        isPaused = false
        overallProgress = 0
        notice = nil
        for i in items.indices where items[i].state != .done {
            items[i].state = .pending
            items[i].progress = 0
            items[i].outputURL = nil
            items[i].resultThumb = nil
            items[i].outputLabel = ""
            items[i].message = nil
        }

        task = Task { [weak self] in
            await self?.runQueue(scale: scale, customWidth: customWidth, format: format, kind: kind, control: ctl)
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        control?.setPaused(true)
        isPaused = true
        status = "已暂停"
    }

    func resume() {
        guard isRunning, isPaused else { return }
        control?.setPaused(false)
        isPaused = false
        status = "继续处理…"
    }

    func cancel() {
        guard isRunning else { return }
        control?.cancel()
        isPaused = false
        status = "正在取消…"
    }

    // MARK: 队列

    private func runQueue(scale: Double, customWidth: Int?, format: ExportFormat,
                          kind: ModelKind, control ctl: RunControl) async {
        defer {
            isRunning = false
            isPaused = false
            control = nil
        }

        let indices = items.indices.filter { items[$0].state == .pending }
        for (n, idx) in indices.enumerated() {
            if ctl.cancelled { break }
            let p = plan(for: items[idx].source, scale: scale, customWidth: customWidth)
            items[idx].state = .running
            items[idx].progress = 0
            items[idx].message = p.note
            status = "\(n + 1)/\(indices.count) · \(items[idx].name)"

            let ok = await processItem(at: idx, plan: p, format: format, kind: kind, control: ctl)
            if ctl.cancelled {
                items[idx].state = .cancelled
                items[idx].progress = 0
                break
            }
            if ok {
                items[idx].state = .done
                items[idx].progress = 1
            } else if items[idx].state == .running {
                items[idx].state = .failed
            }
            overallProgress = Double(n + 1) / Double(max(1, indices.count))
        }

        for i in items.indices where items[i].state == .pending {
            items[i].state = .cancelled
        }

        let doneCount = items.filter { $0.state == .done }.count
        if ctl.cancelled {
            status = "已取消 · 已完成 \(doneCount) 张"
        } else {
            status = "全部完成 · 共 \(doneCount) 张"
        }
    }

    private func processItem(at idx: Int, plan p: Plan, format: ExportFormat,
                             kind: ModelKind, control ctl: RunControl) async -> Bool {
        let item = items[idx]
        let cg = item.source
        let id = item.id

        var aiInput = cg
        if max(cg.width, cg.height) > p.aiLongEdge {
            aiInput = Self.resized(cg, longEdge: p.aiLongEdge) ?? cg
        }
        let w = aiInput.width, h = aiInput.height
        guard let rgbx = Self.rgbx(aiInput, width: w, height: h) else {
            items[idx].message = "像素读取失败"
            return false
        }

        let model = models[kind] ?? models[.photo]
        let buf: [UInt8]? = await Task.detached(priority: .userInitiated) { () -> [UInt8]? in
            TileEngine.upscale(
                model: model, rgbx: rgbx, width: w, height: h, control: ctl,
                onProgress: { done, total in
                    Task { @MainActor [weak self] in
                        self?.setTileProgress(id: id, done: done, total: total)
                    }
                },
                onFallback: { message in
                    Task { @MainActor [weak self] in
                        self?.notice = message
                    }
                }
            )
        }.value

        guard let out = buf else {
            if ctl.cancelled { items[idx].message = "已取消" }
            return false
        }

        let outW = w * 4, outH = h * 4
        guard let aiCG = Self.makeCGImage(from: out, width: outW, height: outH) else {
            items[idx].message = "拼接输出失败"
            return false
        }

        let resizedCG = Self.resampled(aiCG, width: p.targetWidth, height: p.targetHeight) ?? aiCG
        let finalCG = Self.detailPass(resizedCG, detail: detail, denoise: denoise) ?? resizedCG
        guard let url = Self.write(finalCG, format: format,
                                   name: item.name, index: idx + 1) else {
            items[idx].message = "写文件失败"
            return false
        }

        items[idx].outputURL = url
        items[idx].resultThumb = Self.thumbnail(finalCG, maxEdge: 240)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let kb = max(1, bytes / 1024)
        items[idx].outputLabel = "\(finalCG.width) × \(finalCG.height) · \(kb) KB"
        items[idx].progress = 1
        return true
    }

    private func setTileProgress(id: UUID, done: Int, total: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let frac = Double(done) / Double(max(1, total))
        items[i].progress = min(0.96, 0.95 * frac)
    }

    // MARK: 保存

    func saveAllToPhotos() async {
        let urls = items.compactMap { $0.outputURL }
        guard !urls.isEmpty else {
            notice = "还没有处理完成的图片"
            return
        }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            notice = "没有相册写入权限，请在系统设置里打开"
            return
        }
        var saved = 0
        for url in urls {
            guard let img = UIImage(contentsOfFile: url.path) else { continue }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                }
                saved += 1
            } catch {
                notice = "第 \(saved + 1) 张保存失败：\(error.localizedDescription)"
                break
            }
        }
        if saved > 0 {
            notice = "已保存 \(saved) 张到相册"
        }
    }

    func saveToPhotos(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), let url = item.outputURL else { return }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            notice = "没有相册写入权限，请在系统设置里打开"
            return
        }
        guard let img = UIImage(contentsOfFile: url.path) else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }
            notice = "已保存到相册"
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 像素工具

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

    private static func rgbx(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
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

    private static func thumbnail(_ cg: CGImage, maxEdge: Int) -> UIImage? {
        let k = Double(maxEdge) / Double(max(cg.width, cg.height))
        if k >= 1 {
            return UIImage(cgImage: cg)
        }
        let w = max(1, Int(Double(cg.width) * k))
        let h = max(1, Int(Double(cg.height) * k))
        return resampled(cg, width: w, height: h).map { UIImage(cgImage: $0) }
    }

    private static func resized(_ cg: CGImage, longEdge: Int) -> CGImage? {
        let w = cg.width, h = cg.height
        let k = Double(longEdge) / Double(max(w, h))
        let nw = max(1, Int(Double(w) * k)), nh = max(1, Int(Double(h) * k))
        return resampled(cg, width: nw, height: nh)
    }

    /// 细节/降噪：与视频侧共用 QualityCore（亮度域保边锐化 + 软门限降噪 + 8-bit 抖动）。
    /// 纯 Swift 实现，照片尺寸通常 8–24MP，单张几十到两百毫秒，用户感知不到。
    static func detailPass(_ cg: CGImage, detail: Double, denoise: Double) -> CGImage? {
        if detail <= 0.001 && denoise <= 0.001 { return cg }
        let w = cg.width
        let h = cg.height
        if w < 8 || h < 8 { return cg }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let count = w * h * 4
        var buf = [UInt8](repeating: 0, count: count)
        buf.withUnsafeMutableBytes { raw in
            if let dst = raw.baseAddress { memcpy(dst, base, count) }
        }
        QualityCore.applyDetail(&buf, width: w, height: h,
                                amount: Float(detail), denoise: Float(denoise), dither: true)
        return makeCGImage(from: buf, width: w, height: h)
    }

    static func resampled(_ cg: CGImage, width: Int, height: Int) -> CGImage? {        if width == cg.width && height == cg.height { return cg }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func write(_ cg: CGImage, format: ExportFormat, name: String, index: Int) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let file = "PixelLift-\(index)-\(Int(Date().timeIntervalSince1970))-\(safe).\(format.ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] : [:]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }
}
