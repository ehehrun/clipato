import AppKit
import SwiftUI

struct EditorImageViewport: NSViewRepresentable {
    let image: CGImage
    let annotations: [ImageAnnotation]
    let tool: AnnotationTool
    let color: NSColor
    var allowsAnnotation = true
    var fontSize: CGFloat = 48
    var mosaicShape = MosaicShape.brush
    var mosaicBrushSize: CGFloat = 48
    var mosaicSize: CGFloat = 16
    var onAnnotationChange: (AnnotationChange) -> Void = { _ in }
    var onCanvasReady: (EditorImageCanvas) -> Void = { _ in }
    var onTextEditing: (Bool) -> Void = { _ in }
    var onRenderError: (Error) -> Void = { _ in }
    @Binding var zoom: CGFloat
    let minimumZoom: CGFloat
    let maximumZoom: CGFloat
    let onAnnotation: (ImageAnnotation) -> Void

    func makeNSView(context: Context) -> EditorScrollView {
        let view = EditorScrollView(image: image)
        DispatchQueue.main.async { onCanvasReady(view.canvas) }
        return view
    }

    static func dismantleNSView(_ scrollView: EditorScrollView, coordinator: ()) {
        scrollView.onZoom = { _ in }
        scrollView.canvas.onAnnotation = { _ in }
        scrollView.canvas.onAnnotationChange = { _ in }
        scrollView.canvas.onTextEditing = { _ in }
        scrollView.canvas.onRenderError = { _ in }
    }

    func updateNSView(_ scrollView: EditorScrollView, context: Context) {
        scrollView.onZoom = { zoom = $0 }
        scrollView.minimumZoom = minimumZoom
        scrollView.maximumZoom = maximumZoom
        scrollView.canvas.onAnnotation = onAnnotation
        scrollView.canvas.onAnnotationChange = onAnnotationChange
        scrollView.canvas.onTextEditing = onTextEditing
        scrollView.canvas.onRenderError = onRenderError
        scrollView.canvas.updateTextStyle(color: color, fontSize: fontSize)
        scrollView.canvas.image = image
        scrollView.canvas.annotations = annotations
        scrollView.canvas.tool = tool
        scrollView.canvas.color = color
        scrollView.canvas.allowsAnnotation = allowsAnnotation
        scrollView.canvas.mosaicShape = mosaicShape
        scrollView.canvas.mosaicBrushSize = mosaicBrushSize
        scrollView.canvas.mosaicSize = mosaicSize
        scrollView.setZoom(zoom)
        scrollView.canvas.needsDisplay = true
    }
}

final class EditorScrollView: NSScrollView {
    let canvas: EditorImageCanvas
    var onZoom: (CGFloat) -> Void = { _ in }
    var minimumZoom: CGFloat = 1
    var maximumZoom: CGFloat = 32
    private(set) var zoom: CGFloat = 1

    init(image: CGImage) {
        canvas = EditorImageCanvas(image: image)
        super.init(frame: .zero)
        contentView = EditorClipView()
        documentView = canvas
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        canvas.cancelStroke()
        layoutImage()
    }

    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        guard value != zoom else { return }
        let focus = anchor ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let imagePoint = canvas.imagePoint(focus)
        let viewportPoint = CGPoint(x: focus.x - contentView.bounds.minX, y: focus.y - contentView.bounds.minY)
        canvas.cancelStroke()
        zoom = value
        layoutImage()
        let newFocus = CGPoint(x: canvas.imageFrame.minX + imagePoint.x * canvas.imageScale,
                               y: canvas.imageFrame.minY + imagePoint.y * canvas.imageScale)
        contentView.scroll(to: CGPoint(x: newFocus.x - viewportPoint.x, y: newFocus.y - viewportPoint.y))
        reflectScrolledClipView(contentView)
    }

    override func magnify(with event: NSEvent) {
        changeZoom(to: zoom * (1 + event.magnification), event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            changeZoom(to: zoom * exp(event.scrollingDeltaY * 0.01), event: event)
        } else {
            canvas.cancelStroke()
            super.scrollWheel(with: event)
        }
    }

    private func changeZoom(to value: CGFloat, event: NSEvent) {
        let next = min(max(value, minimumZoom), maximumZoom)
        setZoom(next, anchor: canvas.convert(event.locationInWindow, from: nil))
        onZoom(next)
    }

    private func layoutImage() {
        guard let window else { return }
        let backingScale = window.backingScaleFactor
        let scale = zoom / backingScale
        let size = CGSize(width: CGFloat(canvas.image.width) * scale, height: CGFloat(canvas.image.height) * scale)
        let viewport = contentView.bounds.size
        let documentSize = CGSize(width: max(viewport.width, size.width + 32), height: max(viewport.height, size.height + 32))
        canvas.setFrameSize(documentSize)
        canvas.imageScale = scale
        canvas.imageFrame = CGRect(x: floor((documentSize.width - size.width) * backingScale / 2) / backingScale,
                                   y: floor((documentSize.height - size.height) * backingScale / 2) / backingScale,
                                   width: size.width, height: size.height)
        canvas.zoom = zoom
        canvas.layoutTextEditor()
        window.invalidateCursorRects(for: canvas)
        canvas.needsDisplay = true
    }
}

private final class EditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let window {
            let scale = window.backingScaleFactor
            rect.origin.x = (rect.origin.x * scale).rounded() / scale
            rect.origin.y = (rect.origin.y * scale).rounded() / scale
        }
        return rect
    }
}

final class EditorImageCanvas: NSView {
    var image: CGImage {
        didSet {
            guard image !== oldValue else { return }
            mosaicRenderer = nil
            mosaicRenderFailed = false
        }
    }
    var annotations: [ImageAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            textBounds = Dictionary(uniqueKeysWithValues: annotations.enumerated().compactMap { index, annotation in
                annotation.tool == .text ? (index, annotation.textBounds) : nil
            })
            selectedAnnotationIndex = nil
            textDrag = nil
            mosaicRenderFailed = false
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var tool = AnnotationTool.rectangle {
        didSet {
            guard tool != oldValue else { return }
            selectedAnnotationIndex = nil
            cancelStroke()
        }
    }
    var color = NSColor.red
    var mosaicShape = MosaicShape.brush
    var mosaicBrushSize: CGFloat = 48
    var mosaicSize: CGFloat = 16
    var onAnnotation: (ImageAnnotation) -> Void = { _ in }
    var onAnnotationChange: (AnnotationChange) -> Void = { _ in }
    var allowsAnnotation = true
    var imageFrame = CGRect.zero
    var imageScale: CGFloat = 1
    var zoom: CGFloat = 1
    private var currentAnnotation: ImageAnnotation?
    private var textEditor: AnnotationTextEditor?
    private var editingTextIndex: Int?
    private var selectedAnnotationIndex: Int?
    private var textBounds: [Int: CGRect] = [:]
    private var textDrag: TextDrag?
    private var fontSize: CGFloat = 48
    private var mosaicRenderer: MosaicRenderer?
    private var mosaicRenderFailed = false
    var onTextEditing: (Bool) -> Void = { _ in }
    var onRenderError: (Error) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct TextDrag {
        let index: Int
        let before: ImageAnnotation
        let start: CGPoint
        let bounds: CGRect
        var preview: ImageAnnotation
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(imageFrame)
        context.clip(to: imageFrame)
        context.translateBy(x: imageFrame.minX, y: imageFrame.minY)
        context.scaleBy(x: imageScale, y: imageScale)
        context.saveGState()
        context.interpolationQuality = zoom >= 1 ? .none : .high
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        if !mosaicRenderFailed {
            do {
                for (index, annotation) in annotations.enumerated() where index != editingTextIndex {
                    if let textDrag, textDrag.index == index { try drawAnnotation(textDrag.preview, in: context) }
                    else { try drawAnnotation(annotation, in: context) }
                }
                if let currentAnnotation { try drawAnnotation(currentAnnotation, in: context) }
            } catch {
                mosaicRenderFailed = true
                DispatchQueue.main.async { [weak self] in self?.onRenderError(error) }
            }
        }
        if mosaicRenderFailed {
            // A failed redaction must never look like a successful, uncovered preview.
            context.setFillColor(NSColor(Palette.canvas).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        } else if allowsAnnotation, let selectedAnnotationIndex, selectedAnnotationIndex != editingTextIndex {
            var bounds = annotations[selectedAnnotationIndex].selectionBounds(textBounds: textBounds[selectedAnnotationIndex] ?? .null)
            if let textDrag {
                bounds = bounds.offsetBy(dx: textDrag.preview.points[0].x - textDrag.before.points[0].x,
                                         dy: textDrag.preview.points[0].y - textDrag.before.points[0].y)
            }
            context.setStrokeColor(NSColor(Palette.accent).cgColor)
            context.setLineWidth(1 / imageScale)
            context.stroke(bounds.insetBy(dx: -3 / imageScale, dy: -3 / imageScale))
        }
        context.restoreGState()
    }

    private func drawAnnotation(_ annotation: ImageAnnotation, in context: CGContext) throws {
        guard annotation.tool == .mosaic else { annotation.stroke(in: context); return }
        let renderer: MosaicRenderer
        if let mosaicRenderer { renderer = mosaicRenderer }
        else {
            renderer = try MosaicRenderer(image: image)
            mosaicRenderer = renderer
        }
        try renderer.draw(annotation, in: context)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard allowsAnnotation, imageFrame.contains(location) else { return }
        finishTextEditing()
        window?.makeFirstResponder(self)
        let point = imagePoint(location)
        if tool != .mosaic, let index = annotations.indices.reversed().first(where: {
            annotations[$0].hitTest(point, tolerance: 3 / imageScale, textBounds: textBounds[$0] ?? .null)
        }) {
            selectedAnnotationIndex = index
            let annotation = annotations[index]
            if annotation.tool == .text {
                if event.clickCount > 1 { beginTextEditing(annotation, index: index) }
                else {
                    textDrag = TextDrag(index: index, before: annotation, start: point,
                                        bounds: textBounds[index]!, preview: annotation)
                }
            }
            needsDisplay = true
            return
        }
        selectedAnnotationIndex = nil
        if tool == .text {
            beginTextEditing(at: point)
            return
        }
        currentAnnotation = ImageAnnotation(tool: tool, points: [point], color: color,
                                            width: tool == .mosaic ? mosaicBrushSize : max(1, CGFloat(max(image.width, image.height)) / 300),
                                            mosaicShape: mosaicShape, mosaicSize: mosaicSize)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if var drag = textDrag {
            let point = imagePoint(convert(event.locationInWindow, from: nil))
            drag.preview = point == drag.start ? drag.before : drag.before.movedText(
                by: CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y),
                within: CGRect(x: 0, y: 0, width: image.width, height: image.height), textBounds: drag.bounds)
            textDrag = drag
            if window != nil { NSCursor.closedHand.set() }
            needsDisplay = true
            return
        }
        guard var annotation = currentAnnotation else { return }
        let point = imagePoint(convert(event.locationInWindow, from: nil))
        if annotation.tool == .pen || (annotation.tool == .mosaic && annotation.mosaicShape == .brush) {
            if annotation.points.last != point { annotation.points.append(point) }
        }
        else { annotation.points = [annotation.points[0], point] }
        currentAnnotation = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if textDrag != nil || currentAnnotation?.tool == .mosaic { mouseDragged(with: event) }
        if let drag = textDrag {
            textDrag = nil
            if drag.preview != drag.before { commit(.replace(index: drag.index, before: drag.before, after: drag.preview)) }
            window?.invalidateCursorRects(for: self)
        } else if let annotation = currentAnnotation, annotation.isDrawable {
            commit(.add(annotation))
        }
        cancelStroke()
    }

    override func resetCursorRects() {
        guard allowsAnnotation else { return }
        if tool == .mosaic {
            addCursorRect(imageFrame, cursor: .crosshair)
            return
        }
        for bounds in textBounds.values {
            let rect = CGRect(x: imageFrame.minX + bounds.minX * imageScale,
                              y: imageFrame.minY + bounds.minY * imageScale,
                              width: bounds.width * imageScale, height: bounds.height * imageScale)
            addCursorRect(rect.intersection(imageFrame), cursor: .openHand)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let textEditor { textEditor.finish(commit: false) }
        else if textDrag != nil || currentAnnotation != nil { cancelStroke() }
        else if selectedAnnotationIndex != nil { selectedAnnotationIndex = nil; needsDisplay = true }
        else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, deleteSelectedAnnotation(with: event) { return true }
        if event.keyCode == 53, window?.firstResponder === self,
           textDrag != nil || currentAnnotation != nil || selectedAnnotationIndex != nil {
            cancelOperation(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if deleteSelectedAnnotation(with: event) { return }
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    private func deleteSelectedAnnotation(with event: NSEvent) -> Bool {
        guard event.keyCode == 51 || event.keyCode == 117,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              allowsAnnotation, textEditor == nil, let index = selectedAnnotationIndex else { return false }
        cancelStroke()
        commit(.remove(index: index, annotation: annotations[index]))
        return true
    }

    private func commit(_ change: AnnotationChange) {
        change.apply(to: &annotations)
        switch change {
        case .add(let annotation):
            if annotation.tool == .text { selectedAnnotationIndex = annotations.count - 1 }
            onAnnotation(annotation)
        case .replace(let index, _, _):
            selectedAnnotationIndex = index
            onAnnotationChange(change)
        case .remove:
            onAnnotationChange(change)
        }
    }

    private func beginTextEditing(at point: CGPoint) {
        let annotation = ImageAnnotation(tool: .text, points: [point], color: color, width: 0,
                                         fontSize: fontSize, textWidth: min(CGFloat(image.width) - point.x, fontSize * 14))
        beginTextEditing(annotation, index: nil)
    }

    private func beginTextEditing(_ annotation: ImageAnnotation, index: Int?) {
        let editor = AnnotationTextEditor(annotation: annotation, maximumHeight: CGFloat(image.height) - annotation.points[0].y)
        textEditor = editor
        editingTextIndex = index
        editor.onFinish = { [weak self, weak editor] result in
            guard let self else { return }
            editor?.removeFromSuperview()
            self.textEditor = nil
            self.editingTextIndex = nil
            if let result {
                if let index {
                    if result != annotation { self.commit(.replace(index: index, before: annotation, after: result)) }
                } else {
                    self.commit(.add(result))
                }
            }
            self.onTextEditing(false)
            self.window?.makeFirstResponder(self)
            self.needsDisplay = true
        }
        addSubview(editor)
        layoutTextEditor()
        window?.makeFirstResponder(editor)
        onTextEditing(true)
        needsDisplay = true
    }

    func finishTextEditing() { textEditor?.finish(commit: true) }

    func updateTextStyle(color: NSColor, fontSize: CGFloat) {
        let colorChanged = self.color != color
        let fontChanged = self.fontSize != fontSize
        self.color = color
        self.fontSize = fontSize
        guard let textEditor, colorChanged || fontChanged else { return }
        textEditor.updateStyle(color: colorChanged ? color : textEditor.annotation.color,
                               fontSize: fontChanged ? fontSize : textEditor.annotation.fontSize)
    }

    func layoutTextEditor() {
        guard let textEditor else { return }
        let point = textEditor.annotation.points[0]
        textEditor.place(at: CGPoint(x: imageFrame.minX + point.x * imageScale,
                                    y: imageFrame.minY + point.y * imageScale), scale: imageScale)
    }

    func imagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max((point.x - imageFrame.minX) / imageScale, 0), CGFloat(image.width)),
                y: min(max((point.y - imageFrame.minY) / imageScale, 0), CGFloat(image.height)))
    }

    func cancelStroke() {
        if currentAnnotation != nil { mosaicRenderFailed = false }
        currentAnnotation = nil
        textDrag = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
