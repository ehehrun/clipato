import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class VaultLayoutTests: XCTestCase {
    func testFilteringToNoResultsKeepsConsoleHeaderAndSelectionBarAtTheWindowEdges() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_VAULT_LAYOUT_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_VAULT_LAYOUT_QA=1 to run a transparent native vault layout fixture")
        }
        let app = NSApplication.shared
        let oldPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let name = "Clipato.VaultLayout.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try XCTUnwrap(model.library)
        let host = NSHostingView(rootView: MainView(model: model).defaultAppStorage(defaults))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
            app.setActivationPolicy(oldPolicy)
        }

        func chromeIsAtWindowEdges() -> Bool {
            host.layoutSubtreeIfNeeded()
            guard let search = descendants(NSTextField.self, in: host).first(where: \.isEditable) else { return false }
            guard search.stringValue == model.query else { return false }
            let searchRect = search.convert(search.bounds, to: host)
            let distanceToTop = host.isFlipped ? searchRect.minY : host.bounds.maxY - searchRect.maxY
            let bottomMenus = descendants(NSButton.self, in: host).filter { button in
                let rect = button.convert(button.bounds, to: host)
                let distanceToBottom = host.isFlipped ? host.bounds.maxY - rect.maxY : rect.minY
                return distanceToBottom >= 0 && distanceToBottom < 48
            }
            return distanceToTop < 150 && bottomMenus.count >= 2
        }

        try await wait("An empty vault must keep its filter row at the top and selection menus at the bottom", until: chromeIsAtWindowEdges)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        _ = try library.addImage(XCTUnwrap(context.makeImage()), source: "Layout fixture", filename: "fixture.png")
        try await wait("A populated vault must keep the same top and bottom layout", until: chromeIsAtWindowEdges)

        model.query = "no-image-matches-this-query"
        for size in [CGSize(width: 1240, height: 800), CGSize(width: 1240, height: 1040), CGSize(width: 1080, height: 720)] {
            window.setContentSize(size)
            try await wait("Filtering to no results must fill the content pane at \(size)", until: chromeIsAtWindowEdges)
            XCTAssertEqual(window.alphaValue, 0)
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/clipato-vault-no-matches-layout.png"))
        model.query = ""
        try await wait("Clearing the filter must restore results without moving the console chrome", until: chromeIsAtWindowEdges)
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, in: $0) }
    }

    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            try await Task.sleep(for: .milliseconds(40))
        } while !condition() && Date() < deadline
        XCTAssertTrue(condition(), message)
    }
}
