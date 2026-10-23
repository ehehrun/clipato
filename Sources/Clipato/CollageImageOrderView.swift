import AppKit
import SwiftUI

struct CollageImageOrderView: View {
    let images: [CGImage]
    let order: [Int]
    let selectedImageIndex: Int?
    let sessionID: UUID
    let isManual: Bool
    let onSelect: (Int) -> Void
    let onMove: (UUID, Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(L("图片顺序"), systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                Text(isManual ? L("拖动缩略图调整层级 · 越靠右越在上层") : L("拖动缩略图排序 · 按从左到右的顺序拼图"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            CollageOrderStrip(images: images, order: order, selectedImageIndex: selectedImageIndex,
                              sessionID: sessionID, onSelect: onSelect, onMove: onMove)
                .frame(height: 78)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

private struct CollageOrderStrip: NSViewRepresentable {
    let images: [CGImage]
    let order: [Int]
    let selectedImageIndex: Int?
    let sessionID: UUID
    let onSelect: (Int) -> Void
    let onMove: (UUID, Int, Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = CollageOrderStripView(images: images)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let strip = scroll.documentView as! CollageOrderStripView
        strip.onSelect = onSelect
        strip.onMove = onMove
        strip.update(order: order, selectedImageIndex: selectedImageIndex, sessionID: sessionID)
    }
}

final class CollageOrderStripView: NSView {
    private let images: [CGImage]
    private(set) var order: [Int] = []
    private var selectedImageIndex: Int?
    private var sessionID = UUID()
    private var drag: Drag?
    private(set) var dragPreviewImage: NSImage?
    private var dragPreviewPanel: CollageDragPreviewPanel?
    private var dragWindowObserver: NSObjectProtocol?
    var onSelect: (Int) -> Void = { _ in }
    var onMove: (UUID, Int, Int) -> Void = { _, _, _ in }

    private static let cardWidth: CGFloat = 84
    private static let stride: CGFloat = 92
    private struct Drag {
        let source: Int
        let origin: CGPoint
        var isMoving = false
        var slot: Int?
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(images: [CGImage]) {
        self.images = images
        super.init(frame: .zero)
        setAccessibilityRole(.list)
        setAccessibilityLabel(L("图片顺序"))
        toolTip = L("拖动缩略图调整顺序")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let dragWindowObserver { NotificationCenter.default.removeObserver(dragWindowObserver) }
    }

    func update(order: [Int], selectedImageIndex: Int?, sessionID: UUID) {
        if self.order != order || self.sessionID != sessionID {
            clearDrag()
            self.order = order
            self.sessionID = sessionID
            frame.size = CGSize(width: max(1, CGFloat(order.count) * Self.stride - 8), height: 74)
            needsDisplay = true
            setAccessibilityChildren(order.map { index in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.image)
                element.setAccessibilityLabel(L("图片 \(index + 1)"))
                element.setAccessibilityParent(self)
                return element
            })
        }
        if self.selectedImageIndex != selectedImageIndex {
            invalidateCard(self.selectedImageIndex)
            invalidateCard(selectedImageIndex)
            self.selectedImageIndex = selectedImageIndex
        }
    }

    private func cardFrame(at position: Int) -> CGRect {
        CGRect(x: CGFloat(position) * Self.stride, y: 2, width: Self.cardWidth, height: 68)
    }

    private func invalidateCard(_ imageIndex: Int?) {
        guard let imageIndex, let position = order.firstIndex(of: imageIndex) else { return }
        setNeedsDisplay(cardFrame(at: position))
    }

    private var insertionFrame: CGRect? {
        guard let slot = drag?.slot else { return nil }
        let x = slot == 0 ? 0 : slot == order.count ? bounds.maxX - 2 : CGFloat(slot) * Self.stride - 5
        return CGRect(x: x, y: 3, width: 2, height: 66)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (position, imageIndex) in order.enumerated() {
            let card = cardFrame(at: position)
            guard card.intersects(dirtyRect) else { continue }
            drawCollageOrderCard(images[imageIndex], imageIndex: imageIndex, in: card, context: context,
                                 selected: selectedImageIndex == imageIndex,
                                 imageOpacity: drag?.isMoving == true && drag?.source == imageIndex ? 0.45 : 1)
        }
        if let insertionFrame {
            NSColor(Palette.accent).setFill()
            NSBezierPath(roundedRect: insertionFrame, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        clearDrag()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let position = order.indices.first(where: { cardFrame(at: $0).contains(point) }) else { return }
        let source = order[position]
        drag = Drag(source: source, origin: point)
        invalidateCard(selectedImageIndex)
        selectedImageIndex = source
        invalidateCard(source)
        onSelect(source)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        autoscroll(with: event)
        updateDrag(at: convert(event.locationInWindow, from: nil))
        updateDragPreview(with: event)
    }

    private func updateDrag(at point: CGPoint) {
        guard var drag, let current = order.firstIndex(of: drag.source) else { return }
        guard drag.isMoving || hypot(point.x - drag.origin.x, point.y - drag.origin.y) >= 4 else { return }
        if let insertionFrame { setNeedsDisplay(insertionFrame) }
        if !drag.isMoving {
            invalidateCard(drag.source)
            let image = images[drag.source]
            let imageIndex = drag.source
            let preview = NSImage(size: CGSize(width: Self.cardWidth, height: 68), flipped: true) { rect in
                drawCollageOrderCard(image, imageIndex: imageIndex, in: rect,
                                     context: NSGraphicsContext.current!.cgContext, selected: true)
                return true
            }
            preview.cacheMode = .always
            dragPreviewImage = preview
        }
        drag.isMoving = true
        let slot = min(order.count, max(0, Int(floor((point.x + Self.stride - Self.cardWidth / 2) / Self.stride))))
        let target = slot > current ? slot - 1 : slot
        drag.slot = point.y >= 0 && point.y <= bounds.height && target != current ? slot : nil
        self.drag = drag
        if let insertionFrame { setNeedsDisplay(insertionFrame) }
    }

    override func mouseUp(with event: NSEvent) {
        if drag?.isMoving == true { updateDrag(at: convert(event.locationInWindow, from: nil)) }
        guard let completed = drag else { return }
        clearDrag()
        guard let slot = completed.slot, let current = order.firstIndex(of: completed.source) else { return }
        let target = slot > current ? slot - 1 : slot
        onMove(sessionID, completed.source, order[target])
    }

    private func clearDrag() {
        if let insertionFrame { setNeedsDisplay(insertionFrame) }
        invalidateCard(drag?.source)
        drag = nil
        if let dragWindowObserver { NotificationCenter.default.removeObserver(dragWindowObserver) }
        dragWindowObserver = nil
        dragPreviewPanel?.close()
        dragPreviewPanel = nil
        dragPreviewImage = nil
    }

    private func updateDragPreview(with event: NSEvent) {
        guard let image = dragPreviewImage, let window else { return }
        let panel: CollageDragPreviewPanel
        if let dragPreviewPanel { panel = dragPreviewPanel }
        else {
            panel = CollageDragPreviewPanel(contentRect: CGRect(origin: .zero, size: image.size),
                                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.alphaValue = 0.92
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.animationBehavior = .none
            panel.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.floating.rawValue))
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            panel.appearance = window.effectiveAppearance
            let imageView = NSImageView(frame: CGRect(origin: .zero, size: image.size))
            imageView.image = image
            imageView.imageScaling = .scaleNone
            panel.contentView = imageView
            dragPreviewPanel = panel
            dragWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                         object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearDrag() }
            }
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        panel.setFrameOrigin(CGPoint(x: point.x + 12, y: point.y - image.size.height - 12))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        clearDrag()
        super.viewWillMove(toWindow: newWindow)
    }

    override func cancelOperation(_ sender: Any?) {
        if drag != nil { clearDrag() }
        else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, window?.firstResponder === self, drag != nil {
            clearDrag()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CollageDragPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private func drawCollageOrderCard(_ image: CGImage, imageIndex: Int, in card: CGRect, context: CGContext,
                                  selected: Bool, imageOpacity: CGFloat = 1) {
    let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    NSColor(Palette.card).setFill()
    outline.fill()
    (selected ? NSColor(Palette.accent) : NSColor(Palette.line)).setStroke()
    outline.lineWidth = 1
    outline.stroke()

    let scale = min(74 / CGFloat(image.width), 44 / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    let target = CGRect(x: card.midX - size.width / 2, y: card.minY + 5 + (44 - size.height) / 2,
                        width: size.width, height: size.height)
    context.saveGState()
    context.setAlpha(imageOpacity)
    context.interpolationQuality = .high
    context.translateBy(x: target.minX, y: target.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: size))
    context.restoreGState()
    let label = NSAttributedString(string: L("图片 \(imageIndex + 1)"), attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(Palette.foreground)
    ])
    label.draw(at: CGPoint(x: card.midX - label.size().width / 2, y: card.minY + 51))
}
