import AppKit
import XCTest
@testable import Clipato

@MainActor
final class AnnotationTextEditingTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        return try XCTUnwrap(context.makeImage())
    }

    private func control<T: NSView>(_ id: String, in view: NSView, as type: T.Type) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        for child in view.subviews {
            if let result = control(id, in: child, as: type) { return result }
        }
        return nil
    }

    private func key(_ keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func click(_ point: CGPoint, in view: NSView) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                      windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
    }

    func testScreenshotTextUsesSourcePixelsAndToolbarCommitsBeforePin() async throws {
        _ = NSApplication.shared
        let view = SelectionView(image: try image(), frame: CGRect(x: 0, y: 0, width: 400, height: 300), initialFullScreen: true)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try XCTUnwrap(control("text", in: view, as: NSButton.self)).performClick(nil)
        click(CGPoint(x: 80, y: 60), in: view)
        let editor = try XCTUnwrap(control("annotation-text-input", in: view, as: AnnotationTextEditor.self))
        editor.insertText("中文标注\n第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.annotation.fontSize, 48)
        XCTAssertEqual(editor.annotation.points, [CGPoint(x: 160, y: 120)])
        let picker = try XCTUnwrap(control("annotation-font-size", in: view, as: NSPopUpButton.self))
        picker.selectItem(at: 4)
        picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(editor.annotation.fontSize, 64)
        try XCTUnwrap(control("color-4", in: view, as: NSButton.self)).performClick(nil)
        XCTAssertEqual(editor.annotation.color, .systemBlue)
        var finished = false
        view.onFinish = { rect, action in
            finished = true
            XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 800, height: 600))
            if case .pin = action {} else { XCTFail("Expected pin") }
        }
        try XCTUnwrap(control("pin", in: view, as: NSButton.self)).performClick(nil)
        XCTAssertTrue(finished)
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertEqual(view.annotations[0].text, "中文标注\n第二行")
        XCTAssertEqual(view.annotations[0].points, [CGPoint(x: 160, y: 120)])
        XCTAssertNil(control("annotation-text-input", in: view, as: AnnotationTextEditor.self))
    }

    func testReturnInsertsNewlineAndEscapeCancelsOnlyCurrentText() async throws {
        _ = NSApplication.shared
        let view = SelectionView(image: try image(), frame: CGRect(x: 0, y: 0, width: 400, height: 300), initialFullScreen: true)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var finished = false
        view.onFinish = { _, _ in finished = true }
        try XCTUnwrap(control("text", in: view, as: NSButton.self)).performClick(nil)
        click(CGPoint(x: 30, y: 30), in: view)
        let editor = try XCTUnwrap(control("annotation-text-input", in: view, as: AnnotationTextEditor.self))
        editor.insertText("第一行", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.performKeyEquivalent(with: key(36, characters: "\r")))
        XCTAssertEqual(editor.string, "第一行\n")
        XCTAssertFalse(finished)
        XCTAssertTrue(editor.performKeyEquivalent(with: key(53, characters: "\u{1b}")))
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertFalse(finished)
        view.keyDown(with: key(53, characters: "\u{1b}"))
        XCTAssertTrue(finished)
    }

    func testEscapeCancelsIMECompositionBeforeTextAndCapture() async throws {
        _ = NSApplication.shared
        let view = SelectionView(image: try image(), frame: CGRect(x: 0, y: 0, width: 400, height: 300), initialFullScreen: true)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let shortcuts = TextShortcutTarget()
        for key in ["\r", "\u{1b}"] {
            let button = NSButton(title: "Window action", target: shortcuts, action: #selector(TextShortcutTarget.invoke))
            button.keyEquivalent = key
            view.addSubview(button)
        }
        window.makeKeyAndOrderFront(nil)
        var finished = false
        view.onFinish = { _, _ in finished = true }
        try XCTUnwrap(control("text", in: view, as: NSButton.self)).performClick(nil)
        click(CGPoint(x: 40, y: 40), in: view)
        let editor = try XCTUnwrap(control("annotation-text-input", in: view, as: AnnotationTextEditor.self))
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        window.sendEvent(key(53, characters: "\u{1b}"))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "中文")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(finished)
        window.sendEvent(key(36, characters: "\r"))
        XCTAssertEqual(editor.string, "中文\n")
        window.sendEvent(key(53, characters: "\u{1b}"))
        XCTAssertNil(control("annotation-text-input", in: view, as: AnnotationTextEditor.self))
        XCTAssertFalse(finished)
        XCTAssertEqual(shortcuts.invocationCount, 0)
    }

    func testCommittedTextParticipatesInUndoAndRedo() async throws {
        _ = NSApplication.shared
        let view = SelectionView(image: try image(), frame: CGRect(x: 0, y: 0, width: 400, height: 300), initialFullScreen: true)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try XCTUnwrap(control("text", in: view, as: NSButton.self)).performClick(nil)
        click(CGPoint(x: 50, y: 40), in: view)
        let editor = try XCTUnwrap(control("annotation-text-input", in: view, as: AnnotationTextEditor.self))
        editor.insertText("原始像素", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.performKeyEquivalent(with: key(36, characters: "\r", flags: .command)))
        XCTAssertEqual(view.annotations.count, 1)
        try XCTUnwrap(control("undo", in: view, as: NSButton.self)).performClick(nil)
        XCTAssertTrue(view.annotations.isEmpty)
        try XCTUnwrap(control("redo", in: view, as: NSButton.self)).performClick(nil)
        XCTAssertEqual(view.annotations.map(\.text), ["原始像素"])
    }

    func testCanvasZoomDoesNotChangeTextPixelsAndPreviewCannotAnnotate() async throws {
        _ = NSApplication.shared
        let canvas = EditorImageCanvas(image: try image())
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        canvas.imageFrame = CGRect(x: 40, y: 30, width: 400, height: 300)
        canvas.imageScale = 0.5
        canvas.tool = .text
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.allowsAnnotation = false
        click(CGPoint(x: 90, y: 80), in: canvas)
        XCTAssertNil(control("annotation-text-input", in: canvas, as: AnnotationTextEditor.self))
        canvas.allowsAnnotation = true
        click(CGPoint(x: 90, y: 80), in: canvas)
        let editor = try XCTUnwrap(control("annotation-text-input", in: canvas, as: AnnotationTextEditor.self))
        editor.insertText("放大仍清晰", replacementRange: NSRange(location: NSNotFound, length: 0))
        let zoomField = NSTextField(frame: CGRect(x: 0, y: 0, width: 70, height: 24))
        canvas.addSubview(zoomField)
        window.makeFirstResponder(zoomField)
        XCTAssertFalse(editor.performKeyEquivalent(with: key(36, characters: "\r")))
        XCTAssertEqual(editor.string, "放大仍清晰")
        window.makeFirstResponder(editor)
        canvas.imageScale = 2
        canvas.layoutTextEditor()
        XCTAssertEqual(editor.frame.origin, CGPoint(x: 240, y: 230))
        XCTAssertEqual(editor.annotation.fontSize, 48)
        var saved: ImageAnnotation?
        canvas.onAnnotation = { saved = $0 }
        canvas.finishTextEditing()
        XCTAssertEqual(saved?.points, [CGPoint(x: 100, y: 100)])
        XCTAssertEqual(saved?.fontSize, 48)
        XCTAssertEqual(saved?.text, "放大仍清晰")
    }
}

@MainActor
private final class TextShortcutTarget: NSObject {
    var invocationCount = 0
    @objc func invoke(_ sender: Any?) { invocationCount += 1 }
}
