import AppKit
import SwiftUI
import VisionKit
import XCTest
@testable import Clipato

@MainActor
private final class NativePreviewBindingState: ObservableObject {
    @Published var url: URL?
    @Published var urls: [URL]

    init(urls: [URL]) { self.urls = urls }
}

private struct NativePreviewBindingHost: View {
    @ObservedObject var state: NativePreviewBindingState

    var body: some View {
        Color.clear.background(SystemImagePreview(url: $state.url, urls: state.urls))
    }
}

@MainActor
final class NativeImagePreviewIntegrationTests: XCTestCase {
    private func drainApplicationEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private func wait(_ message: String, timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            drainApplicationEvents()
            try await Task.sleep(for: .milliseconds(20))
        }
        drainApplicationEvents()
        guard condition() else {
            XCTFail(message)
            throw NSError(domain: "NativeImagePreviewIntegrationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func fixture(_ text: String, size: NSSize, name: String, directory: URL) throws -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 80, weight: .bold),
                                                     .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 80, y: size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        let url = directory.appendingPathComponent(name + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func key(_ code: UInt16, character: String, window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }

    func testSwiftUIBindingReplayDoesNotReopenAClosedPreview() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_NATIVE_PREVIEW_QA"] == "1" else {
            throw XCTSkip("Run scripts/qa-system-image-preview.sh --run-native to opt into transparent native windows")
        }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipato-preview-binding-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alpha = try fixture("CLOSE ALPHA", size: NSSize(width: 1600, height: 900), name: "Close-Alpha", directory: directory)
        let beta = try fixture("CLOSE BETA", size: NSSize(width: 1400, height: 1000), name: "Close-Beta", directory: directory)
        let state = NativePreviewBindingState(urls: [alpha, beta])
        let hosting = NSHostingView(rootView: NativePreviewBindingHost(state: state))
        let sourceWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 620),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false
        sourceWindow.alphaValue = 0
        sourceWindow.animationBehavior = .none
        sourceWindow.contentView = hosting
        var observations: [NSKeyValueObservation] = []
        var locked: Set<ObjectIdentifier> = []
        var ownedWindows: [NSWindow] = [sourceWindow]
        func lockTransparency(_ window: NSWindow) {
            window.alphaValue = 0
            window.animationBehavior = .none
            if locked.insert(ObjectIdentifier(window)).inserted {
                observations.append(window.observe(\.alphaValue, options: [.new]) { observed, _ in
                    if observed.alphaValue != 0 { observed.alphaValue = 0 }
                })
                if window !== sourceWindow { ownedWindows.append(window) }
            }
        }
        lockTransparency(sourceWindow)
        let keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { notification in
            MainActor.assumeIsolated {
                if let window = notification.object as? ImagePreviewWindow { lockTransparency(window) }
            }
        }
        func previewHost(in view: NSView) -> SystemImagePreviewView? {
            if let preview = view as? SystemImagePreviewView { return preview }
            for child in view.subviews {
                if let preview = previewHost(in: child) { return preview }
            }
            return nil
        }
        addTeardownBlock { @MainActor in
            previewHost(in: hosting)?.invalidate()
            ownedWindows.forEach { $0.close() }
            NotificationCenter.default.removeObserver(keyObserver)
            observations.forEach { $0.invalidate() }
            try FileManager.default.removeItem(at: directory)
            if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                XCTAssertTrue(previousApplication.activate(options: []))
                try await self.wait("The previous foreground application was not restored") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier
                }
            }
        }

        sourceWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("The SwiftUI source window did not enter the active responder chain") {
            hosting.layoutSubtreeIfNeeded()
            return NSApp.isActive && NSApp.keyWindow === sourceWindow && previewHost(in: hosting) != nil
        }
        let preview = try XCTUnwrap(previewHost(in: hosting))
        var errors: [Error] = []
        preview.onError = { errors.append($0) }
        func opened(_ url: URL) -> Bool {
            hosting.layoutSubtreeIfNeeded()
            if let panel = preview.controlledPanel { lockTransparency(panel) }
            return preview.requestedURL == url && preview.controlledPanel?.isVisible == true
                && (preview.controlledPanel?.contentView as? NativeImagePreviewContent)?.imageView.image != nil
        }
        func staysClosed(_ stage: String) async throws {
            XCTAssertNil(preview.controlledPanel, stage + ": replay of the host's current binding must not allocate a new window")
            try await self.wait(stage + ": preview binding did not clear") { state.url == nil && preview.controlledPanel == nil }
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            self.drainApplicationEvents()
            XCTAssertNil(preview.requestedURL, stage)
            XCTAssertNil(preview.controlledPanel, stage)
        }

        state.url = alpha
        try await wait("The real SwiftUI representable did not open its bound image") { opened(alpha) }
        let first = try XCTUnwrap(preview.controlledPanel)
        first.performClose(nil)
        preview.request(state.url, urls: state.urls)
        try await staysClosed("native red close followed by a same-value SwiftUI update")

        state.urls.reverse()
        hosting.layoutSubtreeIfNeeded()
        preview.request(state.url, urls: state.urls)
        try await staysClosed("sorted-list update after native close")

        preview.request(state.url, urls: state.urls)
        state.url = alpha
        try await wait("An explicit same-image request did not reopen after the close binding cleared") { opened(alpha) }
        XCTAssertTrue(preview.controlledPanel !== first, "A deliberate later request may create a new preview")
        let second = try XCTUnwrap(preview.controlledPanel)
        second.performClose(nil)
        preview.request(state.url, urls: state.urls)
        try await staysClosed("second native close")

        state.urls = [alpha, beta]
        state.url = alpha
        try await wait("The preview did not reopen before rapid navigation and close") { opened(alpha) }
        let navigating = try XCTUnwrap(preview.controlledPanel)
        key(124, character: String(UnicodeScalar(NSRightArrowFunctionKey)!), window: navigating)
        XCTAssertEqual(preview.requestedURL, beta, "The key event must actually navigate before closing")
        navigating.performClose(nil)
        preview.request(state.url, urls: state.urls)
        try await staysClosed("close immediately after navigation with pending binding updates")
        XCTAssertTrue(errors.isEmpty, "Unexpected native preview errors: \(errors)")
        XCTAssertTrue(ownedWindows.allSatisfy { $0.alphaValue == 0 })
        print("PASS actual SwiftUI binding: native close and queued same-value updates stay closed; a deliberate same-image reopen still works; rapid navigation cannot revive a closed preview")
    }

    func testNativeWindowOrderingFixedZoomLiveTextAndLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_NATIVE_PREVIEW_QA"] == "1" else {
            throw XCTSkip("Run scripts/qa-system-image-preview.sh --run-native to opt into transparent native windows and real Live Text analysis")
        }
        try XCTSkipUnless(ImageAnalyzer.isSupported, "This Mac does not support Live Text image analysis")
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipato-native-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alpha = try fixture("CLIPATO ALPHA 12345", size: NSSize(width: 2400, height: 1400), name: "Alpha", directory: directory)
        let beta = try fixture("CLIPATO BETA 67890", size: NSSize(width: 1400, height: 2200), name: "Beta", directory: directory)
        let gamma = try fixture("CLIPATO GAMMA 24680", size: NSSize(width: 3200, height: 900), name: "Gamma", directory: directory)
        let expectedPixels = [alpha: NSSize(width: 2400, height: 1400), beta: NSSize(width: 1400, height: 2200),
                              gamma: NSSize(width: 3200, height: 900)]
        let sourceWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 620),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sourceWindow.isReleasedWhenClosed = false
        sourceWindow.alphaValue = 0
        sourceWindow.animationBehavior = .none
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        sourceWindow.contentView = container
        let source = ImagePreviewSourceView(frame: NSRect(x: 30, y: 40, width: 260, height: 180))
        source.url = alpha
        source.image = NSImage(contentsOf: alpha)
        container.addSubview(source)
        let view = SystemImagePreviewView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        container.addSubview(view)

        var observations: [NSKeyValueObservation] = []
        var locked: Set<ObjectIdentifier> = []
        var ownedWindows: [NSWindow] = [sourceWindow]
        func lockTransparency(_ window: NSWindow) {
            window.alphaValue = 0
            window.animationBehavior = .none
            if locked.insert(ObjectIdentifier(window)).inserted {
                observations.append(window.observe(\.alphaValue, options: [.new]) { observed, _ in
                    if observed.alphaValue != 0 { observed.alphaValue = 0 }
                })
                if window !== sourceWindow { ownedWindows.append(window) }
            }
        }
        lockTransparency(sourceWindow)
        let keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { notification in
            MainActor.assumeIsolated {
                if let window = notification.object as? ImagePreviewWindow { lockTransparency(window) }
            }
        }
        addTeardownBlock { @MainActor in
            view.invalidate()
            ownedWindows.forEach { $0.close() }
            NotificationCenter.default.removeObserver(keyObserver)
            observations.forEach { $0.invalidate() }
            try FileManager.default.removeItem(at: directory)
            if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                XCTAssertTrue(previousApplication.activate(options: []), "The previous application must accept foreground restoration")
                try await self.wait("The previous foreground application was not restored") {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier
                }
            }
        }

        var order = [gamma, alpha, beta]
        var boundURL: URL? = alpha
        var navigation: [(URL, URL)] = []
        var closed: [URL] = []
        var errors: [Error] = []
        view.onNavigate = { previous, current in
            navigation.append((previous, current))
            if boundURL == previous {
                boundURL = current
                view.request(boundURL, urls: order)
            }
        }
        view.onClose = { url in
            closed.append(url)
            if boundURL == url { boundURL = nil }
        }
        view.onError = { errors.append($0) }
        func activateSource() async throws {
            sourceWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await self.wait("Source window did not enter the actual active key/main responder chain") {
                NSApp.isActive && NSApp.keyWindow === sourceWindow && NSApp.mainWindow === sourceWindow
            }
        }
        func opened(_ url: URL) -> Bool {
            if let panel = view.controlledPanel { lockTransparency(panel) }
            guard view.requestedURL == url, let panel = view.controlledPanel, panel.isVisible,
                  let content = panel.contentView as? NativeImagePreviewContent,
                  let representation = content.imageView.image?.representations.first else { return false }
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh) == expectedPixels[url]
        }
        func content() throws -> NativeImagePreviewContent {
            try XCTUnwrap(view.controlledPanel?.contentView as? NativeImagePreviewContent)
        }
        func closeIsReleased(_ previousContent: NativeImagePreviewContent) {
            XCTAssertNil(view.requestedURL)
            XCTAssertNil(view.controlledPanel)
            XCTAssertNil(previousContent.imageView.image)
            XCTAssertNil(previousContent.overlay.analysis)
        }

        try await activateSource()
        view.request(boundURL, urls: order)
        try await wait("The initial sorted image did not open") { opened(alpha) }
        let firstWindow = try XCTUnwrap(view.controlledPanel)
        let firstContent = try content()
        XCTAssertTrue(firstWindow.title.contains("Alpha"))
        XCTAssertEqual(firstContent.imageView.image?.size, NSSize(width: 2400 / firstWindow.backingScaleFactor,
                                                                 height: 1400 / firstWindow.backingScaleFactor))
        XCTAssertTrue(navigation.isEmpty, "Opening the requested middle item must not navigate")
        XCTAssertEqual(firstWindow.alphaValue, 0)
        XCTAssertLessThanOrEqual(firstContent.zoom, 1, "Initial fit must not upscale the image")
        XCTAssertLessThanOrEqual(firstContent.imageView.frame.width * firstContent.zoom,
                                 firstContent.scrollView.contentView.frame.width + 1)
        XCTAssertLessThanOrEqual(firstContent.imageView.frame.height * firstContent.zoom,
                                 firstContent.scrollView.contentView.frame.height + 1)
        print("Native initial preview: requested=Alpha.png, actual image=\(String(describing: firstContent.imageView.image?.size)), title=\(firstWindow.title)")

        key(124, character: String(UnicodeScalar(NSRightArrowFunctionKey)!), window: firstWindow)
        try await wait("Right arrow did not follow current list order") { boundURL == beta && opened(beta) }
        let betaContent = try content()
        XCTAssertTrue(view.controlledPanel?.title.contains("Beta") == true)
        let betaWindow = try XCTUnwrap(view.controlledPanel)
        XCTAssertEqual(betaContent.imageView.image?.size, NSSize(width: 1400 / betaWindow.backingScaleFactor,
                                                                height: 2200 / betaWindow.backingScaleFactor))
        key(123, character: String(UnicodeScalar(NSLeftArrowFunctionKey)!), window: try XCTUnwrap(view.controlledPanel))
        try await wait("Left arrow did not return to the previous sorted image") { boundURL == alpha && opened(alpha) }
        XCTAssertEqual(navigation.map { $0.0 }, [alpha, beta])
        XCTAssertEqual(navigation.map { $0.1 }, [beta, alpha])

        let panel = try XCTUnwrap(view.controlledPanel)
        let imageContent = try content()
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 560, height: 420)), display: false)
        imageContent.layoutSubtreeIfNeeded()
        let smallViewport = imageContent.scrollView.contentView.bounds.size
        let imageSize = imageContent.imageView.frame.size
        let initialZoom = imageContent.zoom
        let initialMagnification = imageContent.scrollView.magnification
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 1000, height: 800)), display: false)
        imageContent.layoutSubtreeIfNeeded()
        let largeViewport = imageContent.scrollView.contentView.bounds.size
        XCTAssertGreaterThan(largeViewport.width, smallViewport.width)
        XCTAssertGreaterThan(largeViewport.height, smallViewport.height)
        XCTAssertEqual(imageContent.imageView.frame.size, imageSize, "Growing the viewport must preserve actual image geometry")
        XCTAssertEqual(imageContent.zoom, initialZoom, accuracy: 0.000001)
        XCTAssertEqual(imageContent.scrollView.magnification, initialMagnification, accuracy: 0.000001)

        let manualZoom: CGFloat = 1.25
        XCTAssertNotEqual(initialZoom, manualZoom, "The test must actually change the initial fit zoom")
        imageContent.setZoom(manualZoom)
        XCTAssertEqual(imageContent.zoom, manualZoom, accuracy: 0.000001)
        let manuallyZoomedSize = imageContent.imageView.frame.size
        let manuallyZoomedMagnification = imageContent.scrollView.magnification
        order = [beta, gamma, alpha]
        view.request(boundURL, urls: order)
        XCTAssertTrue(view.controlledPanel === panel)
        XCTAssertEqual(view.requestedURL, alpha)
        XCTAssertEqual(imageContent.zoom, manualZoom, accuracy: 0.000001, "Sorting must retain the current image and manual zoom")
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: 650, height: 500)), display: false)
        imageContent.layoutSubtreeIfNeeded()
        XCTAssertEqual(imageContent.imageView.frame.size, manuallyZoomedSize)
        XCTAssertEqual(imageContent.scrollView.magnification, manuallyZoomedMagnification, accuracy: 0.000001)
        XCTAssertEqual(imageContent.zoom, manualZoom, accuracy: 0.000001)
        print("Native resize: viewport \(smallViewport) -> \(largeViewport), image frame unchanged \(imageSize), initial zoom \(initialZoom), manual zoom retained \(manualZoom)")

        try await wait("Real Live Text did not recognize the fixture", timeout: 20) {
            imageContent.overlay.text.range(of: "ALPHA", options: .caseInsensitive) != nil
        }
        XCTAssertTrue(imageContent.overlay.trackingImageView === imageContent.imageView)
        let recognized = imageContent.overlay.text
        let alphaRange = try XCTUnwrap(recognized.range(of: "ALPHA", options: .caseInsensitive))
        imageContent.overlay.selectedRanges = [alphaRange]
        try await wait("Live Text selection did not update the selected text") { imageContent.overlay.selectedText.uppercased() == "ALPHA" }
        XCTAssertEqual(imageContent.overlay.selectedText.uppercased(), "ALPHA")
        print("Native Live Text recognized \(recognized.debugDescription); selected text \(imageContent.overlay.selectedText.debugDescription)")

        key(53, character: "\u{1b}", window: panel)
        try await wait("Escape did not close and clear the binding") { boundURL == nil && view.controlledPanel == nil }
        closeIsReleased(imageContent)
        XCTAssertEqual(closed, [alpha])

        try await activateSource()
        boundURL = beta
        view.request(boundURL, urls: order)
        try await wait("The preview did not reopen after Escape") { opened(beta) }
        let spaceContent = try content()
        key(49, character: " ", window: try XCTUnwrap(view.controlledPanel))
        try await wait("Space did not close and clear the binding") { boundURL == nil && view.controlledPanel == nil }
        closeIsReleased(spaceContent)
        XCTAssertEqual(closed, [alpha, beta])

        try await activateSource()
        boundURL = gamma
        view.request(boundURL, urls: order)
        try await wait("The preview did not reopen before explicit close") { opened(gamma) }
        let explicitContent = try content()
        boundURL = nil
        view.request(nil, urls: order)
        try await wait("An explicit nil request did not release the preview") { view.controlledPanel == nil }
        closeIsReleased(explicitContent)

        try await activateSource()
        boundURL = alpha
        view.request(boundURL, urls: order)
        try await wait("The preview did not reopen before detach") { opened(alpha) }
        let detachedContent = try content()
        view.removeFromSuperview()
        try await wait("Detaching the preview host did not close its window") { view.controlledPanel == nil }
        closeIsReleased(detachedContent)
        XCTAssertNil(view.window)

        container.addSubview(view)
        try await activateSource()
        boundURL = gamma
        view.request(boundURL, urls: order)
        try await wait("The preview did not reopen after reattaching its host") { opened(gamma) }
        let replacementContent = try content()
        boundURL = alpha
        view.request(boundURL, urls: order)
        boundURL = beta
        view.request(boundURL, urls: order)
        try await wait("The latest image did not replace cancelled analysis", timeout: 20) {
            opened(beta) && replacementContent.overlay.text.range(of: "BETA", options: .caseInsensitive) != nil
        }
        XCTAssertNil(replacementContent.overlay.text.range(of: "ALPHA", options: .caseInsensitive))
        XCTAssertNil(replacementContent.overlay.text.range(of: "GAMMA", options: .caseInsensitive))
        XCTAssertNil(detachedContent.overlay.analysis, "An analysis cancelled by detaching must not publish after later work completes")
        XCTAssertNil(explicitContent.overlay.analysis, "An analysis cancelled by closing must not publish after later work completes")
        XCTAssertNil(spaceContent.overlay.analysis)
        XCTAssertNil(imageContent.overlay.analysis)
        let dismissedWindow = try XCTUnwrap(view.controlledPanel)
        dismissedWindow.performClose(nil)
        XCTAssertNil(boundURL, "Native close must clear the active binding")
        XCTAssertNil(view.controlledPanel)
        view.request(beta, urls: order)
        XCTAssertNil(view.controlledPanel, "An old render replay before the nil acknowledgement must not reopen the dismissed image")
        XCTAssertNil(view.requestedURL)
        view.request(nil, urls: order)
        try await activateSource()
        boundURL = beta
        view.request(boundURL, urls: order)
        try await wait("An acknowledged close must allow a deliberate same-image reopen") { opened(beta) }
        let reopenedWindow = try XCTUnwrap(view.controlledPanel)
        XCTAssertTrue(reopenedWindow !== dismissedWindow)
        reopenedWindow.performClose(nil)
        XCTAssertNil(boundURL)
        XCTAssertNil(view.controlledPanel)
        XCTAssertTrue(errors.isEmpty, "Native preview must report actual loading/analysis failures: \(errors)")
        XCTAssertTrue(ownedWindows.allSatisfy { $0.alphaValue == 0 })
        print("PASS native image preview: list order, fixed zoom during resize, manual zoom, real Live Text selection, close/reopen/detach, and cancellation using production code")
    }
}
