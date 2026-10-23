import AppKit
import Combine
import ScreenCaptureKit

enum ScreenshotAction { case copy, save, pin }

struct ScreenshotResult {
    let image: CGImage
    let action: ScreenshotAction
    let frame: CGRect
    let tag: AssetTag?
}

@MainActor
final class ScreenshotController: ObservableObject {
    @Published private(set) var pinnedMousePassthrough = false
    @Published private(set) var hasPinnedImages = false
    private typealias Selection = (screen: NSScreen, image: CGImage, pixelRect: CGRect, annotations: [ImageAnnotation], action: ScreenshotAction, recordingMode: RecordingMode, tag: AssetTag?)
    private var isCapturing = false
    private var selectionRequestID: UUID?
    private var selectionCancelled = false
    private var selectionError: Error?
    private var selectionWindows: [NSWindow] = []
    private var selectionContinuation: CheckedContinuation<Selection?, Never>?
    private var pinnedPanels: [UUID: NSPanel] = [:]

    func captureRegion(initialFullScreen: Bool = false, allowsDestinationActions: Bool = true, tag: AssetTag? = nil,
                       allowsTagSelection: Bool = true) async throws -> ScreenshotResult? {
        guard let selection = try await selectRegion(displayID: nil, mode: .screenshot(allowsDestinationActions: allowsDestinationActions),
                                                    initialFullScreen: initialFullScreen, tag: tag, allowsTagSelection: allowsTagSelection) else { return nil }
        let image = try renderAnnotatedImage(selection.image, crop: selection.pixelRect, annotations: selection.annotations)
        let screenFrame = selection.screen.frame
        let scaleX = screenFrame.width / CGFloat(selection.image.width)
        let scaleY = screenFrame.height / CGFloat(selection.image.height)
        let frame = CGRect(x: screenFrame.minX + selection.pixelRect.minX * scaleX,
                           y: screenFrame.maxY - selection.pixelRect.maxY * scaleY,
                           width: selection.pixelRect.width * scaleX,
                           height: selection.pixelRect.height * scaleY)
        return ScreenshotResult(image: image, action: selection.action, frame: frame, tag: selection.tag)
    }

    func selectRecordingRegion(displayID: CGDirectDisplayID? = nil, mode: RecordingMode = .keyframes,
                               tag: AssetTag? = nil) async throws -> (region: RecordingRegion, mode: RecordingMode, tag: AssetTag?)? {
        guard let selection = try await selectRegion(displayID: displayID, mode: .recording, recordingMode: mode, tag: tag) else { return nil }
        return (region(for: selection), selection.recordingMode, selection.tag)
    }

    func selectFixedRegion(tag: AssetTag? = nil) async throws -> (region: RecordingRegion, tag: AssetTag?)? {
        guard let selection = try await selectRegion(displayID: nil, mode: .fixedCapture, tag: tag) else { return nil }
        return (region(for: selection), selection.tag)
    }

    private func region(for selection: Selection) -> RecordingRegion {
        let rect = CGRect(x: selection.pixelRect.minX * selection.screen.frame.width / CGFloat(selection.image.width),
                          y: selection.pixelRect.minY * selection.screen.frame.height / CGFloat(selection.image.height),
                          width: selection.pixelRect.width * selection.screen.frame.width / CGFloat(selection.image.width),
                          height: selection.pixelRect.height * selection.screen.frame.height / CGFloat(selection.image.height))
        return RecordingRegion(displayID: selection.screen.displayID, rect: rect)
    }

    func cancelSelection() {
        selectionCancelled = true
        finishSelection(nil)
    }

    private func selectRegion(displayID: CGDirectDisplayID?, mode: SelectionView.Mode, initialFullScreen: Bool = false,
                              recordingMode: RecordingMode = .keyframes, tag: AssetTag? = nil,
                              allowsTagSelection: Bool = true) async throws -> Selection? {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }
        guard !Task.isCancelled else { return nil }
        isCapturing = true
        let requestID = UUID()
        selectionRequestID = requestID
        selectionCancelled = false
        selectionError = nil
        defer {
            selectionRequestID = nil
            isCapturing = false
        }
        let screen: NSScreen
        if let displayID {
            guard let target = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayNotFound(displayID)
            }
            screen = target
        } else {
            let mouseLocation = NSEvent.mouseLocation
            guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
                throw CaptureError.displayUnavailable
            }
            screen = target
        }
        return try await withTaskCancellationHandler {
            do {
                try AutomationAccess.check()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try AutomationAccess.check()
                let excludedApplications: [SCRunningApplication]
                switch mode {
                case .screenshot, .fixedCapture:
                    excludedApplications = []
                case .recording:
                    excludedApplications = content.applications.filter {
                        $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
                    }
                }
                guard !selectionCancelled, !Task.isCancelled else { return nil }
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                    throw CaptureError.displayUnavailable
                }
                let image = try await snapshot(display: display, screen: screen, excluding: excludedApplications)
                guard !selectionCancelled, !Task.isCancelled else { return nil }

                let selection = await withCheckedContinuation { continuation in
                    selectionContinuation = continuation
                    let window = SelectionWindow(contentRect: screen.frame)
                    window.animationBehavior = .none
                    window.level = .screenSaver
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    window.isOpaque = true
                    window.isReleasedWhenClosed = false
                    window.acceptsMouseMovedEvents = true
                    let view = SelectionView(image: image, frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode,
                                             initialFullScreen: initialFullScreen, recordingMode: recordingMode,
                                             tag: tag, allowsTagSelection: allowsTagSelection)
                    view.onRenderError = { [weak self] error in
                        guard let self, self.selectionRequestID == requestID else { return }
                        self.selectionError = error
                        self.finishSelection(nil)
                    }
                    view.onFinish = { [weak self, weak view] rect, action in
                        guard let view else { return }
                        self?.finishSelection(rect.map { (screen: screen, image: image, pixelRect: $0, annotations: view.annotations,
                                                         action: action, recordingMode: view.recordingMode, tag: view.assetTag) })
                    }
                    window.contentView = view
                    selectionWindows = [window]
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(view)
                    view.updateCursor(force: true)
                }
                if let selectionError { throw selectionError }
                return selection
            } catch {
                guard !selectionCancelled, !Task.isCancelled else { return nil }
                throw ScreenCapturePermission.localizedError(error)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.selectionRequestID == requestID else { return }
                self.cancelSelection()
            }
        }
    }

    func captureDisplay() async throws -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else {
            throw CaptureError.displayUnavailable
        }
        return try await captureDisplay(displayID: screen.displayID)
    }

    func captureFixedRegion(_ region: RecordingRegion, excludingWindowIDs: [CGWindowID]) async throws -> CGImage {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == region.displayID }) else {
            throw CaptureError.displayNotFound(region.displayID)
        }
        try region.validate(displayID: screen.displayID, displaySize: screen.frame.size)
        isCapturing = true
        defer { isCapturing = false }
        do {
            try AutomationAccess.check()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try AutomationAccess.check()
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw CaptureError.displayNotFound(region.displayID)
            }
            let excludedIDs = Set(excludingWindowIDs)
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excludedIDs.contains($0.windowID) })
            let configuration = try region.configuration(displayID: display.displayID, contentRect: filter.contentRect,
                                                         pointPixelScale: CGFloat(filter.pointPixelScale), maxDimension: Int.max)
            configuration.showsCursor = false
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try AutomationAccess.check()
            return image
        } catch {
            throw ScreenCapturePermission.localizedError(error)
        }
    }

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage? {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }
        isCapturing = true
        defer { isCapturing = false }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        do {
            try AutomationAccess.check()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try AutomationAccess.check()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayNotFound(displayID)
            }
            return try await snapshot(display: display, screen: screen)
        } catch {
            throw ScreenCapturePermission.localizedError(error)
        }
    }

    @discardableResult
    func pin(image: CGImage, frame: CGRect? = nil) -> NSPanel {
        let id = UUID()
        let panel = PinnedImagePanel(image: image, frame: frame)
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.pinnedPanels.removeValue(forKey: id)
            self.hasPinnedImages = !self.pinnedPanels.isEmpty
            if !self.hasPinnedImages { self.pinnedMousePassthrough = false }
        }
        panel.ignoresMouseEvents = pinnedMousePassthrough
        pinnedPanels[id] = panel
        hasPinnedImages = true
        if pinnedMousePassthrough { panel.orderFront(nil) }
        else { panel.makeKeyAndOrderFront(nil) }
        return panel
    }

    func togglePinnedMousePassthrough() {
        guard hasPinnedImages else { return }
        pinnedMousePassthrough.toggle()
        for panel in pinnedPanels.values {
            panel.ignoresMouseEvents = pinnedMousePassthrough
            if pinnedMousePassthrough && panel.isKeyWindow { panel.resignKey() }
        }
    }

    private func snapshot(display: SCDisplay, screen: NSScreen, excluding applications: [SCRunningApplication] = []) async throws -> CGImage {
        try AutomationAccess.check()
        let filter = SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try AutomationAccess.check()
        return image
    }

    private func finishSelection(_ result: Selection?) {
        guard let continuation = selectionContinuation else { return }
        selectionContinuation = nil
        for window in selectionWindows { window.close() }
        selectionWindows.removeAll()
        NSCursor.arrow.set()
        continuation.resume(returning: result)
    }

    private enum CaptureError: LocalizedError {
        case alreadyCapturing, displayUnavailable
        case displayNotFound(CGDirectDisplayID)
        var errorDescription: String? {
            switch self {
            case .alreadyCapturing: return L("屏幕捕获或选区正在进行。")
            case .displayUnavailable: return L("当前显示器已断开或无法访问，请重新选择屏幕。")
            case .displayNotFound(let id): return L("显示器 \(id) 不存在或已断开，请重新选择屏幕。")
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    }
}

final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
    }
}

@MainActor
private final class PinnedImagePanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { !ignoresMouseEvents }

    init(image: CGImage, frame: CGRect?) {
        let initialFrame: CGRect
        if let frame {
            initialFrame = frame
        } else {
            let maximumHeight = NSScreen.main!.visibleFrame.height * 0.75
            let scale = min(1, 640 / CGFloat(image.width), maximumHeight / CGFloat(image.height))
            initialFrame = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        }
        super.init(contentRect: initialFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        animationBehavior = .none
        // AppKit rounds the initial rectangle outward; restore the selected image size.
        if frame != nil { setFrame(initialFrame, display: false) }
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        worksWhenModal = true
        level = .floating
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinnedImageView(image: image, frame: CGRect(origin: .zero, size: initialFrame.size))
        if frame == nil { center() }
        makeFirstResponder(contentView)
    }

    override func close() {
        super.close()
        let callback = onClose
        onClose = nil
        callback?()
    }
}

@MainActor
private final class PinnedImageView: NSView {
    private let image: NSImage
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, frame: CGRect) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        super.init(frame: frame)
        updateLanguage()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
    }

    @objc private func updateLanguage() {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L("复制图片"), action: #selector(copyImage), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        let close = NSMenuItem(title: L("关闭贴图"), action: #selector(closeImage), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { window?.close() } else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.08))
        let width = min(max(window.frame.width * factor, 60), 2400)
        let height = width * image.size.height / image.size.width
        let old = window.frame
        window.setFrame(CGRect(x: old.midX - width / 2, y: old.midY - height / 2, width: width, height: height), display: true)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.close() }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyImage() }
        else { super.keyDown(with: event) }
    }
    @objc private func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    @objc private func closeImage() { window?.close() }
}
