import AppKit
import Darwin

private final class QATestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@main
@MainActor
enum RecordingRegionQA {
    enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { switch self { case .check(let message): return message } }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("Recording-region QA timed out\n".utf8))
            Darwin.exit(1)
        }
        Task { @MainActor in
            do {
                try await verify()
                print("PASS: retained Retina selection, resize/move, explicit recording Start, inline annotation pixel/color/orientation, undo/redo, copy/save/pin, fullscreen/CLI completion, Esc/cancellation, toolbar placement, strict display selection, negative-screen coordinates, click-through green border, hide/reuse. No desktop capture or recording.")
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data(("Recording-region QA failed: " + error.localizedDescription + "\n").utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    static func mouse(_ type: NSEvent.EventType, point: CGPoint, view: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    static func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure.check("Cannot cache owned view")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    static func panel(_ overlay: RecordingRegionOverlay) throws -> NSPanel {
        let field = Mirror(reflecting: overlay).children.first(where: { $0.label == "window" })!.value
        guard let panel = Mirror(reflecting: field).children.first?.value as? NSPanel else {
            throw Failure.check("Visible overlay must own a panel")
        }
        return panel
    }

    static func verify() async throws {
        let context = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.18, green: 0.28, blue: 0.48, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        context.setFillColor(CGColor(red: 0.92, green: 0.38, blue: 0.23, alpha: 1))
        context.fill(CGRect(x: 60, y: 300, width: 350, height: 240))
        let image = context.makeImage()!
        let window = QATestWindow(contentRect: CGRect(x: 20, y: 20, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var results: [(CGRect?, ScreenshotAction)] = []
        func show(_ mode: SelectionView.Mode, fullScreen: Bool = false) -> SelectionView {
            let view = SelectionView(image: image, frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: mode, initialFullScreen: fullScreen)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            view.onFinish = { results.append(($0, $1)) }
            results.removeAll()
            return view
        }
        func drag(_ view: SelectionView, _ from: CGPoint, _ to: CGPoint) {
            view.mouseDown(with: mouse(.leftMouseDown, point: from, view: view, window: window))
            view.mouseDragged(with: mouse(.leftMouseDragged, point: to, view: view, window: window))
            view.mouseUp(with: mouse(.leftMouseUp, point: to, view: view, window: window))
        }
        func child(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            for subview in view.subviews { if let match = child(subview, id) { return match } }
            return nil
        }
        func click(_ view: SelectionView, _ id: String) throws {
            guard let button = child(view, id) as? NSButton else { throw Failure.check("Missing control: " + id) }
            try require(button.isEnabled, "Control must be enabled: " + id)
            button.performClick(nil)
        }
        let selection = show(.recording)
        let start = CGPoint(x: 10.25, y: 20.75), end = CGPoint(x: 200.10, y: 100.10)
        drag(selection, start, end)
        let expected = CGRect(x: 20, y: 41, width: 381, height: 160)
        try require(results.isEmpty && selection.pixelSelection == expected, "Mouse-up must retain the aligned Retina region without starting recording")
        try require(child(selection, "selection-toolbar")!.isHidden == false, "Mouse-up must expose confirmation toolbar")
        try click(selection, "start")
        try require(results.count == 1 && results[0].0 == expected, "Only the Start action may confirm recording")

        let reverse = show(.recording)
        drag(reverse, end, start)
        try require(results.isEmpty && reverse.pixelSelection == expected, "Reverse drag must retain the same aligned selection")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        try require(results.count == 1 && results[0].0 == nil, "Escape must cancel a retained selection")
        let clipped = show(.recording)
        drag(clipped, .zero, CGPoint(x: 900, y: 700))
        try require(clipped.pixelSelection == CGRect(x: 0, y: 0, width: 1600, height: 1200), "Drag beyond the screen must clip to image boundaries")
        try require(clipped.bounds.contains(child(clipped, "selection-toolbar")!.frame), "Full-screen selection toolbar must remain inside the screen")

        let resizeCases: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x: 50, y: 100), CGPoint(x: 30, y: 80), CGRect(x: 30, y: 80, width: 220, height: 180)),
            (CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 80), CGRect(x: 50, y: 80, width: 200, height: 180)),
            (CGPoint(x: 250, y: 100), CGPoint(x: 280, y: 80), CGRect(x: 50, y: 80, width: 230, height: 180)),
            (CGPoint(x: 250, y: 180), CGPoint(x: 280, y: 180), CGRect(x: 50, y: 100, width: 230, height: 160)),
            (CGPoint(x: 250, y: 260), CGPoint(x: 280, y: 290), CGRect(x: 50, y: 100, width: 230, height: 190)),
            (CGPoint(x: 150, y: 260), CGPoint(x: 150, y: 290), CGRect(x: 50, y: 100, width: 200, height: 190)),
            (CGPoint(x: 50, y: 260), CGPoint(x: 30, y: 290), CGRect(x: 30, y: 100, width: 220, height: 190)),
            (CGPoint(x: 50, y: 180), CGPoint(x: 30, y: 180), CGRect(x: 30, y: 100, width: 220, height: 160))
        ]
        for (index, entry) in resizeCases.enumerated() {
            let adjustable = show(.recording)
            drag(adjustable, CGPoint(x: 50, y: 100), CGPoint(x: 250, y: 260))
            drag(adjustable, entry.0, entry.1)
            try require(adjustable.selection == entry.2 && results.isEmpty, "Resize handle \(index) must adjust its edge while preserving a pending selection")
        }

        let screenshot = show(.screenshot(allowsDestinationActions: true))
        drag(screenshot, CGPoint(x: 50, y: 300), CGPoint(x: 300, y: 500))
        drag(screenshot, CGPoint(x: 300, y: 500), CGPoint(x: 350, y: 540))
        try require(screenshot.pixelSelection == CGRect(x: 100, y: 600, width: 600, height: 480), "Bottom-right handle must resize without changing origin")
        drag(screenshot, CGPoint(x: 100, y: 350), CGPoint(x: 120, y: 370))
        try require(screenshot.pixelSelection == CGRect(x: 140, y: 640, width: 600, height: 480), "Inside drag must move the selection and keep its dimensions")
        try require(results.isEmpty, "Adjusting selection must never complete screenshot")
        try require(screenshot.bounds.contains(child(screenshot, "selection-toolbar")!.frame), "Toolbar must fit above a selection close to the bottom edge")
        try click(screenshot, "rectangle")
        drag(screenshot, CGPoint(x: 220, y: 360), CGPoint(x: 310, y: 430))
        try require(screenshot.annotations.count == 1, "Rectangle drag must create one annotation")
        try click(screenshot, "undo")
        try require(screenshot.annotations.isEmpty, "Undo must remove annotation")
        try click(screenshot, "redo")
        try require(screenshot.annotations.count == 1, "Redo must restore annotation")
        try click(screenshot, "color")
        let palette = child(screenshot, "color-palette")!
        try require(!palette.isHidden && palette.window === screenshot.window && screenshot.bounds.contains(palette.frame), "Color palette must stay above the screenshot in the same owned window and within its screen")
        try click(screenshot, "color-4")
        try require(palette.isHidden, "Choosing a color must close its palette")
        try click(screenshot, "pen")
        drag(screenshot, CGPoint(x: 280, y: 490), CGPoint(x: 320, y: 490))
        try require(screenshot.annotations.count == 2, "Pen must add a stroke using the selected color")
        let rendered = try renderAnnotatedImage(image, crop: screenshot.pixelSelection, annotations: screenshot.annotations)
        try require(rendered.width == 600 && rendered.height == 480, "Output must keep the selected original pixel resolution")
        let pixels = NSBitmapImageRep(cgImage: rendered)
        let annotation = pixels.colorAt(x: 300, y: 100)!.usingColorSpace(.sRGB)!
        try require(annotation.redComponent > 0.8 && annotation.greenComponent < 0.5 && annotation.blueComponent < 0.5, "Rendered original-resolution annotation must have the chosen red color and correct local crop coordinates")
        let blueStroke = pixels.colorAt(x: 450, y: 340)!.usingColorSpace(.sRGB)!
        try require(blueStroke.blueComponent > 0.8 && blueStroke.redComponent < 0.3, "Selected inline palette color must affect actual rendered pen pixels")
        let unchanged = pixels.colorAt(x: 500, y: 400)!.usingColorSpace(.sRGB)!
        let source = NSBitmapImageRep(cgImage: image)
        let sourceBackground = source.colorAt(x: 640, y: 1040)!.usingColorSpace(.sRGB)!
        try require(abs(unchanged.blueComponent - sourceBackground.blueComponent) < 0.01, "Crop pixels outside annotations must preserve the original background")
        for point in [CGPoint(x: 20, y: 5), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 450)] {
            let original = source.colorAt(x: Int(point.x) + 140, y: Int(point.y) + 640)!.usingColorSpace(.sRGB)!
            let actual = pixels.colorAt(x: Int(point.x), y: Int(point.y))!.usingColorSpace(.sRGB)!
            try require(abs(original.redComponent - actual.redComponent) < 0.01 && abs(original.blueComponent - actual.blueComponent) < 0.01, "Crop must preserve top/bottom source orientation without selection shade, border or toolbar")
        }
        let bitmap = try render(screenshot)
        let destination = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : "/private/tmp/clipato-recording-region-qa.png"
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.check("Cannot encode owned selection PNG") }
        try png.write(to: URL(fileURLWithPath: destination))
        try click(screenshot, "copy")
        try require(results.count == 1 && results[0].0 == screenshot.pixelSelection && results[0].1 == .copy, "Copy must complete once with adjusted crop and action")
        try click(screenshot, "copy")
        try require(results.count == 1, "Double activation must not resume a completed request twice")

        for action in ["save", "pin"] {
            let full = show(.screenshot(allowsDestinationActions: true), fullScreen: true)
            try require(full.pixelSelection == CGRect(x: 0, y: 0, width: 1600, height: 1200), "Initial fullscreen mode must select the entire image")
            try click(full, action)
            try require(results.count == 1 && results[0].1 == (action == "save" ? .save : .pin), "Destination action must preserve its identity")
        }
        let commandLine = show(.screenshot(allowsDestinationActions: false), fullScreen: true)
        try require(child(commandLine, "save") == nil && child(commandLine, "pin") == nil && child(commandLine, "copy") != nil, "CLI toolbar must show one completion action and avoid GUI destination side effects")
        try click(commandLine, "color")
        try require(window.firstResponder === commandLine, "Palette buttons must leave keyboard focus on the selection")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(enter)
        try require(results.count == 1 && results[0].0 != nil, "Enter must confirm the retained CLI selection even when the palette is open")
        let paletteCancel = show(.screenshot(allowsDestinationActions: true), fullScreen: true)
        try click(paletteCancel, "color")
        window.sendEvent(escape)
        try require(results.count == 1 && results[0].0 == nil, "Escape must cancel even when the palette is open")

        let controller = ScreenshotController()
        let cancelled = Task { @MainActor in try await controller.selectRecordingRegion() }
        cancelled.cancel()
        try require(try await cancelled.value == nil, "A pre-cancelled request must not ask ScreenCaptureKit for desktop content")
        let invalidID = CGDirectDisplayID.max
        do {
            _ = try await controller.selectRecordingRegion(displayID: invalidID)
            throw Failure.check("Invalid display must fail before desktop capture")
        } catch is Failure { throw Failure.check("Invalid display was accepted") }
        catch { try require(error.localizedDescription.contains(String(invalidID)), "Invalid display must report the exact ID") }
        controller.cancelSelection()

        let negativeFrame = CGRect(x: -1600, y: -300, width: 1600, height: 1000)
        let secondary = RecordingRegion(displayID: 99, rect: CGRect(x: 25.5, y: 40, width: 200, height: 140))
        try require(secondary.appKitFrame(screenFrame: negativeFrame) == CGRect(x: -1574.5, y: 520, width: 200, height: 140), "Secondary negative-origin display must convert top-left points to AppKit coordinates")
        let screen = NSScreen.screens[0]
        for targetScreen in NSScreen.screens {
            let width = min(900, targetScreen.frame.width - 80, (targetScreen.frame.height - 80) * 4 / 3)
            let originalFrame = CGRect(x: targetScreen.frame.minX + 32 + 1 / targetScreen.backingScaleFactor, y: targetScreen.frame.minY + 40,
                                       width: width, height: width * 3 / 4)
            let pinned = controller.pin(image: image, frame: originalFrame)
            try require(pinned.isVisible && pinned.frame.size == originalFrame.size &&
                        abs(pinned.frame.minX - originalFrame.minX) < 1 && abs(pinned.frame.minY - originalFrame.minY) < 1,
                        "Pinning must retain the selection size and location within AppKit's whole-point window placement; expected \(originalFrame), got \(pinned.frame)")
            try require(pinned.contentView!.bounds.size == originalFrame.size, "Pinned content must fill the retained selection frame")
            pinned.close()
            try require(!pinned.isVisible, "Closing the pinned selection must remove its panel")
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let region = RecordingRegion(displayID: displayID, rect: CGRect(x: 100, y: 100, width: 240, height: 140))
        let overlay = RecordingRegionOverlay()
        defer { overlay.hide() }
        let previousKey = NSApp.keyWindow
        try overlay.show(region)
        let marker = try panel(overlay)
        try require(marker.isVisible && marker.frame == region.appKitFrame(screenFrame: screen.frame), "Marker must exactly match selected geometry")
        try require(marker.ignoresMouseEvents && !marker.canBecomeKey && !marker.canBecomeMain && NSApp.keyWindow === previousKey, "Marker must be click-through and must not take focus")
        try require(!marker.isOpaque && !marker.hasShadow && marker.backgroundColor!.alphaComponent == 0, "Marker interior must remain transparent")
        try require(marker.level == .screenSaver && marker.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]), "Marker must remain visible across Spaces and full-screen apps")
        try require(marker.animationBehavior == .none, "Marker must not animate")
        let border = try render(marker.contentView!)
        let borderDestination = URL(fileURLWithPath: destination).deletingPathExtension().path + "-border.png"
        guard let borderPNG = border.representation(using: .png, properties: [:]) else { throw Failure.check("Cannot encode owned border PNG") }
        try borderPNG.write(to: URL(fileURLWithPath: borderDestination))
        let edge = border.colorAt(x: 1, y: border.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        let center = border.colorAt(x: border.pixelsWide / 2, y: border.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        try require(edge.alphaComponent > 0.9 && edge.greenComponent > edge.redComponent && edge.greenComponent > edge.blueComponent, "Marker edge must be opaque green")
        try require(center.alphaComponent == 0, "Marker center must contain no captured desktop pixels")
        let resized = RecordingRegion(displayID: displayID, rect: CGRect(x: 120, y: 140, width: 300, height: 180))
        try overlay.show(resized)
        try require(try panel(overlay) === marker && marker.frame == resized.appKitFrame(screenFrame: screen.frame), "Showing a new region must reuse the marker with exact updated geometry")
        overlay.hide()
        try require(!marker.isVisible, "Hide must close the marker")
        print("Owned selection view PNG: " + destination)
        print("Owned marker view PNG: " + borderDestination)
    }
}
