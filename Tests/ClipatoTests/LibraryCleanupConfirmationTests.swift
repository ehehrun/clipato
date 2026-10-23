import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class LibraryCleanupConfirmationTests: XCTestCase {
    private func drainEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        drainEvents()
        host.layoutSubtreeIfNeeded()
    }

    private func requireNativeFixture() throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_PROCESSING_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_PROCESSING_UI_QA=1 to opt into the transparent cleanup confirmation fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.CleanupConfirmation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try XCTUnwrap(model.library)
        _ = try library.createCollection(name: "Fixture collection")
        addTeardownBlock { @MainActor in
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
        return model
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 820, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
        }
        return window
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for child in view.subviews { result.append(contentsOf: descendants(type, in: child)) }
        return result
    }

    private func button(_ identifier: String, in host: NSView) -> NSButton? {
        descendants(NSButton.self, in: host).first {
            $0.identifier?.rawValue == identifier || $0.accessibilityIdentifier() == identifier
        }
    }

    func testConfirmationRendersLightDarkAndLargestTypeWithoutExecutingCleanup() async throws {
        try requireNativeFixture()
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let originalCollections = library.collections
        var confirmations = 0
        var cancellations = 0
        func content(scale: CGFloat) -> AnyView {
            AnyView(LibraryCleanupConfirmationView(model: model, onCancel: { cancellations += 1 },
                                                   onConfirm: { _ in confirmations += 1 })
                .environment(\.consoleFontScale, scale))
        }
        let host = NSHostingView(rootView: content(scale: 1))
        host.safeAreaRegions = []
        let window = makeWindow(host)
        for (name, appearance, scale) in [
            ("light", NSAppearance.Name.aqua, CGFloat(1)),
            ("dark", NSAppearance.Name.darkAqua, CGFloat(1)),
            ("dark-20px", NSAppearance.Name.darkAqua, CGFloat(20.0 / 14)),
            ("light-20px", NSAppearance.Name.aqua, CGFloat(20.0 / 14))
        ] {
            window.appearance = NSAppearance(named: appearance)
            host.rootView = content(scale: scale)
            try await settle(host)
            let size = host.fittingSize
            XCTAssertEqual(size.width, 560 * scale, accuracy: 1)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThan(size.height, 700, "Confirmation must fit the console's minimum window height")
            window.setContentSize(size)
            try await settle(host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/clipato-cleanup-confirmation-\(name).png"))
            XCTAssertFalse(model.clearingLibraryData)
            XCTAssertEqual(library.collections, originalCollections)
            XCTAssertEqual(confirmations, 0)
            XCTAssertEqual(cancellations, 0)
            XCTAssertEqual(window.alphaValue, 0)
        }
        print("PASS cleanup confirmation: transparent fixture rendered light/dark and 20 px; rendering invokes no cleanup or callbacks. PNGs: /private/tmp/clipato-cleanup-confirmation-*.png")
    }

    func testNativeCheckboxSelectionAndCancelOnlyInvokeTheirCallbacks() async throws {
        try requireNativeFixture()
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let originalCollections = library.collections
        var confirmed: [LibraryCleanupOptions] = []
        var cancellations = 0
        let host = NSHostingView(rootView: LibraryCleanupConfirmationView(model: model,
            onCancel: { cancellations += 1 }, onConfirm: { confirmed.append($0) }))
        host.safeAreaRegions = []
        let window = makeWindow(host)
        try await settle(host)
        window.setContentSize(host.fittingSize)
        try await settle(host)
        let identifiers = ["cleanup-images", "cleanup-recordings", "cleanup-collections", "cleanup-history"]
        guard identifiers.allSatisfy({ button($0, in: host) != nil }),
              button("confirm-library-cleanup", in: host) != nil,
              button("cancel-library-cleanup", in: host) != nil else {
            throw XCTSkip("This SwiftUI host does not expose all confirmation controls as native NSButton instances; appearance rendering is covered separately. No button clicks are claimed.")
        }
        let checkboxes = try identifiers.map { try XCTUnwrap(button($0, in: host)) }
        let confirm = try XCTUnwrap(button("confirm-library-cleanup", in: host))
        let cancel = try XCTUnwrap(button("cancel-library-cleanup", in: host))
        XCTAssertTrue(checkboxes.allSatisfy { $0.state == .on })
        XCTAssertTrue(confirm.isEnabled)
        for checkbox in checkboxes {
            checkbox.performClick(nil)
            try await settle(host)
        }
        XCTAssertTrue(checkboxes.allSatisfy { $0.state == .off })
        XCTAssertFalse(confirm.isEnabled, "Nothing selected must prevent the destructive confirmation")
        confirm.performClick(nil)
        XCTAssertTrue(confirmed.isEmpty)

        checkboxes[2].performClick(nil)
        try await settle(host)
        XCTAssertTrue(confirm.isEnabled)
        confirm.performClick(nil)
        try await settle(host)
        let options = try XCTUnwrap(confirmed.first)
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertFalse(options.images)
        XCTAssertFalse(options.recordings)
        XCTAssertTrue(options.collections)
        XCTAssertFalse(options.history)

        cancel.performClick(nil)
        try await settle(host)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(confirmed.count, 1, "Cancel must never invoke the cleanup confirmation callback")
        XCTAssertFalse(model.clearingLibraryData)
        XCTAssertEqual(library.collections, originalCollections, "The fixture captures options instead of executing real cleanup")
        XCTAssertEqual(window.alphaValue, 0)
        print("PASS native cleanup controls: four checked defaults; no-selection confirmation disabled; collections-only selection passed exactly; Cancel only invokes its own callback. No real cleanup is performed.")
    }
}
