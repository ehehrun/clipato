import AppKit

@MainActor
final class FixedCaptureOverlay {
    var onCapture: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTagChange: ((AssetTag?) -> Void)?
    var onRegionChange: ((RecordingRegion) -> Void)?
    private var borderWindow: NSPanel?
    private var controlsWindow: NSPanel?
    private var referenceWindow: NSPanel?
    private var controls: FixedCaptureControlsView?
    private var region: RecordingRegion?
    private var initialFrame = CGRect.zero
    private var regionFrame = CGRect.zero
    private var screenFrame = CGRect.zero
    private var visibleFrame = CGRect.zero
    private var dragFrame: CGRect?
    private var dragControlsFrame: CGRect?
    private var canMove = false
    private var temporarilyHidden = false

    var windowIDs: [CGWindowID] {
        [borderWindow, controlsWindow, referenceWindow].compactMap { $0.map { CGWindowID($0.windowNumber) } }
    }

    func show(_ region: RecordingRegion, tag: AssetTag? = nil, shortcutDescription: String) throws {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == region.displayID
        }) else {
            throw OverlayError.displayUnavailable(region.displayID)
        }
        let regionFrame = try region.appKitFrame(screenFrame: screen.frame)
        hide()
        self.region = region
        initialFrame = regionFrame
        self.regionFrame = regionFrame
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        canMove = true
        let borderFrame = Self.borderFrame(for: regionFrame)
        let border = FixedCapturePanel(frame: borderFrame, interactive: false)
        border.contentView = FixedCaptureBorderView(frame: CGRect(origin: .zero, size: borderFrame.size))
        borderWindow = border
        border.orderFrontRegardless()

        let frame = Self.controlsFrame(for: regionFrame, within: screen.visibleFrame)
        let panel = FixedCapturePanel(frame: frame, interactive: true)
        let controls = FixedCaptureControlsView(frame: CGRect(origin: .zero, size: frame.size))
        controls.onCapture = { [weak self] in self?.onCapture?() }
        controls.onFinish = { [weak self] in self?.onFinish?() }
        controls.onCancel = { [weak self] in self?.onCancel?() }
        controls.onTagChange = { [weak self] in self?.onTagChange?($0) }
        controls.onMoveStart = { [weak self] in self?.beginMove() }
        controls.onMove = { [weak self] delta, snap in self?.move(by: delta, snap: snap) }
        controls.onMoveEnd = { [weak self] in self?.endMove() }
        controls.onNudge = { [weak self] delta in self?.nudge(by: delta) }
        controls.onRestore = { [weak self] in self?.restorePosition() }
        controls.onSizeChange = { [weak self] in self?.resizeControls() }
        controls.reset(tag: tag, shortcutDescription: shortcutDescription)
        controls.updatePosition(region, atInitialPosition: true)
        panel.contentView = controls
        self.controls = controls
        controlsWindow = panel
        resizeControls()
        panel.orderFrontRegardless()
    }

    func update(count: Int, busy: Bool, pending: Int = 0, finishing: Bool = false) {
        canMove = !busy && !finishing
        if !canMove { endMove() }
        controls?.update(count: count, busy: busy, pending: pending, finishing: finishing)
    }

    func updateShortcutDescription(_ description: String) {
        controls?.updateShortcutDescription(description)
    }

    func setTemporarilyHidden(_ hidden: Bool) {
        temporarilyHidden = hidden
        if hidden { controls?.cancelMove() }
        borderWindow?.alphaValue = hidden ? 0 : 1
        controlsWindow?.alphaValue = hidden ? 0 : 1
        referenceWindow?.alphaValue = hidden ? 0 : 1
        controlsWindow?.ignoresMouseEvents = hidden
    }

    func hide() {
        controls?.cancelMove()
        endMove()
        controlsWindow?.close()
        controlsWindow = nil
        controls = nil
        borderWindow?.close()
        borderWindow = nil
        region = nil
        canMove = false
        temporarilyHidden = false
    }

    private func beginMove() {
        guard canMove, !temporarilyHidden, region != nil else { return }
        dragFrame = regionFrame
        dragControlsFrame = controlsWindow!.frame
        let panel = FixedCapturePanel(frame: screenFrame, interactive: false)
        panel.contentView = FixedCaptureReferenceView(
            frame: CGRect(origin: .zero, size: screenFrame.size),
            reference: initialFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
        referenceWindow = panel
        panel.orderFrontRegardless()
        borderWindow?.orderFrontRegardless()
        controlsWindow?.orderFrontRegardless()
    }

    private func move(by delta: CGSize, snap: Bool) {
        guard canMove, !temporarilyHidden, let dragFrame else { return }
        let proposed = dragFrame.offsetBy(dx: delta.width, dy: delta.height)
        applyFrame(Self.movedFrame(proposed, reference: initialFrame, within: screenFrame, snap: snap))
    }

    private func endMove() {
        referenceWindow?.close()
        referenceWindow = nil
        dragFrame = nil
        dragControlsFrame = nil
    }

    private func nudge(by delta: CGSize) {
        guard canMove, !temporarilyHidden, region != nil else { return }
        let proposed = regionFrame.offsetBy(dx: delta.width, dy: delta.height)
        applyFrame(Self.movedFrame(proposed, reference: initialFrame, within: screenFrame, snap: false))
    }

    private func restorePosition() {
        guard canMove, !temporarilyHidden, region != nil else { return }
        applyFrame(initialFrame)
    }

    private func applyFrame(_ frame: CGRect) {
        guard frame != regionFrame, let region else { return }
        regionFrame = frame
        let moved = Self.recordingRegion(for: frame, displayID: region.displayID, screenFrame: screenFrame)
        self.region = moved
        borderWindow?.setFrame(Self.borderFrame(for: frame), display: true, animate: false)
        let toolbarFrame: CGRect
        if let dragFrame, let dragControlsFrame {
            // Keep the handle beneath the pointer when crossing the toolbar's above/below boundary.
            toolbarFrame = Self.movedFrame(
                dragControlsFrame.offsetBy(dx: frame.minX - dragFrame.minX, dy: frame.minY - dragFrame.minY),
                reference: dragControlsFrame, within: visibleFrame, snap: false)
        } else {
            toolbarFrame = Self.controlsFrame(for: frame, within: visibleFrame, size: controls!.preferredSize)
        }
        controlsWindow?.setFrame(toolbarFrame, display: true, animate: false)
        controls?.updatePosition(moved, atInitialPosition: frame == initialFrame)
        onRegionChange?(moved)
    }

    static func movedFrame(_ frame: CGRect, reference: CGRect, within bounds: CGRect, snap: Bool) -> CGRect {
        var origin = frame.origin
        if snap {
            if abs(origin.x - reference.minX) <= 6 { origin.x = reference.minX }
            if abs(origin.y - reference.minY) <= 6 { origin.y = reference.minY }
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - frame.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }

    static func recordingRegion(for frame: CGRect, displayID: CGDirectDisplayID, screenFrame: CGRect) -> RecordingRegion {
        RecordingRegion(displayID: displayID, rect: CGRect(x: frame.minX - screenFrame.minX,
            y: screenFrame.maxY - frame.maxY, width: frame.width, height: frame.height))
    }

    static func borderFrame(for region: CGRect) -> CGRect {
        region.insetBy(dx: -FixedCaptureBorderView.lineWidth, dy: -FixedCaptureBorderView.lineWidth)
    }

    private func resizeControls() {
        guard let controls, let controlsWindow else { return }
        controlsWindow.setFrame(Self.controlsFrame(for: regionFrame, within: visibleFrame, size: controls.preferredSize),
                                display: true, animate: false)
    }

    static func controlsFrame(for region: CGRect, within visibleFrame: CGRect, size: CGSize = CGSize(width: 420, height: 44)) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = size.height
        let gap: CGFloat = 10
        let x = min(max(region.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let below = region.minY - gap - height
        let above = region.maxY + gap
        let y: CGFloat
        if below >= visibleFrame.minY { y = below }
        else if above + height <= visibleFrame.maxY { y = above }
        else { y = min(max(region.minY + gap, visibleFrame.minY), visibleFrame.maxY - height) }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum OverlayError: LocalizedError {
        case displayUnavailable(CGDirectDisplayID)
        var errorDescription: String? {
            switch self {
            case .displayUnavailable(let id): return L("显示器 \(id) 已断开，无法继续截取固定区域。")
            }
        }
    }
}

private final class FixedCapturePanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect, interactive: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = interactive
        ignoresMouseEvents = !interactive
        hidesOnDeactivate = false
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
}

private final class FixedCaptureReferenceView: NSView {
    private let reference: CGRect

    init(frame: CGRect, reference: CGRect) {
        self.reference = reference
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        let guides = NSBezierPath()
        guides.lineWidth = 1
        guides.setLineDash([5, 4], count: 2, phase: 0)
        for x in [reference.minX, reference.maxX] {
            guides.move(to: CGPoint(x: x, y: bounds.minY))
            guides.line(to: CGPoint(x: x, y: bounds.maxY))
        }
        for y in [reference.minY, reference.maxY] {
            guides.move(to: CGPoint(x: bounds.minX, y: y))
            guides.line(to: CGPoint(x: bounds.maxX, y: y))
        }
        guides.stroke()
    }
}

final class FixedCaptureBorderView: NSView {
    static let lineWidth: CGFloat = 3

    var captureRect: CGRect {
        bounds.insetBy(dx: Self.lineWidth, dy: Self.lineWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setFill()
        let border = NSBezierPath(rect: bounds)
        border.appendRect(captureRect)
        border.windingRule = .evenOdd
        border.fill()
    }
}

@MainActor
final class FixedCaptureControlsView: NSVisualEffectView {
    var onCapture: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTagChange: ((AssetTag?) -> Void)?
    var onMoveStart: (() -> Void)?
    var onMove: ((CGSize, Bool) -> Void)?
    var onMoveEnd: (() -> Void)?
    var onNudge: ((CGSize) -> Void)?
    var onRestore: (() -> Void)?
    private let moveHandle = FixedCaptureMoveHandle()
    private let restore = FixedCaptureButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: L("回到第一次截图位置"))!, target: nil, action: nil)
    private let status = NSTextField(labelWithString: L("连续截图"))
    private let metrics = NSTextField(labelWithString: L("已截 0 张"))
    private let tagPicker = NativeAssetTagPicker()
    private let capture = FixedCaptureButton(title: "", target: nil, action: nil)
    private let finish = FixedCaptureButton(title: "", target: nil, action: nil)
    private let cancel = FixedCaptureButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("取消连续截图"))!, target: nil, action: nil)
    private let row = NSStackView()
    private var busy = false
    private var finishing = false
    private var region: RecordingRegion?
    var onSizeChange: (() -> Void)?
    var preferredSize: CGSize { CGSize(width: ceil(row.fittingSize.width) + 16, height: max(44, ceil(row.fittingSize.height) + 12)) }
    private var lastPreferredSize = CGSize.zero
    private var count = 0
    private var pending = 0
    private var shortcutDescription = ""
    private var atInitialPosition = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 10
        layer!.masksToBounds = true
        for button in [restore, capture, finish, cancel] {
            button.focusRingType = .none
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        moveHandle.identifier = NSUserInterfaceItemIdentifier("fixed-capture-move")
        moveHandle.onMoveStart = { [weak self] in self?.onMoveStart?() }
        moveHandle.onMove = { [weak self] delta, snap in self?.onMove?(delta, snap) }
        moveHandle.onMoveEnd = { [weak self] in self?.onMoveEnd?() }
        moveHandle.onNudge = { [weak self] delta in self?.onNudge?(delta) }
        restore.identifier = NSUserInterfaceItemIdentifier("fixed-capture-restore")
        restore.target = self
        restore.action = #selector(restorePosition)
        restore.toolTip = L("回到第一次截图位置")
        restore.setAccessibilityLabel(L("回到第一次截图位置"))
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.setAccessibilityIdentifier("fixed-capture-status")
        metrics.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        metrics.textColor = .secondaryLabelColor
        metrics.lineBreakMode = .byTruncatingTail
        metrics.setAccessibilityIdentifier("fixed-capture-count")
        let labels = NSStackView(views: [status, metrics])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagPicker.identifier = NSUserInterfaceItemIdentifier("fixed-capture-tag")
        tagPicker.widthAnchor.constraint(equalToConstant: tagPicker.preferredWidth).isActive = true
        tagPicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
        tagPicker.onChange = { [weak self] in self?.onTagChange?($0) }
        capture.identifier = NSUserInterfaceItemIdentifier("fixed-capture-take")
        capture.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        capture.setAccessibilityLabel(L("截一张"))
        capture.target = self
        capture.action = #selector(takeScreenshot)
        finish.identifier = NSUserInterfaceItemIdentifier("fixed-capture-finish")
        finish.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        finish.setAccessibilityLabel(L("完成长图"))
        finish.target = self
        finish.action = #selector(finishCapture)
        finish.toolTip = L("按截取顺序拼成长图并保存")
        cancel.identifier = NSUserInterfaceItemIdentifier("fixed-capture-cancel")
        cancel.target = self
        cancel.action = #selector(cancelCapture)
        cancel.toolTip = L("取消连续截图")
        cancel.setAccessibilityLabel(L("取消连续截图"))
        capture.setContentCompressionResistancePriority(.required, for: .horizontal)
        finish.setContentCompressionResistancePriority(.required, for: .horizontal)
        [moveHandle, restore, labels, tagPicker, capture, finish, cancel].forEach(row.addArrangedSubview)
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        update(count: 0, busy: false)
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func reset(tag: AssetTag?, shortcutDescription: String) {
        tagPicker.assetTag = tag
        atInitialPosition = true
        updateShortcutDescription(shortcutDescription)
        update(count: 0, busy: false)
    }

    func updateShortcutDescription(_ description: String) {
        shortcutDescription = description
        capture.toolTip = description.isEmpty ? L("截取固定区域") : L("截取固定区域 · \(description)")
        updateMetrics()
    }

    func update(count: Int, busy: Bool, pending: Int = 0, finishing: Bool = false) {
        self.count = count
        self.pending = pending
        self.busy = busy
        self.finishing = finishing
        status.stringValue = finishing ? L("正在完成…") : (pending > 0 ? L("正在截图…") : (busy ? L("处理中…") : L("连续截图")))
        updateMetrics()
        capture.isEnabled = !finishing && (!busy || pending > 0)
        finish.isEnabled = !finishing && (count > 0 || pending > 0) && (!busy || pending > 0)
        tagPicker.isEnabled = !busy && !finishing
        cancel.isEnabled = !busy && !finishing
        moveHandle.isEnabled = !busy && !finishing
        restore.isEnabled = moveHandle.isEnabled && !atInitialPosition
    }

    func updatePosition(_ region: RecordingRegion, atInitialPosition: Bool) {
        self.atInitialPosition = atInitialPosition
        self.region = region
        restore.isEnabled = moveHandle.isEnabled && !atInitialPosition
        let x = String(format: "%.1f", region.rect.minX)
        let y = String(format: "%.1f", region.rect.minY)
        moveHandle.toolTip = L("拖动移动选框 · X \(x), Y \(y) pt\n点击后方向键微调 1 pt；Shift 每次 10 pt；⌥ 拖动暂不吸附")
    }

    func cancelMove() { moveHandle.cancelMove() }

    @objc private func updateLanguage() {
        tagPicker.updateLanguage()
        restore.toolTip = L("回到第一次截图位置")
        restore.setAccessibilityLabel(L("回到第一次截图位置"))
        capture.title = ""
        capture.imagePosition = .imageOnly
        capture.setAccessibilityLabel(L("截一张"))
        finish.title = ""
        finish.imagePosition = .imageOnly
        finish.setAccessibilityLabel(L("完成长图"))
        finish.toolTip = L("按截取顺序拼成长图并保存")
        cancel.toolTip = L("取消连续截图")
        cancel.setAccessibilityLabel(L("取消连续截图"))
        updateShortcutDescription(shortcutDescription)
        if let region { updatePosition(region, atInitialPosition: atInitialPosition) }
        update(count: count, busy: busy, pending: pending, finishing: finishing)
    }

    private func updateMetrics() {
        let counts = pending > 0 ? L("已截 \(count) 张 · 待截 \(pending) 张") : L("已截 \(count) 张")
        metrics.stringValue = counts + (shortcutDescription.isEmpty ? "" : " · \(shortcutDescription)")
        notifySizeChange()
    }

    private func notifySizeChange() {
        let size = preferredSize
        guard size != lastPreferredSize else { return }
        lastPreferredSize = size
        onSizeChange?()
    }

    @objc private func takeScreenshot() {
        guard capture.isEnabled, let onCapture else { return }
        onCapture()
    }

    @objc private func finishCapture() {
        guard finish.isEnabled, let onFinish else { return }
        update(count: count, busy: true, pending: pending, finishing: true)
        onFinish()
    }

    @objc private func cancelCapture() {
        guard cancel.isEnabled, let onCancel else { return }
        onCancel()
    }

    @objc private func restorePosition() {
        guard restore.isEnabled else { return }
        onRestore?()
    }
}

@MainActor
final class FixedCaptureMoveHandle: NSControl {
    var onMoveStart: (() -> Void)?
    var onMove: ((CGSize, Bool) -> Void)?
    var onMoveEnd: (() -> Void)?
    var onNudge: ((CGSize) -> Void)?
    private let symbol = NSImageView()
    private var dragOrigin: CGPoint?

    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override var isEnabled: Bool {
        didSet {
            symbol.contentTintColor = isEnabled ? .labelColor : .disabledControlTextColor
            window?.invalidateCursorRects(for: self)
            if !isEnabled { cancelMove() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        symbol.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)
        symbol.imageScaling = .scaleProportionallyDown
        symbol.contentTintColor = .labelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            symbol.widthAnchor.constraint(equalToConstant: 16),
            symbol.heightAnchor.constraint(equalToConstant: 16),
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateLanguage()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
    }

    @objc private func updateLanguage() {
        setAccessibilityLabel(L("移动截图选框"))
        setAccessibilityHelp(L("拖动移动选框，方向键微调；按住 Shift 每次移动 10 pt，按住 Option 暂停吸附。"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeKey()
        window.makeFirstResponder(self)
        dragOrigin = NSEvent.mouseLocation
        onMoveStart?()
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let dragOrigin else { return }
        let point = NSEvent.mouseLocation
        onMove?(CGSize(width: point.x - dragOrigin.x, height: point.y - dragOrigin.y),
                !event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) { cancelMove() }

    func cancelMove() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        onMoveEnd?()
        NSCursor.openHand.set()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard modifiers.subtracting(.shift).isEmpty else { super.keyDown(with: event); return }
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: -step)
        case 126: delta = CGSize(width: 0, height: step)
        default: super.keyDown(with: event); return
        }
        onNudge?(delta)
    }
}

private final class FixedCaptureButton: NSButton {
    // Symbol optical insets must not expand the fixed toolbar hit target.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
