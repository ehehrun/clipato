import AppKit
import SwiftUI

struct SidebarResizeHandle: NSViewRepresentable {
    static let hitWidth: CGFloat = 24
    let width: CGFloat
    var isEnabled = true
    let onResize: (CGFloat) -> Void
    let onResizeEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        SidebarResizeHandleView(width: width, onResize: onResize, onResizeEnd: onResizeEnd)
    }

    func updateNSView(_ view: SidebarResizeHandleView, context: Context) {
        view.width = width
        view.isEnabled = isEnabled
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
        view.setAccessibilityLabel(L("调整侧边栏宽度"))
        view.toolTip = L("调整侧边栏宽度")
    }
}

final class SidebarResizeHandleView: NSView {
    var width: CGFloat
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled {
                isHovered = false
                isPressed = false
                dragging = false
            }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }
    }
    var onResize: (CGFloat) -> Void
    var onResizeEnd: (CGFloat) -> Void
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var dragging = false
    private var isPressed = false
    private var isHovered = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private weak var protectedWindow: NSWindow?
    private var previousWindowMovable = true

    init(width: CGFloat, onResize: @escaping (CGFloat) -> Void, onResizeEnd: @escaping (CGFloat) -> Void) {
        self.width = width
        self.onResize = onResize
        self.onResizeEnd = onResizeEnd
        super.init(frame: .zero)
        setAccessibilityRole(.splitter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        releaseWindowDragProtection()
        isHovered = false
        isPressed = false
        dragging = false
        if let console = window as? ConsoleWindow, console.sidebarResizeHandle === self {
            console.sidebarResizeHandle = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let console = window as? ConsoleWindow { console.sidebarResizeHandle = self }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        isPressed = false
        dragging = false
        releaseWindowDragProtection()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTrackingAreas()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self)
        addTrackingArea(area)
        hoverArea = area
        if let window {
            isHovered = isEnabled && !isHiddenOrHasHiddenAncestor &&
                bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        updateWindowDragProtection()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
        updateWindowDragProtection()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateWindowDragProtection()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered || isPressed else { return }
        NSColor(Palette.accent).withAlphaComponent(0.55).setFill()
        NSRect(x: bounds.midX - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
    }

    private func updateWindowDragProtection() {
        guard isEnabled && !isHiddenOrHasHiddenAncestor && (isHovered || isPressed), let window else {
            releaseWindowDragProtection()
            return
        }
        if protectedWindow == nil {
            protectedWindow = window
            previousWindowMovable = window.isMovable
            // Titlebar dragging can start in WindowServer before NSWindow dispatches mouse-down.
            window.isMovable = false
        }
    }

    private func releaseWindowDragProtection() {
        protectedWindow?.isMovable = previousWindowMovable
        protectedWindow = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateWindowDragProtection()
        startX = event.locationInWindow.x
        startWidth = width
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled && isPressed else { return }
        dragging = true
        onResize(startWidth + event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        isHovered = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        updateWindowDragProtection()
        guard dragging else { return }
        dragging = false
        onResizeEnd(startWidth + event.locationInWindow.x - startX)
    }
}
