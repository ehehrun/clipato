import AppKit
import XCTest
@testable import Clipato

@MainActor
final class PermissionConsoleForegroundTests: XCTestCase {
    func testPermissionConsoleActivatesFromAnotherAppAndReusesAMinimizedWindow() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_PERMISSION_FOREGROUND_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_PERMISSION_FOREGROUND_QA=1 to opt into temporary foreground activation with a transparent console")
        }
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let previousApplication = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        try XCTSkipIf(previousApplication.processIdentifier == processIdentifier,
                      "Start this test while another application is in the foreground")

        let app = NSApplication.shared
        let previousActivationPolicy = app.activationPolicy()
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        let name = "Clipato.PermissionConsoleForegroundTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
        var consoles: [ConsoleWindow] = []
        let keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                               object: nil, queue: nil) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? ConsoleWindow,
                      !existingWindows.contains(ObjectIdentifier(window)) else { return }
                window.alphaValue = 0
                window.animationBehavior = .none
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                if !consoles.contains(where: { $0 === window }) { consoles.append(window) }
            }
        }
        addTeardownBlock { @MainActor in
            NotificationCenter.default.removeObserver(keyObserver)
            for window in app.windows where window is ConsoleWindow && !existingWindows.contains(ObjectIdentifier(window)) {
                window.delegate = nil
                window.contentView = nil
                window.orderOut(nil)
                window.close()
            }
            app.setActivationPolicy(previousActivationPolicy)
            XCTAssertTrue(previousApplication.activate(options: []))
            try await self.wait("The previous foreground application was not restored") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier
            }
        }

        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        _ = try XCTUnwrap(model.library)
        XCTAssertNil(model.errorMessage)
        model.section = .security
        let delegate = ClipatoDelegate(model: model)

        // Do not install the delegate: launching it would register shortcuts and create the status menu.
        XCTAssertTrue(previousApplication.activate(options: []))
        try await wait("Another application must be active before opening permission guidance") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier
        }
        delegate.showConsoleWindow()
        try await wait("Permission guidance did not bring its console and application to the foreground") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
                && app.isActive && consoles.count == 1 && app.keyWindow === consoles[0] && consoles[0].isVisible
        }
        let console = try XCTUnwrap(consoles.first)
        XCTAssertEqual(console.alphaValue, 0)
        XCTAssertEqual(console.level, .normal)
        XCTAssertFalse(console.isMiniaturized)
        XCTAssertNil(console.attachedSheet)
        XCTAssertNil(app.modalWindow)
        XCTAssertEqual(app.windows.filter { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) }.count, 1)

        console.miniaturize(nil)
        try await wait("The console did not enter its minimized state") { console.isMiniaturized }
        XCTAssertTrue(previousApplication.activate(options: []))
        try await wait("Another application must be active before restoring permission guidance") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApplication.processIdentifier
        }
        delegate.showConsoleWindow()
        try await wait("Permission guidance did not restore its existing minimized console to the foreground") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
                && app.isActive && app.keyWindow === console && console.isVisible && !console.isMiniaturized
        }
        XCTAssertEqual(consoles.count, 1, "Repeated permission guidance must reuse the original console")
        XCTAssertTrue(consoles.first === console)
        XCTAssertEqual(console.alphaValue, 0)
        XCTAssertEqual(console.level, .normal)
        XCTAssertNil(console.attachedSheet)
        XCTAssertNil(app.modalWindow)
        XCTAssertEqual(app.windows.filter { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) }.count, 1)
        XCTAssertFalse(model.capturing)
        XCTAssertFalse(model.recordingBusy)
        XCTAssertTrue(try XCTUnwrap(model.library).images.isEmpty)
        print("PASS transparent native permission console: foreground activation, key status, minimized-window reuse and no additional modal window; no screen capture or permission request")
    }

    private func drainApplicationEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private func wait(_ message: String, timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            drainApplicationEvents()
            try await Task.sleep(for: .milliseconds(20))
        }
        drainApplicationEvents()
        guard condition() else {
            XCTFail(message)
            throw NSError(domain: "PermissionConsoleForegroundTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
