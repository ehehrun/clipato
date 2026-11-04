import AppKit
import QuartzCore
import XCTest
@testable import Clipato

@MainActor
final class SelectionWindowSnapTests: XCTestCase {
    private let target = SelectionWindowTarget(windowID: 41, frame: CGRect(x: 120, y: 90, width: 280, height: 180))

    func testFirstMousePressIsAcceptedWithoutAnActivationClick() throws {
        let view = try makeView()
        XCTAssertTrue(view.acceptsFirstMouse(for: mouse(.leftMouseDown, at: CGPoint(x: 180, y: 140), in: view)))
        XCTAssertNil(view.window)
    }

    func testHoverHighlightsTheFrontmostCandidateWithoutSelectingOrFinishing() throws {
        let front = SelectionWindowTarget(windowID: 7, frame: CGRect(x: 80, y: 60, width: 640, height: 420))
        let view = try makeView(targets: [front, target])
        var finishes = 0
        view.onFinish = { _, _ in finishes += 1 }

        move(CGPoint(x: 180, y: 140), in: view)

        XCTAssertEqual(view.hoveredWindow?.windowID, 7)
        XCTAssertEqual(view.hoveredWindow?.frame, front.frame)
        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertTrue(view.isColorPicking)
        XCTAssertEqual(view.currentColorValue, "#FFFFFF")
        XCTAssertTrue(try control("selection-toolbar", in: view).isHidden)
        XCTAssertEqual(finishes, 0)
        try assertBorder(around: front.frame, in: view)
        XCTAssertNil(view.window)
    }

    func testClickSelectsTheWholeWindowOnReleaseAndKeepsDestinationConfirmation() throws {
        for allowsDestinationActions in [true, false] {
            let view = try makeView(mode: .screenshot(allowsDestinationActions: allowsDestinationActions))
            var finishes = 0
            view.onFinish = { _, _ in finishes += 1 }
            let point = CGPoint(x: 180, y: 140)
            move(point, in: view)

            view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
            XCTAssertTrue(view.selection.isEmpty)
            XCTAssertTrue(try control("selection-toolbar", in: view).isHidden)
            view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))

            XCTAssertEqual(view.selection, target.frame)
            XCTAssertEqual(view.pixelSelection, CGRect(x: 240, y: 180, width: 560, height: 360))
            XCTAssertNil(view.hoveredWindow)
            XCTAssertFalse(try control("selection-toolbar", in: view).isHidden)
            XCTAssertFalse(view.isColorPicking)
            XCTAssertEqual(finishes, 0)
            try assertBorder(around: target.frame, in: view)
        }
    }

    func testSmallPointerJitterStillSelectsTheHoveredWindow() throws {
        let view = try makeView()
        let start = CGPoint(x: 180, y: 140), end = CGPoint(x: 182, y: 140)
        move(start, in: view)

        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))

        XCTAssertEqual(view.selection, target.frame)
    }

    func testDraggingFromACandidateCreatesTheUserRectangleInsteadOfMovingTheWindow() throws {
        let view = try makeView()
        let start = CGPoint(x: 180, y: 140)
        move(start, in: view)
        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))

        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 183, y: 145), in: view))
        XCTAssertEqual(view.selection, CGRect(x: 180, y: 140, width: 3, height: 5))
        XCTAssertNil(view.hoveredWindow)
        XCTAssertTrue(try control("selection-toolbar", in: view).isHidden)

        let end = CGPoint(x: 470, y: 330)
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))

        XCTAssertEqual(view.selection, CGRect(x: 180, y: 140, width: 290, height: 190))
        XCTAssertEqual(view.pixelSelection, CGRect(x: 360, y: 280, width: 580, height: 380))
        XCTAssertFalse(try control("selection-toolbar", in: view).isHidden)
    }

    func testFirstDragImmediatelyUpdatesLayerPathsWithoutInvalidatingTheFullDrawingView() throws {
        let view = try makeView()
        let drawing = try control("selection-drawing-overlay", in: view)
        let start = CGPoint(x: 20, y: 30), end = CGPoint(x: 250, y: 210)
        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))
        drawing.needsDisplay = false

        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))

        let expected = CGRect(x: 20, y: 30, width: 230, height: 180)
        XCTAssertEqual(view.selection, expected)
        XCTAssertFalse(drawing.needsDisplay)
        XCTAssertTrue(try control("selection-toolbar", in: view).isHidden)
        XCTAssertFalse(try control("selection-dimensions", in: view).isHidden)
        try assertBorder(around: expected, in: view)
        let shade = try shape("selection-shade", in: view)
        let path = try XCTUnwrap(shade.path)
        XCTAssertTrue(path.contains(CGPoint(x: 600, y: 400), using: .evenOdd))
        XCTAssertFalse(path.contains(CGPoint(x: 100, y: 100), using: .evenOdd))

        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))
        XCTAssertFalse(try control("selection-toolbar", in: view).isHidden)
        XCTAssertNil(view.window)
    }

    func testClickingEmptySpaceDoesNotSnapOrCreateAnAccidentalSelection() throws {
        let view = try makeView()
        let point = CGPoint(x: 20, y: 30)
        move(point, in: view)
        XCTAssertNil(view.hoveredWindow)

        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))

        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertTrue(try control("selection-toolbar", in: view).isHidden)
    }

    func testExistingSelectionKeepsItsMoveAndResizeBehavior() throws {
        let view = try makeView()
        click(CGPoint(x: 180, y: 140), in: view)
        move(CGPoint(x: 260, y: 180), in: view)
        XCTAssertNil(view.hoveredWindow)
        XCTAssertEqual(view.selection, target.frame)

        drag(from: CGPoint(x: 260, y: 180), to: CGPoint(x: 290, y: 200), in: view)
        XCTAssertEqual(view.selection, CGRect(x: 150, y: 110, width: 280, height: 180))
        drag(from: CGPoint(x: 430, y: 290), to: CGPoint(x: 450, y: 320), in: view)

        XCTAssertEqual(view.selection, CGRect(x: 150, y: 110, width: 300, height: 210))
        XCTAssertNil(view.hoveredWindow)
        XCTAssertTrue(view.annotations.isEmpty)
    }

    func testOtherCaptureModesAndAnInitialFullScreenSelectionDoNotOfferWindowSnap() throws {
        for mode in [SelectionView.Mode.recording, .fixedCapture] {
            let view = try makeView(mode: mode)
            move(CGPoint(x: 180, y: 140), in: view)
            XCTAssertNil(view.hoveredWindow)
            click(CGPoint(x: 180, y: 140), in: view)
            XCTAssertTrue(view.selection.isEmpty)
        }
        let view = try makeView(initialFullScreen: true)
        move(CGPoint(x: 180, y: 140), in: view)
        XCTAssertNil(view.hoveredWindow)
        XCTAssertEqual(view.selection, CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testLeavingAndCancellingClearTheHoverCandidate() throws {
        let view = try makeView()
        let point = CGPoint(x: 180, y: 140)
        move(point, in: view)
        XCTAssertEqual(view.hoveredWindow?.windowID, target.windowID)

        view.mouseExited(with: boundary(.mouseExited, at: CGPoint(x: -1, y: 140), in: view))
        XCTAssertNil(view.hoveredWindow)
        view.mouseEntered(with: boundary(.mouseEntered, at: point, in: view))
        XCTAssertEqual(view.hoveredWindow?.windowID, target.windowID)
        var cancellations = 0
        view.onFinish = { rect, _ in
            XCTAssertNil(rect)
            cancellations += 1
        }

        key(53, characters: "\u{1b}", in: view)
        XCTAssertNil(view.hoveredWindow)
        XCTAssertEqual(cancellations, 1)
        move(point, in: view)
        XCTAssertNil(view.hoveredWindow)
        XCTAssertEqual(cancellations, 1)
    }

    func testWindowHoverPreservesColorFormatAndCopyShortcuts() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = try makeView(pasteboard: pasteboard)
        var finishes = 0
        view.onFinish = { _, _ in finishes += 1 }
        move(CGPoint(x: 180, y: 140), in: view)

        key(48, characters: "\t", in: view)
        key(8, characters: "c", in: view)

        XCTAssertEqual(view.currentColorValue, "rgb(255, 255, 255)")
        XCTAssertEqual(pasteboard.string(forType: .string), "rgb(255, 255, 255)")
        XCTAssertEqual(view.hoveredWindow?.windowID, target.windowID)
        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertEqual(finishes, 0)
    }

    private func makeView(mode: SelectionView.Mode = .screenshot(allowsDestinationActions: true),
                          initialFullScreen: Bool = false, targets: [SelectionWindowTarget]? = nil,
                          pasteboard: NSPasteboard? = nil) throws -> SelectionView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let board = pasteboard ?? NSPasteboard.withUniqueName()
        if pasteboard == nil { addTeardownBlock { board.releaseGlobally() } }
        return SelectionView(image: try XCTUnwrap(context.makeImage()), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                             mode: mode, initialFullScreen: initialFullScreen, colorFormat: .hex,
                             colorPasteboard: board, windowTargets: targets ?? [target])
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

    private func click(_ point: CGPoint, in view: SelectionView) {
        move(point, in: view)
        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
    }

    private func drag(from start: CGPoint, to end: CGPoint, in view: SelectionView) {
        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))
    }

    private func key(_ code: UInt16, characters: String, in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }

    private func control(_ identifier: String, in view: NSView) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for child in view.subviews {
                if let match = find(child) { return match }
            }
            return nil
        }
        return try XCTUnwrap(find(view), "Missing control: \(identifier)")
    }

    private func shape(_ name: String, in view: SelectionView) throws -> CAShapeLayer {
        func find(_ layer: CALayer) -> CAShapeLayer? {
            if layer.name == name { return layer as? CAShapeLayer }
            for child in layer.sublayers ?? [] {
                if let match = find(child) { return match }
            }
            return nil
        }
        return try XCTUnwrap(find(try XCTUnwrap(view.layer)), "Missing shape: \(name)")
    }

    private func assertBorder(around frame: CGRect, in view: SelectionView,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try XCTUnwrap(try shape("selection-border", in: view).path, file: file, line: line)
        let bounds = path.boundingBoxOfPath
        XCTAssertEqual(bounds.minX, frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(bounds.minY, frame.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(bounds.maxX, frame.maxX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(bounds.maxY, frame.maxY, accuracy: 1, file: file, line: line)
    }
}
