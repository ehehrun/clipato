import AppKit
import XCTest
@testable import Clipato

@MainActor
final class SelectionFocusTests: XCTestCase {
    private let modes: [SelectionView.Mode] = [
        .screenshot(allowsDestinationActions: true), .recording, .gifRecording, .fixedCapture,
    ]

    func testPointerReentryRemainsTrackedWithoutAKeyWindowAndDoesNotDuplicateTrackingAreas() throws {
        for mode in modes {
            let view = try makeView(mode: mode)
            view.updateTrackingAreas()
            view.updateTrackingAreas()
            let areas = view.trackingAreas.filter { ($0.owner as AnyObject?) === view }
            XCTAssertEqual(areas.count, 2)
            let hover = try XCTUnwrap(areas.first { $0.options.contains(.activeAlways) })
            XCTAssertTrue(hover.options.contains(.mouseEnteredAndExited))
            XCTAssertTrue(hover.options.contains(.mouseMoved))
            XCTAssertTrue(hover.options.contains(.inVisibleRect))
            XCTAssertFalse(hover.options.contains(.cursorUpdate))
            XCTAssertFalse(hover.options.contains(.activeInKeyWindow))
            let cursor = try XCTUnwrap(areas.first { $0.options.contains(.cursorUpdate) })
            XCTAssertTrue(cursor.options.contains(.activeInKeyWindow))
            XCTAssertTrue(cursor.options.contains(.inVisibleRect))
            XCTAssertFalse(cursor.options.contains(.activeAlways))
            XCTAssertFalse(cursor.options.contains(.mouseMoved))
            XCTAssertFalse(cursor.options.contains(.mouseEnteredAndExited))
            XCTAssertNil(view.window)
        }
    }

    func testReentryBeforeDrawingReinstallsCrosshairWithoutSelectingOrCompleting() throws {
        for mode in modes {
            let view = try makeView(mode: mode)
            var finishes = 0
            view.onFinish = { _, _ in finishes += 1 }
            let point = CGPoint(x: 180, y: 140)
            view.mouseMoved(with: try mouse(.mouseMoved, at: point, in: view))
            view.mouseExited(with: try boundary(.mouseExited, at: CGPoint(x: -1, y: 140), in: view))
            NSCursor.arrow.set()

            view.mouseEntered(with: try boundary(.mouseEntered, at: point, in: view))

            XCTAssertTrue(NSCursor.current === NSCursor.crosshair)
            XCTAssertTrue(view.selection.isEmpty)
            XCTAssertTrue(view.annotations.isEmpty)
            XCTAssertEqual(finishes, 0)
            XCTAssertNil(view.window)
        }
    }

    func testEscapeAfterReentryCancelsOnceAndLateEntryCannotReinstallTheCursor() throws {
        for mode in modes {
            let view = try makeView(mode: mode)
            var finishes = 0
            view.onFinish = { rect, action in
                XCTAssertNil(rect)
                guard case .copy = action else { return XCTFail("Escape must cancel without saving or pinning") }
                finishes += 1
            }
            view.mouseExited(with: try boundary(.mouseExited, at: CGPoint(x: -1, y: 140), in: view))
            NSCursor.arrow.set()
            view.mouseEntered(with: try boundary(.mouseEntered, at: CGPoint(x: 180, y: 140), in: view))

            view.keyDown(with: try escape())
            view.keyDown(with: try escape())
            NSCursor.arrow.set()
            view.mouseEntered(with: try boundary(.mouseEntered, at: CGPoint(x: 200, y: 160), in: view))

            XCTAssertEqual(finishes, 1)
            XCTAssertTrue(NSCursor.current === NSCursor.arrow)
            XCTAssertTrue(view.selection.isEmpty)
            XCTAssertNil(view.window)
        }
    }

    func testReentryPreservesAnExistingSelectionAndItsMoveCursor() throws {
        for mode in modes {
            let view = try makeView(mode: mode)
            let start = CGPoint(x: 80, y: 60), end = CGPoint(x: 500, y: 360)
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: view))
            view.mouseUp(with: try mouse(.leftMouseUp, at: end, in: view))
            let selection = view.selection
            XCTAssertEqual(selection, CGRect(x: 80, y: 60, width: 420, height: 300))
            var finishes = 0
            view.onFinish = { _, _ in finishes += 1 }
            view.mouseExited(with: try boundary(.mouseExited, at: CGPoint(x: -1, y: 140), in: view))
            NSCursor.arrow.set()

            view.mouseEntered(with: try boundary(.mouseEntered, at: CGPoint(x: 300, y: 200), in: view))

            XCTAssertTrue(NSCursor.current === NSCursor.openHand)
            XCTAssertEqual(view.selection, selection)
            XCTAssertTrue(view.annotations.isEmpty)
            XCTAssertEqual(view.gifSettings, GIFRecordingSettings(frameRate: 15, quality: .high))
            XCTAssertEqual(finishes, 0)
            XCTAssertNil(view.window)
        }
    }

    private func makeView(mode: SelectionView.Mode) throws -> SelectionView {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { @MainActor in
            originalCursor.set()
            pasteboard.releaseGlobally()
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        return SelectionView(image: try XCTUnwrap(context.makeImage()), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: mode, gifSettings: .init(frameRate: 15, quality: .high), allowsTagSelection: false,
            colorFormat: .hex, colorPasteboard: pasteboard, showsFullScreenCrosshair: false)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func boundary(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func escape() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }
}
