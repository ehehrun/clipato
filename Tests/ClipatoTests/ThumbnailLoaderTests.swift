import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

@MainActor
final class ThumbnailLoaderTests: XCTestCase {
    func testThumbnailCapsPixelDimensionsWithoutChangingSource() async throws {
        let url = try fixture(width: 1560, height: 780)
        let bytes = try Data(contentsOf: url)
        let loader = ThumbnailLoader()

        let image = try await loader.image(at: url)

        XCTAssertEqual(image.width, 520)
        XCTAssertEqual(image.height, 260)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testThumbnailAppliesEXIFOrientation() async throws {
        let url = try fixture(width: 1560, height: 780, orientation: 6)
        let bytes = try Data(contentsOf: url)
        let loader = ThumbnailLoader()

        let image = try await loader.image(at: url)

        XCTAssertEqual(image.width, 260)
        XCTAssertEqual(image.height, 520)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testConcurrentRequestsShareDecodedPixels() async throws {
        let url = try fixture(width: 800, height: 400)
        let loader = ThumbnailLoader()
        let images = try await withThrowingTaskGroup(of: CGImage.self) { group in
            for _ in 0..<16 { group.addTask { try await loader.image(at: url) } }
            var images: [CGImage] = []
            for try await image in group { images.append(image) }
            return images
        }

        XCTAssertEqual(images.count, 16)
        let first = try XCTUnwrap(images.first)
        XCTAssertTrue(images.allSatisfy { $0 === first })
    }

    func testInvalidationAndClearReleaseCachedPixels() async throws {
        let url = try fixture(width: 80, height: 40)
        let loader = ThumbnailLoader()
        let original = try await loader.image(at: url)
        await loader.invalidate([url])
        let reloaded = try await loader.image(at: url)
        XCTAssertFalse(original === reloaded)

        try FileManager.default.removeItem(at: url)
        let cached = try await loader.image(at: url)
        XCTAssertTrue(reloaded === cached)
        await loader.clear()
        do {
            _ = try await loader.image(at: url)
            XCTFail("A cleared thumbnail must not outlive its deleted source")
        } catch LibraryError.unreadableImage(let name) {
            XCTAssertEqual(name, url.lastPathComponent)
        }
    }

    func testCorruptImageReportsItsFilename() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("broken.png")
        let bytes = Data("not an image".utf8)
        try bytes.write(to: url)
        let loader = ThumbnailLoader()

        do {
            _ = try await loader.image(at: url)
            XCTFail("Corrupt images must report failure")
        } catch LibraryError.unreadableImage(let name) {
            XCTAssertEqual(name, "broken.png")
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCancelledRequestDoesNotAttemptToReadMissingSource() async throws {
        let url = try temporaryDirectory().appendingPathComponent("missing.png")
        let loader = ThumbnailLoader()
        // Both creation and cancellation happen before this actor yields to the request.
        let request = Task { @MainActor in try await loader.image(at: url) }
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Cancelled offscreen requests must stop")
        } catch is CancellationError {
        }
    }

    func testVideoThumbnailCapsDecodedPixelsAndPreservesOriginalFile() async throws {
        let url = try await videoFixture(width: 1040, height: 520)
        let bytes = try Data(contentsOf: url)
        let loader = ThumbnailLoader()

        let image = try await loader.video(at: url)

        XCTAssertEqual(image.width, 520)
        XCTAssertEqual(image.height, 260)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
        // H.264 transfer metadata affects RGB values; compare against the decoded original, not pre-encode RGB.
        let decoded = try await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: .zero).image
        XCTAssertEqual(decoded.width, 1040)
        XCTAssertEqual(decoded.height, 520)
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let originalPixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(pixel[channel]) - Int(originalPixel[channel])), 3)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testVideoThumbnailAppliesTrackOrientation() async throws {
        let url = try await videoFixture(width: 1040, height: 520, rotated: true)
        let loader = ThumbnailLoader()

        let image = try await loader.video(at: url)

        XCTAssertEqual(image.width, 260)
        XCTAssertEqual(image.height, 520)
    }

    func testConcurrentVideoRequestsShareCachedPixelsAndInvalidationForcesDecode() async throws {
        let url = try await videoFixture(width: 64, height: 32)
        let loader = ThumbnailLoader()
        let images = try await withThrowingTaskGroup(of: CGImage.self) { group in
            for _ in 0..<12 { group.addTask { try await loader.video(at: url) } }
            var result: [CGImage] = []
            for try await image in group { result.append(image) }
            return result
        }
        let original = try XCTUnwrap(images.first)
        XCTAssertEqual(images.count, 12)
        XCTAssertTrue(images.allSatisfy { $0 === original })

        await loader.invalidate([url])
        let reloaded = try await loader.video(at: url)
        XCTAssertFalse(reloaded === original)
        try FileManager.default.removeItem(at: url)
        let cached = try await loader.video(at: url)
        XCTAssertTrue(reloaded === cached)
        await loader.clear()
        do {
            _ = try await loader.video(at: url)
            XCTFail("Clearing the shared cache must release video thumbnails too")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancelledVideoRequestDoesNotReadMissingSource() async throws {
        let url = try temporaryDirectory().appendingPathComponent("missing.mp4")
        let loader = ThumbnailLoader()
        let request = Task { @MainActor in try await loader.video(at: url) }
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Cancelled offscreen video requests must stop")
        } catch is CancellationError {
        }
    }

    func testCorruptVideoFailureDoesNotBlockFollowingThumbnailRequest() async throws {
        let url = try temporaryDirectory().appendingPathComponent("corrupt.mp4")
        let bytes = Data("not a video".utf8)
        try bytes.write(to: url)
        let loader = ThumbnailLoader()
        do {
            _ = try await loader.video(at: url)
            XCTFail("Corrupt video must report the AVFoundation failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        let validURL = try await videoFixture(width: 64, height: 32)
        let image = try await loader.video(at: validURL)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 32)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func videoFixture(width: Int, height: Int, rotated: Bool = false) async throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                          &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        while !input.isReadyForMoreMediaData {
            if let error = writer.error { throw error }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        if let error = writer.error { throw error }
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func fixture(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("source.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-ThumbnailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
