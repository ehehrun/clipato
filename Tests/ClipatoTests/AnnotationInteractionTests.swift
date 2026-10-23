import AppKit
import XCTest
@testable import Clipato

@MainActor
final class AnnotationInteractionTests: XCTestCase {
    private func image(width: Int = 1600, height: Int = 1200) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func view(mode: SelectionView.Mode = .screenshot(allowsDestinationActions: true)) throws -> SelectionView {
        _ = NSApplication.shared
        let view = SelectionView(image: try image(), frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: mode)
        drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 720, y: 440), in: view)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func control<T: NSView>(_ id: String, in view: NSView, as type: T.Type) throws -> T {
        func find(_ view: NSView) -> T? {
            if view.identifier?.rawValue == id { return view as? T }
            for child in view.subviews {
                if let result = find(child) { return result }
            }
            return nil
        }
        return try XCTUnwrap(find(view), "Missing control: \(id)")
    }

    private func press(_ id: String, in view: SelectionView) throws {
        try control(id, in: view, as: NSButton.self).performClick(nil)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(_ point: CGPoint, in view: SelectionView, clicks: Int = 1) {
        view.mouseDown(with: event(.leftMouseDown, at: point, in: view, clicks: clicks))
        view.mouseUp(with: event(.leftMouseUp, at: point, in: view, clicks: clicks))
    }

    private func drag(from start: CGPoint, to end: CGPoint, in view: SelectionView) {
        view.mouseDown(with: event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: event(.leftMouseUp, at: end, in: view))
    }

    private func textPoint(_ annotation: ImageAnnotation, in view: SelectionView) -> CGPoint {
        let bounds = annotation.textBounds
        return CGPoint(x: view.selection.minX + bounds.midX * view.bounds.width / CGFloat(view.image.width),
                       y: view.selection.minY + bounds.midY * view.bounds.height / CGFloat(view.image.height))
    }

    @discardableResult
    private func addText(_ text: String, at point: CGPoint = CGPoint(x: 130, y: 110), in view: SelectionView) throws -> ImageAnnotation {
        try press("text", in: view)
        click(point, in: view)
        let editor = try control("annotation-text-input", in: view, as: AnnotationTextEditor.self)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.finish(commit: true)
        return try XCTUnwrap(view.annotations.last)
    }

    func testScreenshotTextDragUsesCropLocalSourcePixelsAndOneUndoStep() throws {
        let view = try view()
        let original = try addText("中文标注\n第二行", in: view)
        let selection = view.selection
        let crop = view.pixelSelection
        XCTAssertEqual(original.points, [CGPoint(x: 100, y: 100)])
        XCTAssertEqual(original.fontSize, 48)
        try press("rectangle", in: view)
        let start = textPoint(original, in: view)
        let end = CGPoint(x: start.x + 70, y: start.y + 40)
        view.mouseDown(with: event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, at: end, in: view))
        XCTAssertEqual(view.annotations, [original], "Drag preview must not replace the committed annotation before release")
        view.mouseUp(with: event(.leftMouseUp, at: end, in: view))
        var expected = original
        expected.points = [CGPoint(x: 240, y: 180)]
        XCTAssertEqual(view.annotations, [expected], "Only the text position should change, preserving content, font, width, and color")
        XCTAssertEqual(view.selection, selection)
        XCTAssertEqual(view.pixelSelection, crop)
        try press("undo", in: view)
        XCTAssertEqual(view.annotations, [original])
        try press("redo", in: view)
        XCTAssertEqual(view.annotations, [expected])
        try press("undo", in: view)
        try press("undo", in: view)
        XCTAssertTrue(view.annotations.isEmpty)
    }

    func testSelectingTextWithoutMovementDoesNotAddHistory() throws {
        let view = try view()
        let original = try addText("单击选择", in: view)
        click(textPoint(original, in: view), in: view)
        XCTAssertEqual(view.annotations, [original])
        try press("undo", in: view)
        XCTAssertTrue(view.annotations.isEmpty, "A click must not insert a no-op move ahead of the text creation")
        try press("redo", in: view)
        XCTAssertEqual(view.annotations, [original])
    }

    func testOverlappingTextMovesTopmostAnnotation() throws {
        let view = try view()
        let lower = try addText("下层文字", in: view)
        let upper = try addText("上层文字", at: CGPoint(x: 370, y: 110), in: view)
        let start = textPoint(upper, in: view)
        drag(from: start, to: CGPoint(x: start.x - 240, y: start.y), in: view)
        let overlapping = view.annotations[1]
        XCTAssertEqual(overlapping.points, lower.points)
        let hit = textPoint(overlapping, in: view)
        drag(from: hit, to: CGPoint(x: hit.x + 40, y: hit.y + 30), in: view)
        XCTAssertEqual(view.annotations[0], lower)
        var expected = overlapping
        expected.points[0].x += 80
        expected.points[0].y += 60
        XCTAssertEqual(view.annotations[1], expected)
    }

    func testDoubleClickReeditsInPlaceAndCancelPreservesOriginal() throws {
        let view = try view()
        let original = try addText("原有文字", in: view)
        let hit = textPoint(original, in: view)
        click(hit, in: view, clicks: 2)
        let cancelled = try control("annotation-text-input", in: view, as: AnnotationTextEditor.self)
        XCTAssertEqual(cancelled.annotation, original)
        cancelled.insertText("取消的修改", replacementRange: NSRange(location: 0, length: cancelled.string.utf16.count))
        cancelled.finish(commit: false)
        XCTAssertEqual(view.annotations, [original])
        click(hit, in: view, clicks: 2)
        let committed = try control("annotation-text-input", in: view, as: AnnotationTextEditor.self)
        committed.insertText("替换后的文字", replacementRange: NSRange(location: 0, length: committed.string.utf16.count))
        committed.finish(commit: true)
        var expected = original
        expected.text = "替换后的文字"
        XCTAssertEqual(view.annotations, [expected], "Editing existing text replaces its annotation instead of appending another")
        try press("undo", in: view)
        XCTAssertEqual(view.annotations, [original])
        try press("redo", in: view)
        XCTAssertEqual(view.annotations, [expected])
    }

    func testToolbarAndPaletteBlankSpacePreserveSelectionAndActiveText() throws {
        let view = try view()
        let original = try addText("保留这段文字", in: view)
        let selection = view.selection
        var finished = false
        view.onFinish = { _, _ in finished = true }
        let toolbar = try control("selection-toolbar", in: view, as: NSView.self)
        click(CGPoint(x: toolbar.frame.minX + 1, y: toolbar.frame.minY + 1), in: view)
        XCTAssertEqual(view.selection, selection)
        XCTAssertEqual(view.annotations, [original])
        XCTAssertFalse(finished)

        click(textPoint(original, in: view), in: view, clicks: 2)
        let editor = try control("annotation-text-input", in: view, as: AnnotationTextEditor.self)
        editor.insertText("尚未提交", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        click(CGPoint(x: toolbar.frame.maxX - 1, y: toolbar.frame.minY + 1), in: view)
        XCTAssertTrue(try control("annotation-text-input", in: view, as: AnnotationTextEditor.self) === editor)
        try press("color", in: view)
        let palette = try control("color-palette", in: view, as: NSView.self)
        XCTAssertFalse(palette.isHidden)
        click(CGPoint(x: palette.frame.minX + 1, y: palette.frame.minY + 1), in: view)
        XCTAssertTrue(try control("annotation-text-input", in: view, as: AnnotationTextEditor.self) === editor)
        XCTAssertEqual(editor.string, "尚未提交")
        XCTAssertEqual(view.selection, selection)
        XCTAssertEqual(view.annotations, [original])
        XCTAssertFalse(finished)
        editor.finish(commit: false)
    }

    func testRecordingToolbarBlankSpaceDoesNotCancelOrReselectRegion() throws {
        let view = try view(mode: .recording)
        let selection = view.selection
        var finished = false
        view.onFinish = { _, _ in finished = true }
        let toolbar = try control("selection-toolbar", in: view, as: NSView.self)
        click(CGPoint(x: toolbar.frame.minX + 1, y: toolbar.frame.minY + 1), in: view)
        XCTAssertFalse(finished)
        XCTAssertEqual(view.selection, selection)
        try press("start", in: view)
        XCTAssertTrue(finished, "The real start control must still work after a blank-space click")
    }

    func testTextMovementClampsUsedBoundsWithoutReflowingText() throws {
        _ = NSApplication.shared
        let original = ImageAnnotation(tool: .text, points: [CGPoint(x: 20, y: 30)], color: .red, width: 0,
                                       text: "第一行\n第二行", fontSize: 24, textWidth: 200)
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let bounds = original.textBounds
        XCTAssertLessThan(bounds.width, original.textWidth, "Unused text-container width must not block moving short text to the edge")
        for delta in [CGPoint(x: 1000, y: 1000), CGPoint(x: -1000, y: -1000)] {
            let moved = original.movedText(by: delta, within: canvas, textBounds: bounds)
            XCTAssertEqual(moved.textWidth, original.textWidth)
            XCTAssertEqual(moved.textBounds.size, bounds.size)
            XCTAssertEqual(moved.text, original.text)
            XCTAssertEqual(moved.fontSize, original.fontSize)
            XCTAssertGreaterThanOrEqual(moved.textBounds.minX, canvas.minX - 0.001)
            XCTAssertGreaterThanOrEqual(moved.textBounds.minY, canvas.minY - 0.001)
            XCTAssertLessThanOrEqual(moved.textBounds.maxX, canvas.maxX + 0.001)
            XCTAssertLessThanOrEqual(moved.textBounds.maxY, canvas.maxY + 0.001)
        }
    }

    func testMovedTextExportClearsOldLocationAndOmitsSelectionOutline() throws {
        _ = NSApplication.shared
        let view = SelectionView(image: try image(width: 800, height: 600), frame: CGRect(x: 0, y: 0, width: 400, height: 300), initialFullScreen: true)
        let original = try addText("F\n中", at: CGPoint(x: 30, y: 30), in: view)
        let start = textPoint(original, in: view)
        drag(from: start, to: CGPoint(x: start.x + 100, y: start.y + 60), in: view)
        let moved = try XCTUnwrap(view.annotations.first)
        let output = try renderAnnotatedImage(view.image, crop: view.pixelSelection, annotations: view.annotations)
        let bitmap = NSBitmapImageRep(cgImage: output)
        var oldInk = 0, newInk = 0, outlineInk = 0
        for (index, rect) in [original.textBounds, moved.textBounds].enumerated() {
            let sample = rect.insetBy(dx: -6, dy: -6).integral
            for y in Int(sample.minY)..<Int(sample.maxY) {
                for x in Int(sample.minX)..<Int(sample.maxX) {
                    let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if pixel.greenComponent < 0.8 {
                        if index == 0 { oldInk += 1 } else { newInk += 1 }
                    }
                    if pixel.blueComponent > pixel.redComponent + 0.2 { outlineInk += 1 }
                }
            }
        }
        XCTAssertEqual(oldInk, 0, "The original text location must return to the unchanged white source")
        XCTAssertGreaterThan(newInk, 200)
        XCTAssertEqual(outlineInk, 0, "The blue selection outline belongs only to the editor display")
        XCTAssertEqual(output.width, 800)
        XCTAssertEqual(output.height, 600)
    }
}
