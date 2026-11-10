import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 从相册取视频时用的一次性载体
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("pick-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}

@MainActor
struct VideoView: View {
    @StateObject private var engine = VideoEngine()

    @State private var pickedItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var loading = false
    @State private var showHelp = false

    private let scales: [Double] = [1.5, 2, 3, 4]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    importCard
                    if let clip = engine.clip {
                        clipCard(clip)
                        modeCard
                        scaleCard(clip)
                        motionCard(clip)
                        actionCard(clip)
                    }
                    if let notice = engine.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    buildStamp
                }
                .padding()
                .padding(.bottom, 24)
            }
            .navigationTitle("视频增强")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
                if engine.clip != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) { engine.clear() } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(engine.isRunning)
                    }
                }
            }
            .sheet(isPresented: $showHelp) { helpSheet }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await engine.load(url: url) }
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                loading = true
                Task {
                    if let video = try? await item.loadTransferable(type: PickedVideo.self) {
                        await engine.load(url: video.url)
                    } else {
                        engine.notice = "从相册读取视频失败，换个视频再试"
                    }
                    pickedItem = nil
                    loading = false
                }
            }
        }
    }

    // MARK: 卡片

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedItem, matching: .videos, photoLibrary: .shared()) {
                    Label("从相册选视频", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
            .disabled(engine.isRunning || loading)

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取视频…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func clipCard(_ clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(clip.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(clip.sizeLabel, systemImage: "rectangle.dashed")
                Label(clip.durationLabel, systemImage: "clock")
                Label(clip.fpsLabel, systemImage: "speedometer")
                Label("\(clip.fileMB) MB", systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("处理方式").font(.headline)
            Picker("处理方式", selection: $engine.mode) {
                ForEach(VideoMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isRunning)

            Text(engine.mode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if engine.mode == .ai {
                Picker("模型", selection: $engine.modelKind) {
                    ForEach(ModelKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(engine.isRunning)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func scaleCard(_ clip: VideoClip) -> some View {
        let plan = engine.plan(for: clip)
        return VStack(alignment: .leading, spacing: 10) {
            Text("输出倍率").font(.headline)
            HStack(spacing: 8) {
                ForEach(scales, id: \.self) { s in
                    Button {
                        engine.scale = s
                    } label: {
                        Text(String(format: "%g×", s))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(engine.scale - s) < 0.001 ? .accentColor : .gray)
                    .disabled(engine.isRunning)
                }
            }
            Text("输出 \(plan.width) × \(plan.height)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = plan.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func motionCard(_ clip: VideoClip) -> some View {
        let plan = engine.plan(for: clip)
        return VStack(alignment: .leading, spacing: 12) {
            Text("运动处理").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("补帧").font(.subheadline)
                Picker("补帧", selection: $engine.interp) {
                    ForEach(InterpMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(engine.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("慢动作").font(.subheadline)
                Picker("慢动作", selection: $engine.slow) {
                    ForEach(SlowMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(engine.isRunning)
            }

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

            Text(String(format: "输出 %.0f fps · 约 %@ 帧 · %@",
                        plan.outFps,
                        "\(plan.frames)",
                        engine.slow == .normal ? "保留原音轨" : "无音轨"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func actionCard(_ clip: VideoClip) -> some View {
        VStack(spacing: 12) {
            if engine.isRunning {
                VStack(spacing: 6) {
                    ProgressView(value: engine.progress)
                        .animation(.linear(duration: 0.25), value: engine.progress)
                    HStack {
                        Text(engine.status)
                        Spacer()
                        Text("\(Int(engine.progress * 100))%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if engine.isPaused {
                        Button("继续") { engine.resume() }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("暂停") { engine.pause() }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                    }
                    Button("取消", role: .destructive) { engine.cancel() }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                }
            } else {
                Button {
                    engine.start()
                } label: {
                    Label("开始处理", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(clip.duration <= 0)

                if engine.outputURL != nil {
                    HStack(spacing: 10) {
                        Button {
                            Task { await engine.saveToPhotos() }
                        } label: {
                            Label("存到相册", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)

                        if let url = engine.outputURL {
                            ShareLink(item: url) {
                                Label("分享", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text(engine.outputLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private var buildStamp: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        return Text("v\(version) (build \(build)) · 视频 M3 补帧版")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    private var helpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("视频增强怎么用").font(.headline)
                    Text("1. 从相册或「文件」选一段视频；\n2. 选处理方式和倍率；\n3. 点「开始处理」，完成后存相册或直接分享。")
                        .font(.footnote)

                    Text("两种方式的区别").font(.headline)
                    Text("· 快速放大：只用 CoreGraphics 高质量重采样，速度接近实时，适合单纯把 1080p 拉到 1440p/4K；\n· AI 逐帧超分：每帧都跑一遍 Real-ESRGAN 分块推理，细节最好，但按帧算，一段 10 秒 30fps 的片子要几分钟。")
                        .font(.footnote)

                    Text("补帧 / 慢动作 / 动态模糊").font(.headline)
                    Text("· 补帧：用 Vision 的光流算出每个像素的运动方向，在相邻两帧之间合成中间帧，所以 ×2 就是把 30fps 变成 60fps，运动更顺；\n· 慢动作：把时间轴拉长，多出来的每一帧同样是光流补出来的，(补帧 ×2 + 慢动作 0.5×) 一秒钟要补 4 帧；\n· 动态模糊：把同一时刻前后几个补帧采样叠起来，模拟快门拖影；\n· 慢动作会改变时长，所以这一单不带原音轨；只补帧不改时长时音频照原样透传。")
                        .font(.footnote)

                    Text("本版限制").font(.headline)
                    Text("· 输出上限 4K / 830 万像素；开了补帧或慢动作会降到 1080p 级，动态模糊再降一档，否则一帧要几百毫秒；\n· 补帧靠光流，画面里出现大面积遮挡、闪烁或快速横移时可能有轻微拖影；\n· 处理时要保持 App 在前台，iOS 不允许后台长时间算。")
                        .font(.footnote)

                    Text("编码").font(.headline)
                    Text("输出用 HEVC（H.265）封装成 .mp4，码率按分辨率自动给，兼容「照片」和系统播放器。")
                        .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showHelp = false }
                }
            }
        }
    }
}
