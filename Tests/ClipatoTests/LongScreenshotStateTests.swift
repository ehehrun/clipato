import CoreGraphics
import ClipatoCore
import XCTest
@testable import Clipato

@MainActor
final class LongScreenshotStateTests: XCTestCase {
    func testReorderingPreservesOnlyUnchangedAdjacentSeamsAndOriginalImageReferences() throws {
        let images = try makeImages()
        let state = LongScreenshotState()
        state.reconcile(images: images, order: [0, 1, 2, 3])
        let first = LongScreenshotJoin(overlap: 2, offsetX: 1, confidence: 0.91)
        let second = LongScreenshotJoin(overlap: 4, offsetX: -2, confidence: 0.92)
        let third = LongScreenshotJoin(overlap: 6, offsetX: 3, confidence: 0.93)
        state.joins = [first, second, third]
        state.analyses = [.matched(first), .matched(second), .matched(third)]

        state.reconcile(images: images, order: [2, 3, 0, 1])

        XCTAssertEqual(state.joins, [third, .init(overlap: 0), first])
        XCTAssertEqual(state.analyses, [.matched(third), .noReliableMatch, .matched(first)])
        XCTAssertEqual(state.order, [2, 3, 0, 1])
        XCTAssertTrue(state.images[0] === images[2])
        XCTAssertTrue(state.images[1] === images[3])
        XCTAssertTrue(state.images[2] === images[0])
        XCTAssertTrue(state.images[3] === images[1])
        XCTAssertEqual(state.placements.count, 4)
    }

    func testDeletingAnIntermediateImageCreatesAZeroSeamAndKeepsUnaffectedSeams() throws {
        let images = try makeImages()
        let state = LongScreenshotState()
        state.reconcile(images: images, order: [0, 1, 2, 3])
        let retained = LongScreenshotJoin(overlap: 5, offsetX: -3, confidence: 0.95)
        state.joins = [.init(overlap: 2), .init(overlap: 3), retained]
        state.analyses = [.duplicate, .noReliableMatch, .matched(retained)]
        state.alignmentUndo = (state.joins, state.analyses)

        state.reconcile(images: images, order: [0, 2, 3])

        XCTAssertEqual(state.joins, [.init(overlap: 0), retained])
        XCTAssertEqual(state.analyses, [.noReliableMatch, .matched(retained)])
        XCTAssertNil(state.alignmentUndo, "An undo for a different image sequence must not be applied.")
        XCTAssertEqual(state.placements.count, 3)
    }

    func testSelectionFollowsTheOriginalImageAndClearsWhenItIsRemoved() throws {
        let images = try makeImages()
        let state = LongScreenshotState()
        state.reconcile(images: images, order: [0, 1, 2, 3])
        state.selectImage(at: 2)
        XCTAssertEqual(state.selectedImagePosition, 2)
        let focusRequest = state.focusRequest

        state.reconcile(images: images, order: [2, 3, 0, 1])

        XCTAssertEqual(state.selectedImagePosition, 0)
        XCTAssertNil(state.selectedJoin)
        XCTAssertTrue(state.showsSelection)
        XCTAssertGreaterThan(state.focusRequest, focusRequest)

        state.reconcile(images: images, order: [3, 0, 1])

        XCTAssertNil(state.selectedImagePosition)
        XCTAssertFalse(state.showsSelection)
        XCTAssertNil(state.selectedJoin)
        state.selectImage(at: 1)
        state.selectImage(at: nil)
        XCTAssertNil(state.selectedImagePosition)
    }

    func testReturningToAnUnchangedOrderPreservesStitchCompletionLayoutAndPreviewSettings() throws {
        let images = try makeImages()
        let state = LongScreenshotState()
        state.reconcile(images: images, order: [0, 1, 2, 3])
        state.hasStartedInitialStitch = true
        state.maximumOverlap = 7
        state.zoom = 1.75
        state.fitsWindow = false
        state.selectImage(at: 1)
        let frames = state.placements
        state.alignmentUndo = (state.joins, state.analyses)
        state.alignmentMessage = "completed"

        state.cancelWork()
        state.reconcile(images: images, order: [0, 1, 2, 3])

        XCTAssertTrue(state.hasStartedInitialStitch)
        XCTAssertEqual(state.placements, frames)
        XCTAssertEqual(state.zoom, 1.75)
        XCTAssertFalse(state.fitsWindow)
        XCTAssertEqual(state.maximumOverlap, 7)
        XCTAssertEqual(state.selectedImagePosition, 1)
        XCTAssertEqual(state.alignmentMessage, "completed")
        XCTAssertNotNil(state.alignmentUndo)

        state.reconcile(images: images, order: [3, 0, 1, 2])
        XCTAssertTrue(state.hasStartedInitialStitch, "Reordering must not schedule another initial automatic stitch.")
        XCTAssertEqual(state.zoom, 1.75)
        XCTAssertEqual(state.maximumOverlap, 7)
    }

    func testCancellationResetsBusyAndStaleTaskCompletionDoesNotFinishNewWork() {
        let state = LongScreenshotState()
        let firstID = state.beginWork()
        let task = Task { await Task.yield() }
        state.workTask = task
        XCTAssertTrue(state.isWorking)

        state.cancelWork()

        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(state.isWorking)
        XCTAssertNil(state.workTask)
        XCTAssertFalse(state.hasStartedInitialStitch, "Non-stitch work must not mark the initial stitching attempt.")
        let nextID = state.beginWork()
        state.finishWork(firstID)
        XCTAssertTrue(state.isWorking)
        state.finishWork(nextID)
        XCTAssertFalse(state.isWorking)
        XCTAssertNil(state.workTask)
    }

    func testCancelledInitialStitchDoesNotRestartAfterManualAdjustmentsAndModeSwitching() throws {
        let images = try makeImages()
        let state = LongScreenshotState()
        state.reconcile(images: images, order: [0, 1, 2, 3])
        _ = state.beginWork(initialStitch: true)
        state.cancelWork()
        let adjusted = LongScreenshotJoin(overlap: 3, offsetX: -2)
        state.joins[0] = adjusted
        state.analyses[0] = .matched(adjusted)

        state.reconcile(images: images, order: [0, 1, 2, 3])

        XCTAssertTrue(state.hasStartedInitialStitch)
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.joins[0], adjusted)
        XCTAssertEqual(state.analyses[0], .matched(adjusted))
    }

    private func makeImages() throws -> [CGImage] {
        try (0..<4).map { index in
            let context = try XCTUnwrap(CGContext(data: nil, width: 16 + index, height: 24,
                                                 bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 4, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16 + index, height: 24))
            return try XCTUnwrap(context.makeImage())
        }
    }
}
