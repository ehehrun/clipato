import AppKit
import XCTest
@testable import Clipato

@MainActor
final class EditorTextMovementTests: XCTestCase {
    private func canvas() throws -> EditorImageCanvas {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = EditorImageCanvas(image: try XCTUnwrap(context.makeImage()))
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        canvas.imageScale = 0.5
        canvas.imageFrame = CGRect(x: 20, y: 30, width: 400, height: 300)
        return canvas
    }

    private func text(_ value: String = "可移动文字") -> ImageAnnotation {
        ImageAnnotation(tool: .text, points: [CGPoint(x: 100, y: 100)], color: .systemBlue, width: 0,
                        text: value, fontSize: 24, textWidth: 300)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in canvas: EditorImageCanvas, clicks: Int = 1) -> NSEvent {
        let location = CGPoint(x: canvas.imageFrame.minX + point.x * canvas.imageScale,
                               y: canvas.imageFrame.minY + point.y * canvas.imageScale)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(location, to: nil), modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testDragMovesOnlyTopTextInSourcePixelsAndProducesOneUndoStep() throws {
        let canvas = try canvas()
        let lower = text("下面文字")
        let upper = text("上面文字")
        canvas.annotations = [lower, upper]
        canvas.tool = .rectangle
        var changes: [AnnotationChange] = []
        canvas.onAnnotationChange = { changes.append($0) }
        let start = CGPoint(x: upper.textBounds.midX, y: upper.textBounds.midY)
        let end = CGPoint(x: start.x + 60, y: start.y + 40)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: start.x + 30, y: start.y + 20), in: canvas))
        XCTAssertEqual(canvas.annotations, [lower, upper], "Drag preview must remain transient until release")
        canvas.mouseUp(with: event(.leftMouseUp, at: end, in: canvas))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(canvas.annotations[0], lower)
        XCTAssertEqual(canvas.annotations[1].points, [CGPoint(x: 160, y: 140)])
        XCTAssertEqual(canvas.annotations[1].textWidth, upper.textWidth)
        XCTAssertEqual(canvas.annotations[1].fontSize, upper.fontSize)
        var restored = canvas.annotations
        changes[0].undo(in: &restored)
        XCTAssertEqual(restored, [lower, upper])
        changes[0].apply(to: &restored)
        XCTAssertEqual(restored, canvas.annotations)
    }

    func testReplacingAnnotationsDuringDragCancelsPendingReplacement() throws {
        let canvas = try canvas()
        let annotation = text()
        canvas.annotations = [annotation]
        var changes = 0
        canvas.onAnnotationChange = { _ in changes += 1 }
        let start = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        let end = CGPoint(x: start.x + 60, y: start.y + 40)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end, in: canvas))
        canvas.annotations = []
        canvas.mouseUp(with: event(.leftMouseUp, at: end, in: canvas))
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(canvas.annotations.isEmpty)
    }

    func testClickAndCancelledDragDoNotModifyTextOrCreateHistory() throws {
        let canvas = try canvas()
        let annotation = text()
        canvas.annotations = [annotation]
        var changes = 0
        canvas.onAnnotationChange = { _ in changes += 1 }
        let start = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, at: start, in: canvas))
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas))
        let end = CGPoint(x: start.x + 100, y: start.y + 80)
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end, in: canvas))
        canvas.cancelOperation(nil)
        canvas.mouseUp(with: event(.leftMouseUp, at: end, in: canvas))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(canvas.annotations, [annotation])
    }

    func testReeditingPreservesOriginalStyleAndReplacesInsteadOfAppending() throws {
        let canvas = try canvas()
        let annotation = text()
        canvas.annotations = [annotation]
        canvas.updateTextStyle(color: .red, fontSize: 48)
        let start = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas, clicks: 2))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first)
        canvas.updateTextStyle(color: .red, fontSize: 48)
        XCTAssertEqual(editor.annotation.color, annotation.color)
        XCTAssertEqual(editor.annotation.fontSize, annotation.fontSize)
        canvas.updateTextStyle(color: .red, fontSize: 64)
        XCTAssertEqual(editor.annotation.color, annotation.color, "Changing font must not apply an unrelated toolbar color")
        XCTAssertEqual(editor.annotation.fontSize, 64)
        editor.string = "改好的文字"
        var changes: [AnnotationChange] = []
        canvas.onAnnotationChange = { changes.append($0) }
        canvas.finishTextEditing()
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations[0].text, "改好的文字")
        XCTAssertEqual(canvas.annotations[0].points, annotation.points)
        XCTAssertEqual(changes.count, 1)
        var restored = canvas.annotations
        changes[0].undo(in: &restored)
        XCTAssertEqual(restored, [annotation])
    }

    func testCancelReeditingRestoresOriginalAndReadOnlyCanvasCannotEdit() throws {
        let canvas = try canvas()
        let annotation = text()
        canvas.annotations = [annotation]
        let start = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas, clicks: 2))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first)
        editor.string = "取消的修改"
        editor.finish(commit: false)
        XCTAssertEqual(canvas.annotations, [annotation])
        canvas.allowsAnnotation = false
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas, clicks: 2))
        XCTAssertTrue(canvas.subviews.isEmpty)
        XCTAssertEqual(canvas.annotations, [annotation])
    }
}
