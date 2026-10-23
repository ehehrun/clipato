import AppKit
import XCTest
@testable import Clipato

@MainActor
final class SelectionColorPickerTests: XCTestCase {
    func testRetinaPointerSamplesOriginalTopDownPixelsWithoutRoundingToPoints() throws {
        let (view, _) = try makeView()

        for (point, value) in [
            (CGPoint(x: 0, y: 0), "#FF0000"),
            (CGPoint(x: 799.75, y: 0), "#00FF00"),
            (CGPoint(x: 0, y: 599.75), "#0000FF"),
            (CGPoint(x: 799.75, y: 599.75), "#FFFFFF"),
            (CGPoint(x: 20.49, y: 30.25), "#FFFF00"),
            (CGPoint(x: 20.75, y: 30.25), "#123456"),
            (CGPoint(x: 20.75, y: 30.75), "#00FFFF")
        ] {
            move(point, in: view)
            XCTAssertTrue(view.isColorPicking, "\(point)")
            XCTAssertEqual(view.currentColorValue, value, "\(point)")
        }
        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertNil(view.window)
    }

    func testCopyColorDoesNotFinishCaptureOrChangeTagAndSelectionCanFollow() throws {
        let (view, pasteboard) = try makeView(tag: .purple)
        var captures: [CGRect?] = []
        view.onFinish = { rect, action in
            captures.append(rect)
            if case .copy = action {} else { XCTFail("Expected the screenshot copy action") }
        }
        move(CGPoint(x: 20.75, y: 30.25), in: view)

        key(8, characters: "c", in: view)

        XCTAssertEqual(pasteboard.string(forType: .string), "#123456")
        XCTAssertEqual(view.assetTag, .purple)
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertTrue(captures.isEmpty)
        XCTAssertTrue(view.isColorPicking)

        drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 320, y: 240), in: view)
        let selected = view.pixelSelection
        XCTAssertFalse(view.isColorPicking)
        XCTAssertNil(view.currentColorValue)
        key(8, characters: "c", modifiers: .command, in: view)

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first!, selected)
        XCTAssertEqual(view.assetTag, .purple)
        XCTAssertEqual(pasteboard.string(forType: .string), "#123456")
    }

    func testTabCyclesCurrentSessionFormatsWithoutChangingSavedFormat() throws {
        let (view, pasteboard) = try makeView()
        let savedFormat = UserDefaults.standard.string(forKey: ScreenshotColorFormat.defaultsKey)
        move(.zero, in: view)

        for (format, expected) in [
            (ScreenshotColorFormat.rgb, "rgb(255, 0, 0)"),
            (.hsl, "hsl(0, 100%, 50%)"),
            (.hex, "#FF0000")
        ] {
            key(48, characters: "\t", in: view)
            XCTAssertEqual(view.colorFormat, format)
            XCTAssertEqual(view.currentColorValue, expected)
            key(8, characters: "c", in: view)
            XCTAssertEqual(pasteboard.string(forType: .string), expected)
            XCTAssertEqual(UserDefaults.standard.string(forKey: ScreenshotColorFormat.defaultsKey), savedFormat)
        }

        let (newSession, _) = try makeView(format: .hex)
        move(.zero, in: newSession)
        XCTAssertEqual(newSession.colorFormat, .hex)
        XCTAssertEqual(newSession.currentColorValue, "#FF0000")
    }

    func testFormatSettingIsUsedWhenCopyingAndModifierKeysDoNotCycleIt() throws {
        let (view, pasteboard) = try makeView(format: .rgb)
        move(.zero, in: view)
        XCTAssertEqual(view.currentColorValue, "rgb(255, 0, 0)")

        for modifier: NSEvent.ModifierFlags in [.shift, .command, .control, .option] {
            key(48, characters: "\t", modifiers: modifier, in: view)
            XCTAssertEqual(view.colorFormat, .rgb)
            key(8, characters: "c", modifiers: modifier, in: view)
            XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        }

        key(8, characters: "c", in: view)
        XCTAssertEqual(pasteboard.string(forType: .string), "rgb(255, 0, 0)")
    }

    func testFirstMouseDownPermanentlyEndsColorPickingEvenWithoutCreatingARegion() throws {
        let (view, pasteboard) = try makeView()
        move(.zero, in: view)
        XCTAssertTrue(view.isColorPicking)
        let point = CGPoint(x: 80, y: 60)

        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        XCTAssertFalse(view.isColorPicking)
        XCTAssertNil(view.currentColorValue)
        view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
        XCTAssertTrue(view.selection.isEmpty)

        move(CGPoint(x: 20.75, y: 30.25), in: view)
        key(48, characters: "\t", in: view)
        key(8, characters: "c", in: view)
        XCTAssertFalse(view.isColorPicking)
        XCTAssertNil(view.currentColorValue)
        XCTAssertEqual(view.colorFormat, .hex)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testLeavingImageStopsColorCopyAndReenteringBeforeMouseDownRestoresIt() throws {
        let (view, pasteboard) = try makeView()
        move(.zero, in: view)
        XCTAssertTrue(view.isColorPicking)

        view.mouseExited(with: boundary(.mouseExited, at: CGPoint(x: -1, y: 0), in: view))
        XCTAssertFalse(view.isColorPicking)
        XCTAssertNil(view.currentColorValue)
        key(8, characters: "c", in: view)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")

        view.mouseEntered(with: boundary(.mouseEntered, at: CGPoint(x: 799.75, y: 599.75), in: view))
        XCTAssertTrue(view.isColorPicking)
        XCTAssertEqual(view.currentColorValue, "#FFFFFF")
        key(8, characters: "c", in: view)
        XCTAssertEqual(pasteboard.string(forType: .string), "#FFFFFF")
    }

    func testRecordingFixedCaptureAndInitiallySelectedScreenshotDoNotEnableColorPicking() throws {
        for mode in [SelectionView.Mode.recording, .fixedCapture, .screenshot(allowsDestinationActions: true)] {
            let selected: Bool
            if case .screenshot = mode { selected = true } else { selected = false }
            let (view, pasteboard) = try makeView(mode: mode, initialFullScreen: selected)
            var finished = false
            view.onFinish = { _, _ in finished = true }
            move(CGPoint(x: 20.75, y: 30.25), in: view)

            key(48, characters: "\t", in: view)
            key(8, characters: "c", in: view)

            XCTAssertFalse(view.isColorPicking)
            XCTAssertNil(view.currentColorValue)
            XCTAssertEqual(view.colorFormat, .hex)
            XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
            XCTAssertFalse(finished)
        }
    }

    func testCLIScreenshotWithoutDestinationActionsStillAllowsColorCopyAndEnterCapture() throws {
        let (view, pasteboard) = try makeView(mode: .screenshot(allowsDestinationActions: false))
        var captures: [CGRect?] = []
        view.onFinish = { rect, _ in captures.append(rect) }
        move(.zero, in: view)

        key(8, characters: "c", in: view)
        XCTAssertEqual(pasteboard.string(forType: .string), "#FF0000")
        XCTAssertTrue(captures.isEmpty)

        drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 320, y: 240), in: view)
        key(36, characters: "\r", in: view)
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first!, CGRect(x: 160, y: 120, width: 480, height: 360))
        XCTAssertFalse(view.isColorPicking)
    }

    func testEscapeCancelsColorPickingAndPreventsLaterColorCopies() throws {
        let (view, pasteboard) = try makeView()
        var captures: [CGRect?] = []
        view.onFinish = { rect, _ in captures.append(rect) }
        move(.zero, in: view)

        key(53, characters: "\u{1b}", in: view)

        XCTAssertEqual(captures.count, 1)
        XCTAssertNil(captures.first!)
        XCTAssertFalse(view.isColorPicking)
        XCTAssertNil(view.currentColorValue)
        key(8, characters: "c", in: view)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertEqual(captures.count, 1)
    }

    private func makeView(mode: SelectionView.Mode = .screenshot(allowsDestinationActions: true),
                          initialFullScreen: Bool = false, tag: AssetTag? = nil,
                          format: ScreenshotColorFormat = .hex) throws -> (SelectionView, NSPasteboard) {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("untouched", forType: .string)
        addTeardownBlock { pasteboard.releaseGlobally() }
        let view = SelectionView(image: try fixture(), frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: mode,
                                 initialFullScreen: initialFullScreen, tag: tag, colorFormat: format, colorPasteboard: pasteboard)
        return (view, pasteboard)
    }

    private func fixture() throws -> CGImage {
        let width = 1600, height = 1200
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for alpha in stride(from: 3, to: rgba.count, by: 4) { rgba[alpha] = 255 }
        // Explicit provider rows fix the source orientation independently of AppKit's flipped view.
        for (x, y, r, g, b) in [(0, 0, 255, 0, 0), (1599, 0, 0, 255, 0),
                                 (0, 1199, 0, 0, 255), (1599, 1199, 255, 255, 255),
                                 (40, 60, 255, 255, 0), (41, 60, 18, 52, 86), (41, 61, 0, 255, 255)] {
            let index = (y * width + x) * 4
            rgba[index] = UInt8(r)
            rgba[index + 1] = UInt8(g)
            rgba[index + 2] = UInt8(b)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func boundary(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    private func move(_ point: CGPoint, in view: SelectionView) {
        view.mouseMoved(with: mouse(.mouseMoved, at: point, in: view))
    }

    private func drag(from start: CGPoint, to end: CGPoint, in view: SelectionView) {
        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code)!)
    }
}
