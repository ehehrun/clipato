import AppKit
import QuartzCore
import XCTest
@testable import Clipato

@MainActor
final class SelectionRenderingTests: XCTestCase {
    func testQuadrantsAndSelectionHoleKeepSourceOrientationAtBothScales() throws {
        for scale in [1, 2] {
            try withSelection(scale: scale) { view, _ in
                let bitmap = try snapshot(view, scale: scale)
                let points = [CGPoint(x: 160, y: 120), CGPoint(x: 640, y: 120),
                              CGPoint(x: 160, y: 380), CGPoint(x: 640, y: 380)]
                for (point, color) in zip(points, Self.colors) {
                    try assertColor(color, shade: 0.6, at: point, in: bitmap, scale: scale)
                }
                try drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 720, y: 440), in: view)
                try renderLayers(view, to: bitmap)
                for (point, color) in zip(points, Self.colors) {
                    try assertColor(color, at: point, in: bitmap, scale: scale)
                }
                for (point, color) in zip([CGPoint(x: 30, y: 30), CGPoint(x: 770, y: 30),
                                          CGPoint(x: 30, y: 570), CGPoint(x: 770, y: 570)], Self.colors) {
                    try assertColor(color, shade: 0.6, at: point, in: bitmap, scale: scale)
                }
            }
        }
    }

    func testMovingSelectionClearsPreviousHoleAndRepeatedRedrawDoesNotAccumulateShade() throws {
        for scale in [1, 2] {
            try withSelection(scale: scale) { view, _ in
                try drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 350, y: 260), in: view)
                let bitmap = try snapshot(view, scale: scale)
                let overlay = try XCTUnwrap(find("selection-drawing-overlay", in: view))
                let overlayBitmap = try snapshot(overlay, scale: scale)
                let oldCenter = CGPoint(x: 200, y: 150), newCenter = CGPoint(x: 500, y: 370)
                try assertColor(Self.colors[0], at: oldCenter, in: bitmap, scale: scale)
                XCTAssertEqual(try pixel(oldCenter, in: overlayBitmap, scale: scale).alphaComponent, 0, accuracy: 0.01)

                try drag(from: oldCenter, to: newCenter, in: view)
                for _ in 0..<3 {
                    try renderLayers(overlay, to: overlayBitmap)
                    try renderLayers(view, to: bitmap)
                    try assertColor(Self.colors[0], shade: 0.6, at: oldCenter, in: bitmap, scale: scale)
                    try assertColor(Self.colors[3], at: newCenter, in: bitmap, scale: scale)
                    XCTAssertEqual(try pixel(oldCenter, in: overlayBitmap, scale: scale).alphaComponent, 0.4, accuracy: 0.01)
                    XCTAssertEqual(try pixel(newCenter, in: overlayBitmap, scale: scale).alphaComponent, 0, accuracy: 0.01)
                }
            }
        }
    }

    func testColorPickingUsesOriginalPixelsUnderTheTransparentOverlay() throws {
        for scale in [1, 2] {
            try withSelection(scale: scale) { view, _ in
                let points = [CGPoint(x: 160, y: 120), CGPoint(x: 640, y: 120),
                              CGPoint(x: 160, y: 380), CGPoint(x: 640, y: 380)]
                for (point, color) in zip(points, Self.colors) {
                    view.mouseMoved(with: try event(.mouseMoved, at: point, in: view))
                    _ = try snapshot(view, scale: scale)
                    XCTAssertEqual(view.currentColorValue, color.formatted(.hex))
                }
            }
        }
    }

    func testOverlayLetsSelectionToolbarAndTextReceiveTheirRealHitTests() throws {
        try withSelection { view, window in
            let overlay = try XCTUnwrap(find("selection-drawing-overlay", in: view))
            XCTAssertNil(overlay.hitTest(CGPoint(x: 760, y: 560)))
            XCTAssertTrue(view.hitTest(view.convert(CGPoint(x: 760, y: 560), to: view.superview)) === view)
            try drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 720, y: 440), in: view)
            view.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(find("text", in: view) as? NSButton)
            let buttonPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view.superview)
            let buttonHit = view.hitTest(buttonPoint)
            XCTAssertTrue(buttonHit === button || buttonHit?.isDescendant(of: button) == true)
            XCTAssertTrue(button.sendAction(try XCTUnwrap(button.action), to: button.target))
            view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 150, y: 130), in: view))
            let editor = try XCTUnwrap(find("annotation-text-input", in: view) as? AnnotationTextEditor)
            editor.insertText("Layered text", replacementRange: NSRange(location: NSNotFound, length: 0))
            let textPoint = editor.convert(CGPoint(x: 5, y: 5), to: view.superview)
            let textHit = view.hitTest(textPoint)
            XCTAssertTrue(textHit === editor || textHit?.isDescendant(of: editor) == true)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testPointerMovesLeaveCaptureAndShadeIntactWhileSelectionAndToolsInvalidateDrawing() throws {
        try withSelection { view, _ in
            let overlay = try XCTUnwrap(find("selection-drawing-overlay", in: view))
            _ = try snapshot(view, scale: 2)
            let background = try XCTUnwrap(view.layer!.contents as AnyObject?)
            XCTAssertTrue(view.wantsUpdateLayer)
            @MainActor func reset() {
                view.layoutSubtreeIfNeeded()
                view.needsDisplay = false
                overlay.needsDisplay = false
            }
            @MainActor func assertDynamicInvalidation(_ phase: String) {
                XCTAssertFalse(view.layer!.needsDisplay(), "Static capture layer invalidated by \(phase)")
                XCTAssertTrue((view.layer!.contents as AnyObject?) === background, "Captured image replaced by \(phase)")
                XCTAssertTrue(overlay.layer!.needsDisplay(), "Dynamic drawing must be invalidated by \(phase)")
            }
            reset()
            view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 40, y: 40), in: view))
            XCTAssertFalse(view.layer!.needsDisplay())
            XCTAssertFalse(overlay.layer!.needsDisplay(), "Hover must not repaint the full-screen shade")
            XCTAssertTrue(try XCTUnwrap(find("selection-magnifier", in: view)).layer!.needsDisplay())
            view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 60), in: view))
            reset()
            view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 720, y: 440), in: view))
            assertDynamicInvalidation("selection drag")
            view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 720, y: 440), in: view))
            reset()
            let rectangle = try XCTUnwrap(find("rectangle", in: view) as? NSButton)
            XCTAssertTrue(rectangle.sendAction(try XCTUnwrap(rectangle.action), to: rectangle.target))
            assertDynamicInvalidation("toolbar action")
        }
    }

    private func withSelection(scale: Int = 2, _ operation: (SelectionView, SelectionWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let pasteboard = NSPasteboard.withUniqueName()
        defer { originalCursor.set(); pasteboard.releaseGlobally() }
        let view = SelectionView(image: try fixture(scale: scale), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                 colorFormat: .hex, colorPasteboard: pasteboard, showsFullScreenCrosshair: false)
        let window = SelectionWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600))
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        try operation(view, window)
    }

    private func snapshot(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
                                                  pixelsHigh: Int(view.bounds.height) * scale,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        try renderLayers(view, to: bitmap)
        return bitmap
    }

    private func renderLayers(_ view: NSView, to bitmap: NSBitmapImageRep) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let layer = try XCTUnwrap(view.layer)
        displayLayers(layer)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(context.ctm.inverted())
        context.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                        y: -CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        layer.render(in: context)
    }

    private func displayLayers(_ layer: CALayer) {
        layer.displayIfNeeded()
        for child in layer.sublayers ?? [] { displayLayers(child) }
    }

    private func pixel(_ point: CGPoint, in bitmap: NSBitmapImageRep, scale: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(point.x) * scale, y: Int(point.y) * scale)?.usingColorSpace(.sRGB))
    }

    private func assertColor(_ expected: ScreenPixelColor, shade: CGFloat = 1, at point: CGPoint,
                             in bitmap: NSBitmapImageRep, scale: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try pixel(point, in: bitmap, scale: scale)
        XCTAssertEqual(color.redComponent, CGFloat(expected.r) / 255 * shade, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.greenComponent, CGFloat(expected.g) / 255 * shade, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.blueComponent, CGFloat(expected.b) / 255 * shade, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, file: file, line: line)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(from start: CGPoint, to end: CGPoint, in view: SelectionView) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: try event(.leftMouseUp, at: end, in: view))
        view.layoutSubtreeIfNeeded()
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let match = find(identifier, in: child) { return match }
        }
        return nil
    }

    private static let colors: [ScreenPixelColor] = [.init(r: 240, g: 40, b: 20), .init(r: 20, g: 230, b: 60),
                                                    .init(r: 30, g: 60, b: 240), .init(r: 240, g: 210, b: 30)]

    private func fixture(scale: Int) throws -> CGImage {
        let width = 800 * scale, height = 600 * scale
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = Self.colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                let offset = (y * width + x) * 4
                bytes[offset] = color.r
                bytes[offset + 1] = color.g
                bytes[offset + 2] = color.b
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
