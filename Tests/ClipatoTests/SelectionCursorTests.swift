import AppKit
import XCTest
@testable import Clipato

@MainActor
final class SelectionCursorTests: XCTestCase {
    func testTrackingFollowsTheKeyPanelWithoutRequiringAppActivation() throws {
        try withSelection { view, window in
            view.updateTrackingAreas()
            let area = try XCTUnwrap(view.trackingAreas.first { ($0.owner as AnyObject?) === view })
            XCTAssertTrue(area.options.contains(.activeInKeyWindow))
            XCTAssertTrue(area.options.contains(.cursorUpdate))
            XCTAssertTrue(area.options.contains(.mouseMoved))
            XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
            XCTAssertFalse(area.options.contains(.activeInActiveApp))
            XCTAssertFalse(area.options.contains(.activeAlways), "AppKit does not support cursorUpdate with activeAlways")
            XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(window.canBecomeKey)
        }
    }

    func testCursorUpdateAndEntryReassertCrosshairAfterAnotherCursorWasSet() throws {
        for mode in [SelectionView.Mode.screenshot(allowsDestinationActions: true), .recording, .fixedCapture] {
            try withSelection(mode: mode) { view, _ in
                let point = CGPoint(x: 180, y: 140)
                NSCursor.arrow.set()
                view.cursorUpdate(with: try boundary(.cursorUpdate, at: point, in: view))
                XCTAssertTrue(NSCursor.current === NSCursor.crosshair)

                NSCursor.arrow.set()
                view.mouseEntered(with: try boundary(.mouseEntered, at: point, in: view))
                XCTAssertTrue(NSCursor.current === NSCursor.crosshair)

                view.mouseExited(with: try boundary(.mouseExited, at: CGPoint(x: -1, y: 140), in: view))
                NSCursor.arrow.set()
                view.mouseEntered(with: try boundary(.mouseEntered, at: point, in: view))
                XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            }
        }
    }

    func testContinuousHoverKeepsCrosshairAndRepairsAnAppKitCursorReset() throws {
        try withSelection { view, _ in
            let point = CGPoint(x: 180, y: 140)
            view.cursorUpdate(with: try boundary(.cursorUpdate, at: point, in: view))
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)

            // AppKit can reset the process cursor while a view's intended cursor stays unchanged.
            NSCursor.arrow.set()
            for offset in 1...16 {
                view.mouseMoved(with: try mouse(.mouseMoved, at: CGPoint(x: point.x + CGFloat(offset), y: point.y), in: view))
                XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            }
            NSCursor.arrow.set()
            view.cursorUpdate(with: try boundary(.cursorUpdate, at: point, in: view))
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
        }
    }

    func testLeavingThePanelInvalidatesItsCursorCache() throws {
        try withSelection { view, _ in
            let point = CGPoint(x: 180, y: 140)
            view.mouseMoved(with: try mouse(.mouseMoved, at: point, in: view))
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            view.mouseExited(with: try boundary(.mouseExited, at: CGPoint(x: -1, y: 140), in: view))
            NSCursor.arrow.set()
            view.mouseMoved(with: try mouse(.mouseMoved, at: point, in: view))
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
        }
    }

    func testSelectionMovementHandlesToolbarAndTextKeepTheirNativeCursors() throws {
        try withSelection { view, _ in
            let start = CGPoint(x: 80, y: 60), end = CGPoint(x: 720, y: 440)
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: view))
            view.mouseUp(with: try mouse(.leftMouseUp, at: end, in: view))
            XCTAssertEqual(view.selection, CGRect(x: 80, y: 60, width: 640, height: 380))

            let middle = CGPoint(x: 400, y: 250)
            try assertCursor(.openHand, at: middle, in: view)
            view.mouseDown(with: try mouse(.leftMouseDown, at: middle, in: view))
            try assertCursor(.closedHand, at: middle, in: view)
            view.mouseUp(with: try mouse(.leftMouseUp, at: middle, in: view))
            try assertCursor(.openHand, at: middle, in: view)
            try assertCursor(.resizeUpDown, at: CGPoint(x: 400, y: 60), in: view)
            try assertCursor(.resizeLeftRight, at: CGPoint(x: 80, y: 250), in: view)
            try assertCursor(.crosshair, at: CGPoint(x: 30, y: 30), in: view)

            let toolbar = try XCTUnwrap(find("selection-toolbar", in: view))
            XCTAssertFalse(toolbar.isHidden)
            try assertCursor(.arrow, at: CGPoint(x: toolbar.frame.midX, y: toolbar.frame.midY), in: view)

            let textButton = try XCTUnwrap(find("text", in: view) as? NSButton)
            XCTAssertTrue(textButton.sendAction(textButton.action, to: textButton.target))
            let textPoint = CGPoint(x: 140, y: 120)
            view.mouseDown(with: try mouse(.leftMouseDown, at: textPoint, in: view))
            let editor = try XCTUnwrap(find("annotation-text-input", in: view) as? AnnotationTextEditor)
            try assertCursor(.iBeam, at: CGPoint(x: editor.frame.minX + 4, y: editor.frame.midY), in: view)
            editor.finish(commit: false)
        }
    }

    func testNativeNonactivatingPanelBecomesKeyAndInstallsItsInitialCursor() throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_CURSOR_NATIVE_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_CURSOR_NATIVE_QA=1 to show a generated selection panel briefly without capturing the screen")
        }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
        defer { NSApp.setActivationPolicy(previousPolicy) }
        try withSelection { view, window in
            let previousKeyWindow = NSApp.keyWindow
            let wasActive = NSApp.isActive
            let previousFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let pointer = NSEvent.mouseLocation
            window.setFrameOrigin(CGPoint(x: pointer.x - 400, y: pointer.y - 300))
            window.alphaValue = 1
            defer {
                window.orderOut(nil)
                previousKeyWindow?.makeKey()
            }
            NSCursor.arrow.set()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            view.updateCursor(force: true)
            let deadline = Date(timeIntervalSinceNow: 0.08)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
            XCTAssertTrue(window.isKeyWindow)
            // The XCTest host can update its local active flag when its event loop starts.
            // The frontmost process is the observable check that this panel did not activate another app.
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousFrontmost)
            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            print("[SelectionCursor] visible generated panel key=\(window.isKeyWindow) appActiveBefore=\(wasActive) appActiveAfter=\(NSApp.isActive) localCrosshair=\(NSCursor.current === NSCursor.crosshair); WindowServer cursor is not sampled by this test")
        }
    }

    private func withSelection(mode: SelectionView.Mode = .screenshot(allowsDestinationActions: true),
                               _ operation: (SelectionView, SelectionWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let pasteboard = NSPasteboard.withUniqueName()
        defer { originalCursor.set(); pasteboard.releaseGlobally() }
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let view = SelectionView(image: try XCTUnwrap(context.makeImage()), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                 mode: mode, allowsTagSelection: false, colorFormat: .hex,
                                 colorPasteboard: pasteboard, showsFullScreenCrosshair: false)
        let window = SelectionWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600))
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        try operation(view, window)
        XCTAssertFalse(window.isVisible, "Cursor unit fixtures must not order a window onscreen")
    }

    private func assertCursor(_ cursor: NSCursor, at point: CGPoint, in view: SelectionView,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        view.cursorUpdate(with: try boundary(.cursorUpdate, at: point, in: view))
        // This checks AppKit's local cursor state; it does not sample the WindowServer cursor.
        XCTAssertTrue(NSCursor.current === cursor, file: file, line: line)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func boundary(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                           windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil))
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let match = find(identifier, in: child) { return match }
        }
        return nil
    }
}
