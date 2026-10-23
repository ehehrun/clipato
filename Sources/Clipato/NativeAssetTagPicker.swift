import AppKit

@MainActor
final class NativeAssetTagPicker: NSPopUpButton {
    private static let tagImage = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private var actionToolTip: String?
    var onChange: ((AssetTag?) -> Void)?

    var assetTag: AssetTag? {
        get { indexOfSelectedItem == 0 ? nil : AssetTag.allCases[indexOfSelectedItem - 1] }
        set {
            selectItem(at: newValue.map { AssetTag.allCases.firstIndex(of: $0)! + 1 } ?? 0)
            updateToolTip()
            needsDisplay = true
        }
    }

    override init(frame buttonFrame: NSRect = .zero, pullsDown flag: Bool = false) {
        super.init(frame: buttonFrame, pullsDown: flag)
        cell = NativeAssetTagPickerCell(textCell: "", pullsDown: flag)
        focusRingType = .none
        controlSize = .small
        isBordered = false
        addItem(withTitle: L("无标签"))
        for tag in AssetTag.allCases {
            addItem(withTitle: tag.title)
            lastItem!.image = tag.swatch
        }
        menu!.minimumWidth = 150
        target = self
        action = #selector(selectTag)
        font = .systemFont(ofSize: 12)
        bezelStyle = .texturedRounded
        toolTip = L("设置保存后的颜色标签")
        setAccessibilityLabel(L("颜色标签"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 28) }
    override var toolTip: String? {
        get { super.toolTip }
        set { actionToolTip = newValue; updateToolTip() }
    }
    override func accessibilityValue() -> Any? { assetTag?.title ?? L("无标签") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var preferredWidth: CGFloat { 46 }

    private func updateToolTip() {
        super.toolTip = actionToolTip.map { "\($0) · \(assetTag?.title ?? L("无标签"))" }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    fileprivate func drawTrigger(in bounds: NSRect) {
        let opacity: CGFloat = isEnabled ? 1 : 0.35
        let tint = NSColor.labelColor.withAlphaComponent(opacity)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5)
        let fillAlpha: CGFloat = isHighlighted ? 0.15 : (isHovered && isEnabled ? 0.09 : 0.035)
        NSColor.labelColor.withAlphaComponent(fillAlpha * opacity).setFill()
        background.fill()

        let iconFrame = NSRect(x: bounds.midX - 16, y: bounds.midY - 7, width: 14, height: 14)
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        Self.tagImage.draw(in: iconFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn)
        context.setFillColor(tint.cgColor)
        context.fill(iconFrame)
        context.endTransparencyLayer()
        context.restoreGState()

        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX + 1, y: bounds.midY - 3, width: 6, height: 6))
        if let assetTag {
            NSColor(assetTag.color).withAlphaComponent(opacity).setFill()
            dot.fill()
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.65 * opacity).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }

        let chevron = NSBezierPath()
        let center = NSPoint(x: bounds.midX + 14, y: bounds.midY)
        let direction: CGFloat = isFlipped ? 1 : -1
        chevron.move(to: NSPoint(x: center.x - 2.5, y: center.y - direction))
        chevron.line(to: NSPoint(x: center.x, y: center.y + 1.5 * direction))
        chevron.line(to: NSPoint(x: center.x + 2.5, y: center.y - direction))
        chevron.lineWidth = 1.2
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.secondaryLabelColor.withAlphaComponent(opacity).setStroke()
        chevron.stroke()
    }

    func updateLanguage() {
        item(at: 0)!.title = L("无标签")
        for (index, tag) in AssetTag.allCases.enumerated() { item(at: index + 1)!.title = tag.title }
        toolTip = L("设置保存后的颜色标签")
        setAccessibilityLabel(L("颜色标签"))
        needsDisplay = true
    }

    @objc private func selectTag() {
        guard isEnabled else { return }
        updateToolTip()
        needsDisplay = true
        onChange?(assetTag)
    }
}

private final class NativeAssetTagPickerCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        (controlView as! NativeAssetTagPicker).drawTrigger(in: cellFrame)
    }
}
