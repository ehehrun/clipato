import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipatoCore

final class ImageProcessingTests: XCTestCase {
    func testFitPadAndCropProduceTheirActualPixelLayouts() throws {
        let image = try stripes(width: 120, height: 60)
        let fit = try ImageResizeStep.execute(image: image, options: .init(width: 60, height: 60))
        XCTAssertEqual(fit.width, 60)
        XCTAssertEqual(fit.height, 30)
        XCTAssertEqual(try pixel(fit, x: 10, y: 15), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(fit, x: 30, y: 15), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(fit, x: 50, y: 15), [0, 0, 255, 255])

        let pad = try ImageResizeStep.execute(image: image, options: .init(width: 60, height: 60, mode: .pad))
        XCTAssertEqual(pad.width, 60)
        XCTAssertEqual(pad.height, 60)
        XCTAssertEqual(try pixel(pad, x: 30, y: 5), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(pad, x: 30, y: 55), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(pad, x: 30, y: 30), [0, 255, 0, 255])

        let crop = try ImageResizeStep.execute(image: image, options: .init(width: 60, height: 60, mode: .crop))
        XCTAssertEqual(crop.width, 60)
        XCTAssertEqual(crop.height, 60)
        XCTAssertEqual(try pixel(crop, x: 5, y: 30), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(crop, x: 30, y: 30), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(crop, x: 55, y: 30), [0, 0, 255, 255])
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 60)
    }

    func testInvalidDimensionsAndCanvasAreaFailBeforeAllocation() throws {
        let image = try stripes(width: 6, height: 3)
        for dimensions in [(0, 1), (1, -1), (32_769, 1), (1, Int.max)] {
            XCTAssertThrowsError(try ImageResizeStep.execute(image: image,
                options: .init(width: dimensions.0, height: dimensions.1))) { error in
                guard case ImageProcessingError.invalidDimensions = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertThrowsError(try ImageResizeStep.execute(image: image, options: .init(width: 10_000, height: 10_000, mode: .pad))) { error in
            guard case ImageProcessingError.canvasTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        for quality in [0, 101] {
            XCTAssertThrowsError(try ImageFormatStep.execute(image: image, format: .jpeg, quality: quality)) { error in
                XCTAssertEqual(error as? ImageProcessingError, .invalidQuality(quality))
            }
        }
    }

    func testPNGAndBothWebPModesPreserveTransparentAndSemitransparentPixels() throws {
        let image = try alphaFixture()
        let original = try rgba(image)
        for (format, quality) in [(ImageOutputFormat.png, 100), (.webp, 80), (.webp, 100)] {
            let data = try ImageFormatStep.execute(image: image, format: format, quality: quality)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source), (format == .png ? UTType.png.identifier : "org.webmproject.webp") as CFString)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 4)
            XCTAssertEqual(decoded.height, 1)
            let pixels = try rgba(decoded)
            XCTAssertEqual(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }, [0, 64, 128, 255])
            if quality == 100 {
                for index in pixels.indices { XCTAssertLessThanOrEqual(abs(Int(pixels[index]) - Int(original[index])), 1) }
            }
        }
    }

    func testJPEGCompositesTransparencyOverWhite() throws {
        for (alpha, expected) in [(0.0, [255, 255, 255]), (0.5, [255, 127, 127])] {
            let image = try solid(width: 16, height: 16, red: 1, green: 0, blue: 0, alpha: alpha)
            let data = try ImageFormatStep.execute(image: image, format: .jpeg, quality: 100)
            let decoded = try decode(data)
            let actual = try pixel(decoded, x: 8, y: 8)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - expected[channel]), 3) }
            XCTAssertEqual(actual[3], 255)
        }
    }

    func testJPEGToPNGLeavesOriginalFileUntouched() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("original.jpeg")
        let original = try ImageFormatStep.execute(image: stripes(width: 90, height: 60), format: .jpeg, quality: 90)
        try original.write(to: url)
        let data = try ImageFormatStep.execute(image: ImageFormatStep.readImage(at: url), format: .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source), UTType.png.identifier as CFString)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 90)
        XCTAssertEqual(image.height, 60)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testEXIFOrientationIsBakedOnceAndDownsamplingUsesOrientedDimensions() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("rotated.jpeg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try stripes(width: 120, height: 60), [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 1
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let oriented = try ImageFormatStep.readImage(at: url)
        XCTAssertEqual(oriented.width, 60)
        XCTAssertEqual(oriented.height, 120)
        let converted = directory.appendingPathComponent("upright.png")
        try ImageFormatStep.execute(image: oriented, format: .png).write(to: converted)
        let reread = try ImageFormatStep.readImage(at: converted)
        XCTAssertEqual(reread.width, 60)
        XCTAssertEqual(reread.height, 120)
        XCTAssertEqual(try rgba(reread), try rgba(oriented))
        let thumbnail = try ImageFormatStep.readImage(at: url, maximumDimension: 30)
        XCTAssertEqual(thumbnail.width, 15)
        XCTAssertEqual(thumbnail.height, 30)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAnimatedImageUsesOnlyTheFirstFrame() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("animated.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try solid(width: 12, height: 8, red: 1, green: 0, blue: 0), nil)
        CGImageDestinationAddImage(destination, try solid(width: 12, height: 8, red: 0, green: 0, blue: 1), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let first = try ImageFormatStep.readImage(at: url)

        XCTAssertEqual(first.width, 12)
        XCTAssertEqual(first.height, 8)
        XCTAssertEqual(try pixel(first, x: 6, y: 4), [255, 0, 0, 255])
    }

    func testHEICInputConvertsToJPEGWithoutRequiringHEICOutputSupport() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("source.heic")
        let fixture = try solid(width: 64, height: 48, red: 0.2, green: 0.6, blue: 0.8)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("The system HEIC fixture encoder is unavailable.")
        }
        CGImageDestinationAddImage(destination, fixture, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("The system HEIC fixture encoder cannot run in this environment.")
        }
        let original = try Data(contentsOf: url)
        let decoded = try ImageFormatStep.readImage(at: url)
        let jpeg = try decode(ImageFormatStep.execute(image: decoded, format: .jpeg, quality: 95))
        XCTAssertEqual(jpeg.width, 64)
        XCTAssertEqual(jpeg.height, 48)
        let color = try pixel(jpeg, x: 32, y: 24)
        for (actual, expected) in zip(color.prefix(3), [51, 153, 204]) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 12)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPNGTrailerValidationRejectsTruncatedFiles() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("truncated.png")
        let data = try ImageFormatStep.execute(image: stripes(width: 30, height: 15), format: .png)
        try data.write(to: url)
        XCTAssertNoThrow(try ImageFormatStep.validatePNGEnd(at: url))
        try data.dropLast(12).write(to: url)
        for operation in [{ try ImageFormatStep.validatePNGEnd(at: url) }, { _ = try ImageFormatStep.readImage(at: url) }] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? ImageProcessingError, .unreadableImage(url))
            }
        }
    }

    func testLongPNGAndJPEGAreNotRestrictedByWebPDimensions() throws {
        let image = try solid(width: 20_000, height: 4, red: 0.2, green: 0.4, blue: 0.6)
        for format in [ImageOutputFormat.png, .jpeg] {
            let decoded = try decode(ImageFormatStep.execute(image: image, format: format))
            XCTAssertEqual(decoded.width, 20_000)
            XCTAssertEqual(decoded.height, 4)
        }
        XCTAssertThrowsError(try ImageFormatStep.execute(image: image, format: .webp)) { error in
            XCTAssertEqual(error as? ImageProcessingError, .invalidWebPDimensions(width: 20_000, height: 4))
        }
    }

    func testCompressionFindsHighQualityWithoutChangingDimensionsWhenPossible() throws {
        let image = try noise(width: 128, height: 96)
        for format in [ImageOutputFormat.jpeg, .webp] {
            let target = try ImageFormatStep.execute(image: image, format: format, quality: 75).count
            let result = try ImageCompressionStep.execute(image: image, format: format, targetBytes: target, allowResizing: false)
            XCTAssertLessThanOrEqual(result.data.count, target)
            XCTAssertGreaterThanOrEqual(result.quality, 75)
            XCTAssertEqual(result.width, 128)
            XCTAssertEqual(result.height, 96)
            let decoded = try decode(result.data)
            XCTAssertEqual(decoded.width, result.width)
            XCTAssertEqual(decoded.height, result.height)
        }
    }

    func testWebPCompressionResizesOversizedInputsOnlyWhenPermitted() throws {
        let image = try stripes(width: 20_000, height: 4)
        let original = try rgba(image)

        let result = try ImageCompressionStep.execute(image: image, format: .webp, targetBytes: 2_048)

        XCTAssertLessThanOrEqual(result.data.count, 2_048)
        XCTAssertEqual(result.width, 16_383)
        XCTAssertEqual(result.height, 3)
        let decoded = try decode(result.data)
        XCTAssertEqual(decoded.width, result.width)
        XCTAssertEqual(decoded.height, result.height)
        XCTAssertEqual(try rgba(image), original)
        XCTAssertThrowsError(try ImageCompressionStep.execute(image: image, format: .webp, targetBytes: 2_048, allowResizing: false)) { error in
            XCTAssertEqual(error as? ImageProcessingError, .invalidWebPDimensions(width: 20_000, height: 4))
        }
    }

    func testCompressionCanReduceJPEGQualityBelow55WhenResizingIsDisabled() throws {
        let image = try noise(width: 128, height: 96)
        let lowestQualityBytes = try ImageFormatStep.execute(image: image, format: .jpeg, quality: 1).count
        let preferredQualityBytes = try ImageFormatStep.execute(image: image, format: .jpeg, quality: 55).count
        XCTAssertLessThan(lowestQualityBytes, preferredQualityBytes)
        let target = lowestQualityBytes + (preferredQualityBytes - lowestQualityBytes) / 2
        XCTAssertLessThan(target, preferredQualityBytes)

        let result = try ImageCompressionStep.execute(image: image, format: .jpeg, targetBytes: target, allowResizing: false)

        XCTAssertLessThanOrEqual(result.data.count, target)
        XCTAssertTrue((1..<55).contains(result.quality))
        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
        let decoded = try decode(result.data)
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    func testCompressionReachesTheRealByteTargetForAllFormats() throws {
        let image = try noise(width: 128, height: 96)
        let original = try rgba(image)
        for format in ImageOutputFormat.allCases {
            let result = try ImageCompressionStep.execute(image: image, format: format, targetBytes: 800)
            XCTAssertLessThanOrEqual(result.data.count, 800)
            XCTAssertLessThan(result.width, image.width)
            XCTAssertLessThan(result.height, image.height)
            let decoded = try decode(result.data)
            XCTAssertEqual(decoded.width, result.width)
            XCTAssertEqual(decoded.height, result.height)
            XCTAssertTrue((55...100).contains(result.quality))
            if format == .png { XCTAssertEqual(result.quality, 100) }
        }
        XCTAssertEqual(try rgba(image), original)
    }

    func testImpossibleTargetsFailInsteadOfReturningOversizedOrResizedResults() throws {
        let image = try noise(width: 16, height: 12)
        for format in ImageOutputFormat.allCases {
            XCTAssertThrowsError(try ImageCompressionStep.execute(image: image, format: format, targetBytes: 1, allowResizing: false)) { error in
                guard case ImageProcessingError.targetUnreachable(let target, let smallest) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(target, 1)
                XCTAssertGreaterThan(smallest, target)
            }
        }
        XCTAssertThrowsError(try ImageCompressionStep.execute(image: image, format: .png, targetBytes: 1)) { error in
            guard case ImageProcessingError.targetUnreachable(let target, let smallest) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(target, 1)
            XCTAssertGreaterThan(smallest, target)
        }
        XCTAssertThrowsError(try ImageCompressionStep.execute(image: image, format: .jpeg, targetBytes: 0)) { error in
            XCTAssertEqual(error as? ImageProcessingError, .invalidTargetBytes(0))
        }
    }

    func testCancelledStepsStopBeforeProcessing() async throws {
        let image = try stripes(width: 120, height: 60)
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let operations: [() throws -> Void] = [
                { _ = try ImageResizeStep.execute(image: image, options: .init(width: 60, height: 60)) },
                { _ = try ImageFormatStep.execute(image: image, format: .webp) },
                { _ = try ImageCompressionStep.execute(image: image, format: .jpeg, targetBytes: 800) }
            ]
            var cancelledCount = 0
            for operation in operations {
                do { try operation() }
                catch is CancellationError { cancelledCount += 1 }
                catch { return false }
            }
            return cancelledCount == operations.count
        }.value
        XCTAssertTrue(cancelled)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-ImageProcessing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func solid(width: Int, height: Int, red: Double, green: Double, blue: Double, alpha: Double = 1) throws -> CGImage {
        let bitmap = try context(width: width, height: height)
        bitmap.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func stripes(width: Int, height: Int) throws -> CGImage {
        let bitmap = try context(width: width, height: height)
        for (index, color) in [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                               CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                               CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            bitmap.setFillColor(color)
            bitmap.fill(CGRect(x: index * width / 3, y: 0, width: width / 3, height: height))
        }
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func alphaFixture() throws -> CGImage {
        let bitmap = try context(width: 4, height: 1)
        for (index, alpha) in [0, 64, 128, 255].enumerated() {
            bitmap.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0.25, alpha: Double(alpha) / 255))
            bitmap.fill(CGRect(x: index, y: 0, width: 1, height: 1))
        }
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func noise(width: Int, height: Int) throws -> CGImage {
        let bitmap = try context(width: width, height: height)
        let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        var state: UInt32 = 42
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            for channel in 0..<3 {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[index + channel] = UInt8(truncatingIfNeeded: state >> 24)
            }
            bytes[index + 3] = 255
        }
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let bitmap = try context(width: image.width, height: image.height)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let pixels = try rgba(image)
        let offset = (y * image.width + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }
}
