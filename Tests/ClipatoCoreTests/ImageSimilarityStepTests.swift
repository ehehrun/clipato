import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import ClipatoCore

final class ImageSimilarityStepTests: XCTestCase {
    func testRealJPEGCompressionAndWholeImageResizingAreSimilar() throws {
        let directory = try temporaryDirectory()
        let original = try fixture(seed: 42)
        let png = try write(original, "original.png", in: directory)
        let compressed = try write(original, "quality25.jpeg", in: directory, quality: 0.25)
        let smaller = try write(resized(original, width: 480, height: 360), "smaller.jpeg", in: directory, quality: 0.5)
        for candidate in [compressed, smaller] {
            let result = try XCTUnwrap(ImageSimilarityStep.execute(urls: [png, candidate]).first)
            XCTAssertEqual(result.first, png)
            XCTAssertEqual(result.second, candidate)
            XCTAssertEqual(result.kind, .similar)
            XCTAssertTrue((0...1).contains(result.score))
        }
    }

    func testNoncentralCropAndScaledCompressedCropAreFoundInEitherInputOrder() throws {
        let directory = try temporaryDirectory()
        let original = try fixture(seed: 42)
        let crop = try XCTUnwrap(original.cropping(to: CGRect(x: 285, y: 45, width: 270, height: 310)))
        let png = try write(original, "original.png", in: directory)
        let cropped = try write(crop, "crop.png", in: directory)
        let compressed = try write(crop, "crop.jpeg", in: directory, quality: 0.45)
        let scaled = try write(resized(crop, width: 432, height: 496), "scaled-crop.jpeg", in: directory, quality: 0.35)
        for candidate in [cropped, compressed, scaled] {
            XCTAssertEqual(try ImageSimilarityStep.execute(urls: [png, candidate]).first?.kind, .firstContainsSecond)
            XCTAssertEqual(try ImageSimilarityStep.execute(urls: [candidate, png]).first?.kind, .secondContainsFirst)
        }
    }

    func testUnrelatedPicturesAndDifferentSolidColorsAreNotMatches() throws {
        let directory = try temporaryDirectory()
        let files = try [
            write(fixture(seed: 42), "first.png", in: directory),
            write(fixture(seed: 9), "other.png", in: directory),
            write(solid(red: 1, green: 0, blue: 0), "red.png", in: directory),
            write(solid(red: 0, green: 1, blue: 0), "green.png", in: directory),
            write(solid(red: 0, green: 0, blue: 1), "blue.png", in: directory)
        ]
        XCTAssertTrue(try ImageSimilarityStep.execute(urls: files).isEmpty)
    }

    func testSharedInterfaceChromeDoesNotMatchDifferentMainContent() throws {
        let directory = try temporaryDirectory()
        let first = try write(fixture(seed: 42, template: true), "first.png", in: directory)
        let second = try write(fixture(seed: 777, template: true), "second.png", in: directory)
        XCTAssertTrue(try ImageSimilarityStep.execute(urls: [first, second]).isEmpty)
    }

    func testAnimatedFileUsesOnlyItsFirstFrame() throws {
        let directory = try temporaryDirectory()
        let firstFrame = try fixture(seed: 42)
        let laterFrame = try fixture(seed: 9)
        let first = try write(firstFrame, "first.png", in: directory)
        let later = try write(laterFrame, "later.png", in: directory)
        let gif = directory.appendingPathComponent("animated.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, firstFrame, nil)
        CGImageDestinationAddImage(destination, laterFrame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertEqual(try ImageSimilarityStep.execute(urls: [first, gif]).first?.kind, .similar)
        XCTAssertTrue(try ImageSimilarityStep.execute(urls: [later, gif]).isEmpty)
    }

    func testEXIFOrientationIsAppliedBeforeComparison() throws {
        let directory = try temporaryDirectory()
        let original = try fixture(seed: 42)
        let oriented = directory.appendingPathComponent("oriented.jpeg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(oriented as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 6,
                                         kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, original, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(oriented as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        let context = try bitmap(width: original.height, height: original.width)
        context.translateBy(x: 0, y: CGFloat(original.width))
        context.rotate(by: -.pi / 2)
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        let reference = try write(XCTUnwrap(context.makeImage()), "rotated.png", in: directory)

        XCTAssertEqual(try ImageSimilarityStep.execute(urls: [reference, oriented]).first?.kind, .similar)
    }

    func testLargeIdenticalBatchUsesRepresentativeLinksWithoutDroppingAnyFile() throws {
        let directory = try temporaryDirectory()
        let original = try fixture(seed: 42)
        let first = try write(original, "original.png", in: directory)
        var urls = [first]
        for index in 1..<110 {
            let url = directory.appendingPathComponent("copy-\(index).png")
            try FileManager.default.copyItem(at: first, to: url)
            urls.append(url)
        }
        let matches = try ImageSimilarityStep.execute(urls: urls)
        let covered = Set(matches.flatMap { [$0.first, $0.second] })
        XCTAssertEqual(covered, Set(urls))
        XCTAssertTrue(matches.allSatisfy { $0.kind == .similar })
        XCTAssertEqual(matches.count, urls.count - 1, "Verified whole-image copies should link to a representative, not form all pairs.")
    }

    func testReadErrorsAreExplicitAndCancellationDoesNotReturnPartialMatches() async throws {
        let directory = try temporaryDirectory()
        let first = try write(fixture(seed: 42), "first.png", in: directory)
        let invalid = directory.appendingPathComponent("broken.png")
        try Data([1, 2, 3]).write(to: invalid)
        XCTAssertThrowsError(try ImageSimilarityStep.execute(urls: [first, invalid])) { error in
            guard case ImageSimilarityError.unreadableImage(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, invalid)
        }
        let task = Task.detached { try ImageSimilarityStep.execute(urls: [first, first]) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return a successful empty result.")
        } catch is CancellationError {
        }
    }

    private func fixture(seed: UInt64, template: Bool = false) throws -> CGImage {
        let width = 640, height = 480
        let context = try bitmap(width: width, height: height)
        context.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var state = seed
        func next() -> Int { state = state &* 6364136223846793005 &+ 1; return Int(state >> 33) }
        if template {
            context.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 0.93, alpha: 1))
            context.fill(CGRect(x: 0, y: 430, width: width, height: 50))
            context.setFillColor(CGColor(red: 0.9, green: 0.92, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 430))
        }
        for index in 0..<110 {
            let x = (template ? 100 : 5) + next() % (template ? 480 : 590), y = 5 + next() % 410
            context.setFillColor(CGColor(red: CGFloat(next() % 220) / 255, green: CGFloat(next() % 220) / 255,
                                        blue: CGFloat(next() % 220) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 12 + next() % 55, height: 8 + next() % 50))
            let attributes = [kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                              kCTForegroundColorAttributeName: CGColor(gray: 0.12, alpha: 1)] as CFDictionary
            let text = try XCTUnwrap(CFAttributedStringCreate(nil, "Item \(index) \(next() % 9999)" as CFString, attributes))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try bitmap(width: 160, height: 120)
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return try XCTUnwrap(context.makeImage())
    }

    private func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func write(_ image: CGImage, _ name: String, in directory: URL, quality: Double? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let type = quality == nil ? "public.png" : "public.jpeg"
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-Similarity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
