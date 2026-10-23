import AppKit
import ClipatoCore
import SwiftUI

struct LongScreenshotPreview: NSViewRepresentable {
    let images: [CGImage]
    let placements: [CollagePlacement]
    let canvasSize: CGSize
    let selectedJoin: Int?
    let showsSelection: Bool
    let displayScale: CGFloat
    @Binding var zoom: CGFloat
    let minimumZoom: CGFloat
    let focusRequest: Int
    let resetRequest: Int
    let isEnabled: Bool
    let preservesViewport: Bool
    let onSelect: (Int?) -> Void
    let onDeselect: () -> Void
    let onNudge: (Int, Int) -> Void
    let onMove: (Int, Int, Int) -> Void
    let onBeginMove: () -> Void

    func makeNSView(context: Context) -> LongScreenshotScrollView {
        LongScreenshotScrollView(frame: .zero)
    }

    func updateNSView(_ view: LongScreenshotScrollView, context: Context) {
        view.onZoom = { zoom = $0 }
        view.minimumZoom = minimumZoom
        view.displayScale = displayScale
        view.canvas.images = images
        view.canvas.selectedJoin = selectedJoin
        view.canvas.showsSelection = showsSelection
        view.canvas.isEnabled = isEnabled
        view.canvas.onSelect = onSelect
        view.canvas.onDeselect = onDeselect
        view.canvas.onBeginMove = onBeginMove
        view.canvas.onNudge = { [weak view] dx, dy in
            view?.preserveViewport(moving: selectedJoin.map { $0 + 1 } ?? 0)
            onNudge(dx, dy)
        }
        view.canvas.onMove = { [weak view] index, dx, dy in
            view?.preserveViewport(moving: index)
            onMove(index, dx, dy)
        }
        view.updateGeometry(placements: placements, size: canvasSize, preserveViewport: preservesViewport)
        view.setZoom(zoom)
        view.layoutCanvas()
        if resetRequest != view.resetRequest {
            view.resetRequest = resetRequest
            view.resetViewport()
        }
        if focusRequest != view.focusRequest {
            view.focusRequest = focusRequest
            view.canvas.prefersSelectedImage = showsSelection
            view.window?.makeFirstResponder(view.canvas)
        }
    }

    static func dismantleNSView(_ view: LongScreenshotScrollView, coordinator: ()) {
        view.onZoom = { _ in }
        view.canvas.onSelect = { _ in }
        view.canvas.onDeselect = {}
        view.canvas.onNudge = { _, _ in }
        view.canvas.onMove = { _, _, _ in }
        view.canvas.onBeginMove = {}
    }
}

final class LongScreenshotScrollView: NSScrollView {
    let canvas = LongScreenshotCanvas(frame: .zero)
    var onZoom: (CGFloat) -> Void = { _ in }
    var minimumZoom: CGFloat = 0.001
    var displayScale: CGFloat = 1
    var focusRequest = 0
    var resetRequest = 0
    private(set) var zoom: CGFloat = 1
    private var manualOrigin: CGPoint?
    private var pendingAnchor: (imageIndex: Int, point: CGPoint)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        documentView = canvas
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutCanvas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutCanvas()
    }

    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        guard value != zoom else { return }
        let focus = anchor ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let imagePoint = CGPoint(x: (focus.x - canvas.imageOrigin.x) / canvas.imageScale,
                                 y: (focus.y - canvas.imageOrigin.y) / canvas.imageScale)
        let viewportPoint = CGPoint(x: focus.x - contentView.bounds.minX, y: focus.y - contentView.bounds.minY)
        zoom = value
        manualOrigin = nil
        layoutCanvas()
        contentView.scroll(to: CGPoint(x: canvas.imageOrigin.x + imagePoint.x * canvas.imageScale - viewportPoint.x,
                                       y: canvas.imageOrigin.y + imagePoint.y * canvas.imageScale - viewportPoint.y))
        reflectScrolledClipView(contentView)
    }

    func layoutCanvas() {
        let scale = zoom / displayScale
        let imageSize = CGSize(width: canvas.outputSize.width * scale, height: canvas.outputSize.height * scale)
        let viewport = contentView.bounds.size
        let origin: CGPoint
        let size: CGSize
        if let manualOrigin {
            origin = manualOrigin
            size = CGSize(width: max(contentView.bounds.maxX, origin.x + imageSize.width + 16),
                          height: max(contentView.bounds.maxY, origin.y + imageSize.height + 16))
        } else {
            size = CGSize(width: max(viewport.width, imageSize.width + 32), height: max(viewport.height, imageSize.height + 32))
            origin = CGPoint(x: floor((size.width - imageSize.width) * displayScale / 2) / displayScale,
                             y: floor((size.height - imageSize.height) * displayScale / 2) / displayScale)
        }
        canvas.frame.size = size
        canvas.imageScale = scale
        canvas.zoom = zoom
        canvas.imageOrigin = origin
        canvas.needsDisplay = true
        canvas.window?.invalidateCursorRects(for: canvas)
    }

    func resetViewport() {
        manualOrigin = nil
        pendingAnchor = nil
        layoutCanvas()
        let viewport = contentView.bounds.size
        contentView.scroll(to: CGPoint(x: max(0, floor((canvas.bounds.width - viewport.width) * displayScale / 2) / displayScale),
                                       y: max(0, floor((canvas.bounds.height - viewport.height) * displayScale / 2) / displayScale)))
        reflectScrolledClipView(contentView)
    }

    func preserveViewport(moving imageIndex: Int) {
        let reference = imageIndex == 0 && canvas.placements.count > 1 ? 1 : 0
        guard canvas.placements.indices.contains(reference) else { return }
        let point = canvas.displayFrame(canvas.placements[reference].frame).origin
        pendingAnchor = (reference, CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY))
    }

    func updateGeometry(placements: [CollagePlacement], size: CGSize, preserveViewport: Bool) {
        let changed = placements != canvas.placements || size != canvas.outputSize
        if changed, preserveViewport, pendingAnchor == nil { self.preserveViewport(moving: -1) }
        let anchor = pendingAnchor
        pendingAnchor = nil
        canvas.placements = placements
        canvas.outputSize = size
        if changed, preserveViewport, let anchor,
           let reference = placements.first(where: { $0.imageIndex == anchor.imageIndex }) {
            let scale = zoom / displayScale
            let origin = CGPoint(x: contentView.bounds.minX + anchor.point.x - reference.frame.minX * scale,
                                 y: contentView.bounds.minY + anchor.point.y - reference.frame.minY * scale)
            let shift = CGPoint(x: max(0, 16 - origin.x), y: max(0, 16 - origin.y))
            let scroll = CGPoint(x: contentView.bounds.minX + shift.x, y: contentView.bounds.minY + shift.y)
            let adjustedOrigin = CGPoint(x: origin.x + shift.x, y: origin.y + shift.y)
            manualOrigin = adjustedOrigin
            canvas.frame.size = CGSize(width: max(scroll.x + contentView.bounds.width, adjustedOrigin.x + size.width * scale + 16),
                                       height: max(scroll.y + contentView.bounds.height, adjustedOrigin.y + size.height * scale + 16))
            contentView.scroll(to: scroll)
            reflectScrolledClipView(contentView)
        } else if !preserveViewport { manualOrigin = nil }
        layoutCanvas()
    }

    override func magnify(with event: NSEvent) {
        changeZoom(zoom * (1 + event.magnification), event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            changeZoom(zoom * exp(event.scrollingDeltaY * 0.01), event: event)
        } else { super.scrollWheel(with: event) }
    }

    private func changeZoom(_ value: CGFloat, event: NSEvent) {
        let next = min(max(value, minimumZoom), 32)
        setZoom(next, anchor: canvas.convert(event.locationInWindow, from: nil))
        onZoom(next)
    }
}

final class LongScreenshotCanvas: NSView {
    var images: [CGImage] = []
    var placements: [CollagePlacement] = []
    var outputSize = CGSize.zero
    var imageOrigin = CGPoint.zero
    var imageScale: CGFloat = 1
    var zoom: CGFloat = 1
    var interpolationQuality: CGInterpolationQuality { zoom >= 1 ? .none : .high }
    var selectedJoin: Int?
    var isEnabled = true {
        didSet { if !isEnabled { drag = nil } }
    }
    var onSelect: (Int?) -> Void = { _ in }
    var onDeselect: () -> Void = {}
    var onNudge: (Int, Int) -> Void = { _, _ in }
    var onMove: (Int, Int, Int) -> Void = { _, _, _ in }
    var onBeginMove: () -> Void = {}
    var showsSelection = true
    var prefersSelectedImage = false
    private var drag: Drag?

    private struct Drag {
        let imageIndex: Int
        let pointer: CGPoint
        let scale: CGFloat
        var offset = CGPoint.zero
        var didMove = false
    }

    private var selectedImageIndex: Int { selectedJoin.map { $0 + 1 } ?? 0 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current!.cgContext
        NSColor(Palette.canvas).setFill()
        dirtyRect.fill()
        let output = CGRect(origin: imageOrigin, size: CGSize(width: outputSize.width * imageScale, height: outputSize.height * imageScale))
        NSColor.white.setFill()
        output.fill()
        context.interpolationQuality = interpolationQuality
        for placement in placements {
            let target = displayFrame(previewFrame(placement))
            guard target.intersects(dirtyRect) else { continue }
            context.saveGState()
            context.translateBy(x: target.minX, y: target.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(images[placement.imageIndex], in: CGRect(origin: .zero, size: target.size))
            context.restoreGState()
        }
        if showsSelection, let selected = placements.first(where: { $0.imageIndex == selectedImageIndex }) {
            let frame = displayFrame(previewFrame(selected))
            context.saveGState()
            context.setStrokeColor(NSColor(Palette.accent).cgColor)
            context.setLineWidth(1.5)
            context.stroke(frame.insetBy(dx: 0.75, dy: 0.75))
            context.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let selected = showsSelection && prefersSelectedImage ? placements.first {
            $0.imageIndex == selectedImageIndex && displayFrame($0.frame).contains(point)
        } : nil
        prefersSelectedImage = false
        guard let frame = selected ?? placements.last(where: { displayFrame($0.frame).contains(point) }) else {
            clearSelection()
            return
        }
        selectedJoin = frame.imageIndex == 0 ? nil : frame.imageIndex - 1
        showsSelection = true
        drag = Drag(imageIndex: frame.imageIndex, pointer: point, scale: imageScale)
        needsDisplay = true
        onSelect(selectedJoin)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        updateDrag(event)
        guard let drag else { return }
        self.drag = nil
        if drag.offset != .zero { onMove(drag.imageIndex, Int(drag.offset.x), Int(drag.offset.y)) }
        needsDisplay = true
        NSCursor.openHand.set()
    }

    private func updateDrag(_ event: NSEvent) {
        guard isEnabled, var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        drag.offset = CGPoint(x: ((point.x - drag.pointer.x) / drag.scale).rounded(),
                              y: ((point.y - drag.pointer.y) / drag.scale).rounded())
        let beganMoving = !drag.didMove && drag.offset != .zero
        if beganMoving { drag.didMove = true }
        self.drag = drag
        if beganMoving { onBeginMove() }
        needsDisplay = true
    }

    func previewFrame(_ placement: CollagePlacement) -> CGRect {
        guard let drag, drag.imageIndex == placement.imageIndex else { return placement.frame }
        return placement.frame.offsetBy(dx: drag.offset.x, dy: drag.offset.y)
    }

    private func clearSelection() {
        drag = nil
        selectedJoin = nil
        showsSelection = false
        prefersSelectedImage = false
        needsDisplay = true
        onDeselect()
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        for placement in placements { addCursorRect(displayFrame(placement.frame), cursor: .openHand) }
    }

    override func cancelOperation(_ sender: Any?) {
        if drag != nil {
            drag = nil
            needsDisplay = true
            NSCursor.openHand.set()
            return
        }
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            cancelOperation(nil)
            return
        }
        guard isEnabled else { return }
        guard showsSelection, placements.indices.contains(selectedImageIndex) else {
            super.keyDown(with: event)
            return
        }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: onNudge(-step, 0)
        case 124: onNudge(step, 0)
        case 125: onNudge(0, step)
        case 126: onNudge(0, -step)
        default: super.keyDown(with: event)
        }
    }

    func displayFrame(_ pixels: CGRect) -> CGRect {
        CGRect(x: imageOrigin.x + pixels.minX * imageScale, y: imageOrigin.y + pixels.minY * imageScale,
               width: pixels.width * imageScale, height: pixels.height * imageScale)
    }
}
