import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class SidebarResizeTests: XCTestCase {
    private var nextEventNumber = 1
    private func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 100), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        defer { nextEventNumber += 1 }
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                 context: nil, eventNumber: nextEventNumber, clickCount: 1, pressure: 1)!
    }

    private func hoverEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    private func dispatch(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        let posted = event(type, at: point, in: window)
        NSApp.postEvent(posted, atStart: false)
        let deadline = Date().addingTimeInterval(1)
        while let queued = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
            if queued.type == posted.type && queued.eventNumber == posted.eventNumber &&
                queued.windowNumber == posted.windowNumber { return }
        }
        XCTFail("The application did not dispatch the posted \(type) event before the deadline")
    }

    private func consoleFixture(onResize: @escaping (CGFloat) -> Void,
                                onResizeEnd: @escaping (CGFloat) -> Void)
        -> (window: ConsoleWindow, content: SidebarMouseSink, handle: SidebarResizeHandleView) {
        _ = NSApplication.shared
        let window = ConsoleWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1200, height: 790),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.alphaValue = 0
        window.animationBehavior = .none
        let content = SidebarMouseSink(frame: CGRect(x: 0, y: 0, width: 1200, height: 790))
        let handle = SidebarResizeHandleView(width: 216, onResize: onResize, onResizeEnd: onResizeEnd)
        handle.frame = CGRect(x: 204.5, y: 0, width: 24, height: 790)
        handle.autoresizingMask = [.height]
        content.addSubview(handle)
        window.contentView = content
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
        }
        return (window, content, handle)
    }

    func testConsoleRoutesDividerDragsAtTheTopEdgeAndAcrossTheTitlebar() throws {
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let (window, content, handle) = consoleFixture(onResize: { resized.append($0) },
                                                       onResizeEnd: { committed.append($0) })
        let originalFrame = window.frame
        let handleRect = handle.convert(handle.bounds, to: nil)
        let titlebarTop = content.convert(content.bounds, to: nil).maxY
        XCTAssertGreaterThan(titlebarTop, window.contentLayoutRect.maxY)
        let origins = [CGPoint(x: handleRect.midX, y: titlebarTop - 1),
                       CGPoint(x: handleRect.midX, y: (titlebarTop + window.contentLayoutRect.maxY) / 2),
                       CGPoint(x: handleRect.midX, y: 100)]

        for origin in origins {
            resized.removeAll()
            committed.removeAll()
            window.sendEvent(event(.leftMouseDown, at: origin, in: window))
            window.sendEvent(event(.leftMouseDragged, at: CGPoint(x: origin.x + 60, y: origin.y - 10), in: window))
            window.sendEvent(event(.leftMouseDragged, at: CGPoint(x: origin.x + 90, y: origin.y - 20), in: window))
            XCTAssertTrue(committed.isEmpty)
            window.sendEvent(event(.leftMouseUp, at: CGPoint(x: origin.x + 90, y: origin.y - 20), in: window))

            XCTAssertEqual(resized, [276, 306], "The original divider must keep receiving events after the pointer leaves its strip")
            XCTAssertEqual(committed, [306])
            XCTAssertEqual(window.frame, originalFrame, "Dragging the sidebar divider must never move or resize the console window")
        }
    }

    func testWiderDividerBlocksServerSideWindowDraggingBeforeMouseDown() {
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let (window, content, handle) = consoleFixture(onResize: { resized.append($0) },
                                                       onResizeEnd: { committed.append($0) })
        let originalFrame = window.frame
        let rect = handle.convert(handle.bounds, to: nil)
        let top = content.convert(content.bounds, to: nil).maxY
        let deadline = Date().addingTimeInterval(0.1)
        while let queued = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        for x in [rect.minX + 0.5, rect.midX, rect.maxX - 0.5] {
            for y in [top - 1, top - 14, top - 36, 100] {
                let origin = CGPoint(x: x, y: y)
                handle.mouseEntered(with: hoverEvent(.mouseEntered, at: origin, in: window))
                XCTAssertFalse(window.isMovable, "Native titlebar dragging must be disabled before mouse-down, including both edges of the expanded target")
                resized.removeAll()
                committed.removeAll()
                dispatch(.leftMouseDown, at: origin, in: window)
                handle.mouseExited(with: hoverEvent(.mouseExited, at: origin, in: window))
                XCTAssertFalse(window.isMovable, "Leaving the target during a divider drag must keep the window fixed: \(origin)")
                let destination = CGPoint(x: origin.x + 60, y: origin.y - 20)
                dispatch(.leftMouseDragged, at: destination, in: window)
                dispatch(.leftMouseUp, at: destination, in: window)
                XCTAssertEqual(resized, [276], "Drag origin: \(origin)")
                XCTAssertEqual(committed, [276], "Drag origin: \(origin)")
                XCTAssertEqual(window.frame, originalFrame)
                XCTAssertTrue(window.isMovable, "Ordinary titlebar dragging must be restored after the pointer leaves the target")
            }
        }
    }

    func testDividerRestoresWindowMovabilityWhenDisabledOrDetached() {
        let (window, _, handle) = consoleFixture(onResize: { _ in }, onResizeEnd: { _ in })
        let point = handle.convert(CGPoint(x: handle.bounds.midX, y: 100), to: nil)
        let entered = hoverEvent(.mouseEntered, at: point, in: window)
        let exited = hoverEvent(.mouseExited, at: point, in: window)
        handle.mouseEntered(with: entered)
        handle.mouseDown(with: event(.leftMouseDown, at: point, in: window))
        handle.mouseUp(with: event(.leftMouseUp, at: point, in: window))
        XCTAssertFalse(window.isMovable, "Clicking without leaving the target must retain protection for the next click")
        handle.isEnabled = false
        XCTAssertTrue(window.isMovable)
        handle.mouseEntered(with: entered)
        XCTAssertTrue(window.isMovable, "A disabled divider must not change native window dragging")
        handle.isEnabled = true
        handle.mouseEntered(with: entered)
        XCTAssertFalse(window.isMovable)
        handle.isHidden = true
        XCTAssertTrue(window.isMovable, "Hiding the divider must release native window-drag protection")
        handle.isHidden = false
        handle.mouseEntered(with: entered)
        XCTAssertFalse(window.isMovable)
        handle.removeFromSuperview()
        XCTAssertTrue(window.isMovable)
        XCTAssertNil(window.sidebarResizeHandle)

        window.isMovable = false
        window.contentView!.addSubview(handle)
        handle.mouseEntered(with: entered)
        handle.mouseExited(with: exited)
        XCTAssertFalse(window.isMovable, "A window that was already immovable must retain its original setting")
    }

    func testConsoleDoesNotRouteDragsThroughAnObscuredOrHiddenDivider() {
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let (window, content, handle) = consoleFixture(onResize: { resized.append($0) },
                                                       onResizeEnd: { committed.append($0) })
        let originalFrame = window.frame
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.maxY - 10), to: nil)
        func sendDrag() {
            window.sendEvent(event(.leftMouseDown, at: origin, in: window))
            window.sendEvent(event(.leftMouseDragged, at: CGPoint(x: origin.x + 60, y: origin.y), in: window))
            window.sendEvent(event(.leftMouseUp, at: CGPoint(x: origin.x + 60, y: origin.y), in: window))
        }

        let cover = SidebarMouseSink(frame: handle.frame)
        content.addSubview(cover)
        sendDrag()
        cover.removeFromSuperview()
        handle.isHidden = true
        sendDrag()

        XCTAssertTrue(resized.isEmpty)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(window.frame, originalFrame)
    }

    func testConsoleDoesNotResizeTheSidebarWhileASheetIsAttached() {
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let (window, _, handle) = consoleFixture(onResize: { resized.append($0) },
                                                 onResizeEnd: { committed.append($0) })
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.alphaValue = 0
        sheet.animationBehavior = .none
        sheet.contentView = SidebarMouseSink(frame: CGRect(x: 0, y: 0, width: 300, height: 180))
        window.beginSheet(sheet)
        defer {
            window.endSheet(sheet)
            sheet.orderOut(nil)
            sheet.close()
        }
        XCTAssertTrue(window.attachedSheet === sheet)
        let origin = handle.convert(CGPoint(x: handle.bounds.midX, y: 100), to: nil)
        window.sendEvent(event(.leftMouseDown, at: origin, in: window))
        window.sendEvent(event(.leftMouseDragged, at: CGPoint(x: origin.x + 60, y: origin.y), in: window))
        window.sendEvent(event(.leftMouseUp, at: CGPoint(x: origin.x + 60, y: origin.y), in: window))

        XCTAssertTrue(resized.isEmpty)
        XCTAssertTrue(committed.isEmpty)
    }

    func testConsoleRespectsSwiftUIHitTestingDisabledOnTheDivider() async throws {
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let (window, _, _) = consoleFixture(onResize: { _ in }, onResizeEnd: { _ in })
        let host = NSHostingView(rootView: Color.clear.overlay(alignment: .leading) {
            SidebarResizeHandle(width: 216, onResize: { resized.append($0) },
                                onResizeEnd: { committed.append($0) })
                .frame(width: SidebarResizeHandle.hitWidth)
                .offset(x: 216 - (SidebarResizeHandle.hitWidth - 1) / 2).allowsHitTesting(false)
        })
        host.safeAreaRegions = []
        window.contentView = host
        try await wait("The disabled SwiftUI sidebar handle did not materialize") {
            host.layoutSubtreeIfNeeded()
            return !descendants(SidebarResizeHandleView.self, in: host).isEmpty
        }
        let handle = try XCTUnwrap(descendants(SidebarResizeHandleView.self, in: host).first)
        let container = try XCTUnwrap(host.superview)
        let handleRect = handle.convert(handle.bounds, to: nil)
        let contentTop = host.convert(host.bounds, to: nil).maxY
        for y in [CGFloat(100), (contentTop + window.contentLayoutRect.maxY) / 2, contentTop - 1] {
            let point = CGPoint(x: handleRect.midX, y: y)
            XCTAssertFalse(host.hitTest(container.convert(point, from: nil)) === handle,
                           "SwiftUI must exclude the native divider while the console disables interaction")
        }

        let origin = CGPoint(x: handleRect.midX, y: 100)
        window.sendEvent(event(.leftMouseDown, at: origin, in: window))
        window.sendEvent(event(.leftMouseDragged, at: CGPoint(x: origin.x + 60, y: origin.y), in: window))
        window.sendEvent(event(.leftMouseUp, at: CGPoint(x: origin.x + 60, y: origin.y), in: window))

        XCTAssertTrue(resized.isEmpty)
        XCTAssertTrue(committed.isEmpty)
    }

    func testDragKeepsWindowCoordinateOriginWhenTheHandleMoves() {
        _ = NSApplication.shared
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let view = SidebarResizeHandleView(width: 216, onResize: { resized.append($0) },
                                           onResizeEnd: { committed.append($0) })
        view.frame = CGRect(x: 216, y: 0, width: 8, height: 700)
        view.mouseDown(with: event(.leftMouseDown, x: 220))
        view.mouseDragged(with: event(.leftMouseDragged, x: 290))
        view.width = 286
        view.frame.origin.x = 286
        view.mouseDragged(with: event(.leftMouseDragged, x: 330))
        view.mouseUp(with: event(.leftMouseUp, x: 330))

        XCTAssertEqual(resized, [286, 326])
        XCTAssertEqual(committed, [326], "Moving the divider must not change the original drag coordinate space")
    }

    func testClicksAndRepeatedMouseUpDoNotCommitAnExtraPreferenceWrite() {
        _ = NSApplication.shared
        var resized: [CGFloat] = []
        var committed: [CGFloat] = []
        let view = SidebarResizeHandleView(width: 216, onResize: { resized.append($0) },
                                           onResizeEnd: { committed.append($0) })
        view.mouseDown(with: event(.leftMouseDown, x: 220))
        view.mouseUp(with: event(.leftMouseUp, x: 220))
        XCTAssertTrue(resized.isEmpty)
        XCTAssertTrue(committed.isEmpty)

        view.mouseDown(with: event(.leftMouseDown, x: 220))
        view.mouseDragged(with: event(.leftMouseDragged, x: 300))
        XCTAssertTrue(committed.isEmpty, "Dragging should update layout without persisting every pointer event")
        view.mouseUp(with: event(.leftMouseUp, x: 300))
        view.mouseUp(with: event(.leftMouseUp, x: 300))
        XCTAssertEqual(resized, [296])
        XCTAssertEqual(committed, [296])
    }

    func testReturningFromABoundaryUsesTheOriginalPointerDistance() {
        _ = NSApplication.shared
        var proposed: [CGFloat] = []
        let view = SidebarResizeHandleView(width: 216, onResize: { proposed.append($0) }, onResizeEnd: { _ in })
        view.mouseDown(with: event(.leftMouseDown, x: 220))
        view.mouseDragged(with: event(.leftMouseDragged, x: 1220))
        view.width = 379
        view.mouseDragged(with: event(.leftMouseDragged, x: 250))
        view.width = 246
        view.mouseDragged(with: event(.leftMouseDragged, x: 20))
        view.width = 180
        view.mouseDragged(with: event(.leftMouseDragged, x: 240))
        view.mouseUp(with: event(.leftMouseUp, x: 240))

        XCTAssertEqual(proposed, [1216, 246, 16, 236],
                       "The parent clamps layout; that clamped width must not become the next pointer origin")
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var matches: [T] = []
        if let match = view as? T { matches.append(match) }
        for child in view.subviews { matches.append(contentsOf: descendants(type, in: child)) }
        return matches
    }

    private func drainEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            drainEvents()
            try await Task.sleep(for: .milliseconds(20))
        }
        drainEvents()
        guard condition() else {
            XCTFail(message)
            throw NSError(domain: "SidebarResizeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func render(_ view: NSView, named name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/clipato-sidebar-\(name).png"))
    }

    func testNativeConsoleDragPreservesProcessingStateAndPersistsOnlyThePreferredWidth() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_SIDEBAR_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_SIDEBAR_UI_QA=1 to opt into a transparent native console fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.Sidebar.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaultsName = "Clipato.Sidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(216, forKey: "sidebarWidth")
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
        let library = try XCTUnwrap(model.library)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try library.addImage(XCTUnwrap(context.makeImage()), source: "截图")
        model.prepareImageExport([image], mode: .files, tool: .compress)
        let appearance = AppearanceSettings.shared
        let originalFontSize = appearance.consoleFontSize
        let language = LanguageSettings.shared
        let originalLanguage = language.language
        appearance.setConsoleFontSize(.normal)
        language.setLanguage(.japanese)

        let host = NSHostingView(rootView: MainView(model: model).defaultAppStorage(defaults))
        host.safeAreaRegions = []
        let window = ConsoleWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1020, height: 700),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            model.dismissImageProcessing()
            window.contentView = nil
            window.close()
            appearance.setConsoleFontSize(originalFontSize)
            language.setLanguage(originalLanguage)
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: defaultsName)
            try FileManager.default.removeItem(at: directory)
        }

        func fields() -> [NSTextField] {
            host.layoutSubtreeIfNeeded()
            return descendants(NSTextField.self, in: host).filter(\.isEditable)
        }
        try await wait("The native sidebar handle and processing target input did not materialize") {
            fields().contains { $0.stringValue == "500" } && !descendants(SidebarResizeHandleView.self, in: host).isEmpty
        }
        let handle = try XCTUnwrap(descendants(SidebarResizeHandleView.self, in: host).first)
        let target = try XCTUnwrap(fields().first { $0.stringValue == "500" })
        target.stringValue = "640"
        target.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: target))
        func sidebarWidth() -> CGFloat {
            host.layoutSubtreeIfNeeded()
            return handle.convert(handle.bounds, to: host).minX + (SidebarResizeHandle.hitWidth - 1) / 2
        }
        func startDrag() -> CGFloat {
            let x = handle.convert(CGPoint(x: handle.bounds.minX + 1, y: handle.bounds.midY), to: nil).x
            let origin = CGPoint(x: x, y: host.bounds.maxY - 1)
            handle.mouseEntered(with: hoverEvent(.mouseEntered, at: origin, in: window))
            XCTAssertFalse(window.isMovable)
            dispatch(.leftMouseDown, at: origin, in: window)
            return x
        }
        func finishDrag(from x: CGFloat, delta: CGFloat) {
            dispatch(.leftMouseDragged, at: CGPoint(x: x + delta, y: host.bounds.maxY - 1), in: window)
            dispatch(.leftMouseUp, at: CGPoint(x: x + delta, y: host.bounds.maxY - 1), in: window)
        }
        XCTAssertEqual(sidebarWidth(), 216, accuracy: 0.5)
        let initialX = startDrag()
        dispatch(.leftMouseDragged, at: CGPoint(x: initialX + 100, y: host.bounds.maxY - 1), in: window)
        try await wait("Dragging did not resize the sidebar") { abs(sidebarWidth() - 316) < 0.5 }
        XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), 216)
        XCTAssertTrue(fields().contains { $0 === target })
        XCTAssertEqual(target.stringValue, "640")
        dispatch(.leftMouseUp, at: CGPoint(x: initialX + 100, y: host.bounds.maxY - 1), in: window)
        try await wait("Mouse-up did not persist the preferred width") { abs(defaults.double(forKey: "sidebarWidth") - 316) < 0.5 }

        finishDrag(from: startDrag(), delta: 1000)
        try await wait("The narrow console must preserve 640 points for its main content") { abs(sidebarWidth() - 379) < 0.5 }
        XCTAssertGreaterThanOrEqual(host.bounds.width - sidebarWidth() - 1, 640 - 0.5)
        try render(host, named: "japanese-light")

        window.setContentSize(CGSize(width: 1250, height: 700))
        try await wait("The fixture window did not resize") { abs(host.bounds.width - 1250) < 0.5 }
        finishDrag(from: startDrag(), delta: 1000)
        try await wait("A wider console should allow the full preferred width") { abs(sidebarWidth() - 420) < 0.5 }
        XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), 420, accuracy: 0.5)
        window.setContentSize(CGSize(width: 1020, height: 700))
        try await wait("Shrinking should clamp only the visible sidebar") { abs(sidebarWidth() - 379) < 0.5 }
        XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), 420, accuracy: 0.5)
        window.setContentSize(CGSize(width: 1250, height: 700))
        try await wait("Growing should restore the user's preferred width") { abs(sidebarWidth() - 420) < 0.5 }

        appearance.setConsoleFontSize(.largest)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(CGSize(width: 1020, height: 700))
        try await wait("The largest font must retain the main-content width limit") { abs(sidebarWidth() - 379) < 0.5 }
        try render(host, named: "japanese-dark-20px")
        finishDrag(from: startDrag(), delta: -2000)
        try await wait("The largest font must enforce the scaled sidebar minimum") { abs(sidebarWidth() - 180 * ConsoleFontSize.largest.scale) < 0.5 }
        XCTAssertEqual(defaults.double(forKey: "sidebarWidth"), 180, accuracy: 0.5)
        XCTAssertTrue(fields().contains { $0 === target }, "Resizing must retain the native processing control")
        XCTAssertEqual(target.stringValue, "640")
        XCTAssertEqual(model.imageProcessingRoute, .processing(.compress))
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(window.alphaValue, 0)
    }
}

@MainActor
private final class SidebarMouseSink: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}
