import AppKit
import XCTest
@testable import Clipato

@MainActor
final class SystemImagePreviewTests: XCTestCase {
    private func window(at origin: NSPoint = .zero) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 800, height: 600)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(origin)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        return window
    }

    private func source(in window: NSWindow, imageSize: NSSize) -> ImagePreviewSourceView {
        let container = NSView(frame: NSRect(x: 30, y: 40, width: 500, height: 400))
        window.contentView!.addSubview(container)
        let source = ImagePreviewSourceView(frame: NSRect(x: 25, y: 35, width: 200, height: 200))
        source.url = URL(fileURLWithPath: "/tmp/preview-source.png")
        source.image = NSImage(size: imageSize)
        container.addSubview(source)
        return source
    }

    func testWideAndTallThumbnailsUseImageBoundsOnOffsetDisplays() throws {
        for origin in [NSPoint(x: -1800, y: 100), NSPoint(x: 1900, y: -900), NSPoint(x: 200, y: 1400)] {
            let window = window(at: origin)
            let source = source(in: window, imageSize: NSSize(width: 400, height: 100))
            let wide = try XCTUnwrap(source.transitionGeometry)
            XCTAssertEqual(wide.screenFrame, NSRect(x: origin.x + 55, y: origin.y + 150, width: 200, height: 50))
            XCTAssertEqual(wide.contentRect, NSRect(x: 0, y: 0, width: 400, height: 100))

            source.image = NSImage(size: NSSize(width: 100, height: 400))
            let tall = try XCTUnwrap(source.transitionGeometry)
            XCTAssertEqual(tall.screenFrame, NSRect(x: origin.x + 130, y: origin.y + 75, width: 50, height: 200))
            XCTAssertEqual(tall.contentRect, NSRect(x: 0, y: 0, width: 100, height: 400))
            XCTAssertFalse(window.isVisible)
        }
    }

    func testScrolledThumbnailClipsTransitionToVisibleImagePixels() throws {
        let window = window(at: NSPoint(x: -1200, y: 200))
        let clip = NSClipView(frame: NSRect(x: 100, y: 80, width: 160, height: 120))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView!.addSubview(clip)
        clip.documentView = document
        let source = ImagePreviewSourceView(frame: NSRect(x: 20, y: 30, width: 200, height: 200))
        source.image = NSImage(size: NSSize(width: 400, height: 200))
        document.addSubview(source)
        clip.scroll(to: NSPoint(x: 60, y: 100))

        let geometry = try XCTUnwrap(source.transitionGeometry)
        XCTAssertEqual(geometry.screenFrame, NSRect(x: -1100, y: 280, width: 160, height: 80))
        XCTAssertEqual(geometry.contentRect, NSRect(x: 80, y: 40, width: 320, height: 160))
        XCTAssertFalse(window.isVisible)
    }

    func testSourceSearchIgnoresHiddenAndEvictedCardsAndUsesUpdatedGeometry() throws {
        let window = window()
        let source = source(in: window, imageSize: NSSize(width: 400, height: 100))
        let url = try XCTUnwrap(source.url)
        XCTAssertTrue(SystemImagePreviewView.findSource(for: url, in: window.contentView!) === source)
        source.frame.origin.x += 50
        XCTAssertEqual(try XCTUnwrap(source.transitionGeometry).screenFrame.minX, 105)
        source.superview!.isHidden = true
        XCTAssertNil(SystemImagePreviewView.findSource(for: url, in: window.contentView!))
        source.superview!.isHidden = false
        source.removeFromSuperview()
        XCTAssertNil(source.transitionGeometry)
        XCTAssertNil(SystemImagePreviewView.findSource(for: url, in: window.contentView!))
        XCTAssertFalse(window.isVisible)
    }

    func testBackgroundViewsDoNotInterceptPointerEvents() {
        let source = ImagePreviewSourceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let preview = SystemImagePreviewView(frame: source.bounds)
        XCTAssertNil(source.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertNil(preview.hitTest(NSPoint(x: 50, y: 50)))
    }

    func testDetachedRequestsWaitForAWindowWithoutCreatingAPreviewWindow() {
        let view = SystemImagePreviewView()
        let first = URL(fileURLWithPath: "/tmp/preview-first.png")
        let second = URL(fileURLWithPath: "/tmp/preview-second.png")
        view.request(first, urls: [second, first])
        view.request(second, urls: [second, first])
        XCTAssertEqual(view.requestedURL, second)
        XCTAssertNil(view.controlledPanel)
        view.request(nil)
        XCTAssertNil(view.requestedURL)
        view.request(first)
        view.invalidate()
        XCTAssertNil(view.requestedURL)
        XCTAssertNil(view.controlledPanel)
    }

    func testRequestOutsideFilteredListClosesInsteadOfPreviewingAnotherImage() async {
        let view = SystemImagePreviewView()
        let removed = URL(fileURLWithPath: "/tmp/preview-removed.png")
        let visible = URL(fileURLWithPath: "/tmp/preview-visible.png")
        let closed = expectation(description: "Removed image request is dismissed")
        view.onClose = { url in
            XCTAssertEqual(url, removed)
            closed.fulfill()
        }
        view.request(removed, urls: [visible])
        XCTAssertNil(view.requestedURL)
        XCTAssertNil(view.controlledPanel)
        await fulfillment(of: [closed], timeout: 1)
    }

    func testInitialPanelFrameMatchesConsoleAndFitsItsDisplay() {
        let display = NSRect(x: -1600, y: 80, width: 1600, height: 920)
        let console = NSRect(x: -1500, y: 200, width: 1100, height: 700)
        XCTAssertEqual(SystemImagePreviewView.initialFrame(sourceFrame: console, visibleFrame: display), console)
        let oversized = NSRect(x: -1800, y: 0, width: 1900, height: 1200)
        XCTAssertEqual(SystemImagePreviewView.initialFrame(sourceFrame: oversized, visibleFrame: display), display)
        let crossing = NSRect(x: -500, y: 700, width: 900, height: 600)
        XCTAssertEqual(SystemImagePreviewView.initialFrame(sourceFrame: crossing, visibleFrame: display),
                       NSRect(x: -900, y: 400, width: 900, height: 600))
    }

    func testOnlyUnhandledUnmodifiedSpaceAndEscapeAreCloseKeys() {
        func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: repeated, keyCode: code)!
        }
        XCTAssertTrue(SystemImagePreviewView.isCloseKey(event(49)))
        XCTAssertTrue(SystemImagePreviewView.isCloseKey(event(53)))
        for modifier in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            XCTAssertFalse(SystemImagePreviewView.isCloseKey(event(49, flags: modifier)))
            XCTAssertFalse(SystemImagePreviewView.isCloseKey(event(53, flags: modifier)))
        }
        XCTAssertFalse(SystemImagePreviewView.isCloseKey(event(8, flags: .command)), "Copy stays with native Live Text")
        for arrow in UInt16(123)...UInt16(126) {
            XCTAssertFalse(SystemImagePreviewView.isCloseKey(event(arrow)))
        }
    }
}
