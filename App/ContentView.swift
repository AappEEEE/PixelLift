import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var engine = UpscaleEngine()

    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showHelp = false
    @State private var importing = false

    @State private var scale: Double = 2
    @State private var useCustomWidth = false
    @State private var customWidth: String = ""
    @State private var format: ExportFormat = .png
    @State private var kind: ModelKind = .photo

    private let presets: [Double] = [1.5, 2, 2.5, 3, 4, 6, 8]

    private var customValue: Int? {
        guard useCustomWidth else { return nil }
        let t = customWidth.trimmingCharacters(in: .whitespaces)
        guard let v = Int(t), v >= 16 else { return nil }
        return v
    }

    private var pendingCount: Int { engine.items.filter { $0.state != .done }.count }
    private var doneCount: Int { engine.items.filter { $0.state == .done }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    importCard
                    if !engine.items.isEmpty { listCard }
                    scaleCard
                    modelCard
                    actionCard
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
            .navigationTitle("PixelLift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
                if !engine.items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) { engine.removeAll() } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(engine.isRunning)
                    }
                }
            }
            .sheet(isPresented: $showHelp) { helpSheet }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                handleFileImport(result)
            }
            .onChange(of: pickedPhotos) { _, newItems in
                guard !newItems.isEmpty else { return }
                importing = true
                Task {
                    var idx = engine.items.count
                    for item in newItems {
                        idx += 1
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            engine.add(data: data, name: "相册 \(idx)", fallbackIndex: idx)
                        }
                    }
                    pickedPhotos = []
                    importing = false
                }
            }
        }
    }

    // MARK: - 导入

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedPhotos,
                             maxSelectionCount: 20,
                             selectionBehavior: .ordered,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Label("从相册选", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isRunning)

                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件导入", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(engine.isRunning)
            }
            .controlSize(.large)

            HStack {
                Text(engine.status)
                Spacer()
                if importing {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text("支持多选，一次处理一批。相册一次最多 20 张，「文件」不限。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 列表

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("队列 \(engine.items.count) 张")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if doneCount > 0 {
                    Text("完成 \(doneCount)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if engine.isRunning {
                ProgressView(value: engine.overallProgress)
                    .tint(.accentColor)
                    .animation(.linear(duration: 0.25), value: engine.overallProgress)
            }

            ForEach(engine.items) { item in
                itemRow(item)
                if item.id != engine.items.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func itemRow(_ item: WorkItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: (item.state == .done ? (item.resultThumb ?? item.thumb) : item.thumb))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if item.state == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .background(Circle().fill(.white))
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.sourceLabel + (item.outputLabel.isEmpty ? "" : "  →  " + item.outputLabel))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if item.state == .running {
                    ProgressView(value: item.progress)
                        .controlSize(.small)
                        .animation(.linear(duration: 0.2), value: item.progress)
                } else {
                    HStack(spacing: 8) {
                        Text(item.state.label)
                            .font(.caption2)
                            .foregroundStyle(color(for: item.state))
                        if let msg = item.message, item.state != .done {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if item.state == .done, let url = item.outputURL {
                HStack(spacing: 10) {
                    Button {
                        Task { await engine.saveToPhotos(id: item.id) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderless)
                .font(.body)
            } else if !engine.isRunning {
                Button {
                    engine.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
    }

    private func color(for state: ItemState) -> Color {
        switch state {
        case .done: return .green
        case .failed: return .red
        case .running: return .accentColor
        case .pending, .cancelled: return .secondary
        }
    }

    // MARK: - 倍率

    private var scaleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("输出尺寸")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(presets, id: \.self) { p in
                    Button {
                        scale = p
                        useCustomWidth = false
                    } label: {
                        Text(p == floor(p) ? "\(Int(p))×" : String(format: "%.1f×", p))
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(selectedBackground(isOn: scale == p && !useCustomWidth))
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.isRunning)
                }
                Button {
                    useCustomWidth = true
                } label: {
                    Text("自定宽")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(selectedBackground(isOn: useCustomWidth))
                }
                .buttonStyle(.plain)
                .disabled(engine.isRunning)
            }

            if useCustomWidth {
                HStack(spacing: 8) {
                    TextField("目标宽度，如 3000", text: $customWidth)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Text("px").font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let first = engine.items.first {
                let p = engine.plan(for: first.source, scale: scale, customWidth: customValue)
                Text("首张：\(first.sourceLabel) → \(p.targetWidth) × \(p.targetHeight)"
                     + (p.note.map { "（\($0)）" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("原生 AI 为 4×。1.5–3× 是 4× 重建后缩回，6×/8× 是重建后再放大。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func selectedBackground(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isOn ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isOn ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
    }

    // MARK: - 模型与格式

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型")
                .font(.subheadline.weight(.semibold))
            Picker("模型", selection: $kind) {
                ForEach(ModelKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isRunning)

            Text("格式")
                .font(.subheadline.weight(.semibold))
            Picker("格式", selection: $format) {
                ForEach(ExportFormat.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isRunning)

            Text(engine.modelState)
                .font(.caption2)
                .foregroundStyle(engine.modelState.hasPrefix("⚠️") ? .orange : .secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 操作

    private var actionCard: some View {
        VStack(spacing: 10) {
            if engine.isRunning {
                HStack(spacing: 10) {
                    Button {
                        if engine.isPaused {
                            engine.resume()
                        } else {
                            engine.pause()
                        }
                    } label: {
                        Label(engine.isPaused ? "继续" : "暂停",
                              systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        engine.cancel()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                Button {
                    engine.start(scale: scale, customWidth: customValue,
                                 format: format, kind: kind)
                } label: {
                    Label(pendingCount > 0 ? "开始处理 \(pendingCount) 张" : "开始处理",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine.items.isEmpty || pendingCount == 0)
            }

            if doneCount > 0 {
                Button {
                    Task { await engine.saveAllToPhotos() }
                } label: {
                    Label("全部保存到相册（\(doneCount)）", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(engine.isRunning)
            }
        }
    }

    // MARK: - 文件导入

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importing = true
            Task {
                var idx = engine.items.count
                for url in urls {
                    idx += 1
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    engine.add(data: data, name: url.lastPathComponent, fallbackIndex: idx)
                }
                importing = false
            }
        case .failure(let error):
            engine.notice = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 版本戳

    private var buildStamp: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return Text("v\(version) (build \(build)) · 高分辨率重建版")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - 说明

    private var helpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("这是 PixelLift 的第一个版本，只包含图片处理。视频超分、补帧、慢动作、动态模糊、SDR→HDR 在后续版本。")
                        .font(.subheadline)

                    Divider()

                    bullet("全部在本机推理，图片不上传、不需要网络。")
                    bullet("原生 AI 倍率为 4×；选 1.5×/2×/2.5×/3× 时先在 4× 上重建再缩回，选 6×/8× 时重建后再放大——所以界面会标注「AI 原生」还是「AI+缩放」。")
                    bullet("AI 重建分辨率自动取「目标尺寸 ÷ 4」，上限长边 2048px——保证 4× 结果不小于目标尺寸，基本不做二次放大，这是清晰度的关键。")
                    bullet("单张输出上限 8192px / 2400 万像素，超出会自动限制并在图上标注。")
                    bullet("分块推理带 32px 重叠并丢弃边缘，拼接处不会有接缝和白边。")
                    bullet("处理中可暂停/继续/取消；一批里的每一张都有独立进度。")
                    bullet("保存到相册需要相册写入权限；也可以点每行的分享按钮直接导出到「文件」。")

                    Divider()

                    Text("模型：Real-ESRGAN x4（BSD 3-Clause，作者 Xintao Wang），在构建时转换为 Core ML，不随本 App 分发训练代码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("关于与说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showHelp = false }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(.subheadline.weight(.bold))
            Text(text).font(.subheadline)
        }
    }
}

#Preview {
    ContentView()
}
