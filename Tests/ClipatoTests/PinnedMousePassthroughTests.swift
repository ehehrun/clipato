import AppKit
import XCTest
@testable import Clipato

@MainActor
final class PinnedMousePassthroughTests: XCTestCase {
    func testToggleWithoutPinnedImagesDoesNothing() {
        let screenshots = ScreenshotController()

        screenshots.togglePinnedMousePassthrough()

        XCTAssertFalse(screenshots.hasPinnedImages)
        XCTAssertFalse(screenshots.pinnedMousePassthrough)
    }

    func testToggleAffectsEveryPinnedImageAndLeavesOtherWindowsUntouched() throws {
        _ = NSApplication.shared
        let screenshots = ScreenshotController()
        let first = screenshots.pin(image: try pixels(), frame: offscreenFrame)
        let second = screenshots.pin(image: try pixels(), frame: offscreenFrame)
        let unrelated = SelectionWindow(contentRect: offscreenFrame)
        unrelated.isReleasedWhenClosed = false
        defer { first.close(); second.close(); unrelated.close() }
        let firstFrame = first.frame
        let secondFrame = second.frame

        screenshots.togglePinnedMousePassthrough()

        XCTAssertTrue(screenshots.hasPinnedImages)
        XCTAssertTrue(screenshots.pinnedMousePassthrough)
        XCTAssertTrue(first.ignoresMouseEvents)
        XCTAssertTrue(second.ignoresMouseEvents)
        XCTAssertFalse(first.canBecomeKey)
        XCTAssertFalse(second.canBecomeKey)
        XCTAssertFalse(first.isKeyWindow)
        XCTAssertFalse(second.isKeyWindow)
        XCTAssertFalse(unrelated.ignoresMouseEvents)
        XCTAssertEqual(first.frame, firstFrame)
        XCTAssertEqual(second.frame, secondFrame)

        screenshots.togglePinnedMousePassthrough()

        XCTAssertFalse(screenshots.pinnedMousePassthrough)
        XCTAssertFalse(first.ignoresMouseEvents)
        XCTAssertFalse(second.ignoresMouseEvents)
        XCTAssertTrue(first.canBecomeKey)
        XCTAssertTrue(second.canBecomeKey)
        XCTAssertFalse(first.isKeyWindow, "Restoring mouse interaction must not steal keyboard focus.")
        XCTAssertFalse(second.isKeyWindow)
    }

    func testNewPinnedImagesInheritPassthroughAndTheLastCloseResetsTheSession() throws {
        _ = NSApplication.shared
        let screenshots = ScreenshotController()
        let first = screenshots.pin(image: try pixels(), frame: offscreenFrame)
        defer { first.close() }
        screenshots.togglePinnedMousePassthrough()

        let second = screenshots.pin(image: try pixels(), frame: offscreenFrame)
        defer { second.close() }
        XCTAssertTrue(second.ignoresMouseEvents)
        XCTAssertFalse(second.canBecomeKey)
        XCTAssertFalse(second.isKeyWindow)
        first.close()
        XCTAssertTrue(screenshots.hasPinnedImages)
        XCTAssertTrue(screenshots.pinnedMousePassthrough)

        second.close()

        XCTAssertFalse(screenshots.hasPinnedImages)
        XCTAssertFalse(screenshots.pinnedMousePassthrough)
        let next = screenshots.pin(image: try pixels(), frame: offscreenFrame)
        defer { next.close() }
        first.close()
        XCTAssertTrue(screenshots.hasPinnedImages, "A repeated close of an old panel must not remove a new panel.")
        XCTAssertFalse(next.ignoresMouseEvents)
        XCTAssertTrue(next.canBecomeKey)
    }

    func testEnablingPassthroughReleasesThePinnedKeyWindow() throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_PINNED_NATIVE_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_PINNED_NATIVE_QA=1 in an interactive AppKit session to exercise real pinned-window keyboard focus")
        }
        _ = NSApplication.shared
        let screenshots = ScreenshotController()
        let panel = screenshots.pin(image: try pixels(), frame: offscreenFrame)
        defer { panel.close() }
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)

        screenshots.togglePinnedMousePassthrough()

        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.canBecomeKey)
    }

    func testPassthroughStateBelongsOnlyToItsController() throws {
        _ = NSApplication.shared
        let first = ScreenshotController()
        let second = ScreenshotController()
        let firstPanel = first.pin(image: try pixels(), frame: offscreenFrame)
        let secondPanel = second.pin(image: try pixels(), frame: offscreenFrame)
        defer { firstPanel.close(); secondPanel.close() }

        first.togglePinnedMousePassthrough()

        XCTAssertTrue(firstPanel.ignoresMouseEvents)
        XCTAssertFalse(secondPanel.ignoresMouseEvents)
        XCTAssertFalse(second.pinnedMousePassthrough)
    }

    private var offscreenFrame: CGRect { CGRect(x: -10_000, y: -10_000, width: 120, height: 80) }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
