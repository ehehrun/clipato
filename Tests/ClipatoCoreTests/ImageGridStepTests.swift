import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ClipatoCore

final class ImageGridStepTests: XCTestCase {
    func testFourTilesKeepTopLeftToBottomRightPixelOrder() throws {
        let image = try fixture(width: 512, height: 512) { x, y in
            Self.colors[(y / 256) * 2 + x / 256]
        }
        let options = ImageGridOptions(divisions: 2, tileSize: 256)

        for index in 0..<4 {
            let tile = try ImageGridStep.execute(image: image, options: options, index: index)
            XCTAssertEqual(tile.width, 256)
            XCTAssertEqual(tile.height, 256)
            XCTAssertEqual(try pixel(tile, x: 0, y: 0), Self.colors[index])
            XCTAssertEqual(try pixel(tile, x: 255, y: 255), Self.colors[index])
        }
    }

    func testNineTilesSkipActualSourceGapPixels() throws {
        let options = ImageGridOptions(divisions: 3, tileSize: 256, gap: 5)
        XCTAssertEqual(try ImageGridStep.sourceSide(options: options), 778)
        let image = try fixture(width: 778, height: 778) { x, y in
            let column = x / 261
            let row = y / 261
            return x % 261 >= 256 || y % 261 >= 256 ? [255, 255, 255, 255] : Self.colors[row * 3 + column]
        }

        for index in 0..<9 {
            let tile = try ImageGridStep.execute(image: image, options: options, index: index)
            for (x, y) in [(0, 0), (255, 0), (0, 255), (255, 255)] {
                XCTAssertEqual(try pixel(tile, x: x, y: y), Self.colors[index])
            }
        }
    }

    func testSourceRectsUseAnExplicitIntegerCropOffset() throws {
        let options = ImageGridOptions(divisions: 2, tileSize: 256, gap: 3,
                                       crop: CGRect(x: 17, y: 29, width: 515, height: 515))
        XCTAssertEqual(try ImageGridStep.sourceRects(width: 600, height: 580, options: options), [
            CGRect(x: 17, y: 29, width: 256, height: 256),
            CGRect(x: 276, y: 29, width: 256, height: 256),
            CGRect(x: 17, y: 288, width: 256, height: 256),
            CGRect(x: 276, y: 288, width: 256, height: 256)
        ])
        let image = try fixture(width: 600, height: 580) { x, y in
            guard x >= 17, y >= 29, x < 532, y < 544 else { return [0, 0, 0, 255] }
            return Self.colors[((y - 29) / 259) * 2 + (x - 17) / 259]
        }
        for index in 0..<4 {
            let tile = try ImageGridStep.execute(image: image, options: options, index: index)
            XCTAssertEqual(try pixel(tile, x: 64, y: 192), Self.colors[index])
        }
    }

    func testLargerSourceDownsamplesWithoutChangingTileOrder() throws {
        let image = try fixture(width: 1024, height: 1024) { x, y in Self.colors[(y / 512) * 2 + x / 512] }
        for index in 0..<4 {
            let tile = try ImageGridStep.execute(image: image, options: .init(divisions: 2, tileSize: 256), index: index)
            XCTAssertEqual(tile.width, 256)
            XCTAssertEqual(tile.height, 256)
            XCTAssertEqual(try pixel(tile, x: 128, y: 128), Self.colors[index])
        }
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)
    }

    func testNonSquareNeedsAnExplicitCrop() throws {
        let options = ImageGridOptions(divisions: 2, tileSize: 256)
        XCTAssertThrowsError(try ImageGridStep.sourceRects(width: 600, height: 512, options: options)) {
            XCTAssertEqual($0 as? ImageGridError, .requiresCrop)
        }
        XCTAssertThrowsError(try ImageGridStep.sourceRects(width: 600, height: 600,
            options: .init(divisions: 3, tileSize: 256, crop: CGRect(x: 0, y: 0, width: 599, height: 599)))) {
            XCTAssertEqual($0 as? ImageGridError, .sourceTooSmall(requiredSide: 768))
        }
        XCTAssertEqual(try ImageGridStep.sourceRects(width: 600, height: 512,
            options: .init(divisions: 2, tileSize: 256, crop: CGRect(x: 44, y: 0, width: 512, height: 512))).count, 4)
    }

    func testFractionalSourceRectsCoverEveryCropPixelWithoutDiscardingRemainders() throws {
        let crop = CGRect(x: 161, y: 0, width: 245, height: 245)
        let options = ImageGridOptions(divisions: 3, tileSize: 60, crop: crop)
        let rects = try ImageGridStep.sourceRects(width: 576, height: 245, options: options)
        XCTAssertEqual(rects.count, 9)
        XCTAssertEqual(try ImageGridStep.sourceSide(options: options), 180)
        for row in 0..<3 {
            XCTAssertEqual(rects[row * 3].minX, crop.minX, accuracy: 0.000_001)
            XCTAssertEqual(rects[row * 3 + 2].maxX, crop.maxX, accuracy: 0.000_001)
            for column in 0..<2 {
                XCTAssertEqual(rects[row * 3 + column].maxX, rects[row * 3 + column + 1].minX, accuracy: 0.000_001)
            }
        }
        for column in 0..<3 {
            XCTAssertEqual(rects[column].minY, crop.minY, accuracy: 0.000_001)
            XCTAssertEqual(rects[6 + column].maxY, crop.maxY, accuracy: 0.000_001)
            for row in 0..<2 {
                XCTAssertEqual(rects[row * 3 + column].maxY, rects[(row + 1) * 3 + column].minY, accuracy: 0.000_001)
            }
        }
        XCTAssertEqual(rects.reduce(0) { $0 + $1.width * $1.height }, crop.width * crop.height, accuracy: 0.000_001)
        XCTAssertNoThrow(try ImageGridStep.sourceRects(width: 245, height: 245, options: .init(tileSize: 60)))
        XCTAssertNoThrow(try ImageGridStep.sourceRects(width: 513, height: 513, options: .init(divisions: 2, tileSize: 256)))
    }

    func testSmallScreenshotProducesNineSquareTilesMatchingTheEntireCrop() throws {
        let image = try fixture(width: 576, height: 245) { x, y in [UInt8(x / 3), UInt8(y), 77, 255] }
        let crop = CGRect(x: 161, y: 0, width: 245, height: 245)
        let options = ImageGridOptions(divisions: 3, tileSize: 60, crop: crop)
        var joined = [UInt8](repeating: 0, count: 180 * 180 * 4)
        for index in 0..<9 {
            let tile = try ImageGridStep.execute(image: image, options: options, index: index)
            XCTAssertEqual(tile.width, 60)
            XCTAssertEqual(tile.height, 60)
            let pixels = try rgba(tile)
            for row in 0..<60 {
                let outputOffset = ((index / 3 * 60 + row) * 180 + index % 3 * 60) * 4
                joined.replaceSubrange(outputOffset..<(outputOffset + 60 * 4), with: pixels[(row * 60 * 4)..<((row + 1) * 60 * 4)])
            }
        }
        let selected = try XCTUnwrap(image.cropping(to: crop))
        let expected = try ImageResizeStep.execute(image: selected, options: .init(width: 180, height: 180))
        let differences = zip(joined, try rgba(expected)).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max()!, 1)
    }

    func testFractionalTilesKeepTheRequestedGapBetweenSourceRegions() throws {
        let crop = CGRect(x: 11, y: 17, width: 245, height: 245)
        let options = ImageGridOptions(divisions: 3, tileSize: 60, gap: 5, crop: crop)
        let rects = try ImageGridStep.sourceRects(width: 300, height: 280, options: options)
        for row in 0..<3 {
            for column in 0..<2 {
                XCTAssertEqual(rects[row * 3 + column + 1].minX - rects[row * 3 + column].maxX, 5, accuracy: 0.000_001)
            }
        }
        for column in 0..<3 {
            for row in 0..<2 {
                XCTAssertEqual(rects[(row + 1) * 3 + column].minY - rects[row * 3 + column].maxY, 5, accuracy: 0.000_001)
            }
        }
        XCTAssertEqual(rects.last!.maxX, crop.maxX, accuracy: 0.000_001)
        XCTAssertEqual(rects.last!.maxY, crop.maxY, accuracy: 0.000_001)
        let image = try fixture(width: 300, height: 280) { x, y in
            guard let index = rects.firstIndex(where: { $0.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) }) else {
                return [255, 255, 255, 255]
            }
            return Self.colors[index]
        }
        for index in 0..<9 {
            let tile = try ImageGridStep.execute(image: image, options: options, index: index)
            XCTAssertEqual(tile.width, 60)
            XCTAssertEqual(tile.height, 60)
            XCTAssertEqual(try pixel(tile, x: 30, y: 30), Self.colors[index])
        }
    }

    func testOnePixelTilesAndIntegerPNGAlphaArePreserved() throws {
        let minimal = try fixture(width: 2, height: 2) { x, y in Self.colors[y * 2 + x] }
        for index in 0..<4 {
            let tile = try ImageGridStep.execute(image: minimal, options: .init(divisions: 2, tileSize: 1), index: index)
            XCTAssertEqual(tile.width, 1)
            XCTAssertEqual(tile.height, 1)
            XCTAssertEqual(try pixel(tile, x: 0, y: 0), Self.colors[index])
        }
        let alpha = try fixture(width: 4, height: 4) { x, y in
            x < 2 && y < 2 ? [64, 32, 16, 128] : [0, 0, 0, 0]
        }
        for index in 0..<4 {
            let tile = try ImageGridStep.execute(image: alpha, options: .init(divisions: 2, tileSize: 2), index: index)
            let data = try ImageFormatStep.execute(image: tile, format: .png)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(try pixel(decoded, x: 0, y: 0), index == 0 ? [64, 32, 16, 128] : [0, 0, 0, 0])
            XCTAssertEqual(try pixel(decoded, x: 1, y: 1), index == 0 ? [64, 32, 16, 128] : [0, 0, 0, 0])
        }
    }

    func testSmallSourceDoesNotEnlargePixels() throws {
        for options in [ImageGridOptions(divisions: 2, tileSize: 256), .init(divisions: 3, tileSize: 256, gap: 7)] {
            let required = try ImageGridStep.sourceSide(options: options)
            XCTAssertThrowsError(try ImageGridStep.sourceRects(width: required - 1, height: required - 1, options: options)) {
                XCTAssertEqual($0 as? ImageGridError, .sourceTooSmall(requiredSide: required))
            }
        }
        XCTAssertThrowsError(try ImageGridStep.sourceRects(width: 1024, height: 1024,
            options: .init(divisions: 2, tileSize: 1080))) {
            XCTAssertEqual($0 as? ImageGridError, .sourceTooSmall(requiredSide: 2160))
        }
        XCTAssertEqual(try ImageGridStep.sourceRects(width: 1024, height: 1024,
            options: .init(divisions: 2, tileSize: 512)).count, 4)
    }

    func testCropMustBeFiniteIntegralSquareAndWithinSource() throws {
        let invalid = [
            CGRect(x: -1, y: 0, width: 512, height: 512),
            CGRect(x: 0, y: 0, width: 512, height: 513),
            CGRect(x: 89, y: 0, width: 512, height: 512),
            CGRect(x: 0, y: 89, width: 512, height: 512),
            CGRect(x: 0.5, y: 0, width: 512, height: 512),
            CGRect(x: 0, y: 0, width: 512.5, height: 512.5),
            CGRect(x: 0, y: 0, width: 0, height: 0),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity),
            CGRect(x: CGFloat.nan, y: 0, width: 512, height: 512)
        ]
        for crop in invalid {
            XCTAssertThrowsError(try ImageGridStep.sourceRects(width: 600, height: 600,
                options: .init(divisions: 2, tileSize: 256, crop: crop))) {
                XCTAssertEqual($0 as? ImageGridError, .invalidCrop)
            }
        }
    }

    func testInvalidOptionsAndOverflowAreRejectedBeforePixelAllocation() throws {
        for divisions in [0, 1, 4, Int.max] {
            XCTAssertThrowsError(try ImageGridStep.sourceSide(options: .init(divisions: divisions))) {
                XCTAssertEqual($0 as? ImageGridError, .invalidDivisions(divisions))
            }
        }
        for tileSize in [-1, 0, 4097, Int.max] {
            XCTAssertThrowsError(try ImageGridStep.sourceSide(options: .init(tileSize: tileSize))) {
                XCTAssertEqual($0 as? ImageGridError, .invalidTileSize(tileSize))
            }
        }
        for gap in [-1, Int.max, Int.max / 2] {
            XCTAssertThrowsError(try ImageGridStep.sourceSide(options: .init(gap: gap))) {
                XCTAssertEqual($0 as? ImageGridError, .invalidGap(gap))
            }
        }
        for (width, height) in [(0, 1), (1, -1), (Int.max, 1), (1, 32769)] {
            XCTAssertThrowsError(try ImageGridStep.sourceRects(width: width, height: height, options: .init())) {
                XCTAssertEqual($0 as? ImageProcessingError, .invalidDimensions(width: width, height: height))
            }
        }
        XCTAssertThrowsError(try ImageGridStep.sourceRects(width: 8001, height: 8001, options: .init())) {
            XCTAssertEqual($0 as? ImageProcessingError, .canvasTooLarge(width: 8001, height: 8001))
        }
    }

    func testInvalidTileIndexThrows() throws {
        let image = try fixture(width: 512, height: 512) { _, _ in [255, 0, 0, 255] }
        for index in [-1, 4, Int.max] {
            XCTAssertThrowsError(try ImageGridStep.execute(image: image,
                options: .init(divisions: 2, tileSize: 256), index: index)) {
                XCTAssertEqual($0 as? ImageGridError, .invalidIndex(index))
            }
        }
    }

    func testCancelledTaskDoesNotBeginGridWork() async throws {
        let image = try fixture(width: 512, height: 512) { _, _ in [255, 0, 0, 255] }
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ImageGridStep.execute(image: image, options: .init(divisions: 2, tileSize: 256), index: 0)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
    }

    private static let colors: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
        [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255],
        [96, 32, 0, 255], [0, 96, 32, 255], [32, 0, 96, 255]
    ]

    private func fixture(width: Int, height: Int, color: (Int, Int) -> [UInt8]) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                let rgba = color(x, y)
                for channel in 0..<4 { bytes[offset + channel] = rgba[channel] }
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let bytes = try rgba(image)
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }
}
