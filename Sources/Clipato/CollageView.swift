import AppKit
import ClipatoCore
import SwiftUI

enum CollageWorkspaceMode: String, CaseIterable {
    case grid, flow, longScreenshot

    var title: String {
        switch self {
        case .grid: return L("网格")
        case .flow: return L("自由拼")
        case .longScreenshot: return L("长图")
        }
    }

    static var savedCollageMode: Self {
        UserDefaults.standard.string(forKey: "collageLayoutMode") == Self.flow.rawValue ? .flow : .grid
    }
}

struct CollageView: View {
    let images: [CGImage]
    let onSave: (CGImage, AssetTag?, CollageWorkspaceMode) throws -> Void
    let onCopy: (CGImage) -> Bool
    let onChange: () -> Void
    let onClose: () -> Void

    @State private var mode: CollageWorkspaceMode
    @State private var settings: CollageSettings
    @State private var gridSettings: CollageSettings
    @State private var flowSettings: CollageSettings
    @State private var longScreenshotState = LongScreenshotState()
    @State private var preview: CGImage?
    @State private var previewZoom: CGFloat = 1
    @State private var previewFitsWindow = true
    @State private var freeCanvas = FreeCollageCanvasView(frame: .zero)
    @State private var error: String?
    @State private var previewIsCurrent = false
    @State private var copied = false
    @State private var tag: AssetTag?
    @State private var autoArrange = false
    @State private var automaticOrder: [Int]
    @State private var dragSessionID = UUID()
    @State private var placements: [CollagePlacement] = []
    @State private var selectedImageIndex: Int?
    @State private var fitRequest = 0
    @State private var previewTask: Task<Void, Never>?
    @State private var previewWindow: CollagePreviewWindowController?

    init(images: [CGImage], initialMode: CollageWorkspaceMode, initialTag: AssetTag? = nil,
         onSave: @escaping (CGImage, AssetTag?, CollageWorkspaceMode) throws -> Void,
         onCopy: @escaping (CGImage) -> Bool, onChange: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.images = images
        _mode = State(initialValue: initialMode)
        _tag = State(initialValue: initialTag)
        _automaticOrder = State(initialValue: Array(images.indices))
        self.onSave = onSave
        self.onCopy = onCopy
        self.onChange = onChange
        self.onClose = onClose
        let columns = min(64, max(1, Int(Double(images.count).squareRoot().rounded(.up))))
        let grid = CollageSettings(columns: columns, rows: max(1, (images.count + columns - 1) / columns))
        var flow = grid
        flow.mode = .flow
        _gridSettings = State(initialValue: grid)
        _flowSettings = State(initialValue: flow)
        _settings = State(initialValue: initialMode == .flow ? flow : grid)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("拼图工作台")).font(.title2.weight(.semibold))
                    Text(L("\(automaticOrder.count) 张截图 · 原图保持不变"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("布局"), selection: $mode) {
                    ForEach(CollageWorkspaceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300, height: 28)
                    .disabled(longScreenshotState.isWorking)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(QuietButtonStyle())
                    .help(L("关闭")).accessibilityLabel(L("关闭"))
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(24)

            CollageImageOrderView(
                images: images, order: automaticOrder,
                selectedImageIndex: stripSelectedImage,
                sessionID: dragSessionID, isManual: isManual,
                onSelect: { index in
                    if mode == .longScreenshot {
                        longScreenshotState.selectImage(at: automaticOrder.firstIndex(of: index))
                    } else { selectedImageIndex = index }
                }, onMove: reorderImage
            )
            .disabled(longScreenshotState.isWorking)

            Divider()

            if mode == .longScreenshot {
                LongScreenshotView(images: images, order: $automaticOrder, tag: $tag, state: longScreenshotState,
                                   onSave: { try onSave($0, $1, .longScreenshot) },
                                   onClose: onClose, onChange: onChange)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    ScrollView { controls }.frame(width: 220)

                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Palette.canvas)
                            if isManual {
                                FreeCollageCanvas(view: freeCanvas, images: images, placements: $placements,
                                                  selectedImageIndex: $selectedImageIndex, fitRequest: fitRequest,
                                                  onChange: manualChanged, onError: { error = $0 })
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else if let preview {
                                CollageImagePreview(image: preview, zoom: $previewZoom, fitsWindow: $previewFitsWindow)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                ContentUnavailableView(L("预览拼图"), systemImage: "square.grid.2x2", description: Text(L("调整布局后点击生成预览。")))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 250)

                        if isManual, !placements.isEmpty {
                            let bounds = placements.reduce(CGRect.null) { $0.union($1.frame) }.integral
                            Text(L("\(Int(bounds.width)) × \(Int(bounds.height)) 像素 · 拖动移动，四角缩放 · 滚动平移"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let preview {
                            HStack(spacing: 5) {
                                if !previewIsCurrent { Image(systemName: "exclamationmark.triangle.fill") }
                                Text(L("\(preview.width) × \(preview.height) 像素\(previewIsCurrent ? "" : L(" · 参数已修改，请更新预览"))"))
                            }
                            .font(.caption).fontWeight(previewIsCurrent ? .regular : .medium)
                            .foregroundStyle(previewIsCurrent ? Palette.muted : Palette.warning)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack(spacing: 6) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if copied && outputIsReady {
                        Label(L("图片已拷贝，可用 ⌘V 粘贴"), systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(Palette.accent)
                    } else {
                        Text(L("输出为白色背景 PNG，单张元素等比缩放。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: showFullScreenPreview) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help(L("全屏预览")).accessibilityLabel(L("全屏预览"))
                    .disabled(isManual && placements.isEmpty)
                    Button(action: copyImage) {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(!outputIsReady)
                    .help(L("拷贝拼图图片，可直接用 ⌘V 粘贴"))
                    .accessibilityLabel(L("拷贝"))
                    if isManual {
                        Button { fitRequest += 1 } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                            .help(L("适应画布")).accessibilityLabel(L("适应画布"))
                    } else {
                        Button(action: renderPreview) { Image(systemName: "arrow.clockwise") }
                            .help(L("生成预览")).accessibilityLabel(L("生成预览"))
                    }
                    Menu {
                        AssetTagActions(selected: [tag]) { tag = $0 }
                    } label: {
                        Group {
                            if let tag { AssetTagLabel(tag: tag) }
                            else { Label(L("标签"), systemImage: "tag") }
                        }.menuLabel()
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L("设置导出拼图的颜色标签"))
                    Button(L("导出到保管箱")) {
                        do {
                            try onSave(try outputImage(), tag, mode)
                            onClose()
                        }
                        catch { self.error = workspaceErrorDescription(error) }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!outputIsReady)
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                .buttonStyle(QuietButtonStyle())
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Palette.card)
        .tint(Palette.accent)
        .foregroundStyle(Palette.foreground)
        .onAppear { if mode != .longScreenshot { changeMode() } }
        .onDisappear {
            previewTask?.cancel()
            previewWindow?.close()
            previewWindow = nil
        }
        .onChange(of: mode) { previous, current in
            if previous == .grid { gridSettings = settings }
            else if previous == .flow { flowSettings = settings }
            if current != .longScreenshot {
                settings = current == .grid ? gridSettings : flowSettings
                UserDefaults.standard.set(current.rawValue, forKey: "collageLayoutMode")
            }
            changeMode()
        }
        .onChange(of: automaticOrder) { synchronizeOrder() }
        .onChange(of: tag) { onChange() }
        .onChange(of: autoArrange) { changeMode(); onChange() }
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
    }

    private var isManual: Bool { mode == .flow && !autoArrange }
    private var outputIsReady: Bool { isManual ? !placements.isEmpty : previewIsCurrent && preview != nil }
    private var selectedPlacementIndex: Int? { placements.firstIndex { $0.imageIndex == selectedImageIndex } }
    private var stripSelectedImage: Int? {
        guard mode == .longScreenshot else { return selectedImageIndex }
        guard let position = longScreenshotState.selectedImagePosition, automaticOrder.indices.contains(position) else { return nil }
        return automaticOrder[position]
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            if settings.mode == .flow {
                Toggle(L("开启一键拼"), isOn: $autoArrange)
                    .toggleStyle(.switch)
                Text(autoArrange ? L("自动排列并换行；关闭后恢复手动布局。") : L("拖动图片自由摆放、交叉覆盖，拖动四角等比缩放。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if isManual {
                manualControls
            } else {
                automaticControls
            }

            Text(L("画布上限 6400 万像素，最大边 32768 px。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var automaticControls: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("\(settings.mode == .grid ? L("列数") : L("目标行宽"))：\(settings.columns)\(settings.mode == .flow ? L(" 列") : "")", value: parameter(\.columns), in: 1...64)
                if settings.mode == .grid {
                    Stepper(L("行数：\(settings.rows)"), value: parameter(\.rows), in: 1...64)
                    let insufficientGrid = settings.columns * settings.rows < automaticOrder.count
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if insufficientGrid { Image(systemName: "exclamationmark.triangle.fill") }
                        Text(L("需要至少 \(automaticOrder.count) 个网格位置，当前 \(settings.columns * settings.rows) 个。"))
                    }
                    .font(.caption).fontWeight(insufficientGrid ? .medium : .regular)
                    .foregroundStyle(insufficientGrid ? Palette.warning : Palette.muted)
                } else {
                    Text(L("按图片实际尺寸依次排列并自动换行。目标行宽由最大元素宽度和列数决定。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("缩放比例"))
                    Spacer()
                    Text(settings.scale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: parameter(\.scale), in: 0.05...4, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L("元素最大尺寸")).font(.subheadline.weight(.semibold))
                dimensionField(L("宽"), value: parameter(\.maxWidth))
                dimensionField(L("高"), value: parameter(\.maxHeight))
                Text(L("缩放后的元素仍受最大宽高约束。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Stepper(L("间距：\(settings.spacing) px"), value: parameter(\.spacing), in: 0...512, step: 2)
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(L("选择图片"), selection: $selectedImageIndex) {
                Text(L("未选择")).tag(Int?.none)
                ForEach(automaticOrder, id: \.self) { index in
                    Text(L("图片 \(index + 1)")).tag(Optional(index))
                }
            }.tint(nil as Color?)
            if let index = selectedPlacementIndex {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("单张图片大小")).font(.subheadline.weight(.semibold))
                    dimensionField(L("宽"), value: Binding(
                        get: { Int(placements[index].frame.width.rounded()) },
                        set: { resizeSelected(dimension: $0, isWidth: true) }))
                    dimensionField(L("高"), value: Binding(
                        get: { Int(placements[index].frame.height.rounded()) },
                        set: { resizeSelected(dimension: $0, isWidth: false) }))
                    Text(L("宽高联动，保持原图比例；单边最大 8192 px。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("叠放层级")).font(.subheadline.weight(.semibold))
                    HStack {
                        Button(L("下移一层")) { moveSelected(to: index - 1) }.disabled(index == 0)
                        Button(L("上移一层")) { moveSelected(to: index + 1) }.disabled(index == placements.count - 1)
                    }
                    HStack {
                        Button(L("置底")) { moveSelected(to: 0) }.disabled(index == 0)
                        Button(L("置顶")) { moveSelected(to: placements.count - 1) }.disabled(index == placements.count - 1)
                    }
                }
            } else {
                Text(L("点击画布里的图片，或从上方菜单选择被遮住的图片。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("捏合或 ⌘滚轮缩放画布；导出自动裁到所有图片的边界，保留叠放关系。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dimensionField(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 20)
            TextField(title, value: value, format: .number.grouping(.never))
                .environment(\.isFocusEffectEnabled, true)
                .textFieldStyle(.roundedBorder)
            Text("px").foregroundStyle(.secondary)
        }
    }

    private func parameter<Value>(_ keyPath: WritableKeyPath<CollageSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: {
            settings[keyPath: keyPath] = $0
            parametersChanged()
        })
    }

    private func renderPreview() {
        previewTask?.cancel()
        copied = false
        do {
            preview = try CollageRenderer.render(images: automaticOrder.map { images[$0] }, settings: settings)
            previewIsCurrent = true
            error = nil
        } catch {
            self.error = workspaceErrorDescription(error)
            previewIsCurrent = false
        }
    }

    private func changeMode() {
        dragSessionID = UUID()
        previewTask?.cancel()
        previewWindow?.close()
        previewWindow = nil
        copied = false
        error = nil
        if mode == .longScreenshot {
            preview = nil
            previewIsCurrent = false
            return
        }
        if isManual {
            preview = nil
            previewIsCurrent = false
            if placements.isEmpty {
                do {
                    let layout = try CollageRenderer.layout(images: automaticOrder.map { images[$0] }, settings: settings)
                    placements = layout.placements.map {
                        CollagePlacement(imageIndex: automaticOrder[$0.imageIndex], frame: $0.frame)
                    }
                    if selectedImageIndex == nil { selectedImageIndex = placements.first?.imageIndex }
                    fitRequest += 1
                } catch { self.error = workspaceErrorDescription(error) }
            }
        } else {
            renderPreview()
        }
    }

    private func parametersChanged() {
        onChange()
        previewIsCurrent = false
        copied = false
        previewTask?.cancel()
        if mode == .flow && autoArrange {
            // Sliders can produce many updates; compose once the adjustment settles.
            previewTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch is CancellationError { return }
                catch { self.error = workspaceErrorDescription(error); return }
                guard !Task.isCancelled else { return }
                renderPreview()
            }
        }
    }

    private func manualChanged() {
        copied = false
        error = nil
        onChange()
    }

    private func resizeSelected(dimension: Int, isWidth: Bool) {
        guard let index = selectedPlacementIndex else { return }
        let image = images[placements[index].imageIndex]
        let scale = Double(dimension) / Double(isWidth ? image.width : image.height)
        let width = max(1, (Double(image.width) * scale).rounded())
        let height = max(1, (Double(image.height) * scale).rounded())
        guard dimension > 0, width <= 8192, height <= 8192 else {
            error = L("图片宽高必须介于 1 到 8192 像素。")
            return
        }
        var next = placements
        next[index].frame.size = CGSize(width: width, height: height)
        do {
            _ = try CollageRenderer.bounds(for: next)
            placements = next
            manualChanged()
        } catch { self.error = workspaceErrorDescription(error) }
    }

    private func moveSelected(to index: Int) {
        guard let current = selectedPlacementIndex else { return }
        let placement = placements.remove(at: current)
        placements.insert(placement, at: index)
        automaticOrder = placements.map(\.imageIndex)
        manualChanged()
    }

    private func reorderImage(sessionID: UUID, source: Int, destination: Int) {
        guard sessionID == dragSessionID, source != destination, !longScreenshotState.isWorking,
              let current = automaticOrder.firstIndex(of: source),
              let target = automaticOrder.firstIndex(of: destination) else { return }
        automaticOrder.remove(at: current)
        automaticOrder.insert(source, at: target)
        selectedImageIndex = source
    }

    private func synchronizeOrder() {
        let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.imageIndex, $0) })
        placements = automaticOrder.compactMap { frames[$0] }
        if let selectedImageIndex, !automaticOrder.contains(selectedImageIndex) { self.selectedImageIndex = nil }
        copied = false
        onChange()
        if mode != .longScreenshot && !isManual { renderPreview() }
    }

    private func outputImage() throws -> CGImage {
        if isManual {
            return try CollageRenderer.render(images: images, placements: placements, background: settings.background)
        }
        guard let preview, previewIsCurrent else {
            throw CollageError.invalidSetting(L("请先生成当前参数的预览。"))
        }
        return preview
    }

    private func copyImage() {
        do {
            copied = onCopy(try outputImage())
            error = copied ? nil : L("无法将图片写入剪贴板，请重试。")
        } catch {
            copied = false
            self.error = workspaceErrorDescription(error)
        }
    }

    private func showFullScreenPreview() {
        if !isManual && !previewIsCurrent {
            renderPreview()
            guard previewIsCurrent else { return }
        }
        do {
            let controller = CollagePreviewWindowController(image: try outputImage())
            previewWindow?.close()
            previewWindow = controller
            controller.showFullScreen()
            error = nil
        } catch { self.error = workspaceErrorDescription(error) }
    }
}
