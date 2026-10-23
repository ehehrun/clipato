import AppKit
import Darwin

@main
@MainActor
enum RecordingControlsQA {
    enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { switch self { case .check(let message): return message } }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    static func panel(_ overlay: RecordingRegionOverlay, field: String) throws -> NSPanel {
        let field = Mirror(reflecting: overlay).children.first(where: { $0.label == field })!.value
        guard let panel = Mirror(reflecting: field).children.first?.value as? NSPanel else {
            throw Failure.check("Overlay must retain its visible panel")
        }
        return panel
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            FileHandle.standardError.write(Data("Recording-controls QA timed out\n".utf8))
            Darwin.exit(1)
        }
        Task { @MainActor in
            do {
                try verify()
                print("PASS: recording toolbar visibility, edge positioning, live metrics, one-shot Stop, key-window preservation, click-through marker, hide/reuse. Only owned windows; no desktop capture.")
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data(("Recording-controls QA failed: " + error.localizedDescription + "\n").utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    static func verify() throws {
        let screen = NSScreen.screens[0]
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        let region = RecordingRegion(displayID: displayID, rect: CGRect(x: 100, y: 100, width: 480, height: 240))
        let overlay = RecordingRegionOverlay()
        defer { overlay.hide() }
        var stops = 0
        overlay.onStop = { stops += 1 }
        let previousKey = NSApp.keyWindow
        try overlay.show(region)
        let marker = try panel(overlay, field: "window")
        let toolbar = try panel(overlay, field: "controlsWindow")
        try require(marker.isVisible && toolbar.isVisible, "Both recording panels must be visible")
        try require(marker.ignoresMouseEvents && !toolbar.ignoresMouseEvents, "Only the toolbar may intercept the mouse")
        try require(!toolbar.canBecomeKey && !toolbar.canBecomeMain && NSApp.keyWindow === previousKey, "Toolbar must not take keyboard focus")
        try require(toolbar.level == .screenSaver && toolbar.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]), "Toolbar must follow the marker across Spaces and full-screen apps")
        try require(screen.visibleFrame.contains(toolbar.frame), "Toolbar must fit within the usable screen")
        let views = descendants(toolbar.contentView!)
        let button = views.compactMap { $0 as? NSButton }.first!
        let labels = views.compactMap { $0 as? NSTextField }
        try require(button.isEnabled && button.acceptsFirstMouse(for: nil), "Stop must work on the first click without activating the panel")
        overlay.update(elapsed: 3661, frameCount: 1234)
        try require(labels.contains(where: { $0.stringValue == "1:01:01 · 1234 帧" }), "Toolbar must display caller-supplied elapsed time and keyframe count")

        toolbar.contentView!.layoutSubtreeIfNeeded()
        let view = toolbar.contentView!
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let destination = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : "/private/tmp/clipato-recording-controls-qa.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
        print("Owned toolbar PNG: " + destination)

        button.performClick(nil)
        button.performClick(nil)
        try require(stops == 1 && !button.isEnabled, "Stop must call the handler exactly once and disable itself")
        overlay.update(elapsed: 3662, frameCount: 1235)
        try require(!button.isEnabled && labels.contains(where: { $0.stringValue == "正在保存…" }), "Final metric updates must not re-enable Stop")
        try overlay.show(region)
        try require(button.isEnabled && marker === panel(overlay, field: "window") && toolbar === panel(overlay, field: "controlsWindow"), "Showing another session must reset and reuse the panels")
        overlay.setStopping()
        button.performClick(nil)
        try require(stops == 1, "An external stop must also disable the toolbar action")
        overlay.hide()
        try require(!marker.isVisible && !toolbar.isVisible, "Hide must close both panels")
        try overlay.show(region)
        let freshToolbar = try panel(overlay, field: "controlsWindow")
        try require(freshToolbar !== toolbar, "Hide must release the toolbar before a new recording")
        let freshButton = descendants(freshToolbar.contentView!).compactMap { $0 as? NSButton }.first!
        freshButton.performClick(nil)
        try require(stops == 2, "The assigned Stop handler must remain usable across hide/show")

        let negativeScreen = CGRect(x: -1600, y: -300, width: 1600, height: 1000)
        for frame in [
            CGRect(x: -1600, y: -300, width: 50, height: 50),
            CGRect(x: -50, y: -300, width: 50, height: 50),
            CGRect(x: -1600, y: 650, width: 50, height: 50),
            CGRect(x: -50, y: 650, width: 50, height: 50),
            negativeScreen
        ] {
            try require(negativeScreen.contains(RecordingRegionOverlay.controlsFrame(for: frame, within: negativeScreen)), "Toolbar must remain on negative-origin displays at every edge")
        }
    }
}
