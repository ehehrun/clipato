import AppKit

@MainActor
final class RecordingRegionOverlay {
    private var window: NSPanel?
    private var controlsWindow: NSPanel?
    private var controls: RecordingControlsView?
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onTagChange: ((AssetTag?) -> Void)?

    func show(_ region: RecordingRegion, mode: RecordingMode = .keyframes, tag: AssetTag? = nil) throws {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == region.displayID
        }) else {
            throw OverlayError.displayUnavailable(region.displayID)
        }
        let frame = try region.appKitFrame(screenFrame: screen.frame)
        let panel: NSPanel
        if let window {
            panel = window
            panel.setFrame(frame, display: true)
        } else {
            panel = RecordingRegionMarkerWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.worksWhenModal = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.contentView = RecordingRegionBorderView(frame: CGRect(origin: .zero, size: frame.size))
            window = panel
        }
        panel.orderFrontRegardless()

        let controlsFrame = Self.controlsFrame(for: frame, within: screen.visibleFrame)
        let toolbar: NSPanel
        if let controlsWindow {
            toolbar = controlsWindow
            toolbar.setFrame(controlsFrame, display: true)
        } else {
            toolbar = RecordingRegionMarkerWindow(contentRect: controlsFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            toolbar.isReleasedWhenClosed = false
            toolbar.isOpaque = false
            toolbar.backgroundColor = .clear
            toolbar.hasShadow = true
            toolbar.hidesOnDeactivate = false
            toolbar.worksWhenModal = true
            toolbar.becomesKeyOnlyIfNeeded = true
            toolbar.level = .screenSaver
            toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            toolbar.animationBehavior = .none
            let controls = RecordingControlsView(frame: CGRect(origin: .zero, size: controlsFrame.size))
            controls.onPause = { [weak self] in
                self?.setPauseTransition(true)
                self?.onPause?()
            }
            controls.onStop = { [weak self] in self?.onStop?() }
            controls.onTagChange = { [weak self] in self?.onTagChange?($0) }
            controls.onSizeChange = { [weak self] in self?.resizeControls() }
            toolbar.contentView = controls
            self.controls = controls
            controlsWindow = toolbar
        }
        controls?.reset(canStop: onStop != nil, canPause: onPause != nil, mode: mode, tag: tag)
        resizeControls()
        toolbar.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval, frameCount: Int, isPaused: Bool = false) {
        controls?.update(elapsed: elapsed, frameCount: frameCount, isPaused: isPaused)
    }

    func setPauseTransition(_ transitioning: Bool) {
        controls?.setPauseTransition(transitioning)
    }

    func setStopping() {
        controls?.setStopping()
    }

    func hide() {
        controlsWindow?.close()
        controlsWindow = nil
        controls = nil
        window?.close()
        window = nil
    }

    private func resizeControls() {
        guard let window, let controlsWindow, let controls, let screen = window.screen else { return }
        controlsWindow.setFrame(Self.controlsFrame(for: window.frame, within: screen.visibleFrame,
                                                   width: controls.preferredSize.width, height: controls.preferredSize.height),
                                display: true, animate: false)
    }

    static func controlsFrame(for region: CGRect, within visibleFrame: CGRect, width: CGFloat = 360, height: CGFloat = 44) -> CGRect {
        let width = min(width, visibleFrame.width)
        let gap: CGFloat = 10
        let x = min(max(region.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let below = region.minY - gap - height
        let above = region.maxY + gap
        let y: CGFloat
        if below >= visibleFrame.minY, below + height <= visibleFrame.maxY {
            y = below
        } else if above >= visibleFrame.minY, above + height <= visibleFrame.maxY {
            y = above
        } else {
            // A full-height capture leaves no outside space, so keep the controls on-screen.
            y = min(max(region.minY + gap, visibleFrame.minY), visibleFrame.maxY - height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum OverlayError: LocalizedError {
        case displayUnavailable(CGDirectDisplayID)
        var errorDescription: String? {
            switch self {
            case .displayUnavailable(let id): return L("显示器 \(id) 已断开，无法显示录屏区域。")
            }
        }
    }
}

private final class RecordingRegionMarkerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingRegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()
    }
}

@MainActor
final class RecordingControlsView: NSVisualEffectView {
    private let status = NSTextField(labelWithString: L("正在录屏"))
    private let modeIcon = NSImageView()
    private let metrics = NSTextField(labelWithString: L("00:00 · 0 帧"))
    private let indicator = NSImageView()
    private let pause = RecordingControlButton(title: "", target: nil, action: nil)
    private let stop = RecordingControlButton(title: "", target: nil, action: nil)
    private let tagPicker = NativeAssetTagPicker(frame: .zero, pullsDown: false)
    private let row = NSStackView()
    private var mode = RecordingMode.keyframes
    private var formattedTime = "00:00"
    private var frameCount = 0
    var onSizeChange: (() -> Void)?
    var preferredSize: CGSize { CGSize(width: ceil(row.fittingSize.width) + 16, height: max(44, ceil(row.fittingSize.height) + 12)) }
    private var lastPreferredSize = CGSize.zero
    private var canStop = false
    private var canPause = false
    private var isPaused = false
    private var transitioning = false
    private var stopping = false
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onTagChange: ((AssetTag?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 12
        layer!.masksToBounds = true

        indicator.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L("正在录屏"))
        indicator.contentTintColor = .systemGreen
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.widthAnchor.constraint(equalToConstant: 19).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 19).isActive = true
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = .labelColor
        status.setAccessibilityIdentifier("recording-status")
        modeIcon.contentTintColor = .secondaryLabelColor
        modeIcon.imageScaling = .scaleProportionallyDown
        modeIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        modeIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        modeIcon.setAccessibilityIdentifier("recording-mode")
        updateModeIcon()
        metrics.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        metrics.textColor = .secondaryLabelColor
        metrics.setAccessibilityIdentifier("recording-metrics")
        let heading = NSStackView(views: [status, modeIcon])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        let labels = NSStackView(views: [heading, metrics])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        for button in [pause, stop] {
            button.focusRingType = .none
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        pause.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        pause.target = self
        pause.action = #selector(togglePause)
        pause.setAccessibilityIdentifier("recording-pause")
        pause.setContentHuggingPriority(.required, for: .horizontal)
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.target = self
        stop.action = #selector(stopRecording)
        stop.toolTip = L("停止录屏并保存录制")
        stop.setAccessibilityLabel(L("停止并保存"))
        stop.setAccessibilityIdentifier("recording-stop")
        stop.setContentHuggingPriority(.required, for: .horizontal)
        tagPicker.font = .systemFont(ofSize: 12)
        tagPicker.setAccessibilityIdentifier("recording-tag")
        tagPicker.toolTip = L("为这次录制设置颜色标签")
        tagPicker.widthAnchor.constraint(equalToConstant: tagPicker.preferredWidth).isActive = true
        tagPicker.heightAnchor.constraint(equalToConstant: 28).isActive = true
        tagPicker.onChange = { [weak self] in self?.onTagChange?($0) }
        [indicator, labels, tagPicker, pause, stop].forEach(row.addArrangedSubview)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset(canStop: Bool, canPause: Bool, mode: RecordingMode = .keyframes, tag: AssetTag? = nil) {
        self.canStop = canStop
        self.canPause = canPause
        self.mode = mode
        updateModeIcon()
        tagPicker.assetTag = tag
        transitioning = false
        stopping = false
        isPaused = false
        update(elapsed: 0, frameCount: 0, isPaused: false)
        updateControls()
    }

    func update(elapsed: TimeInterval, frameCount: Int, isPaused: Bool) {
        let pauseChanged = self.isPaused != isPaused
        self.isPaused = isPaused
        let seconds = Int(elapsed)
        let time = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        formattedTime = time
        self.frameCount = frameCount
        metrics.stringValue = L("\(time) · \(frameCount) 帧")
        if pauseChanged { updateControls() }
        else { notifySizeChange() }
    }

    func setPauseTransition(_ transitioning: Bool) {
        self.transitioning = transitioning
        updateControls()
    }

    func setStopping() {
        stopping = true
        updateControls()
    }

    @objc private func updateLanguage() {
        tagPicker.updateLanguage()
        updateModeIcon()
        metrics.stringValue = L("\(formattedTime) · \(frameCount) 帧")
        stop.title = ""
        stop.imagePosition = .imageOnly
        stop.toolTip = L("停止录屏并保存录制")
        stop.setAccessibilityLabel(L("停止并保存"))
        tagPicker.toolTip = L("为这次录制设置颜色标签")
        updateControls()
    }

    private func updateModeIcon() {
        modeIcon.image = NSImage(systemSymbolName: mode.toolbarSymbol, accessibilityDescription: mode.toolbarTitle)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        modeIcon.toolTip = mode.toolbarTitle
        modeIcon.setAccessibilityLabel(mode.toolbarTitle)
    }

    private func updateControls() {
        if stopping {
            status.stringValue = L("正在保存…")
        } else if transitioning {
            status.stringValue = L("正在切换…")
        } else {
            status.stringValue = isPaused ? L("已暂停") : L("正在录屏")
        }
        indicator.image = NSImage(systemSymbolName: isPaused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: status.stringValue)
        indicator.contentTintColor = isPaused ? .systemOrange : .systemGreen
        pause.title = ""
        pause.setAccessibilityLabel(isPaused ? L("继续") : L("暂停"))
        pause.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        pause.imagePosition = .imageOnly
        pause.toolTip = isPaused ? L("继续录屏") : L("暂停录屏，暂停时间不计入录制")
        pause.isEnabled = canPause && !transitioning && !stopping
        stop.isEnabled = canStop && !transitioning && !stopping
        tagPicker.isEnabled = !stopping
        notifySizeChange()
    }

    private func notifySizeChange() {
        let size = preferredSize
        guard size != lastPreferredSize else { return }
        lastPreferredSize = size
        onSizeChange?()
    }

    @objc private func togglePause() {
        guard pause.isEnabled else { return }
        onPause?()
    }

    @objc private func stopRecording() {
        guard stop.isEnabled else { return }
        setStopping()
        onStop?()
    }
}

private final class RecordingControlButton: NSButton {
    // Symbol optical insets must not expand the fixed toolbar hit target.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
