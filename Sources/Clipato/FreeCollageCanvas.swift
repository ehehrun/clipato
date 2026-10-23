import AppKit
import ClipatoCore
import SwiftUI

struct FreeCollageCanvas: NSViewRepresentable {
    let view: FreeCollageCanvasView
    let images: [CGImage]
    @Binding var placements: [CollagePlacement]
    @Binding var selectedImageIndex: Int?
    let fitRequest: Int
    let onChange: () -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> FreeCollageCanvasView {
        view
    }

    func updateNSView(_ view: FreeCollageCanvasView, context: Context) {
        view.onPlacementsChange = { placements = $0 }
        view.onSelectionChange = { selectedImageIndex = $0 }
        view.onChange = onChange
        view.onError = onError
        view.update(images: images, placements: placements,
                    selectedImageIndex: selectedImageIndex, fitRequest: fitRequest)
    }

    static func dismantleNSView(_ view: FreeCollageCanvasView, coordinator: ()) {
        view.onPlacementsChange = { _ in }
        view.onSelectionChange = { _ in }
        view.onChange = {}
        view.onError = { _ in }
    }
}

final class FreeCollageCanvasView: NSView {
    var onPlacementsChange: ([CollagePlacement]) -> Void = { _ in }
    var onSelectionChange: (Int?) -> Void = { _ in }
    var onChange: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    private(set) var images: [CGImage] = []
    private(set) var placements: [CollagePlacement] = []
    private(set) var selectedImageIndex: Int?
    private(set) var viewportScale: CGFloat = 1
    private(set) var viewportOffset = CGPoint.zero
    private(set) var canvasBounds = CGRect.null
    private var lastFitRequest: Int?
    private var drag: Drag?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in frame: CGRect) -> CGPoint {
            CGPoint(x: self == .topLeft || self == .bottomLeft ? frame.minX : frame.maxX,
                    y: self == .topLeft || self == .topRight ? frame.minY : frame.maxY)
        }

        var opposite: Corner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }
    }

    private struct Drag {
        let imageIndex: Int
        let initialFrame: CGRect
        let initialPointer: CGPoint
        let corner: Corner?
        var error: String?
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(images: [CGImage], placements: [CollagePlacement], selectedImageIndex: Int?, fitRequest: Int) {
        if placements != self.placements || selectedImageIndex != self.selectedImageIndex || images.count != self.images.count {
            drag = nil
        }
        self.images = images
        self.placements = placements
        self.selectedImageIndex = selectedImageIndex
        do {
            if placements.isEmpty { canvasBounds = .null }
            else { canvasBounds = try CollageRenderer.bounds(for: placements) }
        } catch {
            canvasBounds = .null
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onError(message) }
        }
        if lastFitRequest != fitRequest {
            finishDrag()
            lastFitRequest = fitRequest
            fitToCanvas()
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            finishDrag()
            fitToCanvas()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitToCanvas()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        finishDrag()
        fitToCanvas()
    }

    func fitToCanvas() {
        guard !canvasBounds.isNull, bounds.width > 64, bounds.height > 64 else { return }
        let backingScale = window?.backingScaleFactor ?? 1
        viewportScale = min(1 / backingScale, (bounds.width - 64) / canvasBounds.width,
                            (bounds.height - 64) / canvasBounds.height)
        viewportOffset = CGPoint(x: ((bounds.midX - canvasBounds.midX * viewportScale) * backingScale).rounded() / backingScale,
                                 y: ((bounds.midY - canvasBounds.midY * viewportScale) * backingScale).rounded() / backingScale)
        needsDisplay = true
    }

    func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - viewportOffset.x) / viewportScale,
                y: (point.y - viewportOffset.y) / viewportScale)
    }

    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * viewportScale + viewportOffset.x,
                y: point.y * viewportScale + viewportOffset.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !canvasBounds.isNull else { return }
        context.saveGState()
        context.translateBy(x: viewportOffset.x, y: viewportOffset.y)
        context.scaleBy(x: viewportScale, y: viewportScale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(canvasBounds)
        let visible = CGRect(origin: canvasPoint(dirtyRect.origin),
                             size: CGSize(width: dirtyRect.width / viewportScale,
                                          height: dirtyRect.height / viewportScale))
        for placement in placements {
            guard placement.frame.intersects(visible) else { continue }
            let image = images[placement.imageIndex]
            let frame = placement.frame
            context.saveGState()
            let pixelScale = viewportScale * (window?.backingScaleFactor ?? 1)
            let sourceScale = min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            context.interpolationQuality = pixelScale * sourceScale >= 1 ? .none : .high
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: frame.size))
            context.restoreGState()
        }
        context.restoreGState()

        if let selected = placements.first(where: { $0.imageIndex == selectedImageIndex }) {
            let origin = viewPoint(selected.frame.origin)
            let rectangle = CGRect(origin: origin, size: CGSize(width: selected.frame.width * viewportScale,
                                                                height: selected.frame.height * viewportScale))
            context.setStrokeColor(NSColor(Palette.accent).cgColor)
            context.setLineWidth(1.5)
            context.stroke(rectangle)
            context.setFillColor(NSColor.white.cgColor)
            for corner in Corner.allCases {
                let point = corner.point(in: rectangle)
                let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(handle)
                context.stroke(handle)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if let selected = placements.first(where: { $0.imageIndex == selectedImageIndex }),
           let corner = Corner.allCases.first(where: {
               let point = viewPoint($0.point(in: selected.frame))
               return CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14).contains(location)
           }) {
            drag = Drag(imageIndex: selected.imageIndex, initialFrame: selected.frame,
                        initialPointer: canvasPoint(location), corner: corner)
            return
        }
        let point = canvasPoint(location)
        let selected = placements.reversed().first { $0.frame.contains(point) }
        if selectedImageIndex != selected?.imageIndex {
            selectedImageIndex = selected?.imageIndex
            onSelectionChange(selectedImageIndex)
        }
        drag = selected.map {
            Drag(imageIndex: $0.imageIndex, initialFrame: $0.frame, initialPointer: point, corner: nil)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
        finishDrag()
    }

    private func updateDrag(at location: CGPoint) {
        guard var drag, let index = placements.firstIndex(where: { $0.imageIndex == drag.imageIndex }) else { return }
        let point = canvasPoint(location)
        let delta = CGPoint(x: point.x - drag.initialPointer.x, y: point.y - drag.initialPointer.y)
        let original = drag.initialFrame
        let nextFrame: CGRect
        if delta == .zero {
            nextFrame = original
        } else if let corner = drag.corner {
            let anchor = corner.opposite.point(in: original)
            let moving = corner.point(in: original)
            let vector = CGPoint(x: moving.x - anchor.x, y: moving.y - anchor.y)
            let proposed = ((vector.x + delta.x) * vector.x + (vector.y + delta.y) * vector.y)
                / (vector.x * vector.x + vector.y * vector.y)
            let factor = min(max(proposed, 1 / min(original.width, original.height)),
                             8_192 / max(original.width, original.height))
            let size = CGSize(width: original.width * factor, height: original.height * factor)
            nextFrame = CGRect(x: vector.x < 0 ? anchor.x - size.width : anchor.x,
                               y: vector.y < 0 ? anchor.y - size.height : anchor.y,
                               width: size.width, height: size.height)
        } else {
            nextFrame = CGRect(x: (original.minX + delta.x).rounded(), y: (original.minY + delta.y).rounded(),
                               width: original.width, height: original.height)
        }
        var candidate = placements
        candidate[index].frame = nextFrame
        do {
            let nextBounds = try CollageRenderer.bounds(for: candidate)
            drag.error = nil
            self.drag = drag
            guard candidate != placements else { return }
            placements = candidate
            canvasBounds = nextBounds
            needsDisplay = true
            onPlacementsChange(candidate)
            onChange()
        } catch {
            drag.error = error.localizedDescription
            self.drag = drag
        }
    }

    private func finishDrag() {
        let message = drag?.error
        drag = nil
        if let message { onError(message) }
    }

    override func magnify(with event: NSEvent) {
        finishDrag()
        changeZoom(to: viewportScale * (1 + event.magnification),
                   anchor: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        finishDrag()
        if event.modifierFlags.contains(.command) {
            changeZoom(to: viewportScale * exp(event.scrollingDeltaY * 0.01),
                       anchor: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
            viewportOffset.x += event.scrollingDeltaX * multiplier
            viewportOffset.y += event.scrollingDeltaY * multiplier
            alignOriginalPixels()
            needsDisplay = true
        }
    }

    private func changeZoom(to proposed: CGFloat, anchor: CGPoint) {
        guard !canvasBounds.isNull else { return }
        let backingScale = window?.backingScaleFactor ?? 1
        let minimumScale = 1 / (max(canvasBounds.width, canvasBounds.height) * backingScale)
        let point = canvasPoint(anchor)
        viewportScale = min(max(proposed, minimumScale), 32 / backingScale)
        viewportOffset = CGPoint(x: anchor.x - point.x * viewportScale,
                                 y: anchor.y - point.y * viewportScale)
        alignOriginalPixels()
        needsDisplay = true
    }

    private func alignOriginalPixels() {
        let backingScale = window?.backingScaleFactor ?? 1
        guard abs(viewportScale * backingScale - 1) < 0.000_001 else { return }
        viewportOffset.x = (viewportOffset.x * backingScale).rounded() / backingScale
        viewportOffset.y = (viewportOffset.y * backingScale).rounded() / backingScale
    }
}
