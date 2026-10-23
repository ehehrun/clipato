import AppKit
import XCTest
@testable import Clipato

@MainActor
final class VaultMarqueeTests: XCTestCase {
    private final class ClosingResponder: NSResponder {
        var requests = 0
        override func cancelOperation(_ sender: Any?) { requests += 1 }
    }
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    private func makeView(selected: Set<UUID> = []) -> VaultMarqueeView {
        _ = NSApplication.shared
        let view = VaultMarqueeView(frame: CGRect(x: 0, y: 0, width: 200, height: 240))
        view.frames = [first: CGRect(x: 20, y: 20, width: 50, height: 40),
                       second: CGRect(x: 90, y: 20, width: 50, height: 40),
                       third: CGRect(x: 20, y: 80, width: 50, height: 40)]
        view.selected = selected
        return view
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in view: VaultMarqueeView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ view: VaultMarqueeView, from start: CGPoint = CGPoint(x: 5, y: 5), to end: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, end, in: view))
        view.mouseUp(with: event(.leftMouseUp, end, in: view))
    }

    func testCompletedMarqueeLeavesTextFocusForListSelection() {
        let view = makeView()
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: view.bounds)
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView = content
        content.addSubview(text)
        content.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(text))

        drag(view, to: CGPoint(x: 145, y: 65))

        XCTAssertFalse(window.firstResponder === text)
        XCTAssertEqual(view.selected, [first, second])
        XCTAssertFalse(window.isVisible)
    }

    func testCancelledMarqueeRestoresTextFocusAndSelection() {
        let view = makeView(selected: [third])
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: view.bounds)
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView = content
        content.addSubview(text)
        content.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(text))

        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 145, y: 65), in: view))
        view.cancelOperation(nil)

        XCTAssertTrue(window.firstResponder === text)
        XCTAssertEqual(view.selected, [third])
        XCTAssertFalse(window.isVisible)
    }

    func testCardsPassThroughOverlayAndBlankSpaceReceivesDragInParentCoordinates() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let view = makeView()
        view.frame.origin = CGPoint(x: 40, y: 50)
        parent.addSubview(view)
        XCTAssertNil(view.hitTest(view.convert(CGPoint(x: 35, y: 35), to: parent)))
        XCTAssertTrue(view.hitTest(view.convert(CGPoint(x: 5, y: 5), to: parent)) === view)
        XCTAssertNil(view.hitTest(view.convert(CGPoint(x: -10, y: 5), to: parent)))
    }

    func testDragSelectsIntersectingCardsAndRetainsSelectionOnRelease() {
        let view = makeView()
        var changes: [Set<UUID>] = []
        var began = 0
        view.onSelectionChange = { changes.append($0) }
        view.onBegin = { began += 1 }
        drag(view, to: CGPoint(x: 110, y: 35))
        XCTAssertEqual(view.selected, [first, second], "Partial intersection selects a card")
        XCTAssertEqual(changes, [[first, second]])
        XCTAssertEqual(began, 1)
    }

    func testDragDeselectsSelectedCardsAndPreservesCardsOutsideRectangle() {
        let view = makeView(selected: [first, second, third])
        drag(view, to: CGPoint(x: 145, y: 65))
        XCTAssertEqual(view.selected, [third])
    }

    func testMixedSelectionTogglesAgainstInitialSnapshot() {
        let hiddenSelection = UUID()
        let view = makeView(selected: [first, third, hiddenSelection])
        drag(view, to: CGPoint(x: 145, y: 65))
        XCTAssertEqual(view.selected, [second, third, hiddenSelection])
    }

    func testReverseDragAndShrinkingRestoreOriginalStates() {
        let view = makeView(selected: [first])
        let origin = CGPoint(x: 150, y: 140)
        view.mouseDown(with: event(.leftMouseDown, origin, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 10, y: 10), in: view))
        XCTAssertEqual(view.selected, [second, third])
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 80, y: 70), in: view))
        XCTAssertEqual(view.selected, [first], "Cards outside the shrinking rectangle regain their snapshot state")
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 80, y: 70), in: view))
        XCTAssertEqual(view.selected, [first])
    }

    func testBackgroundClickAndSmallMotionLeaveSelectionUntouched() {
        let view = makeView(selected: [first])
        var changes = 0
        var began = 0
        view.onSelectionChange = { _ in changes += 1 }
        view.onBegin = { began += 1 }
        drag(view, to: CGPoint(x: 5, y: 5))
        drag(view, to: CGPoint(x: 7, y: 6))
        view.mouseDown(with: event(.rightMouseDown, CGPoint(x: 5, y: 5), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 145, y: 65), in: view))
        XCTAssertEqual(view.selected, [first])
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(began, 0)
    }

    func testRepeatedDragAndReleaseDoNotPublishUnchangedSelection() {
        let view = makeView()
        var changes = 0
        view.onSelectionChange = { _ in changes += 1 }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5), in: view))
        for point in [CGPoint(x: 75, y: 65), CGPoint(x: 75, y: 65), CGPoint(x: 80, y: 70)] {
            view.mouseDragged(with: event(.leftMouseDragged, point, in: view))
        }
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 80, y: 70), in: view))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(view.selected, [first])
    }

    func testEscapeRestoresSnapshotAndEndsGesture() {
        let view = makeView(selected: [first, third])
        var changes: [Set<UUID>] = []
        view.onSelectionChange = { changes.append($0) }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 145, y: 65), in: view))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 145, y: 130), in: view))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 145, y: 130), in: view))
        XCTAssertEqual(view.selected, [first, third])
        XCTAssertEqual(changes, [[second, third], [first, third]])
    }

    func testWindowDetachCancelsActiveDrag() {
        let view = makeView(selected: [third])
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 145, y: 65), in: view))
        view.viewWillMove(toWindow: nil)
        XCTAssertEqual(view.selected, [third])
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 145, y: 65), in: view))
        XCTAssertEqual(view.selected, [third])
    }

    func testEscapeWithoutDragForwardsToWindowCloseHandler() {
        let view = makeView(selected: [first])
        let closing = ClosingResponder()
        view.nextResponder = closing
        view.cancelOperation(nil)
        XCTAssertEqual(closing.requests, 1)
        XCTAssertEqual(view.selected, [first])
    }

    func testLazyGridEvictionRetainsCrossedGeometryAndShrinkingStillRestoresIt() {
        let view = makeView()
        let fourth = UUID()
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5), in: view))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 75, y: 65), in: view))
        XCTAssertEqual(view.selected, [first])
        view.frames = [third: CGRect(x: 20, y: 80, width: 50, height: 40),
                       fourth: CGRect(x: 20, y: 150, width: 50, height: 40)]
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 75, y: 200), in: view))
        XCTAssertEqual(view.selected, [first, third, fourth])
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 10, y: 10), in: view))
        XCTAssertTrue(view.selected.isEmpty)
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 10, y: 10), in: view))
    }
}
