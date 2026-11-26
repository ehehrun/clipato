import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

final class AnimatedImagePreviewLoadingTests: XCTestCase {
    func testAnimatedGIFKeepsItsNativeMultiframeRepresentationAndLoopMetadata() throws {
        let url = try writeGIF(frameCount: 3, extensionName: "gif")
        guard case .animated(let image) = try ImagePreviewAsset.load(at: url) else {
            return XCTFail("Animated GIF was flattened into a still image")
        }
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(image.representations.count, 1)
        XCTAssertEqual((representation.value(forProperty: .frameCount) as? NSNumber)?.intValue, 3)
        XCTAssertEqual((representation.value(forProperty: .loopCount) as? NSNumber)?.intValue, 0)
        XCTAssertEqual(representation.pixelsWide, 12)
        XCTAssertEqual(representation.pixelsHigh, 8)
    }

    func testAnimationDetectionUsesFileContentsRatherThanTheFilenameExtension() throws {
        let url = try writeGIF(frameCount: 2, extensionName: "data")
        guard case .animated(let image) = try ImagePreviewAsset.load(at: url) else {
            return XCTFail("GIF contents must retain animation even after renaming")
        }
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual((representation.value(forProperty: .frameCount) as? NSNumber)?.intValue, 2)
    }

    func testSingleFrameGIFUsesTheExistingStaticImagePath() throws {
        let url = try writeGIF(frameCount: 1, extensionName: "gif")
        guard case .still(let image) = try ImagePreviewAsset.load(at: url) else {
            return XCTFail("Single-frame GIF must keep the static image and Live Text path")
        }
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 8)
    }

    func testStaticImageStillAppliesOrientationBeforePreviewing() throws {
        let url = try temporaryURL(extensionName: "tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        guard case .still(let image) = try ImagePreviewAsset.load(at: url) else {
            return XCTFail("Static TIFF must retain the static preview path")
        }
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 12)
    }

    func testInvalidGIFReportsAnImageReadError() throws {
        let url = try temporaryURL(extensionName: "gif")
        try Data("invalid gif contents".utf8).write(to: url)
        XCTAssertThrowsError(try ImagePreviewAsset.load(at: url)) { error in
            guard case LibraryError.unreadableImage(let filename) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(filename, url.lastPathComponent)
        }
    }

    private func writeGIF(frameCount: Int, extensionName: String) throws -> URL {
        let url = try temporaryURL(extensionName: extensionName)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frameCount {
            let frame = try image(gray: CGFloat(index) / CGFloat(frameCount))
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.1,
                kCGImagePropertyGIFUnclampedDelayTime: 0.1,
            ]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func image(gray: CGFloat = 0.5) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 48,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    private func temporaryURL(extensionName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-PreviewLoading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("preview.\(extensionName)")
    }
}
