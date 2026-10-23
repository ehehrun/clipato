import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

final class KeyframeExporterTests: XCTestCase {
    func testGIFPreservesPixelsQuantizedTimelineAndInfiniteLoop() async throws {
        let directory = try session(times: [0.2, 0.715, 1.344], duration: 2.357)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("exports/演示.gif")
        try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 1280)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount] as? Int, 0)
        for (index, delay) in [0.72, 0.62, 1.02].enumerated() {
            XCTAssertEqual(try gifDelay(source, index: index), delay, accuracy: 0.0001)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 48)
            try assertPixels(image, match: frame(index: index), tolerance: 0)
        }
    }

    func testGIFSplitsLongHoldWithoutLosingDuration() async throws {
        let directory = try session(times: [0.3], duration: 700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("long.gif")
        try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertEqual(try gifDelay(source, index: 0), 655.35, accuracy: 0.001)
        XCTAssertEqual(try gifDelay(source, index: 1), 44.65, accuracy: 0.001)
    }

    func testMP4PreservesVariableSamplesFullDurationAndImageOrientation() async throws {
        let directory = try session(times: [0.2, 0.715, 1.344], duration: 2.357)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("slides.mp4")
        try await KeyframeExporter.export(directory: directory, output: output, format: .mp4, maxDimension: 1920)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.357, accuracy: 0.001)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 64, height: 48))
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)), kCMVideoCodecType_H264)
        XCTAssertEqual(try sampleTimes(asset, track: track), [0, 0.715, 1.344])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (index, time) in [0.1, 1.0, 2.3].enumerated() {
            let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000))
            try assertPixels(result.image, match: frame(index: index), tolerance: 12)
        }
    }

    func testOneFrameMP4RetainsTailAndDownscalesToEvenDimensions() async throws {
        let directory = try session(times: [0.4], duration: 2.25)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("static.mp4")
        try await KeyframeExporter.export(directory: directory, output: output, format: .mp4, maxDimension: 33)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.25, accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 32, height: 24))
        XCTAssertEqual(try sampleTimes(asset, track: track), [0])
        let image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 2.2, preferredTimescale: 600))
        XCTAssertEqual(image.image.width, 32)
    }

    func testOccupiedOutputAndFailedReplacementPreserveExistingFileAndSource() async throws {
        let directory = try session(times: [0, 1], duration: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("existing.gif")
        let old = Data("existing user's export".utf8)
        try old.write(to: output)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        await expectFailure { try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64) }
        XCTAssertEqual(try Data(contentsOf: output), old)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("frames/000002.png"))
        await expectFailure { try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64, overwrite: true) }
        XCTAssertEqual(try Data(contentsOf: output), old)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), manifest)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".partial.") })
    }

    func testExplicitReplacementPublishesOnlyCompletedGIF() async throws {
        let directory = try session(times: [0], duration: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("existing.gif")
        try Data("old".utf8).write(to: output)
        try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64, overwrite: true)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
    }

    func testCorruptOrWrongSizedPNGDoesNotPublishOutput() async throws {
        for damage in ["notPNG", "wrongSize", "truncated"] {
            let directory = try session(times: [0], duration: 1)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = directory.appendingPathComponent("frames/000001.png")
            switch damage {
            case "notPNG": try Data("not a png".utf8).write(to: input)
            case "wrongSize": try writePNG(frame(index: 0, width: 32), to: input)
            default:
                let data = try Data(contentsOf: input)
                try data.dropLast(20).write(to: input)
            }
            let output = directory.appendingPathComponent("bad.gif")
            await expectFailure { try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".partial.") })
        }
    }

    func testInvalidTimelineAndSourcePathsAreRejectedWithoutChangingSources() async throws {
        let directory = try session(times: [0], duration: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        for frames in [
            [KeyframeManifest.Frame(file: "frames/000001.png", time: 0.5), .init(file: "frames/000001.png", time: 0.4)],
            [.init(file: "../outside.png", time: 0)],
            [.init(file: "frames/000001.png", time: 1)],
            [.init(file: "frames/000001.png", time: 0), .init(file: "frames/000001.png", time: 0.001)]
        ] {
            try writeManifest(directory, frames: frames, duration: 1)
            await expectFailure { try await KeyframeExporter.export(directory: directory, output: directory.appendingPathComponent("invalid.gif"), format: .gif, maxDimension: 64) }
        }
        try writeManifest(directory, frames: [.init(file: "frames/000001.png", time: 0)], duration: 1)
        try Data("original player".utf8).write(to: directory.appendingPathComponent("player.html"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.gif"), withDestinationURL: directory.appendingPathComponent("frames/000001.png"))
        for file in ["manifest.json", "player.html", "frames/000001.png", "linked.gif"] {
            let output = directory.appendingPathComponent(file)
            let original = try Data(contentsOf: output)
            await expectFailure { try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64, overwrite: true) }
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
    }

    func testCancellationDoesNotPublishAndRemovesPartialFile() async throws {
        let directory = try session(times: [0], duration: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = (0..<10_000).map { KeyframeManifest.Frame(file: "frames/000001.png", time: Double($0) * 0.1) }
        try writeManifest(directory, frames: frames, duration: 1000)
        let output = directory.appendingPathComponent("cancelled.gif")
        let started = expectation(description: "export has started")
        let task = Task {
            try await KeyframeExporter.export(directory: directory, output: output, format: .gif, maxDimension: 64) { value in
                if value == 0 { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".partial.") })
    }

    private func session(times: [Double], duration: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let frames = try times.enumerated().map { index, time in
            let file = String(format: "frames/%06d.png", index + 1)
            try writePNG(frame(index: index), to: directory.appendingPathComponent(file))
            return KeyframeManifest.Frame(file: file, time: time)
        }
        try writeManifest(directory, frames: frames, duration: duration)
        return directory
    }

    private func writeManifest(_ directory: URL, frames: [KeyframeManifest.Frame], duration: Double) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: duration, sampleRate: 2, threshold: 0.025, width: 64, height: 48, frames: frames)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func frame(index: Int, width: Int = 64) throws -> CGImage {
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
        let top = colors[index % colors.count]
        let bottom: [UInt8] = [255, 255, 0, 255]
        var bytes: [UInt8] = []
        for y in 0..<48 {
            for _ in 0..<width { bytes += y < 24 ? top : bottom }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func gifDelay(_ source: CGImageSource, index: Int) throws -> Double {
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        return try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
    }

    private func assertPixels(_ actual: CGImage, match expected: CGImage, tolerance: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        for y in [8, 40] {
            let actualPixel = try pixel(actual, x: 8, y: y)
            let expectedPixel = try pixel(expected, x: 8, y: y)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(actualPixel[channel]) - Int(expectedPixel[channel])), tolerance,
                "pixel at y=\(y): \(actualPixel) expected \(expectedPixel)", file: file, line: line) }
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }

    private func sampleTimes(_ asset: AVAsset, track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.numSamples > 0 { times.append(CMTimeGetSeconds(sample.presentationTimeStamp)) }
        }
        XCTAssertEqual(reader.status, .completed)
        return times
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }
}
