import AppKit
import XCTest
@testable import Clipato

@MainActor
final class EditorEscapeTests: XCTestCase {
    private final class ClosingResponder: NSResponder {
        var requests = 0
        override func cancelOperation(_ sender: Any?) { requests += 1 }
    }

    private func canvas() throws -> EditorImageCanvas {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = EditorImageCanvas(image: try XCTUnwrap(context.makeImage()))
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        canvas.imageFrame = canvas.bounds
        canvas.imageScale = 1
        return canvas
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in canvas: EditorImageCanvas, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testEscapeClearsSelectionBeforeForwardingCloseRequest() throws {
        let canvas = try canvas()
        let closing = ClosingResponder()
        canvas.nextResponder = closing
        let rectangle = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 30, y: 30), CGPoint(x: 180, y: 160)], color: .red, width: 4)
        canvas.annotations = [rectangle]
        let point = CGPoint(x: 30, y: 80)
        canvas.mouseDown(with: event(.leftMouseDown, at: point, in: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, at: point, in: canvas))
        canvas.cancelOperation(nil)
        XCTAssertEqual(closing.requests, 0)
        XCTAssertEqual(canvas.annotations, [rectangle])
        canvas.cancelOperation(nil)
        XCTAssertEqual(closing.requests, 1)
    }

    func testEscapeCancelsUncommittedStrokeBeforeForwardingCloseRequest() throws {
        let canvas = try canvas()
        let closing = ClosingResponder()
        canvas.nextResponder = closing
        var added = 0
        canvas.onAnnotation = { _ in added += 1 }
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 100, y: 100), in: canvas))
        canvas.cancelOperation(nil)
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 100, y: 100), in: canvas))
        XCTAssertEqual(closing.requests, 0)
        XCTAssertEqual(added, 0)
        XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.cancelOperation(nil)
        XCTAssertEqual(closing.requests, 1)
    }

    func testEscapeCancelsTextInputWithoutSavingOrForwardingCloseRequest() throws {
        let canvas = try canvas()
        let closing = ClosingResponder()
        canvas.nextResponder = closing
        canvas.tool = .text
        let point = CGPoint(x: 30, y: 30)
        canvas.mouseDown(with: event(.leftMouseDown, at: point, in: canvas))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first)
        editor.string = "未完成文字"
        editor.cancelOperation(nil)
        XCTAssertTrue(canvas.subviews.isEmpty)
        XCTAssertTrue(canvas.annotations.isEmpty)
        XCTAssertEqual(closing.requests, 0)
        canvas.cancelOperation(nil)
        XCTAssertEqual(closing.requests, 1)
    }
}
