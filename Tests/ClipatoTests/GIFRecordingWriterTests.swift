import CoreGraphics
import Darwin
import CoreMedia
import ImageIO
import XCTest
@testable import Clipato

final class GIFRecordingWriterTests: XCTestCase {
    func testThirtyFPSWritesNativeGIFWithAccurateTimingAndChangingPixels() async throws {
        let directory = try temporaryDirectory()
        let writer = try makeWriter(directory)
        for frame in 0..<30 {
            try append(writer, at: 100 + Double(frame) / 30, color: (0, 0, UInt8(frame * 8)))
        }
        XCTAssertGreaterThan(try Data(contentsOf: directory.appendingPathComponent(".recording.partial.gif")).count, 100)
        let count = try await writer.finish(duration: 1).get()
        XCTAssertEqual(count, 30)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording.gif"])

        let source = try imageSource(directory.appendingPathComponent("recording.gif"))
        XCTAssertEqual(CGImageSourceGetCount(source), 30)
        let durations = try delays(source)
        XCTAssertEqual(durations.reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(Set(durations.map { Int(($0 * 100).rounded()) }), [3, 4])
        XCTAssertEqual(try color(source, at: 0).red, 0, accuracy: 2)
        XCTAssertEqual(try color(source, at: 29).red, 232, accuracy: 2)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount] as? Int, 0)
    }

    func testUnchangedFramesMergeWithoutLosingTheStaticTail() async throws {
        let directory = try temporaryDirectory()
        let writer = try makeWriter(directory)
        for time in [100.0, 100.1, 100.5, 101.5] {
            try append(writer, at: time, color: (0, 255, 0))
        }
        let count = try await writer.finish(duration: 2.5).get()
        XCTAssertEqual(count, 1)
        let source = try imageSource(directory.appendingPathComponent("recording.gif"))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(try delays(source), [2.5])
        XCTAssertGreaterThan(try color(source, at: 0).green, 250)
    }

    func testLongStaticHoldSplitsTheUnsignedSixteenBitDelayWithoutDrift() async throws {
        let directory = try temporaryDirectory()
        let writer = try makeWriter(directory)
        try append(writer, at: 100, color: (255, 0, 0))
        let count = try await writer.finish(duration: 700).get()
        XCTAssertEqual(count, 1)
        let source = try imageSource(directory.appendingPathComponent("recording.gif"))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let durations = try delays(source)
        XCTAssertEqual(durations[0], 655.35, accuracy: 0.000_001)
        XCTAssertEqual(durations.reduce(0, +), 700, accuracy: 0.000_001)
        XCTAssertGreaterThan(try color(source, at: 1).blue, 250)
    }

    func testPauseRemovesTheGapAndRejectsLateSamplesFromTheOldStream() async throws {
        let directory = try temporaryDirectory()
        let writer = try makeWriter(directory)
        try append(writer, at: 100, color: (0, 0, 255))
        try append(writer, at: 101, color: (255, 0, 0))
        writer.queue.sync { writer.pause(at: time(102)) }
        try append(writer, at: 103, color: (0, 255, 0))
        await writer.resume(at: time(112))
        try append(writer, at: 108, color: (0, 255, 0))
        try append(writer, at: 112.5, color: (0, 255, 0))

        let count = try await writer.finish(duration: 4).get()
        XCTAssertEqual(count, 3)
        let source = try imageSource(directory.appendingPathComponent("recording.gif"))
        XCTAssertEqual(try delays(source), [1, 1.5, 1.5])
        XCTAssertGreaterThan(try color(source, at: 0).red, 250)
        XCTAssertGreaterThan(try color(source, at: 1).blue, 250)
        XCTAssertGreaterThan(try color(source, at: 2).green, 250)
    }

    func testExcessSourceFramesAreSampledWithoutAnAsynchronousWorkQueue() async throws {
        let directory = try temporaryDirectory()
        let writer = try makeWriter(directory, settings: GIFRecordingSettings(frameRate: 10))
        for frame in 0..<100 {
            try append(writer, at: 100 + Double(frame) / 100, color: (0, UInt8(frame * 2), 0))
        }
        let count = try await writer.finish(duration: 1).get()
        XCTAssertEqual(count, 10)
        let source = try imageSource(directory.appendingPathComponent("recording.gif"))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        XCTAssertEqual(try delays(source).reduce(0, +), 1, accuracy: 0.000_001)
    }

    func testFailureKeepsOnlyADecodablePartialAndNeverPublishesTheTarget() async throws {
        let directory = try temporaryDirectory()
        var failures = 0
        let writer = try GIFRecordingWriter(directory: directory, started: time(100), settings: .init(), width: 64, height: 48,
            onFrame: { _ in }, onFailure: { error, stopped in
                failures += 1
                XCTAssertFalse(stopped)
                XCTAssertEqual(error.localizedDescription, KeyframeRecordingError.invalidFrame.localizedDescription)
            })
        try append(writer, at: 100, color: (0, 0, 255))
        let invalid = try recordingSample(at: 101, color: (0, 255, 0), width: 62)
        writer.queue.sync { writer.append(invalid) }
        try append(writer, at: 101.5, color: (255, 0, 0))
        let result = await writer.finish(duration: 2)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error.localizedDescription, KeyframeRecordingError.invalidFrame.localizedDescription)
        }
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.gif").path))
        let source = try imageSource(directory.appendingPathComponent(".recording.partial.gif"))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(try delays(source), [2])
    }

    func testCustomFilenameCannotOverwriteAnExistingFile() async throws {
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("演示.gif")
        let original = Data("preserve original".utf8)
        let writer = try makeWriter(directory, filename: target.lastPathComponent)
        try append(writer, at: 100, color: (0, 0, 255))
        try original.write(to: target)
        let result = await writer.finish(duration: 1)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EEXIST))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(CGImageSourceGetCount(try imageSource(directory.appendingPathComponent(".recording.partial.gif"))), 1)
    }

    func testInvalidSettingsAndNamesFailBeforeCreatingOutput() throws {
        let directory = try temporaryDirectory()
        for filename in ["", "../other.gif", "bad:name.gif", ".hidden.gif", "video.mp4", "line\nname.gif"] {
            XCTAssertThrowsError(try makeWriter(directory, filename: filename))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
        for settings in [GIFRecordingSettings(frameRate: 0), GIFRecordingSettings(frameRate: 60)] {
            XCTAssertThrowsError(try makeWriter(directory, settings: settings))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
        XCTAssertThrowsError(try GIFRecordingWriter(directory: directory, started: .zero, settings: .init(), width: 1921, height: 48,
            onFrame: { _ in }, onFailure: { _, _ in }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testNoFramesAndInvalidDurationCannotPublishAGIF() async throws {
        let emptyDirectory = try temporaryDirectory()
        let empty = try makeWriter(emptyDirectory)
        let emptyResult = await empty.finish(duration: 1)
        XCTAssertThrowsError(try emptyResult.get()) { error in
            XCTAssertEqual(error.localizedDescription, KeyframeRecordingError.noFrames.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyDirectory.appendingPathComponent("recording.gif").path))

        let directory = try temporaryDirectory()
        let writer = try makeWriter(directory)
        try append(writer, at: 100, color: (0, 0, 255))
        try append(writer, at: 101, color: (255, 0, 0))
        let result = await writer.finish(duration: 0.5)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error.localizedDescription, GIFRecordingError.invalidDuration.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.gif").path))
    }

    private func makeWriter(_ directory: URL, settings: GIFRecordingSettings = .init(), filename: String = "recording.gif") throws -> GIFRecordingWriter {
        try GIFRecordingWriter(directory: directory, started: time(100), settings: settings, width: 64, height: 48,
            onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) }, filename: filename)
    }

    private func append(_ writer: GIFRecordingWriter, at seconds: Double, color: (UInt8, UInt8, UInt8)) throws {
        let buffer = try recordingSample(at: seconds, color: color)
        writer.queue.sync { writer.append(buffer) }
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }

    private func imageSource(_ url: URL) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    private func delays(_ source: CGImageSource) throws -> [Double] {
        try (0..<CGImageSourceGetCount(source)).map { index in
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            return try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        }
    }

    private func color(_ source: CGImageSource, at index: Int) throws -> (red: Double, green: Double, blue: Double) {
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-gif-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class GIFRecordingSettingsTests: XCTestCase {
    func testDefaultsNeedNoConfigurationAndPresetsActuallyChangeResolution() throws {
        let settings = GIFRecordingSettings()
        XCTAssertEqual(settings.frameRate, 30)
        XCTAssertEqual(settings.quality, .balanced)
        XCTAssertEqual(settings.maximumDimension, 1280)
        XCTAssertEqual(GIFRecordingQuality.allCases.map(\.maximumDimension), [800, 1280, 1920])
        XCTAssertNoThrow(try settings.validate())
        XCTAssertEqual(RecordingMode.gif.defaultFrameRate, 30)
        XCTAssertEqual(RecordingMode.gif.frameRates, GIFRecordingSettings.frameRates)
        XCTAssertEqual(RecordingMode.gif.maximumDimensionRange, 1...1920)
    }
}
