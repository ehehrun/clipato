import AppKit
import XCTest
@testable import Clipato

@MainActor
final class MarkupDeletionTests: XCTestCase {
    private func view() throws -> SelectionView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = SelectionView(image: try XCTUnwrap(context.makeImage()), frame: CGRect(x: 0, y: 0, width: 800, height: 600))
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

    private func delete(_ code: UInt16 = 51, in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: code == 51 ? "\u{7f}" : "\u{f728}",
                                          charactersIgnoringModifiers: code == 51 ? "\u{7f}" : "\u{f728}", isARepeat: false, keyCode: code)!)
    }

    @discardableResult
    private func addText(_ text: String, at point: CGPoint, in view: SelectionView) throws -> ImageAnnotation {
        try press("text", in: view)
        click(point, in: view)
        let editor = try control("annotation-text-input", in: view, as: AnnotationTextEditor.self)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.finish(commit: true)
        return try XCTUnwrap(view.annotations.last)
    }

    private func textPoint(_ annotation: ImageAnnotation, in view: SelectionView) -> CGPoint {
        CGPoint(x: view.selection.minX + annotation.textBounds.midX * view.bounds.width / CGFloat(view.image.width),
                y: view.selection.minY + annotation.textBounds.midY * view.bounds.height / CGFloat(view.image.height))
    }

    func testBackspaceAndForwardDeleteRemoveEveryKindOfSelectedMarkup() throws {
        for code in [UInt16(51), UInt16(117)] {
            for tool in AnnotationTool.allCases where tool != .mosaic {
                let view = try view()
                var finished = false
                view.onFinish = { _, _ in finished = true }
                let hit: CGPoint
                if tool == .text {
                    hit = textPoint(try addText("删除整条文字", at: CGPoint(x: 130, y: 110), in: view), in: view)
                } else {
                    try press(tool.rawValue, in: view)
                    drag(from: CGPoint(x: 130, y: 110), to: CGPoint(x: 350, y: 250), in: view)
                    switch tool {
                    case .rectangle: hit = CGPoint(x: 240, y: 110)
                    case .arrow: hit = CGPoint(x: 340, y: 250)
                    case .pen: hit = CGPoint(x: 240, y: 180)
                    case .mosaic: XCTFail("Mosaic is not selectable"); return
                    case .text: XCTFail("Text is created through its editor"); return
                    }
                }
                XCTAssertEqual(view.annotations.count, 1)
                let selection = view.selection
                click(hit, in: view)
                delete(code, in: view)
                XCTAssertTrue(view.annotations.isEmpty, "\(tool) must respond to key \(code)")
                XCTAssertEqual(view.selection, selection)
                XCTAssertFalse(finished, "Deleting markup must leave the capture session open")
            }
        }
    }

    func testDeletingMiddleAnnotationRestoresItsOriginalOrderWithOneUndo() throws {
        let view = try view()
        try press("rectangle", in: view)
        drag(from: CGPoint(x: 130, y: 110), to: CGPoint(x: 260, y: 210), in: view)
        try press("arrow", in: view)
        drag(from: CGPoint(x: 350, y: 110), to: CGPoint(x: 510, y: 210), in: view)
        try press("pen", in: view)
        drag(from: CGPoint(x: 140, y: 280), to: CGPoint(x: 280, y: 350), in: view)
        try addText("保留文字", at: CGPoint(x: 390, y: 290), in: view)
        let originals = view.annotations
        XCTAssertEqual(originals.count, 4)
        click(CGPoint(x: 430, y: 160), in: view)
        delete(in: view)
        XCTAssertEqual(view.annotations, [originals[0], originals[2], originals[3]])
        delete(117, in: view)
        XCTAssertEqual(view.annotations, [originals[0], originals[2], originals[3]], "A repeated delete must not select the next object")
        try press("undo", in: view)
        XCTAssertEqual(view.annotations, originals)
        try press("redo", in: view)
        XCTAssertEqual(view.annotations, [originals[0], originals[2], originals[3]])
        try press("undo", in: view)
        XCTAssertEqual(view.annotations, originals)
    }

    func testOverlappingPathsSelectOnlyTheTopmostMarkup() throws {
        let view = try view()
        try press("rectangle", in: view)
        drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 400, y: 250), in: view)
        let lower = try XCTUnwrap(view.annotations.first)
        try press("arrow", in: view)
        drag(from: CGPoint(x: 150, y: 100), to: CGPoint(x: 450, y: 200), in: view)
        XCTAssertEqual(view.annotations.count, 2)
        click(CGPoint(x: 300, y: 150), in: view)
        delete(in: view)
        XCTAssertEqual(view.annotations, [lower], "The arrow is above the rectangle at this crossing")
        click(CGPoint(x: 300, y: 150), in: view)
        delete(in: view)
        XCTAssertTrue(view.annotations.isEmpty)
    }

    func testEmptyRectangleInteriorDoesNotSelectOrCreateAnInvisibleMarkup() throws {
        let view = try view()
        delete(in: view)
        XCTAssertTrue(view.annotations.isEmpty)
        try press("rectangle", in: view)
        drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 400, y: 300), in: view)
        let original = try XCTUnwrap(view.annotations.first)
        click(CGPoint(x: 300, y: 225), in: view)
        delete(in: view)
        XCTAssertEqual(view.annotations, [original], "Only the rectangle's visible border is selectable")
        try press("undo", in: view)
        XCTAssertTrue(view.annotations.isEmpty, "A stationary interior click must not add an invisible annotation or history entry")
    }

    func testActiveTextEditorDeletesCharactersWithoutDeletingItsAnnotation() throws {
        let view = try view()
        let original = try addText("文字AB", at: CGPoint(x: 130, y: 110), in: view)
        click(textPoint(original, in: view), in: view, clicks: 2)
        let editor = try control("annotation-text-input", in: view, as: AnnotationTextEditor.self)
        delete(in: view)
        delete(117, in: view)
        XCTAssertEqual(view.annotations, [original], "The canvas must leave deletion to the active text editor")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "文字A")
        XCTAssertEqual(view.annotations, [original])
        editor.finish(commit: true)
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].text, "文字A")
        click(textPoint(view.annotations[0], in: view), in: view)
        delete(in: view)
        XCTAssertTrue(view.annotations.isEmpty)
    }

    func testToolbarBlankClickPreservesSelectedMarkupForKeyboardDeletion() throws {
        let view = try view()
        try press("rectangle", in: view)
        drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 400, y: 300), in: view)
        let selection = view.selection
        var finished = false
        view.onFinish = { _, _ in finished = true }
        click(CGPoint(x: 300, y: 150), in: view)
        let toolbar = try control("selection-toolbar", in: view, as: NSView.self)
        click(CGPoint(x: toolbar.frame.minX + 1, y: toolbar.frame.minY + 1), in: view)
        delete(in: view)
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertEqual(view.selection, selection)
        XCTAssertFalse(finished)
    }

    func testDeletingDuringTextDragCancelsPreviewAndMouseUpCannotRestoreIt() throws {
        let view = try view()
        let original = try addText("拖动中删除", at: CGPoint(x: 130, y: 110), in: view)
        let start = textPoint(original, in: view)
        let end = CGPoint(x: start.x + 80, y: start.y + 50)
        view.mouseDown(with: event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, at: end, in: view))
        XCTAssertEqual(view.annotations, [original])
        delete(in: view)
        XCTAssertTrue(view.annotations.isEmpty)
        view.mouseUp(with: event(.leftMouseUp, at: end, in: view))
        XCTAssertTrue(view.annotations.isEmpty, "The pending move must not resurrect a deleted annotation")
        try press("undo", in: view)
        XCTAssertEqual(view.annotations, [original], "One undo restores the committed position before the unfinished drag")
        try press("redo", in: view)
        XCTAssertTrue(view.annotations.isEmpty)
    }
}
