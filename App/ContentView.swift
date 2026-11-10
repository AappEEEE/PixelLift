import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var engine = UpscaleEngine()
    @State private var picker: PhotosPickerItem?
    @State private var scale: Double = 2
    @State private var customWidth: String = ""
    @State private var format: ExportFormat = .png
    @State private var kind: ModelKind = .photo
    @State private var showHelp = false

    private let presets: [Double] = [1.5, 2, 2.5, 3, 4, 6, 8]

    private var customValue: Int? {
        let t = customWidth.trimmingCharacters(in: .whitespaces)
        guard let v = Int(t), v >= 16 else { return nil }
        return v
    }

    private var plan: UpscaleEngine.Plan {
        engine.plan(scale: scale, customWidth: customValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    previewCard
                    scaleCard
                    outputCard
                    actionBar
                    if let notice = engine.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding()
            }
            .navigationTitle("PixelLift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                }
            }
            .sheet(isPresented: $showHelp) { helpSheet }
            .onChange(of: picker) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await engine.load(data: data)
                    }
                }
            }
            .onChange(of: kind) { _, _ in engine.notice = engine.modelState }
        }
    }

    // MARK: - 预览

    private var previewCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("原图").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(engine.inputSizeLabel).font(.caption).monospacedDigit()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                if let img = engine.outputPreview ?? engine.inputPreview {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus").font(.largeTitle)
                        Text("选择一张图片").font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                    .padding(40)
                }
            }
            .frame(minHeight: 200)

            PhotosPicker(selection: $picker, matching: .images, photoLibrary: .shared()) {
                Label("从相册选择", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 倍率

    private var scaleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("放大倍率").font(.subheadline.weight(.semibold))
                Spacer()
                Text(customValue == nil ? String(format: "%.1f×", scale) : "自定义宽度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(presets, id: \.self) { p in
                    Button {
                        scale = p
                        customWidth = ""
                    } label: {
                        VStack(spacing: 2) {
                            Text(p == floor(p) ? "\(Int(p))×" : String(format: "%.1f×", p))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                            Text(p == 4 ? "AI 原生" : (p > 4 ? "AI+放大" : "AI+缩回"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(customValue == nil && scale == p ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(customValue == nil && scale == p ? Color.accentColor : .clear, lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("自定义宽度（px）", text: $customWidth)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                if customValue != nil {
                    Button("清除") { customWidth = "" }
                        .font(.footnote)
                }
            }

            Text("模型原生为 4× 重建；其它倍率在 4× 结果上做 Lanczos 缩放，倍率越低越接近「AI 去噪后再缩回」。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if plan.targetWidth > 0 {
                Text("输出：\(plan.targetWidth) × \(plan.targetHeight) px")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("模型", selection: $kind) {
                ForEach(ModelKind.allCases) { k in Text(k.title).tag(k) }
            }
            .pickerStyle(.segmented)

            Picker("格式", selection: $format) {
                ForEach(ExportFormat.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)

            Text(engine.modelState).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 输出信息

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(engine.status).font(.footnote)
                Spacer()
                if engine.isRunning {
                    Text("\(Int(engine.progress * 100))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if engine.isRunning || engine.progress > 0 {
                ProgressView(value: engine.progress)
            }
            if let url = engine.outputURL {
                HStack(spacing: 12) {
                    Button {
                        Task { await engine.saveToPhotos() }
                    } label: {
                        Label("存入相册", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    ShareLink(item: url) {
                        Label("分享/存文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 操作

    private var actionBar: some View {
        HStack(spacing: 10) {
            if engine.isRunning {
                if engine.isPaused {
                    Button { engine.resume() } label: {
                        Label("继续", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button { engine.pause() } label: {
                        Label("暂停", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) { engine.cancel() } label: {
                    Label("取消", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    engine.start(scale: scale, customWidth: customValue, format: format, kind: kind)
                } label: {
                    Label("开始超分", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.inputPreview == nil)
            }
        }
    }

    // MARK: - 说明

    private var helpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    helpBlock("本地运行", "所有推理都在设备上完成，图片不上传任何服务器。")
                    helpBlock("倍率说明", "模型原生 4×。1.5×/2×/2.5×/3× 是「4× 重建后缩回」，画质仍优于直接插值；6×/8× 是「4× 后用 Lanczos 再放大」，细节是模型猜出来的，不会凭空多出真实信息。")
                    helpBlock("尺寸上限", "单图输出限制 8192px / 24MP，避免内存被打爆。原图很大时，AI 会先按长边 1024px 重建再缩放到目标，这是移动端的现实取舍。")
                    helpBlock("关于 AI", "超分模型会「补」出它认为合理的细节，人脸、文字、纹理可能被改写。重要照片请保留原图。")
                    helpBlock("自签安装", "免费 Apple ID 签名有效期 7 天，到期需重新签名安装；想长期免签需付费开发者账号。")
                    helpBlock("功耗", "AI 推理走 Neural Engine，连续处理多张会发热降频，属正常现象。")
                }
                .padding()
            }
            .navigationTitle("说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("好") { showHelp = false }
                }
            }
        }
    }

    private func helpBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
