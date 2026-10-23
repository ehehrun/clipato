import AppKit
import XCTest
@testable import Clipato

@MainActor
final class CaptureWindowTests: XCTestCase {
    func testSelectionPanelAcceptsTextWithoutBecomingMainWindow() throws {
        _ = NSApplication.shared
        let panel = SelectionWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        try enterText(in: panel)
        XCTAssertFalse(panel.isVisible)
    }

    func testCaptureWorkspaceUsesIndependentWindowBehaviorForMissionControl() throws {
        _ = NSApplication.shared
        let window: NSWindow = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertFalse(window is NSPanel)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.styleMask.contains([.titled, .closable, .resizable, .miniaturizable]))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain, "An offscreen window must not become the app's main window.")
        XCTAssertTrue(window.collectionBehavior.contains([.managed, .primary, .participatesInCycle]))
        XCTAssertTrue(window.collectionBehavior.intersection([.transient, .stationary, .ignoresCycle, .canJoinAllSpaces]).isEmpty)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(window.level, .normal)
        try enterText(in: window)
        XCTAssertFalse(window.isVisible)
    }

    func testEscapeConsultsCloseDelegateAndHonorsUnsavedWorkRefusal() throws {
        _ = NSApplication.shared
        let panel = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        panel.isReleasedWhenClosed = false
        let delegate = CaptureWindowCloseDelegate()
        panel.delegate = delegate
        defer {
            panel.delegate = nil
            panel.close()
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))

        panel.keyDown(with: escape)
        XCTAssertEqual(delegate.closeRequests, 1)
        XCTAssertEqual(delegate.closedWindows, 0)

        delegate.allowsClose = true
        panel.keyDown(with: escape)
        XCTAssertEqual(delegate.closeRequests, 2)
        XCTAssertEqual(delegate.closedWindows, 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testSpacePreviewShortcutLeavesTextEditorInputAndFocusUntouched() throws {
        _ = NSApplication.shared
        let window = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var previewRequests = 0
        window.onSpace = { previewRequests += 1; return true }
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        editor.string = "two"
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))

        window.sendEvent(space)

        XCTAssertEqual(editor.string, "two ")
        XCTAssertEqual(previewRequests, 0)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(window.isVisible)
    }

    func testEscapePreservesActiveProcessingRouteAndNormalCloseStillConsultsDelegate() throws {
        _ = NSApplication.shared
        let window = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.isReleasedWhenClosed = false
        let delegate = CaptureWindowCloseDelegate()
        window.delegate = delegate
        var processingRouteIsActive = true
        window.onEscape = { processingRouteIsActive }
        defer {
            window.delegate = nil
            window.close()
        }

        window.cancelOperation(nil)
        XCTAssertEqual(delegate.closeRequests, 0)
        window.performClose(nil)
        XCTAssertEqual(delegate.closeRequests, 1, "The native close button must still reach the close delegate")
        processingRouteIsActive = false
        window.cancelOperation(nil)
        XCTAssertEqual(delegate.closeRequests, 2, "Escape retains its normal behavior outside an active tool")
    }

    func testSpacePreviewShortcutOnlyHandlesUnmodifiedInitialPress() throws {
        _ = NSApplication.shared
        let window = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var previewRequests = 0
        window.onSpace = { previewRequests += 1; return true }

        let modifiers: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
        for modifier in modifiers {
            let modified = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier, timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, characters: " ",
                                                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            window.keyDown(with: modified)
        }
        XCTAssertEqual(previewRequests, 0)
        for isRepeat in [false, true, true] {
            let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: " ",
                                                      charactersIgnoringModifiers: " ", isARepeat: isRepeat, keyCode: 49))
            window.keyDown(with: space)
        }
        XCTAssertEqual(previewRequests, 1)
        XCTAssertFalse(window.isVisible)
    }

    private func enterText(in panel: NSWindow) throws {
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        panel.contentView = editor
        XCTAssertTrue(panel.makeFirstResponder(editor))
        XCTAssertTrue(panel.firstResponder === editor)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil,
                                                  characters: "a", charactersIgnoringModifiers: "a",
                                                  isARepeat: false, keyCode: 0))
        panel.sendEvent(event)
        XCTAssertEqual(editor.string, "a")
        XCTAssertTrue(panel.firstResponder === editor)
    }
}

@MainActor
private final class CaptureWindowCloseDelegate: NSObject, NSWindowDelegate {
    var allowsClose = false
    private(set) var closeRequests = 0
    private(set) var closedWindows = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeRequests += 1
        return allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        closedWindows += 1
    }
}
