import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class AITerminalSettingsTests: XCTestCase {
    func testNativeCapacityDraftEditingAndSaveValidation() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_LOG_CAPACITY_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_LOG_CAPACITY_UI_QA=1 to exercise the transparent settings fixture")
        }
        let app = NSApplication.shared
        let oldPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let suite = "Clipato.LogCapacity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defaults.set(20, forKey: MCPAccessLog.maximumMBKey)
        let log = MCPAccessLog(fileURL: root.appendingPathComponent("access.log"), defaults: defaults)
        let model = AppModel(root: root.appendingPathComponent("library"),
                             shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try XCTUnwrap(model.library)
        let host = NSHostingView(rootView: AITerminalSettingsView(model: model, accessLog: log, defaults: defaults)
            .defaultAppStorage(defaults))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 1200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
            app.setActivationPolicy(oldPolicy)
        }

        func field() -> NSTextField? {
            descendants(NSTextField.self, in: host).first { $0.isEditable }
        }
        try await wait("Capacity controls must materialize") { field() != nil }
        let input = try XCTUnwrap(field())
        XCTAssertEqual(input.stringValue, "20")
        XCTAssertGreaterThanOrEqual(input.frame.width, 80, "The form label must not consume part of the numeric field width")
        func edit(_ text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(input))
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        try edit("2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(MCPAccessLog.maximumMB(in: defaults), 20, "Typing must not save or prune logs")
        host.layoutSubtreeIfNeeded()
        let inputFrame = input.convert(input.bounds, to: host)
        func render(_ state: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/clipato-log-capacity-\(state).png"))
        }
        try render("draft")
        func clickSave() throws {
            // SwiftUI's bordered button is drawn, not exposed as an NSButton in this native host.
            // Its center is 73 points after the adjacent 90-point numeric input in this fixed-size fixture.
            let point = host.convert(CGPoint(x: inputFrame.maxX + 73, y: inputFrame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                           windowNumber: window.windowNumber, context: nil,
                                                           eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        try clickSave()
        try await wait("Save must persist the edited number") { MCPAccessLog.maximumMB(in: defaults) == 2 }
        try await wait("The input must resume after saving") { input.isEnabled }
        try render("saved")
        try edit("3")
        try await Task.sleep(for: .milliseconds(100))
        try render("edited")
        for invalid in ["", "0", "1025", "2.5", "invalid"] {
            try edit(invalid)
            try await Task.sleep(for: .milliseconds(50))
            try clickSave()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(MCPAccessLog.maximumMB(in: defaults), 2)
        }
        try edit("1024")
        try await Task.sleep(for: .milliseconds(100))
        try clickSave()
        try await wait("The largest valid capacity must save") { MCPAccessLog.maximumMB(in: defaults) == 1024 }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result = (view as? T).map { [$0] } ?? []
        for child in view.subviews { result.append(contentsOf: descendants(type, in: child)) }
        return result
    }

    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 3)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail(message)
        throw NSError(domain: "Clipato.LogCapacityTests", code: 1)
    }
}
