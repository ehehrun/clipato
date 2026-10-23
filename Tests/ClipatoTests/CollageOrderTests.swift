import AppKit
import XCTest
@testable import Clipato

@MainActor
final class CollageOrderTests: XCTestCase {
    private final class ClosingResponder: NSResponder {
        var requests = 0
        override func cancelOperation(_ sender: Any?) { requests += 1 }
    }

    private func strip(order: [Int] = [0, 1, 2], session: UUID = UUID()) throws -> CollageOrderStripView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let view = CollageOrderStripView(images: [image, image, image])
        view.update(order: order, selectedImageIndex: nil, sessionID: session)
        return view
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 30, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testClickAndSmallPointerMovementOnlySelect() throws {
        let view = try strip()
        var selection: [Int] = []
        var moved = false
        view.onSelect = { selection.append($0) }
        view.onMove = { _, _, _ in moved = true }
        view.mouseDown(with: event(.leftMouseDown, x: 120, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 122, in: view))
        XCTAssertNil(view.dragPreviewImage, "Clicking or small movement must not create a drag preview")
        view.mouseUp(with: event(.leftMouseUp, x: 122, in: view))
        XCTAssertEqual(selection, [1])
        XCTAssertFalse(moved)
        XCTAssertEqual(view.order, [0, 1, 2])
    }

    func testDragCommitsOnceOnMouseUpAndSurvivesSelectionUpdate() throws {
        let session = UUID()
        let view = try strip(session: session)
        var moves: [(UUID, Int, Int)] = []
        view.onSelect = { view.update(order: [0, 1, 2], selectedImageIndex: $0, sessionID: session) }
        view.onMove = { moves.append(($0, $1, $2)) }
        view.mouseDown(with: event(.leftMouseDown, x: 20, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 140, in: view))
        let preview = try XCTUnwrap(view.dragPreviewImage)
        XCTAssertEqual(preview.size, CGSize(width: 84, height: 68))
        view.mouseDragged(with: event(.leftMouseDragged, x: 260, in: view))
        XCTAssertTrue(view.dragPreviewImage === preview, "Pointer movement must reuse the small preview image")
        XCTAssertTrue(moves.isEmpty, "Dragging must not re-render the collage on every pointer update")
        view.mouseUp(with: event(.leftMouseUp, x: 260, in: view))
        XCTAssertNil(view.dragPreviewImage)
        view.mouseUp(with: event(.leftMouseUp, x: 260, in: view))
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.0, session)
        XCTAssertEqual(moves.first?.1, 0)
        XCTAssertEqual(moves.first?.2, 2)
    }

    func testDraggingLeftUsesSourceImageIdentifiersAfterEarlierReorder() throws {
        let view = try strip(order: [2, 0, 1])
        var source: Int?
        var target: Int?
        view.onMove = { _, from, to in source = from; target = to }
        view.mouseDown(with: event(.leftMouseDown, x: 220, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 15, in: view))
        view.mouseUp(with: event(.leftMouseUp, x: 15, in: view))
        XCTAssertEqual(source, 1)
        XCTAssertEqual(target, 2)
    }

    func testEscapeCancelsDragBeforeForwardingClose() throws {
        let view = try strip()
        let closing = ClosingResponder()
        view.nextResponder = closing
        var moved = false
        view.onMove = { _, _, _ in moved = true }
        view.mouseDown(with: event(.leftMouseDown, x: 20, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 260, in: view))
        view.cancelOperation(nil)
        XCTAssertNil(view.dragPreviewImage)
        view.mouseUp(with: event(.leftMouseUp, x: 260, in: view))
        XCTAssertFalse(moved)
        XCTAssertEqual(closing.requests, 0)
        view.cancelOperation(nil)
        XCTAssertEqual(closing.requests, 1)
    }

    func testDroppingOutsideStripOrBackAtSourceDoesNotReorder() throws {
        let view = try strip()
        var moved = false
        view.onMove = { _, _, _ in moved = true }
        view.mouseDown(with: event(.leftMouseDown, x: 20, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 260, in: view))
        view.mouseUp(with: event(.leftMouseUp, x: 260, y: 100, in: view))
        XCTAssertFalse(moved)
        view.mouseDown(with: event(.leftMouseDown, x: 20, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 260, in: view))
        view.mouseUp(with: event(.leftMouseUp, x: 20, in: view))
        XCTAssertFalse(moved)
    }

    func testChangingLayoutSessionCancelsOutstandingDrag() throws {
        let view = try strip()
        var moved = false
        view.onMove = { _, _, _ in moved = true }
        view.mouseDown(with: event(.leftMouseDown, x: 20, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 260, in: view))
        view.update(order: [0, 1, 2], selectedImageIndex: 0, sessionID: UUID())
        XCTAssertNil(view.dragPreviewImage)
        view.mouseUp(with: event(.leftMouseUp, x: 260, in: view))
        XCTAssertFalse(moved)
    }

    func testLeavingWindowDiscardsPreviewWithoutCommittingDrag() throws {
        let view = try strip()
        var moved = false
        view.onMove = { _, _, _ in moved = true }
        view.mouseDown(with: event(.leftMouseDown, x: 20, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 260, in: view))
        XCTAssertNotNil(view.dragPreviewImage)
        view.viewWillMove(toWindow: nil)
        XCTAssertNil(view.dragPreviewImage)
        view.mouseUp(with: event(.leftMouseUp, x: 260, in: view))
        XCTAssertFalse(moved)
    }

    func testPreviewRendersDraggedSourceAtFullOpacityAfterReordering() throws {
        func solidImage(_ color: CGColor) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try XCTUnwrap(context.makeImage())
        }
        let colors = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                      CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                      CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)]
        let view = CollageOrderStripView(images: try colors.map(solidImage))
        view.update(order: [2, 0, 1], selectedImageIndex: nil, sessionID: UUID())
        view.mouseDown(with: event(.leftMouseDown, x: 220, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, x: 15, in: view))
        let preview = try XCTUnwrap(view.dragPreviewImage)
        let output = try XCTUnwrap(CGContext(data: nil, width: 84, height: 68, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: true)
        preview.draw(in: CGRect(origin: .zero, size: preview.size))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try XCTUnwrap(output.data).assumingMemoryBound(to: UInt8.self)
        let center = 34 * output.bytesPerRow + 42 * 4
        XCTAssertLessThan(pixels[center], 13)
        XCTAssertLessThan(pixels[center + 1], 13)
        XCTAssertGreaterThan(pixels[center + 2], 242)
        XCTAssertGreaterThan(pixels[center + 3], 242)
        view.cancelOperation(nil)
    }
}
