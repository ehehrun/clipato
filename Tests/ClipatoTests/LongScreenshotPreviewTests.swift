import AppKit
import ClipatoCore
import XCTest
@testable import Clipato

@MainActor
final class LongScreenshotPreviewTests: XCTestCase {
    private final class ClosingResponder: NSResponder {
        var requests = 0
        override func cancelOperation(_ sender: Any?) { requests += 1 }
    }

    func testEscapeForwardsToWindowEvenWhileProcessing() throws {
        let canvas = try makeCanvas()
        let closing = ClosingResponder()
        canvas.nextResponder = closing
        canvas.keyDown(with: key(53))
        canvas.isEnabled = false
        canvas.keyDown(with: key(53))
        XCTAssertEqual(closing.requests, 2)
    }

    func testArrowKeysAdjustOneSourcePixelAndShiftAdjustsTenAtAnyZoom() throws {
        let canvas = try makeCanvas()
        canvas.selectedJoin = 0
        canvas.imageScale = 0.125
        var movements: [CGPoint] = []
        canvas.onNudge = { movements.append(CGPoint(x: $0, y: $1)) }
        canvas.keyDown(with: key(126))
        canvas.keyDown(with: key(125))
        canvas.keyDown(with: key(123, modifiers: .shift))
        canvas.keyDown(with: key(124, modifiers: .shift))
        XCTAssertEqual(movements, [CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1),
                                   CGPoint(x: -10, y: 0), CGPoint(x: 10, y: 0)])
    }

    func testFirstFrameAlsoRespondsToArrowKeys() throws {
        let canvas = try makeCanvas()
        canvas.selectedJoin = nil
        var movements: [CGPoint] = []
        canvas.onNudge = { movements.append(CGPoint(x: $0, y: $1)) }
        canvas.keyDown(with: key(125))
        canvas.keyDown(with: key(123, modifiers: .shift))
        XCTAssertEqual(movements, [CGPoint(x: 0, y: 1), CGPoint(x: -10, y: 0)])
    }

    func testDragUsesOriginalPixelsAndCommitsOnlyOnMouseUp() throws {
        let canvas = try makeCanvas()
        canvas.imageScale = 0.5
        canvas.imageOrigin = CGPoint(x: 30, y: 40)
        canvas.selectedJoin = 0
        let original = canvas.placements
        let start = canvas.displayFrame(original[1].frame).center
        let end = CGPoint(x: start.x + 6, y: start.y - 4)
        var moves: [(Int, Int, Int)] = []
        canvas.onMove = { moves.append(($0, $1, $2)) }
        canvas.mouseDown(with: mouse(start, in: canvas))
        canvas.mouseDragged(with: mouse(end, in: canvas, type: .leftMouseDragged))
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(canvas.placements, original)
        XCTAssertEqual(canvas.previewFrame(original[0]), original[0].frame)
        XCTAssertEqual(canvas.previewFrame(original[1]), original[1].frame.offsetBy(dx: 12, dy: -8))
        canvas.mouseUp(with: mouse(end, in: canvas, type: .leftMouseUp))
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.0, 1)
        XCTAssertEqual(moves.first?.1, 12)
        XCTAssertEqual(moves.first?.2, -8)
    }

    func testSelectingWithoutDraggingKeepsFitModeAndOverlappingClickSelectsTopFrame() throws {
        let canvas = try makeCanvas()
        canvas.imageScale = 10
        canvas.selectedJoin = nil
        var begins = 0
        canvas.onBeginMove = { begins += 1 }
        let overlap = canvas.placements[0].frame.intersection(canvas.placements[1].frame)
        let point = canvas.displayFrame(overlap).center
        canvas.mouseDown(with: mouse(point, in: canvas))
        canvas.mouseUp(with: mouse(point, in: canvas, type: .leftMouseUp))
        XCTAssertEqual(canvas.selectedJoin, 0)
        XCTAssertEqual(begins, 0)
        canvas.mouseDown(with: mouse(point, in: canvas))
        let shifted = CGPoint(x: point.x + 10, y: point.y + 20)
        canvas.mouseDragged(with: mouse(shifted, in: canvas, type: .leftMouseDragged))
        canvas.mouseDragged(with: mouse(point, in: canvas, type: .leftMouseDragged))
        canvas.mouseUp(with: mouse(point, in: canvas, type: .leftMouseUp))
        XCTAssertEqual(begins, 1)
    }

    func testCoveredFrameSelectedFromSidebarCanBeDraggedAndEscapeCancels() throws {
        let canvas = try makeCanvas()
        canvas.placements[1].frame = canvas.placements[0].frame
        canvas.imageScale = 10
        canvas.selectedJoin = nil
        canvas.prefersSelectedImage = true
        let point = canvas.displayFrame(canvas.placements[0].frame).center
        var moves = 0
        canvas.onMove = { _, _, _ in moves += 1 }
        canvas.mouseDown(with: mouse(point, in: canvas))
        XCTAssertNil(canvas.selectedJoin)
        canvas.mouseDragged(with: mouse(CGPoint(x: point.x + 20, y: point.y + 30), in: canvas, type: .leftMouseDragged))
        XCTAssertEqual(canvas.previewFrame(canvas.placements[0]), canvas.placements[0].frame.offsetBy(dx: 2, dy: 3))
        canvas.keyDown(with: key(53))
        canvas.mouseUp(with: mouse(point, in: canvas, type: .leftMouseUp))
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(canvas.previewFrame(canvas.placements[0]), canvas.placements[0].frame)
    }

    func testMovingFirstFrameKeepsOtherFramesAtTheSameViewportPosition() throws {
        let canvas = try makeCanvas()
        let scroll = LongScreenshotScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.canvas.images = canvas.images
        scroll.displayScale = 2
        scroll.updateGeometry(placements: canvas.placements, size: canvas.outputSize, preserveViewport: false)
        let before = scroll.canvas.displayFrame(scroll.canvas.placements[1].frame).origin
        let viewportBefore = CGPoint(x: before.x - scroll.contentView.bounds.minX, y: before.y - scroll.contentView.bounds.minY)
        scroll.preserveViewport(moving: 0)
        let joins = try LongScreenshot.moving(joins: [.init(overlap: 3, offsetX: -2)], imageIndex: 0, dx: -400, dy: -500)
        let layout = try LongScreenshot.layout(images: canvas.images, joins: joins)
        scroll.updateGeometry(placements: layout.placements, size: layout.size, preserveViewport: true)
        scroll.layoutCanvas()
        let after = scroll.canvas.displayFrame(scroll.canvas.placements[1].frame).origin
        XCTAssertEqual(after.x - scroll.contentView.bounds.minX, viewportBefore.x, accuracy: 0.01)
        XCTAssertEqual(after.y - scroll.contentView.bounds.minY, viewportBefore.y, accuracy: 0.01)
        XCTAssertEqual(scroll.zoom, 1)
    }

    func testClickingASeamSelectsItWithoutRenderingAnOutput() throws {
        let canvas = try makeCanvas()
        canvas.imageScale = 3
        canvas.imageOrigin = CGPoint(x: 12, y: 14)
        var selected: Int?
        canvas.onSelect = { selected = $0 }
        let seam = canvas.displayFrame(canvas.placements[1].frame)
        canvas.mouseDown(with: mouse(CGPoint(x: seam.midX, y: seam.minY), in: canvas))
        XCTAssertEqual(selected, 0)
        XCTAssertEqual(canvas.selectedJoin, 0)
        XCTAssertEqual(canvas.images.count, 2)
    }

    func testFirstAndFollowingFramesHaveDistinctSelections() throws {
        let canvas = try makeCanvas()
        canvas.imageScale = 10
        canvas.selectedJoin = 0
        var selections: [Int?] = []
        canvas.onSelect = { selections.append($0) }
        let first = canvas.displayFrame(canvas.placements[0].frame)
        canvas.mouseDown(with: mouse(CGPoint(x: first.midX, y: first.minY + 10), in: canvas))
        XCTAssertEqual(selections.count, 1)
        XCTAssertNil(selections[0])
        XCTAssertNil(canvas.selectedJoin)
        let second = canvas.displayFrame(canvas.placements[1].frame)
        canvas.mouseDown(with: mouse(CGPoint(x: second.midX, y: second.maxY - 10), in: canvas))
        XCTAssertEqual(selections.count, 2)
        XCTAssertEqual(selections[1], 0)
        XCTAssertEqual(canvas.selectedJoin, 0)
    }

    func testDisabledPreviewDoesNotSendEditingEvents() throws {
        let canvas = try makeCanvas()
        canvas.selectedJoin = 0
        canvas.isEnabled = false
        var calls = 0
        canvas.onSelect = { _ in calls += 1 }
        canvas.onNudge = { _, _ in calls += 1 }
        canvas.keyDown(with: key(126))
        canvas.mouseDown(with: mouse(CGPoint(x: 4, y: 4), in: canvas))
        XCTAssertEqual(calls, 0)
    }

    func testBlankCanvasDeselectsWithoutMovingImagesAndCanSelectAgain() throws {
        let canvas = try makeCanvas()
        canvas.frame.size = CGSize(width: 240, height: 180)
        canvas.imageOrigin = CGPoint(x: 20, y: 20)
        canvas.selectedJoin = 0
        canvas.prefersSelectedImage = true
        var deselections = 0
        var nudges = 0
        var selections: [Int?] = []
        canvas.onDeselect = { deselections += 1 }
        canvas.onSelect = { selections.append($0) }
        canvas.onNudge = { _, _ in nudges += 1 }
        let placements = canvas.placements
        let size = canvas.outputSize
        canvas.mouseDown(with: mouse(CGPoint(x: 200, y: 140), in: canvas))
        canvas.keyDown(with: key(126))
        XCTAssertFalse(canvas.showsSelection)
        XCTAssertFalse(canvas.prefersSelectedImage)
        XCTAssertEqual(deselections, 1)
        XCTAssertEqual(nudges, 0)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertEqual(canvas.placements, placements)
        XCTAssertEqual(canvas.outputSize, size)

        let first = canvas.displayFrame(placements[0].frame)
        canvas.mouseDown(with: mouse(CGPoint(x: first.midX, y: first.minY + 1), in: canvas))
        XCTAssertTrue(canvas.showsSelection)
        XCTAssertNil(canvas.selectedJoin)
        XCTAssertEqual(selections.count, 1)
        canvas.mouseUp(with: mouse(CGPoint(x: first.midX, y: first.minY + 1), in: canvas, type: .leftMouseUp))
        canvas.keyDown(with: key(126))
        XCTAssertEqual(nudges, 1)
    }

    func testDeselectingRemovesAllPreviewDecorationsWithoutChangingOutputPixels() throws {
        let canvas = try makeCanvas()
        canvas.selectedJoin = 0
        canvas.mouseDown(with: mouse(CGPoint(x: -10, y: -10), in: canvas))
        XCTAssertFalse(canvas.showsSelection)
        let output = try context(width: Int(canvas.outputSize.width), height: Int(canvas.outputSize.height))
        output.translateBy(x: 0, y: canvas.outputSize.height)
        output.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let exported = try LongScreenshot.render(images: canvas.images, joins: [.init(overlap: 3, offsetX: -2)])
        XCTAssertEqual(try pixels(XCTUnwrap(output.makeImage())), try pixels(exported))
    }

    func testRetinaPreviewZoomKeepsSourcePixelsAndPlacementUnchanged() throws {
        let canvas = try makeCanvas()
        let scroll = LongScreenshotScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.canvas.images = canvas.images
        scroll.canvas.placements = canvas.placements
        scroll.canvas.outputSize = canvas.outputSize
        scroll.displayScale = 2
        scroll.layoutSubtreeIfNeeded()
        scroll.layoutCanvas()
        XCTAssertEqual(scroll.canvas.imageScale, 0.5)
        XCTAssertEqual(scroll.canvas.interpolationQuality, .none)
        let first = scroll.canvas.images[0]
        scroll.setZoom(4)
        XCTAssertEqual(scroll.canvas.imageScale, 2)
        XCTAssertEqual(scroll.canvas.interpolationQuality, .none)
        XCTAssertTrue(scroll.canvas.images[0] === first)
        XCTAssertEqual(scroll.canvas.placements, canvas.placements)
        scroll.setZoom(1 / canvas.outputSize.height)
        XCTAssertEqual(scroll.canvas.interpolationQuality, .high)
        XCTAssertEqual(scroll.canvas.outputSize.height * scroll.canvas.imageScale * 2, 1, accuracy: 0.00001)
    }

    func testZoomPreservesThePointUnderThePointer() throws {
        let scroll = LongScreenshotScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.canvas.outputSize = CGSize(width: 1000, height: 1000)
        scroll.layoutSubtreeIfNeeded()
        scroll.layoutCanvas()
        let anchor = CGPoint(x: 140, y: 90)
        let imagePoint = CGPoint(x: (anchor.x - scroll.canvas.imageOrigin.x) / scroll.canvas.imageScale,
                                 y: (anchor.y - scroll.canvas.imageOrigin.y) / scroll.canvas.imageScale)
        let relative = CGPoint(x: anchor.x - scroll.contentView.bounds.minX, y: anchor.y - scroll.contentView.bounds.minY)
        scroll.setZoom(2, anchor: anchor)
        XCTAssertEqual(scroll.canvas.imageOrigin.x + imagePoint.x * scroll.canvas.imageScale - scroll.contentView.bounds.minX,
                       relative.x, accuracy: 0.01)
        XCTAssertEqual(scroll.canvas.imageOrigin.y + imagePoint.y * scroll.canvas.imageScale - scroll.contentView.bounds.minY,
                       relative.y, accuracy: 0.01)
    }

    func testResetCentersDraggedLayoutAtOneSourcePixelPerRetinaPixel() throws {
        let canvas = try makeCanvas()
        let scroll = LongScreenshotScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.displayScale = 2
        scroll.canvas.images = canvas.images
        scroll.updateGeometry(placements: canvas.placements, size: canvas.outputSize, preserveViewport: false)
        scroll.layoutSubtreeIfNeeded()
        scroll.preserveViewport(moving: 0)
        let joins = try LongScreenshot.moving(joins: [.init(overlap: 3, offsetX: -2)], imageIndex: 0, dx: -900, dy: -700)
        let layout = try LongScreenshot.layout(images: canvas.images, joins: joins)
        scroll.updateGeometry(placements: layout.placements, size: layout.size, preserveViewport: true)
        scroll.preserveViewport(moving: 0)

        scroll.resetViewport()

        XCTAssertEqual(scroll.zoom, 1)
        XCTAssertEqual(scroll.canvas.imageScale * scroll.displayScale, 1)
        XCTAssertEqual(scroll.canvas.interpolationQuality, .none)
        XCTAssertEqual(scroll.canvas.placements, layout.placements)
        XCTAssertEqual(scroll.canvas.outputSize, layout.size)
        XCTAssertTrue(scroll.canvas.images[0] === canvas.images[0])
        XCTAssertEqual(scroll.canvas.displayFrame(CGRect(origin: .zero, size: layout.size)).midX,
                       scroll.contentView.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(scroll.canvas.displayFrame(CGRect(origin: .zero, size: layout.size)).midY,
                       scroll.contentView.bounds.midY, accuracy: 0.5)

        let reference = scroll.canvas.displayFrame(layout.placements[0].frame).origin
        let before = CGPoint(x: reference.x - scroll.contentView.bounds.minX, y: reference.y - scroll.contentView.bounds.minY)
        let nextJoins = try LongScreenshot.moving(joins: joins, imageIndex: 1, dx: 20, dy: 20)
        let nextLayout = try LongScreenshot.layout(images: canvas.images, joins: nextJoins)
        scroll.updateGeometry(placements: nextLayout.placements, size: nextLayout.size, preserveViewport: true)
        let after = scroll.canvas.displayFrame(nextLayout.placements[0].frame).origin
        XCTAssertEqual(after.x - scroll.contentView.bounds.minX, before.x, accuracy: 0.01)
        XCTAssertEqual(after.y - scroll.contentView.bounds.minY, before.y, accuracy: 0.01)
    }

    func testRepeatedOriginalSizeResetRecentersAfterZoomingAndScrolling() throws {
        let canvas = try makeCanvas()
        let joins = try LongScreenshot.moving(joins: [.init(overlap: 3, offsetX: -2)], imageIndex: 1, dx: 1200, dy: 900)
        let layout = try LongScreenshot.layout(images: canvas.images, joins: joins)
        let scroll = LongScreenshotScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        scroll.displayScale = 2
        scroll.canvas.images = canvas.images
        scroll.updateGeometry(placements: layout.placements, size: layout.size, preserveViewport: false)
        scroll.layoutSubtreeIfNeeded()
        scroll.setZoom(4)
        scroll.contentView.scroll(to: CGPoint(x: 100, y: 200))
        scroll.setZoom(1)
        scroll.resetViewport()
        let centered = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(centered.x, 0)
        XCTAssertGreaterThan(centered.y, 0)

        scroll.contentView.scroll(to: .zero)
        XCTAssertNotEqual(scroll.contentView.bounds.origin, centered)
        scroll.setZoom(1)
        scroll.resetViewport()

        XCTAssertEqual(scroll.contentView.bounds.origin, centered)
        XCTAssertEqual(scroll.zoom, 1)
        XCTAssertEqual(scroll.canvas.placements, layout.placements)
        XCTAssertEqual(scroll.canvas.outputSize, layout.size)
    }

    func testFitResetShowsWholeSmallAndLargeCanvas() {
        _ = NSApplication.shared
        for size in [CGSize(width: 20, height: 30), CGSize(width: 2000, height: 1600)] {
            let scroll = LongScreenshotScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            scroll.displayScale = 2
            scroll.updateGeometry(placements: [], size: size, preserveViewport: false)
            scroll.layoutSubtreeIfNeeded()
            scroll.setZoom(4)
            scroll.contentView.scroll(to: CGPoint(x: 100, y: 200))
            let viewport = scroll.contentView.bounds.size
            let fit = min(1, min((viewport.width - 32) * scroll.displayScale / size.width,
                                 (viewport.height - 32) * scroll.displayScale / size.height))

            scroll.setZoom(fit)
            scroll.resetViewport()

            let output = scroll.canvas.displayFrame(CGRect(origin: .zero, size: size))
            XCTAssertTrue(scroll.contentView.bounds.contains(output))
            XCTAssertEqual(output.midX, scroll.contentView.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(output.midY, scroll.contentView.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(scroll.zoom, fit)
            XCTAssertEqual(scroll.canvas.outputSize, size)
        }
    }

    func testPreviewPixelsMatchExportWithOverlapAndHorizontalOffset() throws {
        let canvas = try makeCanvas()
        canvas.selectedJoin = nil
        canvas.showsSelection = false
        canvas.frame = CGRect(origin: .zero, size: canvas.outputSize)
        let output = try context(width: Int(canvas.outputSize.width), height: Int(canvas.outputSize.height))
        output.translateBy(x: 0, y: canvas.outputSize.height)
        output.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let preview = try XCTUnwrap(output.makeImage())
        let exported = try LongScreenshot.render(images: canvas.images, joins: [LongScreenshotJoin(overlap: 3, offsetX: -2)])
        XCTAssertEqual(preview.width, exported.width)
        XCTAssertEqual(preview.height, exported.height)
        XCTAssertEqual(try pixels(preview), try pixels(exported))
    }

    private func makeCanvas() throws -> LongScreenshotCanvas {
        _ = NSApplication.shared
        let first = try context(width: 12, height: 10)
        first.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        first.fill(CGRect(x: 0, y: 0, width: 12, height: 10))
        first.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        first.fill(CGRect(x: 0, y: 8, width: 6, height: 2))
        let second = try context(width: 12, height: 10)
        second.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        second.fill(CGRect(x: 0, y: 0, width: 12, height: 10))
        second.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        second.fill(CGRect(x: 7, y: 0, width: 5, height: 3))
        let images = try [XCTUnwrap(first.makeImage()), XCTUnwrap(second.makeImage())]
        let layout = try LongScreenshot.layout(images: images, joins: [LongScreenshotJoin(overlap: 3, offsetX: -2)])
        let canvas = LongScreenshotCanvas(frame: CGRect(origin: .zero, size: layout.size))
        canvas.images = images
        canvas.placements = layout.placements
        canvas.outputSize = layout.size
        return canvas
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let output = try context(width: image.width, height: image.height)
        output.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(output.data), count: output.bytesPerRow * image.height)
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    private func mouse(_ point: CGPoint, in canvas: NSView, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
