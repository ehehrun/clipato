import AppKit
import ClipatoCore
import SwiftUI
import UniformTypeIdentifiers

struct BatchExportView: View {
    @ObservedObject var model: AppModel
    let embedded: Bool
    @State private var options: BatchExportOptions
    @State private var showAdvanced = false
    @State private var inputError: String?
    @State private var isDropTargeted = false
    @State private var gridValidationMessage: String? = L("正在读取图片…")
    @State private var cropConfirmed = false
    private var imageCount: Int { model.batchExportImages.count }

    init(model: AppModel, mode: BatchExportMode, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
        var options = BatchExportOptions(mode: mode)
        if model.batchImageTool == .grid {
            options.grid = ImageGridOptions()
            options.imageFormat = .jpeg
        } else if let tool = model.batchImageTool { options.processing = ImageProcessingOptions(tool: tool) }
        _options = State(initialValue: options)
    }

    private var title: String {
        if let tool = model.batchImageTool { return tool.title }
        switch options.mode {
        case .files: return L("导出图片 / PDF")
        case .zip: return L("导出 ZIP 压缩包")
        case .video: return L("导出 MP4 / GIF")
        }
    }

    @ViewBuilder var body: some View {
        if embedded {
            content
        } else {
            content.onExitCommand { model.dismissImageExport() }
        }
    }

    private var content: some View {
        VStack(spacing: embedded ? 0 : 20) {
            if embedded {
                ScrollView {
                    formContent
                        .padding(24)
                        .frame(maxWidth: 960, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                formContent
            }
            Divider()
            footer
                .padding(.horizontal, embedded ? 24 : 0)
                .padding(.vertical, embedded ? 14 : 0)
                .background(embedded ? Palette.card : Palette.background)
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : options.grid != nil ? 720 : options.processing == nil ? 480 : 640)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Palette.background).foregroundStyle(Palette.foreground).tint(Palette.accent)
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .overlay {
            if isDropTargeted, options.processing != nil, !model.exportingImages {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard options.processing != nil, !model.exportingImages else { return false }
            do {
                try model.appendImageExportSources(urls)
                inputError = nil
                return true
            } catch { inputError = error.localizedDescription; return false }
        } isTargeted: { isDropTargeted = $0 }
        .interactiveDismissDisabled(model.exportingImages)
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
        .accessibilityIdentifier(embedded ? "image-processing-options" : "batch-export-sheet")
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                if !embedded { Text(title).consoleFont(17, weight: .semibold) }
                Text(options.grid != nil ? L("先裁切为正方形，再生成宫格切片。")
                     : options.processing != nil ? L("\(imageCount) 张图片 · 按输入顺序处理") : L("\(imageCount) 张图片 · 按保管箱当前显示顺序导出"))
                    .consoleFont(12).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if options.processing != nil, !model.exportingImages {
                HStack {
                    Text(L("可拖入图片继续添加")).consoleFont(11).foregroundStyle(Palette.muted)
                    Spacer()
                    Button(L("添加图片…"), action: addImages).buttonStyle(QuietButtonStyle())
                }
                if let inputError { Text(inputError).consoleFont(11).foregroundStyle(.red) }
            }
            if model.exportingImages {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.exportFilename).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(model.exportProgress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(Palette.muted)
                    }
                    ProgressView(value: model.exportProgress)
                }.padding(.vertical, 12)
            }
            if embedded || !model.exportingImages {
                if options.grid != nil, let imageURL = model.batchExportImages.first {
                    if embedded {
                        gridOptions(imageURL)
                    } else {
                        ScrollView { gridOptions(imageURL) }.frame(height: 460)
                    }
                } else if options.processing != nil {
                    if embedded {
                        processingOptions
                    } else {
                        ScrollView { processingOptions }.frame(height: 360)
                    }
                } else if options.mode == .video {
                    videoOptions
                } else {
                    imageOptions
                }
            }
        }
        .disabled(model.exportingImages)
    }

    private var processingOptions: some View {
        ImageProcessingControls(options: Binding(get: { options.processing! }, set: { options.processing = $0 }),
                                images: model.batchExportImages)
    }

    private func gridOptions(_ imageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ImageGridControls(options: Binding(get: { options.grid! }, set: { options.grid = $0 }),
                              imageURL: imageURL, validationMessage: $gridValidationMessage,
                              cropConfirmed: $cropConfirmed)
            if cropConfirmed {
                Divider()
                gridFileOptions
            }
        }
    }

    private var footer: some View {
        HStack {
            if embedded {
                Button(model.exportingImages ? L("取消导出") : L("返回上一步")) {
                    if model.exportingImages { model.cancelExport() }
                    else { model.returnToImageProcessingInput() }
                }
                .buttonStyle(QuietButtonStyle())
            } else {
                Button(model.exportingImages ? L("取消导出") : L("取消")) { model.dismissImageExport() }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: 12)
            if !model.exportingImages, options.grid == nil || cropConfirmed {
                Button(L("选择位置并导出…")) { model.exportImages(options: options) }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(options.mode == .video && !(2...4096).contains(options.maxDimension))
                    .disabled(options.processing.map { !$0.isValid } == true)
                    .disabled(options.grid != nil && (!cropConfirmed || gridValidationMessage != nil || imageCount != 1))
            }
        }
    }

    private var gridFileOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("格式"), selection: $options.imageFormat) {
                Text("JPEG").tag(BatchImageFormat.jpeg)
                Text("PNG").tag(BatchImageFormat.png)
            }.pickerStyle(.segmented)
            if options.imageFormat == .jpeg {
                HStack(spacing: 10) {
                    Text(L("质量"))
                    Slider(value: Binding(get: { Double(options.quality) }, set: { options.quality = Int($0.rounded()) }),
                           in: 1...100)
                    Text("\(options.quality)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            if let imageURL = model.batchExportImages.first, let grid = options.grid,
               let first = BatchImageExporter.gridFilenames(imageURL, options: grid, format: options.imageFormat).first {
                Text(L("文件名从 \(first) 开始编号，按编号顺序发布。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.controlSize(.small)
    }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.title = L("选择要处理的图片")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do { try model.appendImageExportSources(panel.urls); inputError = nil }
        catch { inputError = error.localizedDescription }
    }

    private var imageOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("格式"), selection: $options.imageFormat) {
                Text("PNG").tag(BatchImageFormat.png)
                Text("JPEG").tag(BatchImageFormat.jpeg)
                Text("PDF").tag(BatchImageFormat.pdf)
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("质量"))
                    Spacer()
                    Text("\(options.quality)%").monospacedDigit()
                }
                Slider(value: Binding(get: { Double(options.quality) }, set: { options.quality = Int($0.rounded()) }),
                       in: 1...100)
                    .disabled(options.imageFormat == .png)
                Text(options.imageFormat == .png ? L("PNG 无损保存，质量固定为 100%。") : L("100% 为最佳质量；降低质量可减小文件。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
            }
            Text(options.imageFormat == .pdf ? L("按顺序合成一个多页 PDF，每张图片独占一页。") : L("每张图片单独保存，保留原始尺寸。"))
                .consoleFont(12).foregroundStyle(Palette.muted)
            if options.mode == .zip {
                Text(L("所选格式的文件将打包为一个 ZIP 压缩包。"))
                    .consoleFont(12).foregroundStyle(Palette.muted)
            }
        }
        .onChange(of: options.imageFormat) { _, format in
            if format == .png { options.quality = 100 }
        }
    }

    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("格式"), selection: $options.videoFormat) {
                Text("MP4").tag(KeyframeExportFormat.mp4)
                Text("GIF").tag(KeyframeExportFormat.gif)
            }.pickerStyle(.segmented)
            HStack(spacing: 8) {
                ForEach([1, 5, 15], id: \.self) { fps in
                    Button { options.fps = fps } label: {
                        VStack(spacing: 4) {
                            Text("\(fps) fps").fontWeight(.medium)
                            Text(fps == 1 ? L("逐张查看") : fps == 5 ? L("快速浏览") : L("动态播放"))
                                .consoleFont(11)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(options.fps == fps ? Palette.accent : Palette.foreground)
                        .background(options.fps == fps ? Palette.accent.opacity(0.1) : Palette.card,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay { SurfaceBorder(color: options.fps == fps ? Palette.accent : Palette.line, cornerRadius: 6) }
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(options.fps == fps ? .isSelected : [])
                }
            }
            Text(L("每张图片显示 \((1.0 / Double(options.fps)).formatted(.number.precision(.fractionLength(0...2)))) 秒，共 \((Double(imageCount) / Double(options.fps)).formatted(.number.precision(.fractionLength(0...2)))) 秒。"))
                .consoleFont(12).foregroundStyle(Palette.muted)
            DisclosureGroup(L("高级"), isExpanded: $showAdvanced) {
                VStack(spacing: 14) {
                    Stepper(L("帧率：\(options.fps) fps"), value: $options.fps, in: 1...30)
                    HStack {
                        Text(L("最长边"))
                        Spacer()
                        TextField(L("像素"), value: $options.maxDimension, format: .number.grouping(.never))
                            .environment(\.isFocusEffectEnabled, true)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 76)
                        Text("px").foregroundStyle(Palette.muted)
                    }
                    Text(L("最长边 2–4096 px；保持比例，仅缩小。尺寸不一致时以白底补齐。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 12)
            }
        }
        .onChange(of: options.videoFormat) { _, format in
            options.maxDimension = format.defaultMaxDimension
        }
    }
}
