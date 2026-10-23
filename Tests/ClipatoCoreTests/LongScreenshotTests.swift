import CoreGraphics
import XCTest
@testable import ClipatoCore

final class LongScreenshotTests: XCTestCase {
    func testReconstructsThreeOverlappingFramesWithoutResampling() throws {
        let original = image(width: 73, height: 198)
        let frames = [0, 53, 102].map { original.cropping(to: CGRect(x: 0, y: $0, width: 73, height: 96))! }
        var joins: [LongScreenshotJoin] = []
        for index in 1..<frames.count {
            guard case .matched(let join) = try LongScreenshot.analyze(previous: frames[index - 1], next: frames[index]) else {
                return XCTFail("Unique overlapping pixels must match")
            }
            joins.append(join)
        }
        XCTAssertEqual(joins.map(\.overlap), [43, 47])
        let result = try LongScreenshot.render(images: frames, joins: joins)
        XCTAssertEqual(result.width, original.width)
        XCTAssertEqual(result.height, original.height)
        XCTAssertEqual(bytes(result), bytes(original))
    }

    func testTenPixelMinimumIsInclusive() throws {
        let original = image(width: 61, height: 150)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 61, height: 80))!
        let second = original.cropping(to: CGRect(x: 0, y: 70, width: 61, height: 80))!
        guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: second, minimumOverlap: 10) else {
            return XCTFail("Exactly ten overlapping rows are valid")
        }
        XCTAssertEqual(join.overlap, 10)
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second, minimumOverlap: 11), .noReliableMatch)
    }

    func testTenPixelHorizontalOverlapIsInclusive() throws {
        let original = image(width: 150, height: 61)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 61))!
        let next = original.cropping(to: CGRect(x: 70, y: 0, width: 80, height: 61))!
        guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: next, minimumOverlap: 10) else {
            return XCTFail("Exactly ten shared columns must remain usable for horizontal alignment")
        }
        XCTAssertEqual(join.offsetX, 70)
        XCTAssertEqual(join.overlap, 61)
        XCTAssertEqual(bytes(try LongScreenshot.render(images: [first, next], joins: [join])), bytes(original))
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next, minimumOverlap: 11), .noReliableMatch)
    }

    func testDefaultAlignmentReconstructsFivePixelOverlap() throws {
        let original = image(width: 725, height: 253)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 725, height: 129))!
        let next = original.cropping(to: CGRect(x: 0, y: 124, width: 725, height: 129))!
        guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: next) else {
            return XCTFail("Distinct shared content must align even when fewer than ten rows overlap")
        }
        XCTAssertEqual(join.overlap, 5)
        XCTAssertEqual(join.offsetX, 0)
        XCTAssertEqual(bytes(try LongScreenshot.render(images: [first, next], joins: [join])), bytes(original))
        for minimum in [6, 10] {
            XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next, minimumOverlap: minimum), .noReliableMatch)
        }
    }

    func testMaximumOverlapSearchIncludesOneFiveAndTenButExcludesElevenPixels() throws {
        let original = image(width: 240, height: 160)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 80))!
        for overlap in [1, 5, 10, 11] {
            let next = original.cropping(to: CGRect(x: 0, y: 80 - overlap, width: 240, height: 80))!
            XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: 0), .noReliableMatch)
            if overlap == 11 {
                XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: 10), .noReliableMatch)
            }
            guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: overlap) else {
                XCTFail("The inclusive upper bound must accept \(overlap) shared rows")
                continue
            }
            XCTAssertEqual(join.overlap, overlap)
            XCTAssertEqual(join.offsetX, 0)
            let expected = original.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 160 - overlap))!
            XCTAssertEqual(bytes(try LongScreenshot.render(images: [first, next], joins: [join])), bytes(expected))
            if overlap < 10 {
                XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: 10), .matched(join))
            }
        }
    }

    func testMaximumOverlapMeasuresIntersectionForEitherDirectionAndUnequalSizes() throws {
        for horizontal in [false, true] {
            let original = image(width: horizontal ? 160 : 100, height: horizontal ? 100 : 160)
            let first = original.cropping(to: CGRect(x: 0, y: 0, width: horizontal ? 80 : 100, height: horizontal ? 100 : 80))!
            let next = original.cropping(to: CGRect(x: horizontal ? 70 : 0, y: horizontal ? 0 : 70,
                                                    width: horizontal ? 90 : 100, height: horizontal ? 100 : 90))!
            for frames in [[first, next], [next, first]] {
                XCTAssertEqual(try LongScreenshot.analyze(previous: frames[0], next: frames[1], maximumOverlap: 9), .noReliableMatch)
                guard case .matched(let join) = try LongScreenshot.analyze(previous: frames[0], next: frames[1], maximumOverlap: 10) else {
                    XCTFail("Ten shared rows or columns must match in either direction")
                    continue
                }
                XCTAssertEqual(bytes(try LongScreenshot.render(images: frames, joins: [join])), bytes(original))
            }
        }
    }

    func testMaximumOverlapHandlesOnePixelHorizontalBoundary() throws {
        let original = image(width: 159, height: 240)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 240))!
        let next = original.cropping(to: CGRect(x: 79, y: 0, width: 80, height: 240))!
        guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: 1) else {
            return XCTFail("A distinctive single shared column can establish horizontal alignment")
        }
        XCTAssertEqual(join.offsetX, 79)
        XCTAssertEqual(bytes(try LongScreenshot.render(images: [first, next], joins: [join])), bytes(original))
    }

    func testMaximumOverlapBoundsSmallImageExactSearch() throws {
        let original = image(width: 4, height: 4)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 4, height: 3))!
        let next = original.cropping(to: CGRect(x: 0, y: 1, width: 4, height: 3))!
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: 1), .noReliableMatch)
        guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: next, maximumOverlap: 2) else {
            return XCTFail("Small-image exact matching must honor the same inclusive range")
        }
        XCTAssertEqual(join.overlap, 2)
        XCTAssertEqual(bytes(try LongScreenshot.render(images: [first, next], joins: [join])), bytes(original))
    }

    func testMaximumOverlapRejectsOutOfRangeSettingsAndKeepsDuplicateClassification() throws {
        let source = image(width: 80, height: 90)
        for maximum in [-1, 32_769] {
            XCTAssertThrowsError(try LongScreenshot.analyze(previous: source, next: source, maximumOverlap: maximum)) { error in
                guard case LongScreenshotError.invalidSetting = error else { return XCTFail("Expected invalid overlap setting") }
            }
        }
        XCTAssertEqual(try LongScreenshot.analyze(previous: source, next: source, maximumOverlap: 0), .noReliableMatch)
        XCTAssertEqual(try LongScreenshot.analyze(previous: source, next: source, minimumOverlap: 11, maximumOverlap: 10), .noReliableMatch)
        XCTAssertEqual(try LongScreenshot.analyze(previous: source, next: source, maximumOverlap: 10), .duplicate)
        XCTAssertEqual(try LongScreenshot.analyze(previous: source, next: source, maximumOverlap: 32_768), .duplicate)
    }

    func testMaximumOverlapDoesNotResolveAmbiguityInsideRange() throws {
        let tile = bytes(image(width: 80, height: 4))
        let repeated = Array(repeating: tile, count: 20).flatMap { $0 }
        let previous = image(width: 80, height: 80, bytes: repeated)
        var next = repeated
        next.replaceSubrange((70 * 80 * 4)..<next.count, with: bytes(image(width: 80, height: 10, seed: 311)))
        XCTAssertEqual(try LongScreenshot.analyze(previous: previous, next: image(width: 80, height: 80, bytes: next), maximumOverlap: 10), .noReliableMatch)

        let row: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255, 128, 128, 128, 255]
        let smallPrevious = image(width: 3, height: 3, bytes: row + row + row)
        let smallNext = image(width: 3, height: 2, bytes: row + row)
        XCTAssertEqual(try LongScreenshot.analyze(previous: smallPrevious, next: smallNext, maximumOverlap: 1), .noReliableMatch)
    }

    func testSmallPixelImagesStillUseUniqueExactContent() throws {
        let original = image(width: 3, height: 3)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 3, height: 2))!
        let next = original.cropping(to: CGRect(x: 0, y: 1, width: 3, height: 2))!
        guard case .matched(let join) = try LongScreenshot.analyze(previous: first, next: next, minimumOverlap: 1) else {
            return XCTFail("Small images can be aligned exactly without requiring feature descriptors")
        }
        XCTAssertEqual(join.offsetX, 0)
        XCTAssertEqual(join.overlap, 1)
        XCTAssertEqual(bytes(try LongScreenshot.render(images: [first, next], joins: [join])), bytes(original))
    }

    func testSmallRepeatedAndFlatImagesDoNotInventPositions() throws {
        let row: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255, 128, 128, 128, 255]
        let previous = image(width: 3, height: 3, bytes: row + row + row)
        let next = image(width: 3, height: 2, bytes: row + row)
        XCTAssertEqual(try LongScreenshot.analyze(previous: previous, next: next, minimumOverlap: 1), .noReliableMatch)
        let red: [UInt8] = [255, 0, 0, 255]
        let flatA = image(width: 3, height: 3, bytes: Array(repeating: red, count: 9).flatMap { $0 })
        let flatB = image(width: 3, height: 2, bytes: Array(repeating: red, count: 6).flatMap { $0 })
        XCTAssertEqual(try LongScreenshot.analyze(previous: flatA, next: flatB, minimumOverlap: 1), .noReliableMatch)
    }

    func testDuplicateRequiresEveryPixelToMatch() throws {
        let original = image(width: 240, height: 90)
        XCTAssertEqual(try LongScreenshot.analyze(previous: original, next: original), .duplicate)
        var changed = bytes(original)
        changed[4 * (37 * 240 + 1)] ^= 255
        let edited = image(width: 240, height: 90, bytes: changed)
        guard case .matched(let join) = try LongScreenshot.analyze(previous: original, next: edited) else {
            return XCTFail("A minor edit may align at the same position, but is not an exact duplicate")
        }
        XCTAssertEqual(join.offsetX, 0)
        XCTAssertEqual(join.overlap, original.height)
    }

    func testUnrelatedFramesHaveNoReliableMatch() throws {
        XCTAssertEqual(try LongScreenshot.analyze(previous: image(width: 80, height: 90), next: image(width: 80, height: 90, seed: 123)), .noReliableMatch)
    }

    func testBlurredOverlapIsNotSilentlyAccepted() throws {
        let original = image(width: 80, height: 120)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 80))!
        let second = original.cropping(to: CGRect(x: 0, y: 40, width: 80, height: 80))!
        let source = bytes(second)
        var blurred = source
        for y in 1..<79 {
            for x in 1..<79 {
                for channel in 0..<3 {
                    var sum = 0
                    for dy in -1...1 { for dx in -1...1 { sum += Int(source[((y + dy) * 80 + x + dx) * 4 + channel]) } }
                    blurred[(y * 80 + x) * 4 + channel] = UInt8(sum / 9)
                }
            }
        }
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: image(width: 80, height: 80, bytes: blurred)), .noReliableMatch)
    }

    func testRepeatedPatternCannotEstablishUniqueOffset() throws {
        let tile = bytes(image(width: 80, height: 4))
        let repeated = Array(repeating: tile, count: 20).flatMap { $0 }
        let previous = image(width: 80, height: 80, bytes: repeated)
        var next = repeated
        next.replaceSubrange((70 * 80 * 4)..<next.count, with: bytes(image(width: 80, height: 10, seed: 311)))
        XCTAssertEqual(try LongScreenshot.analyze(previous: previous, next: image(width: 80, height: 80, bytes: next)), .noReliableMatch)
    }

    func testUniformColorOverlapHasInsufficientEvidence() throws {
        var first = bytes(image(width: 80, height: 20))
        var next = bytes(image(width: 80, height: 20, seed: 17))
        let flat: [UInt8] = Array(repeating: [UInt8](arrayLiteral: 200, 30, 80, 255), count: 800).flatMap { $0 }
        first.replaceSubrange((10 * 80 * 4)..<first.count, with: flat)
        next.replaceSubrange(0..<(10 * 80 * 4), with: flat)
        XCTAssertEqual(try LongScreenshot.analyze(previous: image(width: 80, height: 20, bytes: first), next: image(width: 80, height: 20, bytes: next)), .noReliableMatch)
    }

    func testLowContrastBackgroundEdgeDoesNotEstablishAnAlignment() throws {
        var values = bytes(image(width: 80, height: 150))
        for index in stride(from: 0, to: values.count, by: 4) {
            for channel in 0..<3 { values[index + channel] = values[index + channel] < 128 ? 235 : 247 }
        }
        let original = image(width: 80, height: 150, bytes: values)
        let first = original.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 80))!
        let next = original.cropping(to: CGRect(x: 0, y: 70, width: 80, height: 80))!
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: next), .noReliableMatch)
    }

    func testChangesInsideIgnoredScrollbarEdgeAreNotClassifiedAsDuplicate() throws {
        let original = image(width: 759, height: 80)
        var changed = bytes(original)
        changed[4 * (37 * 759 + 758)] ^= 255
        let edited = image(width: 759, height: 80, bytes: changed)
        guard case .matched(let join) = try LongScreenshot.analyze(previous: original, next: edited) else {
            return XCTFail("A minor edit may align at the same position, but is not an exact duplicate")
        }
        XCTAssertEqual(join.offsetX, 0)
        XCTAssertEqual(join.overlap, original.height)
    }

    func testApplyingAlignmentKeepsUnmatchedAndDuplicateFramesAtTheirCurrentPositions() throws {
        let frames = (0..<4).map { _ in image(width: 40, height: 50) }
        let joins = [LongScreenshotJoin(overlap: 0), .init(overlap: 0), .init(overlap: 0)]
        let aligned = try LongScreenshot.aligning(joins: joins, analyses: [
            .matched(.init(overlap: 20, offsetX: 8, confidence: 0.98)), .noReliableMatch, .duplicate
        ])
        let layout = try LongScreenshot.layout(images: frames, joins: aligned)
        XCTAssertEqual(layout.placements.map(\.frame.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 30), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 150)])
        XCTAssertEqual(aligned[0].confidence, 0.98)
        XCTAssertEqual(joins, [.init(overlap: 0), .init(overlap: 0), .init(overlap: 0)])
    }

    func testConsecutiveAlignmentUsesAlreadyAlignedPrecedingFrame() throws {
        let frames = (0..<4).map { _ in image(width: 40, height: 50) }
        let joins = [LongScreenshotJoin(overlap: 0), .init(overlap: 0), .init(overlap: 0)]
        let aligned = try LongScreenshot.aligning(joins: joins, analyses: [
            .matched(.init(overlap: 20, offsetX: 8)), .matched(.init(overlap: 35, offsetX: -3)), .noReliableMatch
        ])
        let layout = try LongScreenshot.layout(images: frames, joins: aligned)
        XCTAssertEqual(layout.placements.map(\.frame.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 30), CGPoint(x: 5, y: 45), CGPoint(x: 0, y: 150)])
    }

    func testRequestedZeroOverlapJoinsUnmatchedFrameAndPreservesDuplicatePosition() throws {
        let frames = (0..<4).map { _ in image(width: 40, height: 50) }
        let joins = [LongScreenshotJoin(overlap: -12, offsetX: 6), .init(overlap: 18, offsetX: -9), .init(overlap: 5, offsetX: 14)]
        let original = try LongScreenshot.layout(images: frames, joins: joins)
        let aligned = try LongScreenshot.aligning(joins: joins, analyses: [
            .matched(.init(overlap: 5, offsetX: 3, confidence: 1)), .noReliableMatch, .duplicate
        ], joinUnmatched: true)
        let layout = try LongScreenshot.layout(images: frames, joins: aligned)
        XCTAssertEqual(aligned[1], .init(overlap: 0))
        XCTAssertEqual(layout.placements[1].frame.origin, CGPoint(x: 3, y: 45))
        XCTAssertEqual(layout.placements[2].frame.origin, CGPoint(x: 3, y: 95))
        XCTAssertEqual(layout.placements[3].frame.origin.x - layout.placements[0].frame.origin.x,
                       original.placements[3].frame.origin.x - original.placements[0].frame.origin.x)
        XCTAssertEqual(layout.placements[3].frame.origin.y - layout.placements[0].frame.origin.y,
                       original.placements[3].frame.origin.y - original.placements[0].frame.origin.y)
        XCTAssertNil(aligned[1].confidence)
    }

    func testAlignmentRejectsMismatchedCountAndOverflowWithoutChangingOriginalJoins() {
        let joins = [LongScreenshotJoin(overlap: 0, offsetX: .min)]
        XCTAssertThrowsError(try LongScreenshot.aligning(joins: joins, analyses: []))
        XCTAssertThrowsError(try LongScreenshot.aligning(joins: joins, analyses: [.matched(.init(overlap: 0, offsetX: .max))]))
        XCTAssertEqual(joins[0].offsetX, .min)
    }

    func testManualOffsetsAccumulateAndNormalizeToCanvasOrigin() throws {
        let frames = [image(width: 20, height: 30), image(width: 20, height: 30), image(width: 20, height: 30)]
        let layout = try LongScreenshot.layout(images: frames, joins: [.init(overlap: 10, offsetX: -3), .init(overlap: 5, offsetX: 8)])
        XCTAssertEqual(layout.size, CGSize(width: 28, height: 75))
        XCTAssertEqual(layout.placements.map(\.frame), [CGRect(x: 3, y: 0, width: 20, height: 30), CGRect(x: 0, y: 20, width: 20, height: 30), CGRect(x: 8, y: 45, width: 20, height: 30)])
    }

    func testMovingMiddleFrameKeepsOtherFramesInPlace() throws {
        let frames = [image(width: 20, height: 30), image(width: 20, height: 30), image(width: 20, height: 30)]
        let joins = [LongScreenshotJoin(overlap: 10, offsetX: 3, confidence: 1), .init(overlap: 5, offsetX: 5, confidence: 1)]
        let moved = try LongScreenshot.moving(joins: joins, imageIndex: 1, dx: 8, dy: -6)
        let result = try LongScreenshot.layout(images: frames, joins: moved)
        XCTAssertEqual(result.placements.map(\.frame.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 11, y: 14), CGPoint(x: 8, y: 45)])
        XCTAssertTrue(moved.allSatisfy { $0.confidence == nil })
        XCTAssertEqual(joins.map(\.confidence), [1, 1])
    }

    func testMovingFirstFramePreservesOtherFramesRelativePositions() throws {
        let frames = [image(width: 20, height: 30), image(width: 20, height: 30), image(width: 20, height: 30)]
        let joins = [LongScreenshotJoin(overlap: 10, offsetX: 3, confidence: 1), .init(overlap: 5, offsetX: 5, confidence: 1)]
        let moved = try LongScreenshot.moving(joins: joins, imageIndex: 0, dx: 9, dy: 6)
        let result = try LongScreenshot.layout(images: frames, joins: moved)
        XCTAssertEqual(result.placements.map(\.frame.origin), [CGPoint(x: 6, y: 0), CGPoint(x: 0, y: 14), CGPoint(x: 5, y: 39)])
        XCTAssertNil(moved[0].confidence)
        XCTAssertEqual(moved[1], joins[1])
    }

    func testMovingLastFramePastCanvasOriginPreservesEarlierFrames() throws {
        let frames = [image(width: 20, height: 30), image(width: 20, height: 30), image(width: 20, height: 30)]
        let joins = [LongScreenshotJoin(overlap: 10, offsetX: 3, confidence: 1), .init(overlap: 5, offsetX: 5, confidence: 1)]
        let moved = try LongScreenshot.moving(joins: joins, imageIndex: 2, dx: -12, dy: -52)
        let result = try LongScreenshot.layout(images: frames, joins: moved)
        XCTAssertEqual(result.placements.map(\.frame.origin), [CGPoint(x: 4, y: 7), CGPoint(x: 7, y: 27), CGPoint(x: 0, y: 0)])
        XCTAssertEqual(moved[0], joins[0])
        XCTAssertNil(moved[1].confidence)
    }

    func testSeparatedFramesRenderOriginalPixelsAndWhiteGap() throws {
        let red = image(width: 10, height: 10, bytes: Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, 255), count: 100).flatMap { $0 })
        let blue = image(width: 10, height: 10, bytes: Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 255), count: 100).flatMap { $0 })
        let result = try LongScreenshot.render(images: [red, blue], joins: [.init(overlap: -5, offsetX: 15)])
        XCTAssertEqual(result.width, 25)
        XCTAssertEqual(result.height, 25)
        let output = bytes(result)
        XCTAssertEqual(Array(output[0..<4]), [255, 0, 0, 255])
        XCTAssertEqual(Array(output[(12 * 25 + 12) * 4..<(12 * 25 + 13) * 4]), [255, 255, 255, 255])
        XCTAssertEqual(Array(output[(20 * 25 + 20) * 4..<(20 * 25 + 21) * 4]), [0, 0, 255, 255])
    }

    func testFullCoverageAndOverlapBeyondFrameHeightAreAllowed() throws {
        let first = image(width: 10, height: 10)
        let second = image(width: 10, height: 10, seed: 123)
        let covered = try LongScreenshot.render(images: [first, second], joins: [.init(overlap: 10)])
        XCTAssertEqual(bytes(covered), bytes(second))
        let crossed = try LongScreenshot.render(images: [first, second], joins: [.init(overlap: 15)])
        XCTAssertEqual(crossed.height, 15)
        XCTAssertEqual(bytes(crossed), bytes(second) + Array(bytes(first).suffix(5 * 10 * 4)))
    }

    func testMovingSingleFrameAndZeroMovementAreNoOps() throws {
        XCTAssertEqual(try LongScreenshot.moving(joins: [], imageIndex: 0, dx: .max, dy: .min), [])
        let joins = [LongScreenshotJoin(overlap: 5, offsetX: 0, confidence: 1)]
        XCTAssertEqual(try LongScreenshot.moving(joins: joins, imageIndex: 1, dx: 0, dy: 0), joins)
    }

    func testMoveRejectsInvalidIndexAndIntegerOverflowWithoutChangingInput() {
        let joins = [LongScreenshotJoin(overlap: 5, offsetX: 0, confidence: 1)]
        for index in [-1, 2] {
            XCTAssertThrowsError(try LongScreenshot.moving(joins: joins, imageIndex: index, dx: 1, dy: 1))
        }
        let cases: [(LongScreenshotJoin, Int, Int, Int)] = [
            (.init(overlap: 0, offsetX: .max), 1, 1, 0),
            (.init(overlap: 0, offsetX: .min), 0, 1, 0),
            (.init(overlap: .min), 1, 0, 1),
            (.init(overlap: .max), 0, 0, 1)
        ]
        for (join, index, dx, dy) in cases {
            XCTAssertThrowsError(try LongScreenshot.moving(joins: [join], imageIndex: index, dx: dx, dy: dy))
        }
        XCTAssertEqual(joins, [.init(overlap: 5, offsetX: 0, confidence: 1)])
    }

    func testInvalidArrayAndCanvasOverflowThrowBeforeRendering() throws {
        let source = image(width: 20, height: 30)
        for join in [LongScreenshotJoin(overlap: .min), .init(overlap: .max), .init(overlap: 1, offsetX: .max), .init(overlap: 1, offsetX: .min)] {
            XCTAssertThrowsError(try LongScreenshot.layout(images: [source, source], joins: [join]))
        }
        XCTAssertThrowsError(try LongScreenshot.layout(images: [source, source, source], joins: [.init(overlap: 1, offsetX: .max), .init(overlap: 1, offsetX: 1)]))
        XCTAssertThrowsError(try LongScreenshot.layout(images: [], joins: []))
        XCTAssertThrowsError(try LongScreenshot.layout(images: [source, source], joins: []))
        XCTAssertThrowsError(try LongScreenshot.layout(images: Array(repeating: source, count: 1_100), joins: Array(repeating: .init(overlap: 0), count: 1_099)))
        XCTAssertThrowsError(try LongScreenshot.analyze(previous: source, next: source, minimumOverlap: 0))
    }

    private func image(width: Int, height: Int, seed: UInt64 = 71) -> CGImage {
        var state = seed
        var values = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: values.count, by: 4) {
            for channel in 0..<3 {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                values[index + channel] = UInt8(truncatingIfNeeded: state >> 32)
            }
        }
        return image(width: width, height: height, bytes: values)
    }

    private func image(width: Int, height: Int, bytes: [UInt8]) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}
