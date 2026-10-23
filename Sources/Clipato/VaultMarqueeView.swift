import AppKit
import SwiftUI

struct VaultMarqueeOverlay: NSViewRepresentable {
    var frames: [UUID: CGRect]
    var selected: Set<UUID>
    var onSelectionChange: (Set<UUID>) -> Void
    var onBegin: () -> Void

    func makeNSView(context: Context) -> VaultMarqueeView {
        VaultMarqueeView(frame: .zero)
    }

    func updateNSView(_ view: VaultMarqueeView, context: Context) {
        if view.frames != frames { view.frames = frames }
        view.selected = selected
        view.onSelectionChange = onSelectionChange
        view.onBegin = onBegin
    }
}

final class VaultMarqueeView: NSView {
    var frames: [UUID: CGRect] = [:] {
        didSet {
            guard origin != nil else { return }
            // Lazy grids discard offscreen geometry while the drag scrolls through it.
            gestureFrames.merge(frames) { _, current in current }
        }
    }
    var selected: Set<UUID> = []
    var onSelectionChange: (Set<UUID>) -> Void = { _ in }
    var onBegin: () -> Void = {}

    private var origin: CGPoint?
    private var selectionRect: CGRect?
    private var snapshot: Set<UUID> = []
    private var gestureFrames: [UUID: CGRect] = [:]
    private weak var previousResponder: NSResponder?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent {
            switch event.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp: break
            default: return nil
            }
        }
        let location = convert(point, from: superview)
        guard !isHidden, bounds.contains(location), !frames.values.contains(where: { $0.contains(location) }) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard event.type == .leftMouseDown, bounds.contains(location),
              !frames.values.contains(where: { $0.contains(location) }) else { return }
        origin = location
        snapshot = selected
        gestureFrames = frames
    }

    override func mouseDragged(with event: NSEvent) {
        guard origin != nil else { return }
        if window != nil { _ = autoscroll(with: event) }
        updateDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        updateDrag(with: event)
        finishDrag()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, origin != nil { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        guard origin != nil else {
            nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
            return
        }
        publish(snapshot)
        finishDrag(restoreFocus: true)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, origin != nil { cancelOperation(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let selectionRect else { return }
        let path = NSBezierPath(rect: selectionRect)
        NSColor(Palette.accent).withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor(Palette.accent).withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func updateDrag(with event: NSEvent) {
        guard let origin else { return }
        let location = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: min(max(location.x, bounds.minX), bounds.maxX),
                            y: min(max(location.y, bounds.minY), bounds.maxY))
        if selectionRect == nil {
            guard hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(self)
            onBegin()
        }
        let rectangle = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                               width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        if selectionRect != rectangle {
            if let selectionRect { setNeedsDisplay(selectionRect.insetBy(dx: -1, dy: -1)) }
            selectionRect = rectangle
            setNeedsDisplay(rectangle.insetBy(dx: -1, dy: -1))
        }
        let enclosed = Set(gestureFrames.compactMap { rectangle.intersects($0.value) ? $0.key : nil })
        publish(snapshot.symmetricDifference(enclosed))
    }

    private func publish(_ selection: Set<UUID>) {
        guard selected != selection else { return }
        selected = selection
        onSelectionChange(selection)
    }

    private func finishDrag(restoreFocus: Bool = false) {
        if let selectionRect { setNeedsDisplay(selectionRect.insetBy(dx: -1, dy: -1)) }
        origin = nil
        selectionRect = nil
        snapshot.removeAll(keepingCapacity: false)
        gestureFrames.removeAll(keepingCapacity: false)
        if window?.firstResponder === self { window?.makeFirstResponder(restoreFocus ? previousResponder : nil) }
        previousResponder = nil
    }
}
