import AppKit
import CoreText

@MainActor
final class SelectionView: NSView {
    enum Mode {
        case screenshot(allowsDestinationActions: Bool)
        case recording
        case fixedCapture
    }

    private enum Drag {
        case create(CGPoint)
        case move(CGPoint, CGRect)
        case resize(Int, CGRect)
        case annotate
        case moveText(index: Int, anchor: CGPoint, original: ImageAnnotation, bounds: CGRect)
    }

    let image: CGImage
    let mode: Mode
    var onFinish: ((CGRect?, ScreenshotAction) -> Void)?
    var onRenderError: ((Error) -> Void)?
    var onRecordingModeChange: ((RecordingMode) -> Void)?
    private(set) var recordingMode: RecordingMode
    private(set) var assetTag: AssetTag?
    private(set) var selection = CGRect.zero
    private(set) var annotations: [ImageAnnotation] = [] {
        didSet {
            textBounds = annotations.map(\.textBounds)
            if !annotations.contains(where: { $0.tool == .mosaic }) {
                mosaicRenderer = nil
                mosaicCrop = nil
            }
        }
    }
    private var textBounds: [CGRect] = []
    private let background: NSImage
    private let drawingOverlay = SelectionDrawingView()
    private let pointerOverlay = SelectionPointerView()
    private let pointerValueText = SelectionTextLine(font: CTFontCreateUIFontForLanguage(.userFixedPitch, 11, nil)!)
    private let pointerHintText = SelectionTextLine(font: CTFontCreateUIFontForLanguage(.system, 10, nil)!)
    private let pointerLabelText = SelectionTextLine(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!)
    private let dimensionsText = SelectionTextLine(font: CTFontCreateUIFontForLanguage(.userFixedPitch, 11, nil)!)
    private let colorSampler = Result { try ScreenPixelColorSampler() }
    private let toolbar = NSVisualEffectView()
    private let toolbarStack = NSStackView()
    private let colorPalette = NSVisualEffectView()
    private let mosaicOptions = NSVisualEffectView()
    private let mosaicShapePicker = SelectionSegmentedControl()
    private let mosaicBrushPicker = SelectionPopUpButton(frame: .zero, pullsDown: false)
    private let mosaicSizePicker = SelectionPopUpButton(frame: .zero, pullsDown: false)
    private let recordingModePicker = SelectionSegmentedControl()
    private let tagPicker = NativeAssetTagPicker()
    private let allowsTagSelection: Bool
    private var mosaicShape = MosaicShape.brush
    private var mosaicBrushSize: CGFloat = 24
    private var mosaicSize: CGFloat = 16
    private var mosaicRenderer: MosaicRenderer?
    private var mosaicCrop: CGRect?
    private var renderingFailed = false
    private var buttons: [String: NSButton] = [:]
    private var tool: AnnotationTool?
    private var color = NSColor.systemRed
    private var history: [AnnotationChange] = []
    private var undone: [AnnotationChange] = []
    private var currentAnnotation: ImageAnnotation?
    private var textEditor: AnnotationTextEditor?
    private var editingTextIndex: Int?
    private var selectedAnnotationIndex: Int?
    private var fontSize: CGFloat = 24
    private let fontSizePicker = SelectionPopUpButton(frame: .zero, pullsDown: false)
    private var drag: Drag?
    private var pointer = CGPoint.zero
    private var installedCursor: NSCursor?
    private var isPointerInside = false
    private var finished = false
    private var hasStartedSelection = false
    private let showsFullScreenCrosshair: Bool
    private let colorPasteboard: NSPasteboard
    private(set) var colorFormat: ScreenshotColorFormat
    private var sampledColor: ScreenPixelColor?
    private var sampledPixel: CGPoint?
    private var didCopyColor = false
    private var colors: [(String, NSColor)] { [(L("红色"), .systemRed), (L("橙色"), .systemOrange), (L("黄色"), .systemYellow),
                                               (L("绿色"), .systemGreen), (L("蓝色"), .systemBlue), (L("紫色"), .systemPurple),
                                               (L("黑色"), .black), (L("白色"), .white)] }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, frame: CGRect, mode: Mode = .screenshot(allowsDestinationActions: true), initialFullScreen: Bool = false,
         recordingMode: RecordingMode = .keyframes, tag: AssetTag? = nil, allowsTagSelection: Bool = true,
         colorFormat: ScreenshotColorFormat? = nil, colorPasteboard: NSPasteboard = .general,
         showsFullScreenCrosshair: Bool = UserDefaults.standard.object(forKey: "screenshotShowsFullScreenCrosshair") == nil
            || UserDefaults.standard.bool(forKey: "screenshotShowsFullScreenCrosshair")) {
        self.image = image
        self.mode = mode
        self.recordingMode = recordingMode
        self.assetTag = tag
        self.allowsTagSelection = allowsTagSelection
        self.colorFormat = colorFormat ?? .saved()
        self.colorPasteboard = colorPasteboard
        self.showsFullScreenCrosshair = showsFullScreenCrosshair
        background = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        // Share the captured image with Core Animation; interaction only redraws the transparent overlay.
        wantsLayer = true
        drawingOverlay.selectionView = self
        drawingOverlay.identifier = NSUserInterfaceItemIdentifier("selection-drawing-overlay")
        drawingOverlay.frame = bounds
        drawingOverlay.autoresizingMask = [.width, .height]
        drawingOverlay.wantsLayer = true
        addSubview(drawingOverlay)
        pointerOverlay.identifier = NSUserInterfaceItemIdentifier("selection-pointer-overlay")
        pointerOverlay.frame = bounds
        pointerOverlay.autoresizingMask = [.width, .height]
        pointerOverlay.magnifier.selectionView = self
        addSubview(pointerOverlay)
        buildToolbar()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
        if initialFullScreen { selection = bounds }
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    static func prepareInterface() {
        autoreleasepool {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let pixel = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            pixel.setFillColor(CGColor(gray: 0, alpha: 1))
            pixel.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let view = SelectionView(image: pixel.makeImage()!, frame: CGRect(x: 0, y: 0, width: 640, height: 360))
            let window = SelectionWindow(contentRect: CGRect(x: -20000, y: -20000, width: 640, height: 360))
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            defer { window.contentView = nil; window.close() }
            let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            @MainActor func render() {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                CATransaction.flush()
                view.layer!.render(in: context)
            }
            view.pointer = CGPoint(x: 80, y: 80)
            view.isPointerInside = true
            view.updateColorSample()
            view.updatePointerOverlay()
            render()
            view.selection = CGRect(x: 48, y: 40, width: 520, height: 240)
            view.updateSelection()
            render()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installedCursor = nil
        if let window {
            pointer = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            isPointerInside = bounds.contains(pointer)
            updateColorSample()
            updatePointerOverlay()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil), force: true)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .crosshair)
    }

    func updateCursor(force: Bool = false) {
        guard let window, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        updateCursor(at: point, force: force)
    }

    private func updateCursor(at point: CGPoint, force: Bool = false) {
        guard !finished else { return }
        let cursor: NSCursor
        switch drag {
        case .create, .annotate:
            cursor = .crosshair
        case .move, .moveText:
            cursor = .closedHand
        case .resize(let handle, _):
            cursor = handle == 1 || handle == 5 ? .resizeUpDown : .resizeLeftRight
        case nil:
            if let textEditor, textEditor.frame.contains(point) {
                cursor = .iBeam
            } else if isOverToolbar(point) {
                cursor = .arrow
            } else if !selection.isEmpty, let handle = handleCenters.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 8 }) {
                cursor = handle == 1 || handle == 5 ? .resizeUpDown : .resizeLeftRight
            } else if selection.contains(point), tool != .mosaic, textIndex(at: point) != nil || tool == nil {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        }
        // Nonactivating panels can display another app's cursor despite NSCursor.current.
        if force || installedCursor !== cursor || NSCursor.current !== cursor {
            cursor.set()
            installedCursor = cursor
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.contains(pointer)
        updateColorSample()
        updateCursor(at: pointer, force: event.type == .mouseEntered)
        updatePointerOverlay()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        installedCursor = nil
        isPointerInside = false
        updateColorSample()
        updatePointerOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        guard !finished else { return }
        hasStartedSelection = true
        sampledColor = nil
        sampledPixel = nil
        drawingOverlay.needsDisplay = true
        let location = convert(event.locationInWindow, from: nil)
        // Empty toolbar space is still toolbar space, not a request for a new capture region.
        guard !isOverToolbar(location) else { return }
        finishTextEditing()
        window?.makeKey()
        window?.makeFirstResponder(self)
        pointer = constrained(location)
        isPointerInside = true
        selectedAnnotationIndex = nil
        if !selection.isEmpty, let handle = handleCenters.firstIndex(where: { hypot($0.x - pointer.x, $0.y - pointer.y) <= 8 }) {
            drag = .resize(handle, selection)
        } else if selection.contains(pointer) {
            if tool != .mosaic, let index = annotationIndex(at: pointer) {
                selectedAnnotationIndex = index
                if annotations[index].tool != .text {
                    updateSelection()
                } else if event.clickCount > 1 {
                    beginTextEditing(annotations[index], index: index)
                } else {
                    currentAnnotation = annotations[index]
                    drag = .moveText(index: index, anchor: annotationPoint(pointer), original: annotations[index], bounds: textBounds[index])
                    updateSelection()
                }
                return
            }
            if tool == .text {
                beginTextEditing(at: pointer)
                return
            }
            if event.clickCount == 2, tool != .mosaic { finish(.copy); return }
            if let tool {
                let scale = CGFloat(image.width) / bounds.width
                currentAnnotation = ImageAnnotation(tool: tool, points: [annotationPoint(pointer)], color: color,
                                                    width: (tool == .mosaic ? mosaicBrushSize : 2) * scale,
                                                    mosaicShape: mosaicShape, mosaicSize: mosaicSize)
                drag = .annotate
            } else {
                drag = .move(pointer, selection)
            }
        } else {
            annotations.removeAll()
            history.removeAll()
            undone.removeAll()
            currentAnnotation = nil
            tool = nil
            drag = .create(pointer)
            selection = .zero
        }
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !finished else { return }
        pointer = constrained(convert(event.locationInWindow, from: nil))
        switch drag {
        case .create(let anchor):
            selection = CGRect(x: min(anchor.x, pointer.x), y: min(anchor.y, pointer.y), width: abs(pointer.x - anchor.x), height: abs(pointer.y - anchor.y))
        case .move(let anchor, let original):
            selection.origin = CGPoint(x: min(max(original.minX + pointer.x - anchor.x, 0), bounds.width - original.width),
                                       y: min(max(original.minY + pointer.y - anchor.y, 0), bounds.height - original.height))
        case .resize(let handle, let original):
            var left = original.minX, right = original.maxX, top = original.minY, bottom = original.maxY
            if [0, 6, 7].contains(handle) { left = min(pointer.x, right - 2) }
            if [2, 3, 4].contains(handle) { right = max(pointer.x, left + 2) }
            if [0, 1, 2].contains(handle) { top = min(pointer.y, bottom - 2) }
            if [4, 5, 6].contains(handle) { bottom = max(pointer.y, top + 2) }
            selection = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        case .annotate:
            let point = annotationPoint(CGPoint(x: min(max(pointer.x, selection.minX), selection.maxX), y: min(max(pointer.y, selection.minY), selection.maxY)))
            if currentAnnotation!.tool == .pen || (currentAnnotation!.tool == .mosaic && currentAnnotation!.mosaicShape == .brush) {
                currentAnnotation!.points.append(point)
            }
            else { currentAnnotation!.points = [currentAnnotation!.points[0], point] }
        case .moveText(_, let anchor, let original, let textBounds):
            let point = annotationPoint(pointer)
            currentAnnotation = point == anchor ? original : original.movedText(
                by: CGPoint(x: point.x - anchor.x, y: point.y - anchor.y),
                within: CGRect(origin: .zero, size: pixelSelection.size), textBounds: textBounds)
            drawingOverlay.needsDisplay = true
            return
        case nil: return
        }
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil, !finished else { return }
        mouseDragged(with: event)
        if case .moveText(let index, _, let original, _) = drag, let currentAnnotation {
            if currentAnnotation != original { record(.replace(index: index, before: original, after: currentAnnotation)) }
            self.currentAnnotation = nil
            drag = nil
            updateSelection()
            return
        }
        if case .annotate = drag, let currentAnnotation {
            if currentAnnotation.isDrawable {
                record(.add(currentAnnotation))
            }
            self.currentAnnotation = nil
        }
        drag = nil
        if selection.width < 2 || selection.height < 2 { selection = .zero }
        else {
            let rect = pixelSelection
            selection = CGRect(x: rect.minX * bounds.width / CGFloat(image.width), y: rect.minY * bounds.height / CGFloat(image.height),
                               width: rect.width * bounds.width / CGFloat(image.width), height: rect.height * bounds.height / CGFloat(image.height))
        }
        updateSelection()
    }

    override func keyDown(with event: NSEvent) {
        if isColorPicking, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 48 {
                colorFormat = colorFormat.next
                didCopyColor = false
                updatePointerOverlay()
                return
            }
            if event.charactersIgnoringModifiers?.lowercased() == "c" {
                if let value = currentColorValue {
                    colorPasteboard.clearContents()
                    didCopyColor = colorPasteboard.setString(value, forType: .string)
                    if !didCopyColor { NSSound.beep() }
                } else { NSSound.beep() }
                updatePointerOverlay()
                return
            }
        }
        if moveSelection(with: event) { return }
        if (event.keyCode == 51 || event.keyCode == 117), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            deleteSelectedAnnotation()
        } else if event.keyCode == 53, selectedAnnotationIndex != nil {
            selectedAnnotationIndex = nil
            currentAnnotation = nil
            drag = nil
            updateSelection()
        } else if event.keyCode == 53 { cancel() }
        else if event.keyCode == 36 || event.keyCode == 76 { finish(.copy) }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { finish(.copy) }
        else { super.keyDown(with: event) }
    }

    private func moveSelection(with event: NSEvent) -> Bool {
        guard [123, 124, 125, 126].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !finished, !selection.isEmpty, textEditor == nil, drag == nil else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
        let dy: CGFloat = event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0)
        selection.origin = CGPoint(x: min(max(selection.minX + dx, 0), bounds.width - selection.width),
                                   y: min(max(selection.minY + dy, 0), bounds.height - selection.height))
        updateSelection()
        return true
    }

    private func deleteSelectedAnnotation() {
        guard !finished, textEditor == nil, let index = selectedAnnotationIndex else { return }
        let annotation = annotations[index]
        selectedAnnotationIndex = nil
        currentAnnotation = nil
        drag = nil
        record(.remove(index: index, annotation: annotation))
        updateSelection()
    }

    override func updateLayer() {
        layer!.contents = background
    }

    fileprivate func drawSelection(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        shade.fill()

        if !selection.isEmpty {
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            context.clip(to: selection)
            context.translateBy(x: selection.minX, y: selection.minY)
            context.scaleBy(x: bounds.width / CGFloat(image.width), y: bounds.height / CGFloat(image.height))
            drawAnnotations(in: context)
            if let index = selectedAnnotationIndex, editingTextIndex == nil {
                var rect = annotations[index].selectionBounds(textBounds: textBounds[index])
                if isDraggingText, let currentAnnotation {
                    rect = rect.offsetBy(dx: currentAnnotation.points[0].x - annotations[index].points[0].x,
                                         dy: currentAnnotation.points[0].y - annotations[index].points[0].y)
                }
                let scale = bounds.width / CGFloat(image.width)
                context.setStrokeColor(NSColor.systemBlue.cgColor)
                context.setLineWidth(1 / scale)
                context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
                context.stroke(rect.insetBy(dx: -2 / scale, dy: -2 / scale))
            }
            context.restoreGState()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1.5
            outline.stroke()
            if drag == nil {
                for point in handleCenters {
                    let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    NSColor.systemBlue.setFill(); handle.fill()
                    NSColor.white.setStroke(); handle.lineWidth = 1.2; handle.stroke()
                }
            }
            drawDimensions()
        }
    }

    var pixelSelection: CGRect {
        CGRect(x: selection.minX * CGFloat(image.width) / bounds.width,
               y: selection.minY * CGFloat(image.height) / bounds.height,
               width: selection.width * CGFloat(image.width) / bounds.width,
               height: selection.height * CGFloat(image.height) / bounds.height).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    var isColorPicking: Bool {
        guard case .screenshot = mode else { return false }
        return !finished && !hasStartedSelection && isPointerInside && selection.isEmpty && drag == nil
    }

    var currentColorValue: String? {
        isColorPicking ? sampledColor?.formatted(colorFormat) : nil
    }

    private var pointerPixel: CGPoint {
        CGPoint(x: min(max(floor(pointer.x * CGFloat(image.width) / bounds.width), 0), CGFloat(image.width - 1)),
                y: min(max(floor(pointer.y * CGFloat(image.height) / bounds.height), 0), CGFloat(image.height - 1)))
    }

    private func updateColorSample() {
        guard isColorPicking else {
            sampledColor = nil
            sampledPixel = nil
            return
        }
        let pixel = pointerPixel
        guard sampledPixel != pixel else { return }
        sampledPixel = pixel
        didCopyColor = false
        do { sampledColor = try colorSampler.get().sample(image: image, x: Int(pixel.x), y: Int(pixel.y)) }
        catch { sampledColor = nil }
    }

    private func drawAnnotations(in context: CGContext) {
        if renderingFailed {
            context.setFillColor(NSColor.gray.cgColor)
            context.fill(CGRect(origin: .zero, size: pixelSelection.size))
            return
        }
        do {
            let hasMosaic = currentAnnotation?.tool == .mosaic || annotations.contains { $0.tool == .mosaic }
            if hasMosaic, mosaicRenderer == nil || mosaicCrop != pixelSelection {
                mosaicRenderer = try MosaicRenderer(image: image, crop: pixelSelection)
                mosaicCrop = pixelSelection
            }
            func draw(_ annotation: ImageAnnotation) throws {
                if let mosaicRenderer { try mosaicRenderer.draw(annotation, in: context) }
                else { annotation.stroke(in: context) }
            }
            for (index, annotation) in annotations.enumerated() where index != editingTextIndex {
                if isDraggingText, index == selectedAnnotationIndex, let currentAnnotation { try draw(currentAnnotation) }
                else { try draw(annotation) }
            }
            if !isDraggingText, let currentAnnotation { try draw(currentAnnotation) }
        } catch {
            renderingFailed = true
            context.setFillColor(NSColor.gray.cgColor)
            context.fill(CGRect(origin: .zero, size: pixelSelection.size))
            DispatchQueue.main.async { [weak self] in self?.onRenderError?(error) }
        }
    }

    private var isCreating: Bool { if case .create = drag { return true }; return false }
    private var isDraggingText: Bool { if case .moveText = drag { return true }; return false }
    private func isOverToolbar(_ point: CGPoint) -> Bool {
        (!toolbar.isHidden && toolbar.frame.contains(point)) || (!colorPalette.isHidden && colorPalette.frame.contains(point))
            || (!mosaicOptions.isHidden && mosaicOptions.frame.contains(point))
    }
    private func textIndex(at point: CGPoint) -> Int? {
        let pixel = annotationPoint(point)
        let tolerance = 3 * CGFloat(image.width) / bounds.width
        return textBounds.indices.reversed().first { !textBounds[$0].isNull && textBounds[$0].insetBy(dx: -tolerance, dy: -tolerance).contains(pixel) }
    }
    private func annotationIndex(at point: CGPoint) -> Int? {
        let pixel = annotationPoint(point)
        let tolerance = 3 * CGFloat(image.width) / bounds.width
        return annotations.indices.reversed().first { annotations[$0].hitTest(pixel, tolerance: tolerance, textBounds: textBounds[$0]) }
    }
    private var handleCenters: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.maxX, y: selection.midY), CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY)]
    }

    @objc private func updateLanguage() {
        tagPicker.updateLanguage()
        let showingColors = !colorPalette.isHidden
        for container in [toolbar, colorPalette, mosaicOptions] {
            container.subviews.forEach { $0.removeFromSuperview() }
        }
        for control in [fontSizePicker, mosaicBrushPicker, mosaicSizePicker, recordingModePicker, mosaicShapePicker, tagPicker] as [NSControl] {
            NSLayoutConstraint.deactivate(control.constraints)
        }
        fontSizePicker.removeAllItems()
        mosaicBrushPicker.removeAllItems()
        mosaicSizePicker.removeAllItems()
        buttons.removeAll(keepingCapacity: true)
        buildToolbar()
        colorPalette.isHidden = !showingColors
        updateSelection()
    }

    private func buildToolbar() {
        toolbar.identifier = NSUserInterfaceItemIdentifier("selection-toolbar")
        toolbar.material = .popover
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer!.cornerRadius = 9
        let stack = toolbarStack
        stack.subviews.forEach { $0.removeFromSuperview() }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: toolbar.topAnchor), stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)])
        func button(_ id: String, _ title: String, _ symbol: String, _ action: Selector) {
            let image: NSImage
            if let annotationTool = AnnotationTool(rawValue: id) { image = annotationTool.image }
            else { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)! }
            let control = SelectionButton(image: image, target: self, action: action)
            control.title = ""
            control.imagePosition = .imageOnly
            control.focusRingType = .none
            control.identifier = NSUserInterfaceItemIdentifier(id)
            control.toolTip = title
            control.setAccessibilityLabel(title)
            control.bezelStyle = .texturedRounded
            control.isBordered = false
            control.controlSize = .small
            control.imageScaling = .scaleProportionallyDown
            control.widthAnchor.constraint(equalToConstant: 28).isActive = true
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons[id] = control
            stack.addArrangedSubview(control)
        }
        func addTagPicker() {
            guard allowsTagSelection else { return }
            tagPicker.identifier = NSUserInterfaceItemIdentifier("selection-tag-picker")
            tagPicker.assetTag = assetTag
            tagPicker.widthAnchor.constraint(equalToConstant: tagPicker.preferredWidth).isActive = true
            tagPicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
            tagPicker.onChange = { [weak self] tag in
                guard let self else { return }
                self.assetTag = tag
                if let editor = self.textEditor { self.window?.makeFirstResponder(editor) }
                else { self.window?.makeFirstResponder(self) }
            }
            stack.addArrangedSubview(tagPicker)
        }
        button("move", L("移动 / 调整选区 · 方向键 1 pt · Shift 10 pt"), "arrow.up.and.down.and.arrow.left.and.right", #selector(selectTool))
        switch mode {
        case .screenshot(let allowsDestinationActions):
            for annotationTool in AnnotationTool.allCases {
                button(annotationTool.rawValue, annotationTool == .text ? L("文字 · 拖动移动 · 双击编辑 · ⌘Enter 完成") : annotationTool.title, annotationTool.symbol, #selector(selectTool))
            }
            button("color", L("标注颜色"), "rectangle.fill", #selector(showColors))
            fontSizePicker.identifier = NSUserInterfaceItemIdentifier("annotation-font-size")
            fontSizePicker.focusRingType = .none
            fontSizePicker.controlSize = .small
            fontSizePicker.bezelStyle = .texturedRounded
            fontSizePicker.addItems(withTitles: [12, 16, 20, 24, 32, 48, 64, 96].map { "\($0) pt" })
            fontSizePicker.selectItem(withTitle: "\(Int(fontSize)) pt")
            fontSizePicker.target = self
            fontSizePicker.action = #selector(selectFontSize)
            fontSizePicker.toolTip = L("文字字号")
            fontSizePicker.setAccessibilityLabel(L("文字字号"))
            fontSizePicker.widthAnchor.constraint(equalToConstant: 64).isActive = true
            fontSizePicker.font = .systemFont(ofSize: 12)
            fontSizePicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
            fontSizePicker.isHidden = tool != .text && textEditor == nil
            stack.addArrangedSubview(fontSizePicker)
            button("undo", L("撤销 ⌘Z"), "arrow.uturn.backward", #selector(undo))
            button("redo", L("重做 ⇧⌘Z"), "arrow.uturn.forward", #selector(redo))
            addTagPicker()
            button("cancel", L("取消 Esc"), "xmark", #selector(cancel))
            if allowsDestinationActions {
                button("pin", L("贴到屏幕"), "pin.fill", #selector(pin))
                button("save", L("保存到文件…"), "square.and.arrow.down", #selector(save))
                button("copy", L("复制并完成 Enter"), "doc.on.doc", #selector(confirm))
            } else { button("copy", L("完成"), "checkmark", #selector(confirm)) }
        case .recording:
            recordingModePicker.identifier = NSUserInterfaceItemIdentifier("recording-mode-picker")
            recordingModePicker.focusRingType = .none
            recordingModePicker.controlSize = .small
            recordingModePicker.segmentStyle = .texturedRounded
            recordingModePicker.font = .systemFont(ofSize: 12)
            recordingModePicker.segmentCount = RecordingMode.allCases.count
            recordingModePicker.trackingMode = .selectOne
            for (index, recordingMode) in RecordingMode.allCases.enumerated() {
                recordingModePicker.setLabel("", forSegment: index)
                recordingModePicker.setImage(NSImage(systemSymbolName: recordingMode.toolbarSymbol,
                                                     accessibilityDescription: recordingMode.toolbarTitle)!
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)), forSegment: index)
                recordingModePicker.setImageScaling(.scaleProportionallyDown, forSegment: index)
                recordingModePicker.setToolTip(recordingMode.toolbarTitle, forSegment: index)
                recordingModePicker.setWidth(30, forSegment: index)
            }
            recordingModePicker.target = self
            recordingModePicker.action = #selector(selectRecordingMode)
            recordingModePicker.toolTip = L("关键帧保存变化画面，可导出视频或 GIF；完整视频连续录制 MP4。")
                + "\n" + L("录屏不支持录音，主要用于后续按帧截取图片。")
            recordingModePicker.setAccessibilityLabel(L("录屏模式"))
            recordingModePicker.widthAnchor.constraint(equalToConstant: 68).isActive = true
            recordingModePicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
            setRecordingMode(recordingMode)
            stack.addArrangedSubview(recordingModePicker)
            addTagPicker()
            button("cancel", L("取消 Esc"), "xmark", #selector(cancel))
            button("start", L("开始录屏"), "record.circle", #selector(confirm))
            buttons["start"]!.toolTip = L("开始录屏") + "\n" + L("录屏不支持录音，主要用于后续按帧截取图片。")
        case .fixedCapture:
            addTagPicker()
            button("cancel", L("取消 Esc"), "xmark", #selector(cancel))
            button("start-fixed-capture", L("开始连续截图"), "rectangle.stack.badge.plus", #selector(confirm))
        }
        updateToolbarSize()
        addSubview(toolbar)
        if case .screenshot = mode { buildColors(); buildMosaicOptions() }
    }

    private func updateToolbarSize() {
        let visible = toolbarStack.arrangedSubviews.filter { !$0.isHidden }
        let insets = toolbarStack.edgeInsets
        let spacing = CGFloat(max(visible.count - 1, 0)) * toolbarStack.spacing
        let width = visible.reduce(insets.left + insets.right + spacing) { total, view in
            total + view.constraints.first(where: { $0.firstAttribute == .width })!.constant
        }
        let contentHeight = visible.reduce(CGFloat.zero) { height, view in
            max(height, view.constraints.first(where: { $0.firstAttribute == .height })!.constant)
        }
        toolbar.frame.size = CGSize(width: width, height: max(38, contentHeight + insets.top + insets.bottom))
    }

    private func buildMosaicOptions() {
        mosaicOptions.identifier = NSUserInterfaceItemIdentifier("mosaic-options")
        mosaicOptions.material = .popover
        mosaicOptions.blendingMode = .withinWindow
        mosaicOptions.state = .active
        mosaicOptions.wantsLayer = true
        mosaicOptions.layer!.cornerRadius = 8
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        mosaicShapePicker.identifier = NSUserInterfaceItemIdentifier("mosaic-shape")
        mosaicShapePicker.focusRingType = .none
        mosaicShapePicker.controlSize = .small
        mosaicShapePicker.segmentStyle = .texturedRounded
        mosaicShapePicker.font = .systemFont(ofSize: 12)
        mosaicShapePicker.segmentCount = MosaicShape.allCases.count
        mosaicShapePicker.trackingMode = .selectOne
        for (index, shape) in MosaicShape.allCases.enumerated() { mosaicShapePicker.setLabel(shape.title, forSegment: index) }
        mosaicShapePicker.selectedSegment = MosaicShape.allCases.firstIndex(of: mosaicShape)!
        mosaicShapePicker.target = self
        mosaicShapePicker.action = #selector(selectMosaicShape)
        mosaicShapePicker.setAccessibilityLabel(L("马赛克方式"))
        mosaicShapePicker.widthAnchor.constraint(equalToConstant: max(120, mosaicShapePicker.intrinsicContentSize.width)).isActive = true
        mosaicShapePicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(mosaicShapePicker)
        func picker(_ control: NSPopUpButton, id: String, title: String, values: [Int], selected: Int, unit: String, action: Selector) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.widthAnchor.constraint(equalToConstant: max(26, label.intrinsicContentSize.width)).isActive = true
            stack.addArrangedSubview(label)
            control.identifier = NSUserInterfaceItemIdentifier(id)
            control.focusRingType = .none
            control.controlSize = .small
            control.bezelStyle = .texturedRounded
            control.font = .systemFont(ofSize: 12)
            control.addItems(withTitles: values.map { "\($0) \(unit)" })
            control.selectItem(withTitle: "\(selected) \(unit)")
            control.target = self
            control.action = action
            control.setAccessibilityLabel(L("马赛克\(title)"))
            control.widthAnchor.constraint(equalToConstant: 78).isActive = true
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
            stack.addArrangedSubview(control)
        }
        picker(mosaicBrushPicker, id: "mosaic-brush-size", title: L("笔刷"), values: [8, 16, 24, 32, 48, 64, 96], selected: Int(mosaicBrushSize), unit: "pt", action: #selector(selectMosaicBrush))
        picker(mosaicSizePicker, id: "mosaic-block-size", title: L("颗粒"), values: [4, 8, 12, 16, 24, 32], selected: Int(mosaicSize), unit: "px", action: #selector(selectMosaicSize))
        mosaicBrushPicker.isEnabled = mosaicShape == .brush
        let size = stack.fittingSize
        stack.frame = CGRect(x: 8, y: 5, width: size.width, height: max(28, size.height))
        mosaicOptions.frame.size = CGSize(width: size.width + 16, height: max(38, size.height + 10))
        mosaicOptions.addSubview(stack)
        mosaicOptions.isHidden = true
        addSubview(mosaicOptions)
    }

    func setRecordingMode(_ mode: RecordingMode) {
        recordingMode = mode
        recordingModePicker.selectedSegment = RecordingMode.allCases.firstIndex(of: mode)!
        recordingModePicker.setAccessibilityValue(mode.toolbarTitle)
    }

    @objc private func selectRecordingMode(_ sender: NSSegmentedControl) {
        setRecordingMode(RecordingMode.allCases[sender.selectedSegment])
        onRecordingModeChange?(recordingMode)
        window?.makeFirstResponder(self)
    }

    @objc private func selectMosaicShape(_ sender: NSSegmentedControl) {
        mosaicShape = MosaicShape.allCases[sender.selectedSegment]
        mosaicBrushPicker.isEnabled = mosaicShape == .brush
        window?.makeFirstResponder(self)
    }
    @objc private func selectMosaicBrush(_ sender: NSPopUpButton) {
        mosaicBrushSize = CGFloat([8, 16, 24, 32, 48, 64, 96][sender.indexOfSelectedItem])
        window?.makeFirstResponder(self)
    }
    @objc private func selectMosaicSize(_ sender: NSPopUpButton) {
        mosaicSize = CGFloat([4, 8, 12, 16, 24, 32][sender.indexOfSelectedItem])
        window?.makeFirstResponder(self)
    }

    private func buildColors() {
        colorPalette.identifier = NSUserInterfaceItemIdentifier("color-palette")
        colorPalette.material = .popover
        colorPalette.blendingMode = .withinWindow
        colorPalette.state = .active
        colorPalette.wantsLayer = true
        colorPalette.layer!.cornerRadius = 8
        colorPalette.frame.size = CGSize(width: colors.count * 28 + 12, height: 36)
        for (index, entry) in colors.enumerated() {
            let swatch = SelectionButton(image: NSImage(systemSymbolName: "rectangle.fill", accessibilityDescription: entry.0)!, target: self, action: #selector(selectColor))
            swatch.title = ""
            swatch.imagePosition = .imageOnly
            swatch.focusRingType = .none
            swatch.identifier = NSUserInterfaceItemIdentifier("color-\(index)")
            swatch.toolTip = entry.0
            swatch.setAccessibilityLabel(entry.0)
            swatch.tag = index
            swatch.isBordered = false
            swatch.contentTintColor = entry.1
            swatch.frame = CGRect(x: 6 + index * 28, y: 4, width: 28, height: 28)
            colorPalette.addSubview(swatch)
        }
        colorPalette.isHidden = true
        addSubview(colorPalette)
    }

    private func updateSelection() {
        let showsFontSize = tool == .text || textEditor != nil
        fontSizePicker.isHidden = !showsFontSize
        fontSizePicker.isEnabled = showsFontSize
        updateToolbarSize()
        toolbar.isHidden = selection.isEmpty || (drag != nil && !isDraggingText)
        if toolbar.isHidden { colorPalette.isHidden = true }
        if !toolbar.isHidden {
            let x = min(max(selection.maxX - toolbar.frame.width, 8), max(8, bounds.width - toolbar.frame.width - 8))
            let below = selection.maxY + 12
            let above = selection.minY - toolbar.frame.height - 40
            let y = below + toolbar.frame.height <= bounds.height - 8 ? below : (above >= 8 ? above : bounds.height - toolbar.frame.height - 8)
            toolbar.setFrameOrigin(CGPoint(x: x, y: y))
        }
        mosaicOptions.isHidden = toolbar.isHidden || tool != .mosaic
        if !mosaicOptions.isHidden {
            let x = min(max(toolbar.frame.minX, 8), max(8, bounds.width - mosaicOptions.frame.width - 8))
            let below = toolbar.frame.maxY + 6
            let y = below + mosaicOptions.frame.height <= bounds.height - 8 ? below : toolbar.frame.minY - mosaicOptions.frame.height - 6
            mosaicOptions.setFrameOrigin(CGPoint(x: x, y: max(8, y)))
        }
        for (id, button) in buttons {
            let selected = id == (tool?.rawValue ?? "move")
            button.contentTintColor = selected ? .systemBlue : .labelColor
        }
        buttons["color"]?.contentTintColor = color
        buttons["color"]?.isEnabled = tool != .mosaic
        buttons["undo"]?.isEnabled = !history.isEmpty || textEditor != nil
        buttons["redo"]?.isEnabled = !undone.isEmpty && textEditor == nil
        buttons["start"]?.contentTintColor = .systemRed
        buttons["start-fixed-capture"]?.contentTintColor = .systemGreen
        updateCursor()
        updatePointerOverlay()
        drawingOverlay.needsDisplay = true
    }

    @objc private func selectTool(_ sender: NSButton) {
        finishTextEditing()
        selectedAnnotationIndex = nil
        let id = sender.identifier!.rawValue
        tool = id == "move" ? nil : AnnotationTool(rawValue: id)!
        colorPalette.isHidden = true
        updateSelection()
    }
    @objc private func showColors(_ sender: NSButton) {
        let buttonRect = convert(sender.bounds, from: sender)
        let x = min(max(buttonRect.midX - colorPalette.frame.width / 2, 8), bounds.width - colorPalette.frame.width - 8)
        let below = toolbar.frame.maxY + 6
        let y = below + colorPalette.frame.height <= bounds.height - 8 ? below : toolbar.frame.minY - colorPalette.frame.height - 6
        colorPalette.setFrameOrigin(CGPoint(x: x, y: max(8, y)))
        colorPalette.isHidden.toggle()
        updateCursor()
    }
    @objc private func selectColor(_ sender: NSButton) {
        color = colors[sender.tag].1
        colorPalette.isHidden = true
        updateTextStyle()
        updateSelection()
    }
    @objc private func selectFontSize(_ sender: NSPopUpButton) {
        fontSize = CGFloat([12, 16, 20, 24, 32, 48, 64, 96][sender.indexOfSelectedItem])
        updateTextStyle()
        if let textEditor { window?.makeFirstResponder(textEditor) }
    }
    @objc private func undo() {
        if isDraggingText {
            drag = nil
            currentAnnotation = nil
            updateSelection()
            return
        }
        finishTextEditing()
        guard let change = history.popLast() else { return }
        selectedAnnotationIndex = nil
        change.undo(in: &annotations)
        undone.append(change)
        updateSelection()
    }
    @objc private func redo() {
        guard drag == nil else { return }
        finishTextEditing()
        guard let change = undone.popLast() else { return }
        selectedAnnotationIndex = nil
        change.apply(to: &annotations)
        history.append(change)
        updateSelection()
    }
    @objc private func cancel() {
        guard !finished else { return }
        finished = true
        updatePointerOverlay()
        onFinish?(nil, .copy)
    }
    @objc private func pin() { finish(.pin) }
    @objc private func save() { finish(.save) }
    @objc private func confirm() { finish(.copy) }
    private func finish(_ action: ScreenshotAction) {
        guard !finished, !renderingFailed, !selection.isEmpty, drag == nil else { return }
        finishTextEditing()
        finished = true
        updatePointerOverlay()
        onFinish?(pixelSelection, action)
    }

    private func beginTextEditing(at point: CGPoint) {
        let origin = annotationPoint(point)
        let scale = bounds.width / CGFloat(image.width)
        let annotation = ImageAnnotation(tool: .text, points: [origin], color: color, width: 0,
                                         fontSize: fontSize / scale,
                                         textWidth: min(pixelSelection.width - origin.x, 320 / scale))
        beginTextEditing(annotation)
    }

    private func beginTextEditing(_ annotation: ImageAnnotation, index: Int? = nil) {
        let origin = annotation.points[0]
        let scale = bounds.width / CGFloat(image.width)
        editingTextIndex = index
        selectedAnnotationIndex = index
        tool = .text
        color = annotation.color
        fontSize = annotation.fontSize * scale
        fontSizePicker.selectItem(withTitle: "\(Int(fontSize)) pt")
        let editor = AnnotationTextEditor(annotation: annotation, maximumHeight: pixelSelection.height - origin.y)
        textEditor = editor
        editor.onFinish = { [weak self, weak editor] annotation in
            guard let self else { return }
            if let annotation {
                if let index {
                    let original = self.annotations[index]
                    if annotation != original { self.record(.replace(index: index, before: original, after: annotation)) }
                } else {
                    self.record(.add(annotation))
                    self.selectedAnnotationIndex = self.annotations.count - 1
                }
            }
            editor?.removeFromSuperview()
            self.textEditor = nil
            self.editingTextIndex = nil
            self.window?.makeFirstResponder(self)
            self.updateSelection()
        }
        addSubview(editor, positioned: .below, relativeTo: toolbar)
        editor.place(at: CGPoint(x: selection.minX + origin.x * scale, y: selection.minY + origin.y * scale), scale: scale)
        window?.makeFirstResponder(editor)
        updateSelection()
    }

    private func finishTextEditing() { textEditor?.finish(commit: true) }

    private func record(_ change: AnnotationChange) {
        change.apply(to: &annotations)
        history.append(change)
        undone.removeAll()
    }

    private func updateTextStyle() {
        textEditor?.updateStyle(color: color, fontSize: fontSize * CGFloat(image.width) / bounds.width)
    }

    private func annotationPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - selection.minX) * CGFloat(image.width) / bounds.width,
                y: (point.y - selection.minY) * CGFloat(image.height) / bounds.height)
    }
    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func drawDimensions() {
        let pixels = pixelSelection
        dimensionsText.update("\(Int(selection.width)) × \(Int(selection.height)) pt  ·  \(Int(pixels.width)) × \(Int(pixels.height)) px")
        let rect = CGRect(x: min(max(selection.minX, 8), bounds.width - dimensionsText.width - 20),
                          y: selection.minY >= 30 ? selection.minY - 28 : selection.minY + 10,
                          width: dimensionsText.width + 12, height: 22)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        dimensionsText.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), color: NSColor.white.cgColor,
                            in: NSGraphicsContext.current!.cgContext)
    }

    private func updatePointerOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pointerOverlay.isHidden = finished || !isPointerInside || (!selection.isEmpty && !isCreating)
        guard !pointerOverlay.isHidden else { return }
        pointerOverlay.horizontalLine.isHidden = !showsFullScreenCrosshair
        pointerOverlay.verticalLine.isHidden = !showsFullScreenCrosshair
        pointerOverlay.horizontalLine.frame = CGRect(x: 0, y: pointer.y - 0.25, width: bounds.width, height: 0.5)
        pointerOverlay.verticalLine.frame = CGRect(x: pointer.x - 0.25, y: 0, width: 0.5, height: bounds.height)
        pointerLabelText.update(L("拖动选区 · Esc 取消"))
        if isColorPicking {
            pointerValueText.update(currentColorValue ?? L("无法读取颜色"))
            pointerHintText.update(didCopyColor ? L("已复制") : L("C 复制 · Tab 切换"))
        }
        let width = isColorPicking ? max(max(190, pointerValueText.width + 46),
                                        max(pointerHintText.width + 24, pointerLabelText.width + 24))
            : max(148, pointerLabelText.width + 16)
        let height: CGFloat = isColorPicking ? 208 : 160
        let proposedX = pointer.x + 24 + width <= bounds.maxX - 12 ? pointer.x + 24 : pointer.x - 24 - width
        let proposedY = pointer.y + 24 + height <= bounds.maxY - 12 ? pointer.y + 24 : pointer.y - 24 - height
        let origin = CGPoint(x: max(12, min(proposedX, bounds.maxX - width - 12)),
                             y: max(12, min(proposedY, bounds.maxY - height - 12)))
        pointerOverlay.magnifier.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        pointerOverlay.magnifier.needsDisplay = true
    }

    fileprivate func drawMagnifier(in bounds: CGRect) {
        let pixelX = Int(pointerPixel.x)
        let pixelY = Int(pointerPixel.y)
        let sampleWidth = min(21, image.width), sampleHeight = min(21, image.height)
        let source = CGRect(x: min(max(pixelX - 10, 0), image.width - sampleWidth), y: min(max(pixelY - 10, 0), image.height - sampleHeight), width: sampleWidth, height: sampleHeight)
        let width = bounds.width
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let preview = CGRect(x: (width - 126) / 2, y: 7, width: 126, height: 126)
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.clip(to: preview)
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.translateBy(x: preview.minX, y: preview.maxY)
        context.scaleBy(x: preview.width / source.width, y: -preview.height / source.height)
        context.draw(image, in: CGRect(x: -source.minX, y: source.maxY - CGFloat(image.height),
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        context.restoreGState()
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        let target = CGPoint(x: preview.minX + (CGFloat(pixelX) - source.minX + 0.5) / source.width * preview.width,
                             y: preview.minY + (CGFloat(pixelY) - source.minY + 0.5) / source.height * preview.height)
        cross.move(to: CGPoint(x: max(target.x - 9, preview.minX), y: target.y)); cross.line(to: CGPoint(x: min(target.x + 9, preview.maxX), y: target.y))
        cross.move(to: CGPoint(x: target.x, y: max(target.y - 9, preview.minY))); cross.line(to: CGPoint(x: target.x, y: min(target.y + 9, preview.maxY))); cross.stroke()
        if isColorPicking {
            if let sampledColor {
                NSColor(srgbRed: CGFloat(sampledColor.r) / 255, green: CGFloat(sampledColor.g) / 255,
                        blue: CGFloat(sampledColor.b) / 255, alpha: 1).setFill()
                let swatch = NSBezierPath(roundedRect: CGRect(x: 12, y: 144, width: 14, height: 14), xRadius: 3, yRadius: 3)
                swatch.fill()
                NSColor.white.withAlphaComponent(0.5).setStroke()
                swatch.lineWidth = 1
                swatch.stroke()
            }
            pointerValueText.draw(at: CGPoint(x: 34, y: 143), color: NSColor.white.cgColor, in: context)
            pointerHintText.draw(at: CGPoint(x: 12, y: 166),
                                 color: (didCopyColor ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.8)).cgColor,
                                 in: context)
        }
        pointerLabelText.draw(at: CGPoint(x: (isColorPicking ? 12 : 8), y: (isColorPicking ? 185 : 139)),
                              color: NSColor.white.withAlphaComponent(0.8).cgColor, in: context)
    }
}

@MainActor
private final class SelectionTextLine {
    private let font: CTFont
    private var text = ""
    private var line = CTLineCreateWithAttributedString(NSAttributedString(string: ""))
    private var ascent: CGFloat = 0
    private(set) var width: CGFloat = 0

    init(font: CTFont) { self.font = font }

    func update(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        // Keep a real CTFont and its shaped line; mouse movement must not re-enter NSString's font conversion.
        line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        width = ceil(CTLineGetTypographicBounds(line, &ascent, nil, nil))
    }

    func draw(at point: CGPoint, color: CGColor, in context: CGContext) {
        let textMatrix = context.textMatrix
        let textPosition = context.textPosition
        context.saveGState()
        defer {
            context.restoreGState()
            context.textMatrix = textMatrix
            context.textPosition = textPosition
        }
        context.translateBy(x: point.x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        context.setFillColor(color)
        CTLineDraw(line, context)
    }
}

private final class SelectionDrawingView: NSView {
    weak var selectionView: SelectionView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        selectionView?.drawSelection(dirtyRect)
    }
}

private final class SelectionPointerView: NSView {
    let horizontalLine = CALayer()
    let verticalLine = CALayer()
    let magnifier = SelectionMagnifierView()
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        horizontalLine.name = "selection-crosshair-horizontal"
        verticalLine.name = "selection-crosshair-vertical"
        for line in [horizontalLine, verticalLine] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            layer!.addSublayer(line)
        }
        magnifier.identifier = NSUserInterfaceItemIdentifier("selection-magnifier")
        magnifier.wantsLayer = true
        addSubview(magnifier)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}

private final class SelectionMagnifierView: NSView {
    weak var selectionView: SelectionView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { selectionView?.drawMagnifier(in: bounds) }
}

private final class SelectionButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var acceptsFirstResponder: Bool { false }
}

private final class SelectionPopUpButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
}

private final class SelectionSegmentedControl: NSSegmentedControl {
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
}
