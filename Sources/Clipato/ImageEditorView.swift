import AppKit
import SwiftUI

struct ImageEditorView: View {
    let image: CGImage
    let onSave: (CGImage, AssetTag?) throws -> Void
    let onPin: (CGImage) -> Void
    let onClose: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var tool = AnnotationTool.rectangle
    @State private var color: Color = .red
    @State private var annotations: [ImageAnnotation] = []
    @State private var changes: [AnnotationChange] = []
    @State private var undone: [AnnotationChange] = []
    @State private var fontSize: CGFloat = 48
    @State private var mosaicShape = MosaicShape.brush
    @State private var mosaicBrushSize: CGFloat = 48
    @State private var mosaicSize: CGFloat = 16
    @State private var canvas: EditorImageCanvas?
    @State private var isEditingText = false
    @State private var zoom: CGFloat = 1
    @State private var zoomText = "100"
    @State private var zoomInputError = false
    @State private var errorMessage: String?
    @State private var showsColors = false
    @State private var tag: AssetTag?

    init(image: CGImage, initialTag: AssetTag? = nil,
         onSave: @escaping (CGImage, AssetTag?) throws -> Void,
         onPin: @escaping (CGImage) -> Void, onClose: @escaping () -> Void) {
        self.image = image
        self.onSave = onSave
        self.onPin = onPin
        self.onClose = onClose
        _tag = State(initialValue: initialTag)
    }

    private var minimumZoom: CGFloat { 1 / CGFloat(max(image.width, image.height)) }
    private let maximumZoom: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                            .help(L("缩小")).accessibilityLabel(L("缩小")).disabled(zoom <= minimumZoom)
                        HStack(spacing: 3) {
                            TextField(L("缩放"), text: $zoomText)
                                .environment(\.isFocusEffectEnabled, true)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 6)
                                .frame(width: 74, height: 28)
                                .background(Palette.card, in: RoundedRectangle(cornerRadius: 5))
                                .overlay { SurfaceBorder(color: zoomInputError ? .red : Palette.line, cornerRadius: 5) }
                                .onSubmit(commitZoom)
                                .accessibilityIdentifier("editorZoomPercentage")
                                .help(L("输入百分比后按回车。缩放仅影响预览，保存保留原图像素。"))
                            Text("%").foregroundStyle(.secondary)
                        }.font(.caption.monospacedDigit())
                        if zoomInputError { Text(L("须大于 0")).font(.caption).foregroundStyle(.red) }
                        Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                            .help(L("放大")).accessibilityLabel(L("放大")).disabled(zoom >= maximumZoom)
                        Button(L("100% 原始像素")) { setZoom(1) }
                        Button(L("适应窗口")) {
                            let available = CGSize(width: geometry.size.width - 32, height: geometry.size.height - 79)
                            setZoom(min(1, min(available.width * displayScale / CGFloat(image.width),
                                              available.height * displayScale / CGFloat(image.height))))
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L("原图 \(image.width) × \(image.height) px"))
                            Text(L("显示 \(max(1, Int((CGFloat(image.width) * zoom).rounded()))) × \(max(1, Int((CGFloat(image.height) * zoom).rounded()))) px"))
                        }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                    .buttonStyle(QuietButtonStyle())
                    .font(.system(size: 12))
                    .padding(.horizontal, 16).frame(height: 46)
                    Divider()
                    EditorImageViewport(image: image, annotations: annotations, tool: tool, color: NSColor(color),
                                        fontSize: fontSize, mosaicShape: mosaicShape,
                                        mosaicBrushSize: mosaicBrushSize, mosaicSize: mosaicSize, onAnnotationChange: apply,
                                        onCanvasReady: { canvas = $0 }, onTextEditing: { isEditingText = $0 },
                                        onRenderError: { errorMessage = $0.localizedDescription },
                                        zoom: $zoom, minimumZoom: minimumZoom, maximumZoom: maximumZoom) {
                        apply(.add($0))
                    }
                }
            }.background(Palette.background)
            Divider()
            VStack(spacing: 8) {
                if tool == .mosaic { mosaicOptions }
                annotationToolbar
                Text(tool == .mosaic ? L("拖动涂抹 · ⌘Z 撤销 · ⇧⌘Z 重做") :
                     tool == .text ? L("Delete 删除标注 · 双击文字编辑 · ⌘Enter 完成") : L("Delete 删除标注 · 双击文字编辑"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Palette.card)
        .tint(Palette.accent)
        .foregroundStyle(Palette.foreground)
        .onChange(of: tool) { _, _ in showsColors = false; canvas?.finishTextEditing() }
        .onChange(of: zoom) { _, _ in zoomText = formattedZoom; zoomInputError = false }
        .alert(L("标注失败"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L("好")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
    }

    private var annotationToolbar: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { annotationTool in
                Button { tool = annotationTool } label: {
                    if annotationTool == .text || annotationTool == .mosaic {
                        Image(nsImage: annotationTool.image).renderingMode(.template)
                    } else { Image(systemName: annotationTool.symbol) }
                }
                    .buttonStyle(EditorToolbarButtonStyle(selected: tool == annotationTool))
                    .help(annotationTool.title).accessibilityLabel(annotationTool.title)
                    .accessibilityValue(tool == annotationTool ? L("已选中") : "")
            }
            toolbarDivider
            if tool != .mosaic {
                Button { showsColors.toggle() } label: {
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .overlay { SurfaceBorder(color: .primary.opacity(0.18), cornerRadius: 3) }
                        .frame(width: 21, height: 15)
                }
                .buttonStyle(EditorToolbarButtonStyle())
                .help(L("标注颜色")).accessibilityLabel(L("标注颜色"))
                .popover(isPresented: $showsColors, arrowEdge: .bottom) { colorPalette }
                if tool == .text || isEditingText {
                    Menu {
                        Picker(L("字号"), selection: $fontSize) {
                            ForEach([12, 16, 24, 32, 48, 64, 96, 128], id: \.self) { size in
                                Text("\(size) px").tag(CGFloat(size))
                            }
                        }
                    } label: { optionLabel("\(Int(fontSize)) px") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("文字字号")).accessibilityLabel(L("文字字号"))
                }
            }
            toolbarButton(L("撤销 ⌘Z"), symbol: "arrow.uturn.backward", action: undo)
                .disabled(changes.isEmpty && !isEditingText)
                .keyboardShortcut("z", modifiers: .command)
            toolbarButton(L("重做 ⇧⌘Z"), symbol: "arrow.uturn.forward", action: redo)
                .disabled(undone.isEmpty || isEditingText)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            toolbarDivider
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
            .font(.system(size: 12))
            .help(L("保存时设置颜色标签"))
            .accessibilityIdentifier("editor-save-tag")
            toolbarDivider
            toolbarButton(L("关闭 Esc"), symbol: "xmark", action: onClose)
            toolbarButton(L("贴到屏幕"), symbol: "pin.fill") { perform(onPin) }
            toolbarButton(L("保存到保管箱"), symbol: "square.and.arrow.down") {
                perform { result in try onSave(result, tag); onClose() }
            }.keyboardShortcut(.defaultAction)
            toolbarButton(L("复制图片"), symbol: "doc.on.doc") {
                perform { result in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: result, size: CGSize(width: result.width, height: result.height))])
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay { SurfaceBorder(cornerRadius: 9) }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("editor-annotation-toolbar")
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Palette.line).frame(width: 1, height: 18).padding(.horizontal, 2)
    }

    private func toolbarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(EditorToolbarButtonStyle()).help(title).accessibilityLabel(title)
    }

    private func optionLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.foreground)
        .padding(.horizontal, 7).frame(height: 28)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 5))
        .overlay { SurfaceBorder(cornerRadius: 5) }
    }

    private var colorPalette: some View {
        let colors: [(String, NSColor)] = [(L("红色"), .systemRed), (L("橙色"), .systemOrange), (L("黄色"), .systemYellow),
                                          (L("绿色"), .systemGreen), (L("蓝色"), .systemBlue), (L("紫色"), .systemPurple),
                                          (L("黑色"), .black), (L("白色"), .white)]
        return HStack(spacing: 4) {
            ForEach(colors.indices, id: \.self) { index in
                Button {
                    color = Color(nsColor: colors[index].1)
                    showsColors = false
                } label: {
                    RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: colors[index].1))
                        .overlay { SurfaceBorder(color: .primary.opacity(0.18), cornerRadius: 3) }
                        .frame(width: 21, height: 18)
                }
                .buttonStyle(EditorToolbarButtonStyle())
                .help(colors[index].0).accessibilityLabel(colors[index].0)
            }
            ColorPicker(L("自定义"), selection: $color, supportsOpacity: false)
                .labelsHidden().controlSize(.small).frame(width: 28, height: 28)
                .help(L("自定义颜色")).accessibilityLabel(L("自定义颜色"))
        }.padding(8).focusEffectDisabled()
    }

    private var mosaicOptions: some View {
        HStack(spacing: 8) {
            Picker(L("涂抹方式"), selection: $mosaicShape) {
                ForEach(MosaicShape.allCases) { shape in Text(shape.title).tag(shape) }
            }.pickerStyle(.segmented).frame(minWidth: 120).frame(height: 28)
                .fixedSize(horizontal: true, vertical: false)
            if mosaicShape == .brush {
                Text(L("笔刷"))
                Menu {
                    Picker(L("笔刷"), selection: $mosaicBrushSize) {
                        ForEach([16, 32, 48, 80, 128], id: \.self) { size in Text("\(size) px").tag(CGFloat(size)) }
                    }
                } label: { optionLabel("\(Int(mosaicBrushSize)) px") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("笔刷"))
            }
            Text(L("颗粒"))
            Menu {
                Picker(L("颗粒"), selection: $mosaicSize) {
                    ForEach([8, 16, 24, 32, 48], id: \.self) { size in Text("\(size) px").tag(CGFloat(size)) }
                }
            } label: { optionLabel("\(Int(mosaicSize)) px") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("颗粒"))
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { SurfaceBorder(cornerRadius: 8) }
    }

    private var formattedZoom: String {
        (Double(zoom) * 100).formatted(.number.precision(.fractionLength(0...5)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private func commitZoom() {
        guard let percent = Double(zoomText), percent.isFinite, percent > 0 else {
            zoomInputError = true
            return
        }
        setZoom(CGFloat(percent / 100))
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, minimumZoom), maximumZoom)
        zoomText = formattedZoom
        zoomInputError = false
    }

    private func undo() {
        canvas?.finishTextEditing()
        guard let change = changes.popLast() else { return }
        change.undo(in: &annotations)
        canvas?.annotations = annotations
        undone.append(change)
    }

    private func redo() {
        guard let change = undone.popLast() else { return }
        change.apply(to: &annotations)
        canvas?.annotations = annotations
        changes.append(change)
    }

    private func apply(_ change: AnnotationChange) {
        change.apply(to: &annotations)
        changes.append(change)
        undone.removeAll()
    }

    private func perform(_ action: (CGImage) throws -> Void) {
        canvas?.finishTextEditing()
        do { try action(renderedImage()) }
        catch { errorMessage = error.localizedDescription }
    }

    private func renderedImage() throws -> CGImage {
        try renderAnnotatedImage(image, annotations: annotations)
    }
}

private struct EditorToolbarButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .foregroundStyle(selected ? Palette.accent : Palette.foreground)
            .background(selected ? Palette.accent.opacity(0.13) : (configuration.isPressed ? Palette.foreground.opacity(0.08) : .clear),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.3)
    }
}
