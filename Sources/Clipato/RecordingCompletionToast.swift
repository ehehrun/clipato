import AppKit

@MainActor
final class RecordingCompletionToast {
    private var window: NSPanel?
    private var dismissal: Timer?

    deinit {
        dismissal?.invalidate()
        if let window { Task { @MainActor in window.close() } }
    }

    func show(message: String, displayID: CGDirectDisplayID?) {
        dismiss()
        let screens = NSScreen.screens
        let recordedScreen = displayID.flatMap { id in
            screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == id }
        }
        // A disconnected recording display places completion feedback on the screen in use.
        guard let screen = recordedScreen ?? screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let width = min(460, screen.visibleFrame.width - 40)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        let textWidth = width - 62
        let textSize = label.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: max(48, textSize.height + 28))
        let frame = Self.frame(for: size, within: screen.visibleFrame)
        let panel = RecordingCompletionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.setAccessibilityLabel(message)

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer!.cornerRadius = 12
        content.layer!.masksToBounds = true
        let icon = NSImageView(frame: CGRect(x: 16, y: (frame.height - 20) / 2, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemGreen
        icon.imageScaling = .scaleProportionallyDown
        label.frame = CGRect(x: 46, y: 14, width: frame.width - 62, height: frame.height - 28)
        content.addSubview(icon)
        content.addSubview(label)
        panel.contentView = content
        window = panel
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss() {
        dismissal?.invalidate()
        dismissal = nil
        window?.close()
        window = nil
    }

    nonisolated static func frame(for size: CGSize, within visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let topMargin = min(16, visibleFrame.height - height)
        return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.maxY - topMargin - height, width: width, height: height)
    }
}

private final class RecordingCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
