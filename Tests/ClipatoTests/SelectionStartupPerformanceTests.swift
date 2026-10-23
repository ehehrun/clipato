import AppKit
import QuartzCore
import XCTest
@testable import Clipato

@MainActor
final class SelectionStartupPerformanceTests: XCTestCase {
    func testGenerated4KSelectionColdAndWarmInteractionPhases() throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_SELECTION_PERFORMANCE_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_SELECTION_PERFORMANCE_QA=1 and filter this test in a fresh process to measure native selection phases")
        }
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        if ProcessInfo.processInfo.environment["CLIPATO_SELECTION_SKIP_PREPARE"] != "1" {
            let pasteboardChange = NSPasteboard.general.changeCount
            let windows = Set(NSApplication.shared.windows.map(\.windowNumber))
            let preparation = measured { SelectionView.prepareInterface() }.milliseconds
            XCTAssertEqual(NSPasteboard.general.changeCount, pasteboardChange)
            XCTAssertEqual(Set(NSApplication.shared.windows.map(\.windowNumber)), windows)
            print("[SelectionPerformance] interface_prepare_ms=\(preparation)")
        }
        let image = try fixture()
        print("[SelectionPerformance] generated=3840x2160 view=1920x1080 rounds=3 hidden=true; first/toolbar/color snapshots include full view, pointer snapshots render retained crosshair+compact HUD, selection snapshots render drawing overlay; no screen capture, compositor latency or screen FPS")
        for round in 1...3 {
            try autoreleasepool {
                let pasteboard = NSPasteboard(name: .init("Clipato.SelectionPerformance.\(UUID().uuidString)"))
                defer { pasteboard.releaseGlobally() }
                let (view, initialization) = measured {
                    SelectionView(image: image, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  colorFormat: .hex, colorPasteboard: pasteboard, showsFullScreenCrosshair: true)
                }
                let (window, attachment) = measured {
                    let window = SelectionWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1920, height: 1080))
                    window.isReleasedWhenClosed = false
                    window.alphaValue = 0
                    window.animationBehavior = .none
                    window.ignoresMouseEvents = true
                    window.contentView = view
                    return window
                }
                defer {
                    view.onFinish = nil
                    view.onRenderError = nil
                    window.contentView = nil
                    window.close()
                }
                var metrics: [(String, Double)] = [("view_init", initialization), ("window_attach", attachment)]
                let firstMove = try event(.mouseMoved, point: CGPoint(x: 120, y: 100), view: view, window: window)
                metrics.append(("first_mouse_move", measured { view.mouseMoved(with: firstMove) }.milliseconds))
                XCTAssertNotNil(view.currentColorValue)

                let (bitmap, allocation) = try measured {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3840, pixelsHigh: 2160,
                                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                              isPlanar: false, colorSpaceName: .deviceRGB,
                                                              bytesPerRow: 0, bitsPerPixel: 0))
                    bitmap.size = view.bounds.size
                    return bitmap
                }
                metrics.append(("bitmap_allocate", allocation))
                metrics.append(("first_bitmap_draw", measured { redraw(view, bitmap: bitmap) }.milliseconds))
                let overlay = try XCTUnwrap(descendant("selection-drawing-overlay", in: view))
                let pointerOverlay = try XCTUnwrap(descendant("selection-pointer-overlay", in: view))

                var pointerHandlers = 0.0, pointerDraws = 0.0
                for index in 1...16 {
                    let movement = try event(.mouseMoved, point: CGPoint(x: 120 + index * 18, y: 100 + index * 8), view: view, window: window)
                    pointerHandlers += measured { view.mouseMoved(with: movement) }.milliseconds
                    pointerDraws += measured { redraw(pointerOverlay, bitmap: bitmap) }.milliseconds
                }
                metrics += [("pointer_16_handlers", pointerHandlers), ("pointer_16_overlay_draws", pointerDraws)]

                let start = CGPoint(x: 220, y: 180), end = CGPoint(x: 1450, y: 760)
                let down = try event(.leftMouseDown, point: start, view: view, window: window)
                metrics.append(("selection_mouse_down", measured { view.mouseDown(with: down) }.milliseconds))
                var dragHandlers = 0.0, dragDraws = 0.0
                for index in 1...16 {
                    let progress = CGFloat(index) / 16
                    let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
                    let drag = try event(.leftMouseDragged, point: point, view: view, window: window)
                    dragHandlers += measured { view.mouseDragged(with: drag) }.milliseconds
                    dragDraws += measured { redraw(overlay, bitmap: bitmap) }.milliseconds
                }
                metrics += [("selection_16_drag_handlers", dragHandlers), ("selection_16_drag_overlay_draws", dragDraws)]
                let up = try event(.leftMouseUp, point: end, view: view, window: window)
                metrics.append(("selection_mouse_up", measured { view.mouseUp(with: up) }.milliseconds))
                metrics.append(("first_toolbar_draw", measured { redraw(view, bitmap: bitmap) }.milliseconds))
                XCTAssertFalse(view.selection.isEmpty)
                XCTAssertFalse(try XCTUnwrap(descendant("selection-toolbar", in: view)).isHidden)

                let rectangle = try XCTUnwrap(descendant("rectangle", in: view) as? NSButton)
                metrics.append(("rectangle_tool_action", try measured { try activate(rectangle) }.milliseconds))
                metrics.append(("rectangle_tool_overlay_draw", measured { redraw(overlay, bitmap: bitmap) }.milliseconds))
                let annotationStart = try event(.leftMouseDown, point: CGPoint(x: 360, y: 260), view: view, window: window)
                let annotationDrag = try event(.leftMouseDragged, point: CGPoint(x: 980, y: 590), view: view, window: window)
                let annotationEnd = try event(.leftMouseUp, point: CGPoint(x: 980, y: 590), view: view, window: window)
                metrics.append(("first_annotation_handlers", measured {
                    view.mouseDown(with: annotationStart)
                    view.mouseDragged(with: annotationDrag)
                    view.mouseUp(with: annotationEnd)
                }.milliseconds))
                metrics.append(("first_annotation_overlay_draw", measured { redraw(overlay, bitmap: bitmap) }.milliseconds))
                XCTAssertEqual(view.annotations.count, 1)

                let color = try XCTUnwrap(descendant("color", in: view) as? NSButton)
                metrics.append(("first_color_action", try measured { try activate(color) }.milliseconds))
                metrics.append(("first_color_draw", measured { redraw(view, bitmap: bitmap) }.milliseconds))
                XCTAssertFalse(try XCTUnwrap(descendant("color-palette", in: view)).isHidden)
                XCTAssertFalse(window.isVisible, "Performance QA must not order its window onscreen")
                let output = metrics.map { name, value in
                    "\(name)_ms=" + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
                }.joined(separator: " ")
                print("[SelectionPerformance] round=\(round) \(output)")
            }
        }
    }

    private func measured<T>(_ operation: () throws -> T) rethrows -> (value: T, milliseconds: Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try operation()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private func redraw(_ view: NSView, bitmap: NSBitmapImageRep) {
        view.superview?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let layer = view.layer!
        displayLayers(layer)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
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

    private func event(_ type: NSEvent.EventType, point: CGPoint, view: SelectionView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func descendant(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = descendant(identifier, in: child) { return found }
        }
        return nil
    }

    private func activate(_ button: NSButton) throws {
        // Dispatch the real action without performClick's deliberate button animation delay.
        let action = try XCTUnwrap(button.action)
        XCTAssertTrue(button.sendAction(action, to: button.target))
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.12, green: 0.34, blue: 0.58, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        for index in 0..<12 {
            context.setFillColor(CGColor(red: CGFloat(index) / 12, green: 0.7, blue: 0.35, alpha: 1))
            context.fill(CGRect(x: index * 320, y: index * 90, width: 280, height: 900))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
