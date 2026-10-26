import AppKit
import QuartzCore
import XCTest
@testable import Clipato

@MainActor
final class SelectionPointerRenderingTests: XCTestCase {
    func testHoverAndColorKeysRedrawOnlyTheCompactMagnifier() throws {
        try withSelection { view, _, pasteboard in
            let shade = try XCTUnwrap(find("selection-drawing-overlay", in: view))
            let pointer = try XCTUnwrap(find("selection-pointer-overlay", in: view))
            let magnifier = try XCTUnwrap(find("selection-magnifier", in: view))
            move(CGPoint(x: 160, y: 120), in: view)
            _ = try snapshot(view, scale: 2)
            let background = try XCTUnwrap(view.layer!.contents as AnyObject?)
            let shadeContents = try XCTUnwrap(shade.layer!.contents as AnyObject?)
            XCTAssertTrue(pointer.wantsUpdateLayer)

            @MainActor func assertCompactRedraw(file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertFalse(view.layer!.needsDisplay(), file: file, line: line)
                XCTAssertFalse(shade.layer!.needsDisplay(), file: file, line: line)
                XCTAssertFalse(pointer.layer!.needsDisplay(), file: file, line: line)
                XCTAssertTrue(magnifier.layer!.needsDisplay(), file: file, line: line)
                XCTAssertTrue((view.layer!.contents as AnyObject?) === background, file: file, line: line)
                XCTAssertTrue((shade.layer!.contents as AnyObject?) === shadeContents, file: file, line: line)
            }

            for point in [CGPoint(x: 401.25, y: 301.75), CGPoint(x: 170, y: 130)] {
                move(point, in: view)
                assertCompactRedraw()
                let horizontal = try XCTUnwrap(pointer.layer!.sublayers?.first { $0.name == "selection-crosshair-horizontal" })
                let vertical = try XCTUnwrap(pointer.layer!.sublayers?.first { $0.name == "selection-crosshair-vertical" })
                XCTAssertEqual(horizontal.frame.midY, point.y, accuracy: 0.001)
                XCTAssertEqual(horizontal.frame.width, view.bounds.width)
                XCTAssertEqual(vertical.frame.midX, point.x, accuracy: 0.001)
                XCTAssertEqual(vertical.frame.height, view.bounds.height)
                _ = try snapshot(view, scale: 2)
            }

            key(48, characters: "\t", in: view)
            XCTAssertEqual(view.currentColorValue, "rgb(240, 40, 20)")
            assertCompactRedraw()
            _ = try snapshot(view, scale: 2)
            key(8, characters: "c", in: view)
            XCTAssertEqual(pasteboard.string(forType: .string), "rgb(240, 40, 20)")
            assertCompactRedraw()
        }
    }

    func testMagnifierKeepsOriginalPixelOrientationAndSwatchAtBothScales() throws {
        for scale in [1, 2] {
            try withSelection(scale: scale) { view, _, _ in
                move(CGPoint(x: 400, y: 300), in: view)
                let magnifier = try XCTUnwrap(find("selection-magnifier", in: view))
                let bitmap = try snapshot(magnifier, scale: scale)
                let previewX = (magnifier.bounds.width - 126) / 2
                let corners = [CGPoint(x: previewX + 24, y: 31), CGPoint(x: previewX + 102, y: 31),
                               CGPoint(x: previewX + 24, y: 109), CGPoint(x: previewX + 102, y: 109)]
                for (point, color) in zip(corners, Self.colors) {
                    try assertColor(color, at: point, in: bitmap, scale: scale)
                }
                try assertColor(.init(r: 190, g: 40, b: 220), at: CGPoint(x: previewX + 39, y: 58), in: bitmap, scale: scale)
                try assertColor(.init(r: 20, g: 200, b: 220), at: CGPoint(x: previewX + 87, y: 88), in: bitmap, scale: scale)
                XCTAssertEqual(view.currentColorValue, "#F0D21E")
                try assertColor(Self.colors[3], at: CGPoint(x: 19, y: 151), in: bitmap, scale: scale)
            }
        }
    }

    func testCrosshairIsCompositedAtThePointerRatherThanItsMirroredVerticalPosition() throws {
        for scale in [1, 2] {
            try withSelection(scale: scale) { view, _, _ in
                move(CGPoint(x: 160, y: 120), in: view)
                let bitmap = try snapshot(view, scale: scale)
                let horizontal = try [119.75, 120].map { try brightness(at: CGPoint(x: 80, y: $0), in: bitmap, scale: scale) }.max()!
                let vertical = try [159.75, 160].map { try brightness(at: CGPoint(x: $0, y: 60), in: bitmap, scale: scale) }.max()!
                XCTAssertGreaterThan(horizontal, try brightness(at: CGPoint(x: 80, y: 118), in: bitmap, scale: scale) + 0.08)
                XCTAssertGreaterThan(vertical, try brightness(at: CGPoint(x: 158, y: 60), in: bitmap, scale: scale) + 0.08)
                try assertColor(Self.colors[2], shade: 0.6, at: CGPoint(x: 80, y: 480), in: bitmap, scale: scale)

                if scale == 2, let output = ProcessInfo.processInfo.environment["CLIPATO_POINTER_RENDER_QA_OUTPUT"] {
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
                }
            }
        }
    }

    func testPointerCardClampsToEdgesAndNeverInterceptsSelectionHitTests() throws {
        try withSelection { view, window, _ in
            let pointer = try XCTUnwrap(find("selection-pointer-overlay", in: view))
            let magnifier = try XCTUnwrap(find("selection-magnifier", in: view))
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 799.75, y: 0),
                           CGPoint(x: 0, y: 599.75), CGPoint(x: 799.75, y: 599.75)]
            for (point, color) in zip(corners, Self.colors) {
                move(point, in: view)
                XCTAssertFalse(pointer.isHidden)
                XCTAssertGreaterThanOrEqual(magnifier.frame.minX, 12)
                XCTAssertGreaterThanOrEqual(magnifier.frame.minY, 12)
                XCTAssertLessThanOrEqual(magnifier.frame.maxX, view.bounds.maxX - 12)
                XCTAssertLessThanOrEqual(magnifier.frame.maxY, view.bounds.maxY - 12)
                XCTAssertEqual(view.currentColorValue, color.formatted(.hex))
                let bitmap = try snapshot(magnifier, scale: 2)
                try assertColor(color, at: CGPoint(x: 19, y: 151), in: bitmap, scale: 2)
                let cardCenter = CGPoint(x: magnifier.frame.midX, y: magnifier.frame.midY)
                XCTAssertNil(pointer.hitTest(cardCenter))
                XCTAssertNil(magnifier.hitTest(CGPoint(x: magnifier.bounds.midX, y: magnifier.bounds.midY)))
                XCTAssertTrue(view.hitTest(view.convert(cardCenter, to: view.superview)) === view)
            }
            view.mouseExited(with: try boundary(.mouseExited, at: CGPoint(x: 801, y: 300), in: view))
            XCTAssertTrue(pointer.isHidden)
            XCTAssertNil(view.currentColorValue)
            view.mouseEntered(with: try boundary(.mouseEntered, at: CGPoint(x: 400, y: 300), in: view))
            XCTAssertFalse(pointer.isHidden)
            XCTAssertEqual(view.currentColorValue, "#F0D21E")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testSelectionDragShrinksThenHidesTheCardAndRedrawsTheSelectionHole() throws {
        try withSelection { view, _, _ in
            let pointer = try XCTUnwrap(find("selection-pointer-overlay", in: view))
            let magnifier = try XCTUnwrap(find("selection-magnifier", in: view))
            let shade = try XCTUnwrap(find("selection-drawing-overlay", in: view))
            let start = CGPoint(x: 80, y: 60), end = CGPoint(x: 720, y: 440)
            move(start, in: view)
            XCTAssertEqual(magnifier.frame.height, 208)
            _ = try snapshot(view, scale: 2)
            view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: view))
            XCTAssertFalse(view.isColorPicking)
            XCTAssertNil(view.currentColorValue)
            XCTAssertFalse(pointer.isHidden)
            XCTAssertEqual(magnifier.frame.height, 160)
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, in: view))
            XCTAssertTrue(shade.layer!.needsDisplay())
            XCTAssertFalse(pointer.isHidden)
            XCTAssertEqual(magnifier.frame.height, 160)
            view.mouseUp(with: try mouse(.leftMouseUp, at: end, in: view))
            XCTAssertTrue(pointer.isHidden)
            XCTAssertEqual(view.selection, CGRect(x: 80, y: 60, width: 640, height: 380))
            let bitmap = try snapshot(view, scale: 2)
            try assertColor(Self.colors[0], at: CGPoint(x: 160, y: 120), in: bitmap, scale: 2)
            try assertColor(Self.colors[3], at: CGPoint(x: 640, y: 380), in: bitmap, scale: 2)
            try assertColor(Self.colors[3], shade: 0.6, at: CGPoint(x: 770, y: 570), in: bitmap, scale: 2)
            move(CGPoint(x: 40, y: 40), in: view)
            XCTAssertTrue(pointer.isHidden)
        }
    }

    func testDisablingFullScreenCrosshairKeepsMagnifierAndCancelHidesEverything() throws {
        try withSelection(showsCrosshair: false) { view, _, _ in
            move(CGPoint(x: 160, y: 120), in: view)
            let pointer = try XCTUnwrap(find("selection-pointer-overlay", in: view))
            let magnifier = try XCTUnwrap(find("selection-magnifier", in: view))
            XCTAssertFalse(pointer.isHidden)
            XCTAssertFalse(magnifier.isHidden)
            for name in ["selection-crosshair-horizontal", "selection-crosshair-vertical"] {
                let line = try XCTUnwrap(pointer.layer!.sublayers?.first { $0.name == name })
                XCTAssertTrue(line.isHidden)
            }
            let bitmap = try snapshot(view, scale: 2)
            try assertColor(Self.colors[0], shade: 0.6, at: CGPoint(x: 160, y: 60), in: bitmap, scale: 2)
            try assertColor(Self.colors[0], shade: 0.6, at: CGPoint(x: 80, y: 120), in: bitmap, scale: 2)
            var cancelled = false
            view.onFinish = { rect, _ in
                XCTAssertNil(rect)
                cancelled = true
            }
            key(53, characters: "\u{1B}", in: view)
            XCTAssertTrue(cancelled)
            XCTAssertTrue(pointer.isHidden)
            move(CGPoint(x: 640, y: 380), in: view)
            XCTAssertTrue(pointer.isHidden)
        }
    }

    func testLocalizedPointerTextSurvivesRepeatedMovementFormatChangesAndAutoreleasePools() throws {
        let settings = LanguageSettings.shared
        let originalLanguage = settings.language
        let originalResolvedLanguage = settings.resolvedLanguage
        let originalPreference = UserDefaults.standard.object(forKey: "language")
        defer {
            settings.setLanguage(originalLanguage, preferredLanguages: [originalResolvedLanguage.rawValue])
            if let originalPreference {
                UserDefaults.standard.set(originalPreference, forKey: "language")
            } else {
                UserDefaults.standard.removeObject(forKey: "language")
            }
        }
        try withSelection { view, window, pasteboard in
            let magnifier = try XCTUnwrap(find("selection-magnifier", in: view))
            let formats: [(ScreenshotColorFormat, String)] = [
                (.hex, "#F02814"), (.rgb, "rgb(240, 40, 20)"), (.hsl, "hsl(5.5, 88%, 51%)")
            ]
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 799.75, y: 0),
                           CGPoint(x: 799.75, y: 599.75), CGPoint(x: 0, y: 599.75)]
            for language in AppLanguage.allCases where language != .system {
                for (format, expected) in formats {
                    autoreleasepool {
                        settings.setLanguage(language)
                        for index in 0..<48 {
                            move(CGPoint(x: 80 + index * 4, y: 70 + index * 3), in: view)
                        }
                        XCTAssertEqual(view.colorFormat, format, language.rawValue)
                        XCTAssertEqual(view.currentColorValue, expected, language.rawValue)
                        key(8, characters: "c", in: view)
                        XCTAssertEqual(pasteboard.string(forType: .string), expected, language.rawValue)
                    }
                    // Draw only after temporary strings and fonts from the event phase have been released.
                    magnifier.needsDisplay = true
                    let bitmap = try snapshot(magnifier, scale: 2)
                    for band in [143..<162, 166..<183, 185..<205] {
                        var hasText = false
                        for y in stride(from: band.lowerBound, to: band.upperBound, by: 2) {
                            for x in stride(from: 34, to: Int(magnifier.bounds.width) - 8, by: 2) {
                                let color = try XCTUnwrap(bitmap.colorAt(x: x * 2, y: y * 2)?.usingColorSpace(.sRGB))
                                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.6 {
                                    hasText = true
                                    break
                                }
                            }
                            if hasText { break }
                        }
                        XCTAssertTrue(hasText, "Missing pointer text in \(band), \(language.rawValue), \(format)")
                    }
                    for point in corners {
                        autoreleasepool { move(point, in: view) }
                        magnifier.needsDisplay = true
                        _ = try snapshot(magnifier, scale: 2)
                        XCTAssertGreaterThanOrEqual(magnifier.frame.minX, 12)
                        XCTAssertGreaterThanOrEqual(magnifier.frame.minY, 12)
                        XCTAssertLessThanOrEqual(magnifier.frame.maxX, view.bounds.maxX - 12)
                        XCTAssertLessThanOrEqual(magnifier.frame.maxY, view.bounds.maxY - 12)
                    }
                    key(48, characters: "\t", in: view)
                }
            }
            XCTAssertTrue(view.selection.isEmpty)
            XCTAssertFalse(window.isVisible)
        }
    }

    private func withSelection(scale: Int = 2, showsCrosshair: Bool = true,
                               _ operation: (SelectionView, SelectionWindow, NSPasteboard) throws -> Void) throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let pasteboard = NSPasteboard.withUniqueName()
        defer { originalCursor.set(); pasteboard.releaseGlobally() }
        let view = SelectionView(image: try fixture(scale: scale), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                 colorFormat: .hex, colorPasteboard: pasteboard, showsFullScreenCrosshair: showsCrosshair)
        let window = SelectionWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600))
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        try operation(view, window, pasteboard)
    }

    private func snapshot(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let layer = try XCTUnwrap(view.layer)
        displayLayers(layer)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
                                                  pixelsHigh: Int(view.bounds.height) * scale,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.concatenate(context.ctm.inverted())
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                        y: -CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        layer.render(in: context)
        return bitmap
    }

    private func displayLayers(_ layer: CALayer) {
        layer.displayIfNeeded()
        for child in layer.sublayers ?? [] { displayLayers(child) }
    }

    private func assertColor(_ expected: ScreenPixelColor, shade: CGFloat = 1, at point: CGPoint,
                             in bitmap: NSBitmapImageRep, scale: Int,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * CGFloat(scale)), y: Int(point.y * CGFloat(scale)))?.usingColorSpace(.sRGB),
                                  file: file, line: line)
        XCTAssertEqual(color.redComponent, CGFloat(expected.r) / 255 * shade, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.greenComponent, CGFloat(expected.g) / 255 * shade, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.blueComponent, CGFloat(expected.b) / 255 * shade, accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, file: file, line: line)
    }

    private func brightness(at point: CGPoint, in bitmap: NSBitmapImageRep, scale: Int) throws -> CGFloat {
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * CGFloat(scale)), y: Int(point.y * CGFloat(scale)))?.usingColorSpace(.sRGB))
        return color.redComponent + color.greenComponent + color.blueComponent
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func boundary(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                           windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: 0, userData: nil))
    }

    private func move(_ point: CGPoint, in view: SelectionView) {
        view.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    private func key(_ code: UInt16, characters: String, in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: view.window!.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
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
        // Single source pixels distinguish a 21-pixel magnifier from one sampling 21 screen points.
        for (dx, dy, color) in [(-4, -2, ScreenPixelColor(r: 190, g: 40, b: 220)),
                                (4, 3, ScreenPixelColor(r: 20, g: 200, b: 220))] {
            let offset = ((height / 2 + dy) * width + width / 2 + dx) * 4
            bytes[offset] = color.r
            bytes[offset + 1] = color.g
            bytes[offset + 2] = color.b
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
