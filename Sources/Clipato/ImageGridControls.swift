import ClipatoCore
import ImageIO
import SwiftUI

struct ImageGridControls: View {
    @Binding var options: ImageGridOptions
    let imageURL: URL
    @Binding var validationMessage: String?
    @Binding var cropConfirmed: Bool
    @Environment(\.consoleFontScale) private var fontScale
    @State private var tileSize: String
    @State private var gap: String
    @State private var sourceSize: CGSize?
    @State private var previewImage: CGImage?
    @State private var sourceError: String?
    @State private var loadedURL: URL?
    @State private var rects: [CGRect] = []
    @State private var dragOrigin: CGPoint?
    @State private var dragSide: CGFloat = 0
    @State private var dragCorner: ImageGridCropCorner?
    @FocusState private var cropFocused: Bool

    init(options: Binding<ImageGridOptions>, imageURL: URL, validationMessage: Binding<String?>,
         cropConfirmed: Binding<Bool>) {
        _options = options
        self.imageURL = imageURL
        _validationMessage = validationMessage
        _cropConfirmed = cropConfirmed
        _tileSize = State(initialValue: String(options.wrappedValue.tileSize))
        _gap = State(initialValue: String(options.wrappedValue.gap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if cropConfirmed { gridControls } else { squareCropControls }
        }
        .consoleFont(12)
        .controlSize(.small)
        .textFieldStyle(.roundedBorder)
        .onChange(of: options) { previous, current in
            if cropConfirmed, previous.divisions != current.divisions || previous.gap != current.gap {
                fitTileSizeToCrop()
            }
            if previous.tileSize != current.tileSize { tileSize = String(options.tileSize) }
            if previous.gap != current.gap { gap = String(current.gap) }
            validate()
        }
        .onChange(of: cropConfirmed) { _, _ in validate() }
        .task(id: imageURL) { await readSource() }
    }

    private var squareCropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("1 · 裁切正方形")).fontWeight(.medium)
                Spacer(minLength: 6)
                if let sourceSize {
                    Text(L("原图 \(Int(sourceSize.width)) × \(Int(sourceSize.height)) px"))
                        .foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
            cropPreview
            if let crop = options.crop, let sourceSize {
                let side = Binding(get: { Int(crop.width) }, set: { resizeCrop(side: $0) })
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(L("裁切范围"))
                        cropDimensionFields(side)
                        Spacer(minLength: 4)
                        Button(L("重置裁切")) { resetCrop() }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("裁切范围"))
                            Spacer(minLength: 4)
                            Button(L("重置裁切")) { resetCrop() }
                        }
                        cropDimensionFields(side)
                    }
                }
                let maximumSide = Int(min(sourceSize.width, sourceSize.height))
                if maximumSide > 1 {
                    HStack(spacing: 8) {
                        Text(L("裁切大小"))
                        Slider(value: Binding(get: { Double(crop.width) }, set: { resizeCrop(side: Int($0.rounded())) }),
                               in: 1...Double(maximumSide))
                        Text(L("拖动预览可移动"))
                            .consoleFont(11).foregroundStyle(Palette.muted)
                    }
                }
            }
            if let sourceError {
                Text(sourceError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("请先确认正方形裁切区域。"))
                    .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("下一步：宫格设置")) { confirmCrop() }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(sourceSize == nil || sourceError != nil || options.crop == nil)
            }
        }
    }

    private var gridControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("2 · 宫格设置")).fontWeight(.medium)
                Spacer(minLength: 6)
                Button(L("返回调整裁切")) { cropConfirmed = false }
            }
            HStack(spacing: 12) {
                Picker(L("宫格"), selection: $options.divisions) {
                    Text(L("4 宫格")).tag(2)
                    Text(L("9 宫格")).tag(3)
                }.pickerStyle(.segmented).frame(width: 190 * max(1, fontScale))
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    tileSizeControl
                    Spacer(minLength: 8)
                    gapControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    tileSizeControl
                    gapControl
                }
            }
            Text(L("发布排列预览")).fontWeight(.medium)
            gridPreview
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("\(options.divisions * options.divisions) 个输出文件 · 每片 \(options.tileSize) × \(options.tileSize) px · 从左到右、从上到下编号"))
                .foregroundStyle(Palette.muted).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Text(L("间隙处的原图像素将被裁掉，直接无缝拼回不会还原原图。"))
                .consoleFont(11).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cropDimensionFields(_ side: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(L("宽")).foregroundStyle(Palette.muted)
            TextField(L("宽"), value: side, format: .number.grouping(.never))
                .frame(width: 68 * max(1, fontScale)).multilineTextAlignment(.trailing)
            Text("×").foregroundStyle(Palette.muted)
            Text(L("高")).foregroundStyle(Palette.muted)
            TextField(L("高"), value: side, format: .number.grouping(.never))
                .frame(width: 68 * max(1, fontScale)).multilineTextAlignment(.trailing)
            Text("px").foregroundStyle(Palette.muted)
            Label("1:1", systemImage: "lock")
                .foregroundStyle(Palette.muted)
                .help(L("裁切保持正方形，修改宽度或高度会同步另一边。"))
        }
        .environment(\.isFocusEffectEnabled, true)
    }

    private var tileSizeControl: some View {
        HStack(spacing: 8) {
            Text(L("单片尺寸"))
            TextField(L("单片尺寸"), text: Binding(get: { tileSize }, set: {
                tileSize = $0
                if let value = Int($0) { options.tileSize = value }
                validate()
            })).frame(width: 74 * max(1, fontScale)).multilineTextAlignment(.trailing)
            Text("px").foregroundStyle(Palette.muted)
        }
        .environment(\.isFocusEffectEnabled, true)
    }

    private var gapControl: some View {
        HStack(spacing: 8) {
            Text(L("跳过间隙"))
            TextField(L("跳过间隙"), text: Binding(get: { gap }, set: {
                gap = $0
                if let value = Int($0) { options.gap = value }
                validate()
            })).frame(width: 66 * max(1, fontScale)).multilineTextAlignment(.trailing)
            Text("px").foregroundStyle(Palette.muted)
        }
        .environment(\.isFocusEffectEnabled, true)
    }

    private var cropPreview: some View {
        GeometryReader { geometry in
            let frame = sourceSize.map { fittedFrame(content: $0, in: geometry.size) } ?? .zero
            Canvas { context, _ in
                guard let previewImage, let sourceSize, let crop = options.crop else { return }
                context.draw(Image(decorative: previewImage, scale: 1), in: frame)
                let scale = frame.width / sourceSize.width
                let displayCrop = displayRect(crop, in: frame, scale: scale)
                var outside = Path(frame)
                outside.addRect(displayCrop)
                context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                context.stroke(Path(displayCrop), with: .color(Palette.accent), lineWidth: 2)
                for corner in ImageGridCropCorner.allCases {
                    let point = corner.point(in: displayCrop)
                    let handle = Path(roundedRect: CGRect(x: point.x - 4.5, y: point.y - 4.5,
                                                          width: 9, height: 9), cornerRadius: 2)
                    context.fill(handle, with: .color(.white))
                    context.stroke(handle, with: .color(Palette.accent), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let sourceSize, let crop = options.crop else { return }
                let scale = frame.width / sourceSize.width
                if dragOrigin == nil {
                    let displayCrop = displayRect(crop, in: frame, scale: scale)
                    // Keep the centre movable when a small crop's corner hit areas overlap.
                    let moveArea = displayCrop.insetBy(dx: displayCrop.width / 4, dy: displayCrop.height / 4)
                    let corner = moveArea.contains(value.startLocation) ? nil
                        : ImageGridCropCorner.hit(at: value.startLocation, in: displayCrop, radius: 11)
                    guard corner != nil || displayCrop.contains(value.startLocation) else { return }
                    dragOrigin = crop.origin
                    dragSide = crop.width
                    dragCorner = corner
                    cropFocused = true
                }
                if let dragOrigin {
                    let translation = CGSize(width: value.translation.width / scale,
                                             height: value.translation.height / scale)
                    if let dragCorner {
                        let initial = CGRect(origin: dragOrigin, size: CGSize(width: dragSide, height: dragSide))
                        options.crop = dragCorner.resized(initial, translation: translation, within: sourceSize)
                        validate()
                    } else {
                        setCropOrigin(CGPoint(x: dragOrigin.x + translation.width.rounded(),
                                              y: dragOrigin.y + translation.height.rounded()))
                    }
                }
            }.onEnded { _ in
                dragOrigin = nil
                dragCorner = nil
            })
            .focusable(options.crop != nil)
            .focused($cropFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard let crop = options.crop else { return }
                var origin = crop.origin
                switch direction {
                case .left: origin.x -= 1
                case .right: origin.x += 1
                case .up: origin.y -= 1
                case .down: origin.y += 1
                @unknown default: return
                }
                setCropOrigin(origin)
            }
            .overlay {
                if previewImage == nil, sourceError == nil { ProgressView().controlSize(.small) }
            }
            .help(L("拖动四角调整大小；拖动框内移动；方向键每次微调 1 px。"))
            .accessibilityLabel(L("裁切范围"))
        }
        .frame(height: 260)
        .background(Palette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { SurfaceBorder(cornerRadius: 7) }
    }

    private var gridPreview: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                guard let previewImage, let sourceSize, let crop = options.crop else { return }
                let frame = fittedFrame(content: crop.size, in: geometry.size)
                let scale = frame.width / crop.width
                let sourceFrame = CGRect(x: frame.minX - crop.minX * scale, y: frame.minY - crop.minY * scale,
                                         width: sourceSize.width * scale, height: sourceSize.height * scale)
                context.clip(to: Path(frame))
                context.draw(Image(decorative: previewImage, scale: 1), in: sourceFrame)
                guard rects.count == options.divisions * options.divisions else { return }
                if options.gap > 0 {
                    for index in 1..<options.divisions {
                        let vertical = CGRect(x: rects[index - 1].maxX, y: crop.minY,
                                              width: CGFloat(options.gap), height: crop.height)
                        let horizontal = CGRect(x: crop.minX, y: rects[(index - 1) * options.divisions].maxY,
                                                width: crop.width, height: CGFloat(options.gap))
                        context.fill(Path(displayRect(vertical, in: sourceFrame, scale: scale)), with: .color(Palette.canvas))
                        context.fill(Path(displayRect(horizontal, in: sourceFrame, scale: scale)), with: .color(Palette.canvas))
                    }
                }
                for (index, rect) in rects.enumerated() {
                    let tile = displayRect(rect, in: sourceFrame, scale: scale)
                    context.stroke(Path(tile.insetBy(dx: 0.5, dy: 0.5)), with: .color(Palette.accent), lineWidth: 1)
                    let badge = CGRect(x: tile.minX + 4, y: tile.minY + 4, width: 20, height: 20)
                    context.fill(Path(roundedRect: badge, cornerRadius: 5), with: .color(.black.opacity(0.65)))
                    context.draw(Text(String(index + 1)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white),
                                 at: CGPoint(x: badge.midX, y: badge.midY))
                }
            }
            .accessibilityLabel(L("发布排列预览"))
        }
        .frame(height: 260)
        .background(Palette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { SurfaceBorder(cornerRadius: 7) }
    }

    private func fittedFrame(content: CGSize, in size: CGSize) -> CGRect {
        let scale = min(max(1, size.width - 16) / content.width, max(1, size.height - 16) / content.height)
        let width = content.width * scale
        let height = content.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func displayRect(_ rect: CGRect, in frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: frame.minX + rect.minX * scale, y: frame.minY + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    private var maximumTileSize: Int? {
        guard let crop = options.crop, [2, 3].contains(options.divisions), options.gap >= 0 else { return nil }
        let (skipped, overflow) = (options.divisions - 1).multipliedReportingOverflow(by: options.gap)
        let side = Int(crop.width)
        guard !overflow, skipped < side else { return nil }
        let maximum = (side - skipped) / options.divisions
        return maximum > 0 ? min(4096, maximum) : nil
    }

    private func fitTileSizeToCrop() {
        if let maximumTileSize, options.tileSize > maximumTileSize {
            options.tileSize = maximumTileSize
            tileSize = String(maximumTileSize)
        }
    }

    private func confirmCrop() {
        fitTileSizeToCrop()
        cropFocused = false
        cropConfirmed = true
        validate()
    }

    private func resetCrop() {
        guard let sourceSize else { return }
        let side = min(sourceSize.width, sourceSize.height)
        let origin = CGPoint(x: ((sourceSize.width - side) / 2).rounded(.down),
                             y: ((sourceSize.height - side) / 2).rounded(.down))
        options.crop = CGRect(origin: origin, size: CGSize(width: side, height: side))
        validate()
    }

    private func resizeCrop(side: Int) {
        guard let crop = options.crop, let sourceSize else { return }
        let maximumSide = Int(min(sourceSize.width, sourceSize.height))
        let side = CGFloat(min(max(1, side), maximumSide))
        let origin = CGPoint(x: crop.midX - side / 2, y: crop.midY - side / 2)
        options.crop = CGRect(origin: origin, size: CGSize(width: side, height: side))
        setCropOrigin(origin)
    }

    private func setCropOrigin(_ origin: CGPoint) {
        guard let sourceSize, let crop = options.crop else { return }
        options.crop = CGRect(x: min(max(0, origin.x.rounded()), sourceSize.width - crop.width),
                              y: min(max(0, origin.y.rounded()), sourceSize.height - crop.height),
                              width: crop.width, height: crop.height)
        validate()
    }

    private func validate() {
        rects = []
        if let sourceError { validationMessage = sourceError; return }
        guard cropConfirmed else { validationMessage = L("请先确认正方形裁切区域。"); return }
        guard let size = Int(tileSize), (1...4096).contains(size) else {
            validationMessage = imageGridErrorDescription(ImageGridError.invalidTileSize(0))
            return
        }
        guard let pixels = Int(gap), pixels >= 0 else {
            validationMessage = imageGridErrorDescription(ImageGridError.invalidGap(-1))
            return
        }
        guard let sourceSize else { validationMessage = L("正在读取图片…"); return }
        do {
            if let crop = options.crop {
                let (skipped, overflow) = (options.divisions - 1).multipliedReportingOverflow(by: pixels)
                guard !overflow, skipped < Int(crop.width) else { throw ImageGridError.invalidGap(pixels) }
            }
            rects = try ImageGridStep.sourceRects(width: Int(sourceSize.width), height: Int(sourceSize.height), options: options)
            validationMessage = nil
        } catch { validationMessage = imageGridErrorDescription(error) }
    }

    private func readSource() async {
        if let loadedURL, loadedURL != imageURL {
            options.crop = nil
            cropConfirmed = false
        }
        loadedURL = imageURL
        sourceSize = nil
        previewImage = nil
        sourceError = nil
        validate()
        let url = imageURL
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { throw ImageProcessingError.unreadableImage(url) }
                let orientation = properties[kCGImagePropertyOrientation] as? Int
                let rotated = orientation.map { (5...8).contains($0) } == true
                let size = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
                let image = try ImageFormatStep.readImage(at: url, maximumDimension: 800)
                try Task.checkCancellation()
                return (size, image)
            }
        }
        do {
            let (size, image) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            sourceSize = size
            previewImage = image
            if options.crop == nil { resetCrop() }
            validate()
        } catch is CancellationError { return }
        catch {
            sourceError = imageProcessingErrorDescription(error)
            validationMessage = sourceError
        }
    }
}
