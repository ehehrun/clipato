import AppKit
import Carbon
import XCTest
@testable import Clipato

@MainActor
final class ShortcutTests: XCTestCase {
    func testFirstLaunchDefaultsDoNotRegisterGlobalKeys() throws {
        let defaults = isolatedDefaults()
        let manager = ShortcutManager(defaults: defaults)
        XCTAssertEqual(manager.bindings[.captureRegion]?.displayName, "F1")
        XCTAssertEqual(manager.bindings[.pinLatest]?.displayName, "F2")
        XCTAssertEqual(manager.bindings[.toggleRecording]?.displayName, "F3")
        XCTAssertEqual(manager.bindings[.fixedCapture]?.displayName, "F4")
        XCTAssertEqual(manager.bindings[.togglePinnedMousePassthrough]?.displayName, "F5")
        XCTAssertNil(manager.bindings[.captureDisplay])
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(manager.errors.isEmpty)
        XCTAssertNil(defaults.data(forKey: "FrameVault.shortcuts"))
    }

    func testClearedBindingsStayClearedAcrossRestartIncludingEmptyDictionary() throws {
        let defaults = isolatedDefaults()
        let manager = ShortcutManager(defaults: defaults)
        try manager.setShortcut(nil, for: .captureRegion)
        let restarted = ShortcutManager(defaults: defaults)
        XCTAssertNil(restarted.bindings[.captureRegion])
        XCTAssertEqual(restarted.bindings[.pinLatest]?.displayName, "F2")
        for action in ShortcutAction.allCases { try manager.setShortcut(nil, for: action) }
        XCTAssertNotNil(defaults.data(forKey: "FrameVault.shortcuts"))
        XCTAssertTrue(ShortcutManager(defaults: defaults).bindings.isEmpty)
    }

    func testDuplicateModificationPreservesPreviousBindingAndPersistence() throws {
        let defaults = isolatedDefaults()
        let manager = ShortcutManager(defaults: defaults)
        let before = manager.bindings
        XCTAssertThrowsError(try manager.setShortcut(before[.captureRegion], for: .pinLatest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("截取区域"))
        }
        XCTAssertEqual(manager.bindings, before)
        XCTAssertTrue(manager.errors.isEmpty)
        XCTAssertEqual(ShortcutManager(defaults: defaults).bindings, before)
    }

    func testPersistenceKeepsOnlyNativeKeyFieldsAndRecreatesDisplayName() throws {
        let defaults = isolatedDefaults()
        let manager = ShortcutManager(defaults: defaults)
        let shortcut = try GlobalShortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(cmdKey | controlKey))
        try manager.setShortcut(shortcut, for: .captureDisplay)
        let data = try XCTUnwrap(defaults.data(forKey: "FrameVault.shortcuts"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("displayName"))
        XCTAssertTrue(json.contains("keyCode"))
        XCTAssertTrue(json.contains("modifiers"))
        let restarted = ShortcutManager(defaults: defaults)
        XCTAssertEqual(restarted.bindings[.captureDisplay], shortcut)
        XCTAssertEqual(restarted.bindings[.captureDisplay]?.displayName, "⌃⌘F18")
    }

    func testDisabledStateSurvivesEditingAndRestartAndRestoreDefaults() throws {
        let defaults = isolatedDefaults()
        let manager = ShortcutManager(defaults: defaults)
        manager.setEnabled(false)
        manager.beginRecording(.captureRegion)
        XCTAssertEqual(manager.recordingAction, .captureRegion)
        try manager.setShortcut(try GlobalShortcut(keyCode: UInt32(kVK_F20), modifiers: 0), for: .captureRegion)
        manager.endRecording()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNil(manager.recordingAction)
        XCTAssertEqual(ShortcutManager(defaults: defaults).bindings[.captureRegion]?.displayName, "F20")
        XCTAssertFalse(ShortcutManager(defaults: defaults).isEnabled)
        try manager.restoreDefaults()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.bindings[.captureRegion]?.displayName, "F1")
        XCTAssertEqual(manager.bindings[.togglePinnedMousePassthrough]?.displayName, "F5")
        XCTAssertNil(manager.bindings[.captureDisplay])
    }

    func testSavedBindingsDoNotAcquireOrStealTheNewPassthroughShortcut() throws {
        let defaults = isolatedDefaults()
        let original = [ShortcutAction.captureRegion: try GlobalShortcut(keyCode: UInt32(kVK_F5), modifiers: 0)]
        let data = try JSONEncoder().encode(original)
        defaults.set(data, forKey: "FrameVault.shortcuts")
        defaults.set(true, forKey: "FrameVault.fixedCaptureShortcutAdded")

        let manager = ShortcutManager(defaults: defaults)

        XCTAssertEqual(manager.bindings, original)
        XCTAssertNil(manager.bindings[.togglePinnedMousePassthrough])
        XCTAssertEqual(defaults.data(forKey: "FrameVault.shortcuts"), data)
        XCTAssertTrue(manager.errors.isEmpty)
    }

    func testPassthroughBindingCanBeCustomizedAndClearedWithoutChangingOtherBindings() throws {
        let defaults = isolatedDefaults()
        let manager = ShortcutManager(defaults: defaults)
        let previous = manager.bindings
        XCTAssertThrowsError(try manager.setShortcut(previous[.captureRegion], for: .togglePinnedMousePassthrough))
        XCTAssertEqual(manager.bindings, previous)
        let custom = try GlobalShortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(optionKey))

        try manager.setShortcut(custom, for: .togglePinnedMousePassthrough)
        XCTAssertEqual(ShortcutManager(defaults: defaults).bindings[.togglePinnedMousePassthrough], custom)
        try manager.setShortcut(nil, for: .togglePinnedMousePassthrough)
        let restarted = ShortcutManager(defaults: defaults)
        XCTAssertNil(restarted.bindings[.togglePinnedMousePassthrough])
        XCTAssertEqual(restarted.bindings, previous.filter { $0.key != .togglePinnedMousePassthrough })
    }

    func testMalformedAndDuplicateStoredBindingsAreReportedWithoutDefaults() throws {
        for data in [Data("broken".utf8), try JSONEncoder().encode([
            ShortcutAction.captureRegion: GlobalShortcut(keyCode: UInt32(kVK_F1), modifiers: 0),
            ShortcutAction.pinLatest: GlobalShortcut(keyCode: UInt32(kVK_F1), modifiers: 0)
        ])] {
            let defaults = isolatedDefaults()
            defaults.set(data, forKey: "FrameVault.shortcuts")
            let manager = ShortcutManager(defaults: defaults)
            XCTAssertTrue(manager.bindings.isEmpty)
            XCTAssertEqual(manager.errors.count, ShortcutAction.allCases.count)
            XCTAssertTrue(manager.errors.values.allSatisfy { $0.contains("读取快捷键失败") })
            XCTAssertEqual(defaults.data(forKey: "FrameVault.shortcuts"), data)
        }
    }

    func testFunctionEventIgnoresFnAndMapsOnlyFourPrimaryModifiers() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.function, .capsLock, .numericPad, .command, .option, .control, .shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_F4)))
        let shortcut = try GlobalShortcut.from(event: event)
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | optionKey | controlKey | shiftKey))
        XCTAssertEqual(shortcut.displayName, "⌃⌥⇧⌘F4")
        let bareFunction = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.function], timestamp: 0, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_F1)))
        XCTAssertEqual(try GlobalShortcut.from(event: bareFunction).displayName, "F1")
    }

    func testBareCharacterModifierOnlyAndInvalidCodesAreRejected() throws {
        XCTAssertThrowsError(try GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0))
        XCTAssertThrowsError(try GlobalShortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)))
        XCTAssertThrowsError(try GlobalShortcut(keyCode: 128, modifiers: UInt32(cmdKey)))
        XCTAssertThrowsError(try GlobalShortcut(keyCode: UInt32(kVK_F1), modifiers: UInt32(alphaLock)))
        let shortcut = try GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey))
        XCTAssertEqual(shortcut.displayName, "⌘←")
    }

    func testDecodeRevalidatesNativeFieldsAndIgnoresObsoleteDisplayLabel() throws {
        let data = Data("{\"keyCode\":122,\"modifiers\":0,\"displayName\":\"wrong\"}".utf8)
        let shortcut = try JSONDecoder().decode(GlobalShortcut.self, from: data)
        XCTAssertEqual(shortcut.displayName, "F1")
        XCTAssertEqual(shortcut, try GlobalShortcut(keyCode: UInt32(kVK_F1), modifiers: 0))
        XCTAssertThrowsError(try JSONDecoder().decode(GlobalShortcut.self,
            from: Data("{\"keyCode\":0,\"modifiers\":0}".utf8)))
    }

    func testRejectedDraftDoesNotReplaceActualRegistrationErrors() throws {
        let manager = ShortcutManager(defaults: isolatedDefaults())
        manager.beginRecording(.captureDisplay)
        XCTAssertThrowsError(try manager.setShortcut(manager.bindings[.captureRegion], for: .captureDisplay))
        XCTAssertNil(manager.errors[.captureDisplay])
        manager.endRecording()
        XCTAssertNil(manager.errors[.captureDisplay])
        XCTAssertNil(manager.bindings[.captureDisplay])

        let defaults = isolatedDefaults()
        defaults.set(Data("broken".utf8), forKey: "FrameVault.shortcuts")
        let corrupted = ShortcutManager(defaults: defaults)
        let errors = corrupted.errors
        corrupted.beginRecording(.captureRegion)
        corrupted.endRecording()
        XCTAssertEqual(corrupted.errors, errors)
    }

    func testFixedCaptureMigrationPreservesExistingBindingsAndClearedChoice() throws {
        let defaults = isolatedDefaults()
        let original = [ShortcutAction.captureRegion: try GlobalShortcut(keyCode: UInt32(kVK_F9), modifiers: 0)]
        defaults.set(try JSONEncoder().encode(original), forKey: "FrameVault.shortcuts")
        let manager = ShortcutManager(defaults: defaults)
        XCTAssertEqual(manager.bindings[.captureRegion], original[.captureRegion])
        XCTAssertEqual(manager.bindings[.fixedCapture]?.displayName, "F4")
        try manager.setShortcut(nil, for: .fixedCapture)
        XCTAssertNil(ShortcutManager(defaults: defaults).bindings[.fixedCapture])
    }

    func testFixedCaptureMigrationDoesNotStealF4FromExistingAction() throws {
        let defaults = isolatedDefaults()
        let original = [ShortcutAction.captureRegion: try GlobalShortcut(keyCode: UInt32(kVK_F4), modifiers: 0)]
        defaults.set(try JSONEncoder().encode(original), forKey: "FrameVault.shortcuts")
        XCTAssertEqual(ShortcutManager(defaults: defaults).bindings, original)
        XCTAssertTrue(ShortcutManager(defaults: defaults).errors.isEmpty)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "Clipato.ShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
