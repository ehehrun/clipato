import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class MCPSettingsInteractionTests: XCTestCase {
    func testMCPPressConfirmsExternalAccessAndCancelPreservesAuthorization() async throws {
        try requireNativeQA()
        let authorizationKeys = [MCPSettings.enabledKey, MCPSettings.serverEnabledKey,
                                 MCPSettings.allowTrashKey, MCPSettings.generationKey,
                                 MCPSettings.serverGenerationKey, "privacyMode"]
        func standardAuthorization() -> NSDictionary {
            NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: authorizationKeys.compactMap { key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            }))
        }
        let originalStandard = standardAuthorization()
        let fixture = try Fixture(masterEnabled: false, privacyMode: false)
        defer { fixture.close() }
        let originalFixture = NSDictionary(dictionary: fixture.defaults.dictionaryRepresentation())
        let toggle = try await mcpCheckbox(in: fixture, expectedCount: 2)
        XCTAssertTrue(toggle.isEnabled, "The MCP checkbox must remain clickable when the master permission is off")
        try click(toggle)
        try await wait("Pressing MCP must show the explicit external-access confirmation") {
            fixture.window.attachedSheet != nil
        }
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        XCTAssertTrue(descendants(NSTextField.self, in: content).contains { $0.stringValue == L("允许外部调用并启用 MCP？") })
        let cancel = try XCTUnwrap(descendants(NSButton.self, in: content).first { $0.title == L("取消") })
        cancel.performClick(nil)
        try await wait("Cancel must dismiss the permission confirmation") { fixture.window.attachedSheet == nil }
        XCTAssertEqual(NSDictionary(dictionary: fixture.defaults.dictionaryRepresentation()), originalFixture)
        XCTAssertEqual(standardAuthorization(), originalStandard, "Opening and canceling confirmation must not grant real authorization")
    }

    func testPrivacyDisablesMCPAndMasterPermissionAllowsDirectSelection() async throws {
        try requireNativeQA()
        let privateFixture = try Fixture(masterEnabled: false, privacyMode: true)
        defer { privateFixture.close() }
        let disabled = try await mcpCheckbox(in: privateFixture, expectedCount: 2)
        XCTAssertFalse(disabled.isEnabled)

        let permittedFixture = try Fixture(masterEnabled: true, privacyMode: false)
        defer { permittedFixture.close() }
        let enabled = try await mcpCheckbox(in: permittedFixture, expectedCount: 3)
        XCTAssertTrue(enabled.isEnabled)
    }

    private func requireNativeQA() throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_MCP_SETTINGS_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_MCP_SETTINGS_UI_QA=1 to exercise the transparent MCP settings fixture")
        }
    }

    private func mcpCheckbox(in fixture: Fixture, expectedCount: Int) async throws -> NSButton {
        try await wait("The settings checkboxes must materialize") {
            self.descendants(NSButton.self, in: fixture.host).count == expectedCount
        }
        // Hosted SwiftUI checkboxes expose native buttons without their accessibility identifiers.
        // MCP is the final checkbox after external access and its optional Trash permission.
        return try XCTUnwrap(descendants(NSButton.self, in: fixture.host).last)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result = (view as? T).map { [$0] } ?? []
        for child in view.subviews { result.append(contentsOf: descendants(type, in: child)) }
        return result
    }

    private func click(_ view: NSView) throws {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
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
        throw NSError(domain: "Clipato.MCPSettingsInteractionTests", code: 1)
    }

    @MainActor
    private final class Fixture {
        let suite = "Clipato.MCPSettingsInteraction.\(UUID().uuidString)"
        let defaults: UserDefaults
        let host: NSView
        let window: NSWindow
        let previousPolicy: NSApplication.ActivationPolicy

        init(masterEnabled: Bool, privacyMode: Bool) throws {
            let app = NSApplication.shared
            previousPolicy = app.activationPolicy()
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(masterEnabled, forKey: MCPSettings.enabledKey)
            defaults.set(false, forKey: MCPSettings.serverEnabledKey)
            host = NSHostingView(rootView: Form {
                MCPSettingsSection(privacyMode: privacyMode)
            }.formStyle(.grouped).defaultAppStorage(defaults))
            window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.animationBehavior = .none
            window.contentView = host
            window.orderFront(nil)
        }

        func close() {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            NSApp.setActivationPolicy(previousPolicy)
        }
    }
}
