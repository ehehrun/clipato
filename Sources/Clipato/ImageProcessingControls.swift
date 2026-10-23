import ClipatoCore
import ImageIO
import SwiftUI

enum ImageTool: Hashable, Identifiable, Sendable {
    case compress, resize, convert, grid

    var id: Self { self }

    var title: String {
        switch self {
        case .compress: return L("压缩图片")
        case .resize: return L("调整尺寸")
        case .convert: return L("转换格式")
        case .grid: return L("宫格切图")
        }
    }
}

struct ImageProcessingOptions: Equatable, Sendable {
    var format: ImageOutputFormat = .jpeg
    var quality = 90
    var targetBytes: Int?
    var allowResizing = true
    var resizeEnabled = false
    var sizes: [ImageResizeOptions] = []

    init(tool: ImageTool) {
        switch tool {
        case .compress: targetBytes = 500 * 1024
        case .resize:
            resizeEnabled = true
            sizes = [.init(width: 1280, height: 720)]
        case .convert, .grid: break
        }
    }

    var isValid: Bool { validationMessage == nil }

    var validationMessage: String? {
        if let targetBytes, targetBytes <= 0 { return L("请输入有效的目标体积（KB）。") }
        guard (1...100).contains(quality) else { return L("导出质量须为 1% 到 100%。") }
        guard resizeEnabled else { return nil }
        guard !sizes.isEmpty else { return L("请至少选择一个输出规格，或关闭调整尺寸。") }
        for (index, size) in sizes.enumerated() {
            guard (1...ImageResizeStep.maximumDimension).contains(size.width),
                  (1...ImageResizeStep.maximumDimension).contains(size.height) else {
                return L("宽高须为 1 到 32768 px。")
            }
            if size.mode != .fit, size.width * size.height > ImageResizeStep.maximumPixels {
                return L("每个输出规格不能超过 6400 万像素。")
            }
            if format == .webp, size.mode != .fit, max(size.width, size.height) > 16_383 {
                return L("WebP 每边最多为 16383 px。")
            }
            if sizes[..<index].contains(size) {
                return L("请勿重复选择相同尺寸。")
            }
        }
        return nil
    }
}

struct ImageProcessingControls: View {
    @Binding var options: ImageProcessingOptions
    let images: [URL]
    @Environment(\.consoleFontScale) private var fontScale
    @State private var targetKB: String
    @State private var resizeMode: ImageResizeOptions.Mode
    @State private var customEnabled: Bool
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var sourceSize: CGSize?
    @State private var metadataError: String?

    private static let presets = [
        ImageResizeOptions(width: 256, height: 256),
        ImageResizeOptions(width: 800, height: 800),
        ImageResizeOptions(width: 1280, height: 720),
        ImageResizeOptions(width: 1920, height: 1080),
        ImageResizeOptions(width: 1080, height: 1920)
    ]

    init(options: Binding<ImageProcessingOptions>, images: [URL]) {
        _options = options
        self.images = images
        let value = options.wrappedValue
        _targetKB = State(initialValue: value.targetBytes.map { String($0 / 1024) } ?? "500")
        _resizeMode = State(initialValue: value.sizes.first?.mode ?? .fit)
        let custom = value.sizes.last { size in
            !Self.presets.contains { $0.width == size.width && $0.height == size.height }
        }
        _customEnabled = State(initialValue: custom != nil)
        _customWidth = State(initialValue: String(custom?.width ?? 1280))
        _customHeight = State(initialValue: String(custom?.height ?? 720))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("格式"), selection: $options.format) {
                Text("JPEG").tag(ImageOutputFormat.jpeg)
                Text("PNG").tag(ImageOutputFormat.png)
                Text("WebP").tag(ImageOutputFormat.webp)
            }.pickerStyle(.segmented)
            Text(L("仅处理首帧；JPEG 将透明区域填为白色，PNG / WebP 保留透明度。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            compressionControls
            Divider()
            resizeControls
            if let message = options.validationMessage {
                Text(message).consoleFont(11).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            outputPlan
        }
        .controlSize(.small)
        .textFieldStyle(.roundedBorder)
        .task(id: images.first) { await readSourceSize() }
    }

    private var compressionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Toggle(L("目标体积"), isOn: Binding(get: { options.targetBytes != nil }, set: {
                    options.targetBytes = $0 ? targetByteCount : nil
                }))
                Spacer(minLength: 8)
                if options.targetBytes != nil {
                    TextField(L("目标体积"), text: $targetKB)
                        .environment(\.isFocusEffectEnabled, true)
                        .multilineTextAlignment(.trailing).frame(width: 90 * max(1, fontScale))
                        .onChange(of: targetKB) { _, _ in options.targetBytes = targetByteCount }
                    Text("KB").foregroundStyle(Palette.muted)
                }
            }
            if options.targetBytes != nil {
                Toggle(L("必要时允许缩小尺寸"), isOn: $options.allowResizing)
                Text(options.format == .png
                     ? L("PNG 保持无损；达到目标体积可能需要缩小尺寸。无法达标时会提示失败。")
                     : L("自动优化质量以满足体积目标；允许时再缩小尺寸，无法达标时会提示失败。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if options.format == .png {
                Text(L("PNG 无损保存，质量固定为 100%。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 10) {
                    Text(L("质量"))
                    Slider(value: Binding(get: { Double(options.quality) }, set: { options.quality = Int($0.rounded()) }), in: 1...100)
                    Text("\(options.quality)%").monospacedDigit().frame(width: 40 * max(1, fontScale), alignment: .trailing)
                }
            }
        }
    }

    private var resizeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(L("调整尺寸"), isOn: Binding(get: { options.resizeEnabled }, set: {
                    options.resizeEnabled = $0
                    if $0, options.sizes.isEmpty {
                        options.sizes = [.init(width: 1280, height: 720, mode: resizeMode)]
                    }
                }))
                Spacer()
                if let sourceSize {
                    Text(L("原图 \(Int(sourceSize.width)) × \(Int(sourceSize.height)) px"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                }
            }
            if options.resizeEnabled {
                LazyVGrid(columns: [.init(.adaptive(minimum: 240 * max(1, fontScale)), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(Self.presets.indices, id: \.self) { index in
                        let size = Self.presets[index]
                        Toggle(isOn: presetBinding(size)) {
                            HStack(spacing: 6) {
                                Text("\(size.width) × \(size.height)").monospacedDigit()
                                Text(presetTitle(index)).consoleFont(11).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                    Toggle(L("自定义"), isOn: Binding(get: { customEnabled }, set: { enabled in
                        if enabled {
                            options.sizes.append(.init(width: Int(customWidth) ?? 0, height: Int(customHeight) ?? 0, mode: resizeMode))
                        } else { options.sizes.removeLast() }
                        customEnabled = enabled
                    }))
                }
                if customEnabled {
                    HStack(spacing: 8) {
                        Text(L("宽"))
                        TextField(L("宽"), text: $customWidth).frame(width: 80 * max(1, fontScale))
                        Text("×").foregroundStyle(Palette.muted)
                        Text(L("高"))
                        TextField(L("高"), text: $customHeight).frame(width: 80 * max(1, fontScale))
                        Text("px").foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                    }
                    .environment(\.isFocusEffectEnabled, true)
                    .onChange(of: customWidth) { _, _ in updateCustomSize() }
                    .onChange(of: customHeight) { _, _ in updateCustomSize() }
                }
                Picker(L("尺寸适配"), selection: $resizeMode) {
                    Text(L("保持比例")).tag(ImageResizeOptions.Mode.fit)
                    Text(L("白底补齐")).tag(ImageResizeOptions.Mode.pad)
                    Text(L("中心裁剪")).tag(ImageResizeOptions.Mode.crop)
                }.pickerStyle(.segmented)
                    .onChange(of: resizeMode) { _, mode in
                        for index in options.sizes.indices { options.sizes[index].mode = mode }
                    }
                Text(L("可同时选择多个规格；每边 1–32768 px，单张最多 6400 万像素。WebP 每边最多 16383 px。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var outputPlan: some View {
        let variants = options.resizeEnabled ? options.sizes.count : 1
        let names = BatchImageExporter.processedFilenames(Array(images.prefix(1)), options: options)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L("输出计划")).fontWeight(.medium)
                Spacer()
                Text(L("\(images.count * variants) 个输出文件")).foregroundStyle(Palette.muted)
            }
            if let metadataError {
                Text(metadataError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(names.indices, id: \.self) { index in
                            HStack(spacing: 10) {
                                Text(names[index]).lineLimit(1).truncationMode(.middle).help(names[index])
                                Spacer(minLength: 8)
                                if let size = previewSize(at: index) {
                                    Text("\(Int(size.width)) × \(Int(size.height)) px").monospacedDigit().foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
                Text(L("以上为首张图片的计划，其余图片沿用同一规则。启用目标体积时，实际尺寸可能缩小。"))
                    .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.consoleFont(11)
    }

    private var targetByteCount: Int {
        guard let kilobytes = Int(targetKB), kilobytes > 0 else { return 0 }
        let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
        return overflow ? 0 : bytes
    }

    private func presetTitle(_ index: Int) -> String {
        switch index {
        case 0: return L("头像")
        case 1: return L("商品")
        case 2: return L("高清")
        case 3: return L("全高清")
        default: return L("竖屏")
        }
    }

    private func presetBinding(_ size: ImageResizeOptions) -> Binding<Bool> {
        Binding(get: {
            options.sizes.dropLast(customEnabled ? 1 : 0).contains { $0.width == size.width && $0.height == size.height }
        }, set: { selected in
            if selected {
                options.sizes.insert(.init(width: size.width, height: size.height, mode: resizeMode), at: options.sizes.count - (customEnabled ? 1 : 0))
            } else if let index = options.sizes.dropLast(customEnabled ? 1 : 0).firstIndex(where: { $0.width == size.width && $0.height == size.height }) {
                options.sizes.remove(at: index)
            }
        })
    }

    private func updateCustomSize() {
        options.sizes[options.sizes.count - 1] = .init(width: Int(customWidth) ?? 0, height: Int(customHeight) ?? 0, mode: resizeMode)
    }

    private func previewSize(at index: Int) -> CGSize? {
        guard let sourceSize else { return nil }
        guard options.resizeEnabled else { return sourceSize }
        let size = options.sizes[index]
        guard size.width > 0, size.height > 0 else { return nil }
        if size.mode != .fit { return CGSize(width: size.width, height: size.height) }
        let scale = min(Double(size.width) / sourceSize.width, Double(size.height) / sourceSize.height)
        return CGSize(width: max(1, (sourceSize.width * scale).rounded(.down)), height: max(1, (sourceSize.height * scale).rounded(.down)))
    }

    private func readSourceSize() async {
        sourceSize = nil
        metadataError = nil
        guard let url = images.first else { return }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let size: CGSize = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { throw ImageProcessingError.unreadableImage(url) }
                if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                    return CGSize(width: height, height: width)
                }
                return CGSize(width: width, height: height)
            }
            try Task.checkCancellation()
            return size
        }
        do {
            let size = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            sourceSize = size
        } catch is CancellationError { return }
        catch { metadataError = L("无法读取图片：\(url.path)") }
    }
}
