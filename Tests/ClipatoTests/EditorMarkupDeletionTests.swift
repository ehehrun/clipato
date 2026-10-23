import AppKit
import XCTest
@testable import Clipato

@MainActor
final class EditorMarkupDeletionTests: XCTestCase {
    private func canvas(scale: CGFloat = 0.5) throws -> EditorImageCanvas {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = EditorImageCanvas(image: try XCTUnwrap(context.makeImage()))
        canvas.frame = CGRect(x: 0, y: 0, width: 800 * scale + 40, height: 600 * scale + 60)
        canvas.imageScale = scale
        canvas.imageFrame = CGRect(x: 20, y: 30, width: 800 * scale, height: 600 * scale)
        return canvas
    }

    private func text(_ value: String = "可删除文字") -> ImageAnnotation {
        ImageAnnotation(tool: .text, points: [CGPoint(x: 100, y: 100)], color: .systemBlue, width: 0,
                        text: value, fontSize: 24, textWidth: 300)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in canvas: EditorImageCanvas, clicks: Int = 1) -> NSEvent {
        let location = CGPoint(x: canvas.imageFrame.minX + point.x * canvas.imageScale,
                               y: canvas.imageFrame.minY + point.y * canvas.imageScale)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(location, to: nil), modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(_ point: CGPoint, in canvas: EditorImageCanvas, clicks: Int = 1) {
        canvas.mouseDown(with: event(.leftMouseDown, at: point, in: canvas, clicks: clicks))
        canvas.mouseUp(with: event(.leftMouseUp, at: point, in: canvas, clicks: clicks))
    }

    private func deleteKey(_ code: UInt16 = 51, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: code == 51 ? "\u{7f}" : "\u{f728}", charactersIgnoringModifiers: "",
                        isARepeat: repeated, keyCode: code)!
    }

    func testClickSelectsEachShapeAndDeleteRemovesOnlySelectedAnnotation() throws {
        for tool in [AnnotationTool.rectangle, .arrow, .pen] {
            let canvas = try canvas()
            let shape = ImageAnnotation(tool: tool, points: [CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 400)], color: .red, width: 4)
            let unrelated = text()
            canvas.annotations = [shape, unrelated]
            var changes: [AnnotationChange] = []
            canvas.onAnnotationChange = { changes.append($0) }
            let point = tool == .rectangle ? CGPoint(x: 100, y: 350) : CGPoint(x: 200, y: 350)
            click(point, in: canvas)
            canvas.keyDown(with: deleteKey())
            XCTAssertEqual(canvas.annotations, [unrelated], "Selected \(tool) must be deletable regardless of the active tool")
            canvas.keyDown(with: deleteKey(repeated: true))
            XCTAssertEqual(canvas.annotations, [unrelated], "Key repeat must not delete the adjacent item")
            XCTAssertEqual(changes.count, 1)
        }
    }

    func testTopmostHitWinsBetweenTextAndShape() throws {
        let annotation = text()
        let bounds = annotation.textBounds
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        let arrow = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 70, y: point.y), CGPoint(x: 350, y: point.y)], color: .red, width: 4)
        for annotations in [[annotation, arrow], [arrow, annotation]] {
            let canvas = try canvas()
            canvas.annotations = annotations
            click(point, in: canvas)
            canvas.keyDown(with: deleteKey(117, flags: .function))
            XCTAssertEqual(canvas.annotations, [annotations[0]])
        }
    }

    func testRectangleEmptyInteriorDeselectsAndClickDoesNotCreateShape() throws {
        let canvas = try canvas()
        let rectangle = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)], color: .red, width: 4)
        canvas.annotations = [rectangle]
        var added = 0
        canvas.onAnnotation = { _ in added += 1 }
        click(CGPoint(x: 100, y: 200), in: canvas)
        let empty = CGPoint(x: 200, y: 200)
        canvas.mouseDown(with: event(.leftMouseDown, at: empty, in: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: empty, in: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, at: empty, in: canvas))
        canvas.keyDown(with: deleteKey())
        XCTAssertEqual(canvas.annotations, [rectangle])
        XCTAssertEqual(added, 0, "A click or a zero-distance drag must not create an invisible shape")
    }

    func testSelectionHitToleranceStaysInDisplayPointsAcrossZoomLevels() throws {
        let rectangle = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)], color: .red, width: 2)
        for scale in [CGFloat(0.25), 0.5, 2] {
            let canvas = try canvas(scale: scale)
            canvas.annotations = [rectangle]
            click(CGPoint(x: 100 - 2.5 / scale, y: 200), in: canvas)
            canvas.keyDown(with: deleteKey())
            XCTAssertTrue(canvas.annotations.isEmpty, "A point 2.5 display points from the line must select at scale \(scale)")
            canvas.annotations = [rectangle]
            click(CGPoint(x: 100 - 6 / scale, y: 200), in: canvas)
            canvas.keyDown(with: deleteKey())
            XCTAssertEqual(canvas.annotations, [rectangle], "A point 6 display points away is outside the hit tolerance")
        }
    }

    func testDeleteCancelsPendingTextDragAndUndoRestoresExactMiddleLayer() throws {
        let canvas = try canvas()
        let before = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 300, y: 300), CGPoint(x: 500, y: 500)], color: .red, width: 3)
        let annotation = text("中文\n第二行")
        let after = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 500, y: 100), CGPoint(x: 700, y: 200)], color: .green, width: 5)
        let original = [before, annotation, after]
        canvas.annotations = original
        var changes: [AnnotationChange] = []
        canvas.onAnnotationChange = { changes.append($0) }
        let start = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        let end = CGPoint(x: start.x + 80, y: start.y + 40)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end, in: canvas))
        canvas.keyDown(with: deleteKey())
        canvas.mouseUp(with: event(.leftMouseUp, at: end, in: canvas))
        XCTAssertEqual(canvas.annotations, [before, after])
        XCTAssertEqual(changes.count, 1, "Delete during a pending drag must not create a subsequent move")
        let change = try XCTUnwrap(changes.first)
        change.undo(in: &canvas.annotations)
        XCTAssertEqual(canvas.annotations, original, "Undo must restore original position, style, content, and layer order")
        change.apply(to: &canvas.annotations)
        XCTAssertEqual(canvas.annotations, [before, after])
        canvas.keyDown(with: deleteKey(repeated: true))
        XCTAssertEqual(canvas.annotations, [before, after])
    }

    func testTextEditingDeletesCharactersWithoutRemovingMarkup() throws {
        let canvas = try canvas()
        let annotation = text("中文ABC")
        canvas.annotations = [annotation]
        let point = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        click(point, in: canvas, clicks: 2)
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first)
        canvas.keyDown(with: deleteKey())
        XCTAssertEqual(canvas.annotations, [annotation])
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "中文AB")
        canvas.finishTextEditing()
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations[0].text, "中文AB")
    }

    func testExternalReplacementClearsSelectionEvenWhenIndexStillExists() throws {
        let canvas = try canvas()
        let annotation = text()
        let replacement = text("外部更新")
        canvas.annotations = [annotation]
        click(CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY), in: canvas)
        canvas.annotations = [replacement]
        canvas.keyDown(with: deleteKey())
        XCTAssertEqual(canvas.annotations, [replacement])
    }

    func testDeleteDoesNotConsumeUnfocusedShortcutOrReadOnlyAndModifiedKeys() throws {
        let canvas = try canvas()
        let annotation = text()
        let point = CGPoint(x: annotation.textBounds.midX, y: annotation.textBounds.midY)
        canvas.annotations = [annotation]
        click(point, in: canvas)
        XCTAssertFalse(canvas.performKeyEquivalent(with: deleteKey()), "A canvas without focus must not intercept Delete")
        XCTAssertEqual(canvas.annotations, [annotation])
        for flags in [NSEvent.ModifierFlags.command, .control, .option] {
            canvas.keyDown(with: deleteKey(flags: flags))
            XCTAssertEqual(canvas.annotations, [annotation])
        }
        canvas.allowsAnnotation = false
        canvas.keyDown(with: deleteKey())
        XCTAssertEqual(canvas.annotations, [annotation])
    }
}
