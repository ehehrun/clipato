import AppKit
import SwiftUI

struct SystemImagePreview: NSViewRepresentable {
    @Binding var url: URL?
    var urls: [URL] = []

    func makeNSView(context: Context) -> SystemImagePreviewView {
        SystemImagePreviewView()
    }

    func updateNSView(_ view: SystemImagePreviewView, context: Context) {
        let binding = $url
        view.onClose = { closedURL in
            if binding.wrappedValue == closedURL { binding.wrappedValue = nil }
        }
        view.onNavigate = { previous, current in
            if binding.wrappedValue == previous { binding.wrappedValue = current }
        }
        view.request(url, urls: urls)
    }

    static func dismantleNSView(_ view: SystemImagePreviewView, coordinator: ()) {
        view.invalidate()
    }
}

struct ImagePreviewSource: NSViewRepresentable {
    let url: URL
    let image: NSImage?

    func makeNSView(context: Context) -> ImagePreviewSourceView {
        ImagePreviewSourceView()
    }

    func updateNSView(_ view: ImagePreviewSourceView, context: Context) {
        view.url = url
        view.image = image
    }
}

final class ImagePreviewSourceView: NSView {
    var url: URL?
    var image: NSImage?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var transitionGeometry: (screenFrame: NSRect, contentRect: NSRect)? {
        guard let image, image.size.width > 0, image.size.height > 0,
              let window, !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = NSRect(x: bounds.midX - image.size.width * scale / 2,
                            y: bounds.midY - image.size.height * scale / 2,
                            width: image.size.width * scale, height: image.size.height * scale)
        let visible = fitted.intersection(visibleRect)
        guard !visible.isEmpty else { return nil }
        let content = NSRect(x: (visible.minX - fitted.minX) / scale,
                             y: (visible.minY - fitted.minY) / scale,
                             width: visible.width / scale, height: visible.height / scale)
        return (window.convertToScreen(convert(visible, to: nil)), content)
    }
}

final class SystemImagePreviewView: NSView, NSWindowDelegate {
    var onClose: ((URL) -> Void)?
    var onNavigate: ((URL, URL) -> Void)?
    var onError: (Error) -> Void = { _ = NSApp.presentError($0) }
    private(set) var requestedURL: URL?
    private(set) var controlledPanel: ImagePreviewWindow?
    private var previewURL: URL?
    private var urls: [URL] = []
    private var loadTask: Task<Void, Never>?
    private var transitionWindow: NSWindow?
    private var closing = false
    private var dismissedURL: URL?
    private weak var source: ImagePreviewSourceView?
    private weak var sourceWindow: NSWindow?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func request(_ url: URL?, urls: [URL] = []) {
        // Keep an old render from reopening a native dismissal before the
        // binding has acknowledged nil. A later nil → URL is a new request.
        if let url, url == dismissedURL { return }
        dismissedURL = nil
        let items = url.map { urls.isEmpty ? [$0] : urls } ?? []
        guard requestedURL != url || (url != nil && self.urls != items) else { return }
        if url != nil, closing { controlledPanel?.close() }
        requestedURL = url
        guard let url else { closeOwnedPanel(); return }
        guard items.contains(url) else {
            requestedURL = nil
            dismissedURL = url
            closeOwnedPanel()
            notifyClosed(url)
            return
        }
        self.urls = items
        openRequestedImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, requestedURL != nil { openRequestedImage() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow !== window {
            requestedURL = nil
            dismissedURL = nil
            controlledPanel?.close()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func invalidate() {
        onClose = nil
        onNavigate = nil
        onError = { _ in }
        requestedURL = nil
        dismissedURL = nil
        controlledPanel?.close()
    }

    private func openRequestedImage() {
        guard let requestedURL, let window else { return }
        let opening = controlledPanel == nil
        let needsImage = opening || previewURL != requestedURL
        sourceWindow = window
        source = window.contentView.flatMap { Self.findSource(for: requestedURL, in: $0) }
        let panel: ImagePreviewWindow
        if let controlledPanel {
            panel = controlledPanel
        } else {
            let frame = window.screen.map { Self.initialFrame(sourceFrame: window.frame, visibleFrame: $0.visibleFrame) } ?? window.frame
            panel = ImagePreviewWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            panel.setFrame(frame, display: false)
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 360, height: 240)
            panel.animationBehavior = .documentWindow
            panel.tabbingMode = .disallowed
            panel.titlebarAppearsTransparent = true
            panel.contentView = NativeImagePreviewContent(frame: panel.contentRect(forFrameRect: frame))
            panel.delegate = self
            panel.onKey = { [weak self] in self?.handleKey($0) == true }
            let content = panel.contentView as! NativeImagePreviewContent
            content.onError = { [weak self] in self?.onError($0) }
            controlledPanel = panel
        }
        guard needsImage else { return }
        previewURL = requestedURL
        panel.title = requestedURL.lastPathComponent
        stopTransition()
        if panel.isVisible { panel.alphaValue = 1 }
        let content = panel.contentView as! NativeImagePreviewContent
        content.clear()
        loadTask?.cancel()
        loadTask = Task { [weak self, weak panel, weak content] in
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let image = try LibraryStore.readImage(at: requestedURL)
                    try Task.checkCancellation()
                    return image
                }.value
                try Task.checkCancellation()
                guard let self, let panel, let content,
                      self.requestedURL == requestedURL, self.controlledPanel === panel else { return }
                self.loadTask = nil
                content.display(image)
                if !panel.isVisible { self.show(panel) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, let panel,
                      self.requestedURL == requestedURL, self.controlledPanel === panel else { return }
                self.loadTask = nil
                if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
                self.onError(error)
            }
        }
    }

    private func show(_ panel: ImagePreviewWindow) {
        let content = panel.contentView as! NativeImagePreviewContent
        content.layoutSubtreeIfNeeded()
        if let source, source.url == previewURL,
           let sourceWindow = source.window, sourceWindow.isVisible, sourceWindow.alphaValue > 0,
           let image = source.image, let geometry = source.transitionGeometry,
           geometry.contentRect == NSRect(origin: .zero, size: image.size),
           content.imageView.visibleRect == content.imageView.bounds,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.animationBehavior = .none
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            animate(image, from: geometry.screenFrame, to: imageFrame(in: panel), in: panel) { [weak self, weak panel] in
                guard let self, let panel, self.controlledPanel === panel, !self.closing else { return }
                panel.alphaValue = 1
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        content.analyzeIfVisible()
    }

    private func closeOwnedPanel(notifyingBinding: Bool = false) {
        guard let panel = controlledPanel, !closing else { return }
        closing = true
        if notifyingBinding, let previewURL {
            dismissedURL = previewURL
            requestedURL = nil
            onClose?(previewURL)
            guard controlledPanel === panel else { return }
        }
        loadTask?.cancel()
        loadTask = nil
        stopTransition()
        let content = panel.contentView as! NativeImagePreviewContent
        if let source, source.url == previewURL, let sourceWindow, source.window === sourceWindow, sourceWindow.isVisible,
           sourceWindow.alphaValue > 0, let image = source.image,
           let geometry = source.transitionGeometry, panel.isVisible,
           geometry.contentRect == NSRect(origin: .zero, size: image.size),
           content.imageView.visibleRect == content.imageView.bounds,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let frame = imageFrame(in: panel)
            panel.alphaValue = 0
            content.clear()
            animate(image, from: frame, to: geometry.screenFrame, in: panel) { [weak panel] in panel?.close() }
        } else {
            panel.animationBehavior = .documentWindow
            panel.close()
        }
    }

    private func imageFrame(in panel: NSWindow) -> NSRect {
        let content = panel.contentView as! NativeImagePreviewContent
        let image = content.imageView
        let visible = image.visibleRect
        return panel.convertToScreen(image.convert(visible, to: nil))
    }

    private func animate(_ image: NSImage, from: NSRect, to: NSRect, in panel: NSWindow, completion: @escaping () -> Void) {
        let transition = NSPanel(contentRect: from, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        transition.isReleasedWhenClosed = false
        transition.backgroundColor = .clear
        transition.isOpaque = false
        transition.hasShadow = false
        transition.ignoresMouseEvents = true
        transition.animationBehavior = .none
        transition.alphaValue = panel.alphaValue == 0 ? 1 : panel.alphaValue
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: from.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        transition.contentView = imageView
        transitionWindow = transition
        panel.addChildWindow(transition, ordered: .above)
        transition.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            transition.animator().setFrame(to, display: true)
        } completionHandler: { [weak self, weak transition] in
            guard let self, let transition, self.transitionWindow === transition else { return }
            self.stopTransition()
            completion()
        }
    }

    private func stopTransition() {
        guard let transitionWindow else { return }
        transitionWindow.parent?.removeChildWindow(transitionWindow)
        transitionWindow.close()
        self.transitionWindow = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if Self.isCloseKey(event) {
            if !event.isARepeat { closeOwnedPanel(notifyingBinding: true) }
            return true
        }
        guard event.keyCode == 123 || event.keyCode == 124,
              let requestedURL, let index = urls.firstIndex(of: requestedURL) else { return false }
        let current = urls[(index + (event.keyCode == 124 ? 1 : -1) + urls.count) % urls.count]
        if current != requestedURL {
            request(current, urls: urls)
            onNavigate?(requestedURL, current)
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeOwnedPanel(notifyingBinding: true)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? ImagePreviewWindow, controlledPanel === panel else { return }
        let closedURL = requestedURL
        if let closedURL { dismissedURL = closedURL }
        loadTask?.cancel()
        loadTask = nil
        stopTransition()
        (panel.contentView as! NativeImagePreviewContent).clear()
        panel.onKey = nil
        panel.delegate = nil
        controlledPanel = nil
        requestedURL = nil
        previewURL = nil
        urls = []
        source = nil
        sourceWindow = nil
        closing = false
        if let closedURL { onClose?(closedURL) }
    }

    private func notifyClosed(_ closedURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedURL == nil else { return }
            self.onClose?(closedURL)
        }
    }

    static func findSource(for url: URL, in view: NSView) -> ImagePreviewSourceView? {
        if let source = view as? ImagePreviewSourceView, source.url == url,
           source.transitionGeometry != nil { return source }
        for child in view.subviews {
            if let source = findSource(for: url, in: child) { return source }
        }
        return nil
    }

    static func initialFrame(sourceFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let width = min(sourceFrame.width, visibleFrame.width)
        let height = min(sourceFrame.height, visibleFrame.height)
        return NSRect(x: min(max(sourceFrame.minX, visibleFrame.minX), visibleFrame.maxX - width),
                      y: min(max(sourceFrame.minY, visibleFrame.minY), visibleFrame.maxY - height),
                      width: width, height: height)
    }

    static func isCloseKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && (event.keyCode == 49 || event.keyCode == 53)
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}

final class ImagePreviewWindow: NSWindow, NSToolbarDelegate {
    var onKey: ((NSEvent) -> Bool)?
    private static let zoomIdentifier = NSToolbarItem.Identifier("imagePreviewZoom")

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        let toolbar = NSToolbar(identifier: "imagePreview")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.zoomIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.zoomIdentifier else { return nil }
        let labels = [L("缩小"), L("原比例"), L("适合窗口"), L("放大")]
        let symbols = ["minus.magnifyingglass", "1.magnifyingglass", "arrow.up.left.and.arrow.down.right", "plus.magnifyingglass"]
        let controls = NSSegmentedControl(images: zip(symbols, labels).map { NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1)! },
                                          trackingMode: .momentary, target: self, action: #selector(changeZoom(_:)))
        controls.segmentStyle = .separated
        controls.focusRingType = .none
        for index in labels.indices { controls.setToolTip(labels[index], forSegment: index) }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = controls
        return item
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        let content = contentView as! NativeImagePreviewContent
        switch sender.selectedSegment {
        case 0: content.setZoom(content.zoom / 1.25)
        case 1: content.setZoom(1)
        case 2: content.fitImage()
        case 3: content.setZoom(content.zoom * 1.25)
        default: break
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if onKey?(event) == true { return }
        super.sendEvent(event)
    }
}
