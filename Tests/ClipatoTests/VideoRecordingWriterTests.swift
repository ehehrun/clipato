import AVFoundation
import Darwin
@preconcurrency import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import Clipato

final class VideoRecordingWriterTests: XCTestCase {
    func testCustomFilenamePublishesDecodableMP4WithoutChangingTemporaryName() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = "演示_2026-10-20_001.mp4"
        let writer = try VideoRecordingWriter(directory: directory, started: time(100), sampleRate: 30,
            width: 64, height: 48, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) },
            filename: filename)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [".recording.partial.mp4"])
        try await append(writer, recordingSample(at: 100, color: (0, 255, 0)))

        let count = try await writer.finish(duration: 2).get()
        XCTAssertEqual(count, 1)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [filename])
        let frames = try await decodedFrames(directory.appendingPathComponent(filename))
        XCTAssertEqual(frames.count, 1)
        XCTAssertGreaterThan(frames[0].green, 230)
    }

    func testCustomFilenameNeverOverwritesFileCreatedWhileRecording() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("existing.mp4")
        let original = Data("Existing recording must survive".utf8)
        let writer = try VideoRecordingWriter(directory: directory, started: time(100), sampleRate: 30,
            width: 64, height: 48, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) },
            filename: target.lastPathComponent)
        try await append(writer, recordingSample(at: 100, color: (0, 255, 0)))
        try original.write(to: target)

        let result = await writer.finish(duration: 2)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EEXIST))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        let frames = try await decodedFrames(directory.appendingPathComponent(".recording.partial.mp4"))
        XCTAssertEqual(frames.count, 1)
    }

    func testInvalidCustomFilenameFailsBeforeCreatingEncoderOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = ["", "../other.mp4", "folder/video.mp4", "/tmp/out.mp4", "bad:name.mp4", "line\nname.mp4",
                       "nul\0name.mp4", ".recording.partial.mp4", ".hidden.mp4", "video.png", "video",
                       String(repeating: "图", count: 85) + ".mp4"]
        for filename in invalid {
            XCTAssertThrowsError(try VideoRecordingWriter(directory: directory, started: .zero, sampleRate: 30,
                width: 64, height: 48, onFrame: { _ in }, onFailure: { _, _ in }, filename: filename), filename) { error in
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteInvalidFileName)
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, filename)
        }
    }

    func testRealH264FileRetainsStaticTailAndPixelContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = CMTime(seconds: 100, preferredTimescale: 60_000)
        let writer = try VideoRecordingWriter(directory: directory, started: started, sampleRate: 30, width: 64, height: 48,
            onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) })
        try await append(writer, recordingSample(at: 99.9, color: (0, 0, 255)))
        try await Task.sleep(for: .milliseconds(100))
        try await append(writer, recordingSample(at: 101, color: (255, 0, 0)))
        let count = try await writer.finish(duration: 3).get()
        XCTAssertEqual(count, 2)
        let url = directory.appendingPathComponent("recording.mp4")
        let frames = try await decodedFrames(url)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].time, 1, accuracy: 0.001)
        XCTAssertGreaterThan(frames[0].red, 230)
        XCTAssertLessThan(frames[0].blue, 20)
        XCTAssertGreaterThan(frames[1].blue, 230)
        XCTAssertLessThan(frames[1].red, 20)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3, accuracy: 0.001)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let tail = try await generator.image(at: CMTime(seconds: 2.9, preferredTimescale: 600))
        XCTAssertEqual(tail.image.width, 64)
        XCTAssertEqual(tail.image.height, 48)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording.mp4"])
    }

    func testSingleFrameVideoCoversWholeDurationWithoutDuplicateFrames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try VideoRecordingWriter(directory: directory, started: CMTime(seconds: 100, preferredTimescale: 600),
            sampleRate: 15, width: 64, height: 48, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) })
        try await append(writer, recordingSample(at: 100.1, color: (0, 255, 0)))
        let count = try await writer.finish(duration: 1.75).get()
        XCTAssertEqual(count, 1)
        let frames = try await decodedFrames(directory.appendingPathComponent("recording.mp4"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].time, 0, accuracy: 0.001)
        let duration = try await AVURLAsset(url: directory.appendingPathComponent("recording.mp4")).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.75, accuracy: 0.001)
        XCTAssertGreaterThan(frames[0].green, 230)
    }

    func testInvalidFramePreservesDecodablePartialAndReportsFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = expectation(description: "Original invalid frame failure is delivered")
        let writer = try VideoRecordingWriter(directory: directory, started: CMTime(seconds: 100, preferredTimescale: 600),
            sampleRate: 60, width: 64, height: 48, onFrame: { _ in }, onFailure: { error, alreadyStopped in
                XCTAssertFalse(alreadyStopped)
                XCTAssertEqual(error.localizedDescription, KeyframeRecordingError.invalidFrame.localizedDescription)
                failure.fulfill()
            })
        try await append(writer, recordingSample(at: 100, color: (0, 255, 0)))
        try await append(writer, recordingSample(at: 101, color: (0, 255, 0), width: 62))
        let result = await writer.finish(duration: 2)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error.localizedDescription, KeyframeRecordingError.invalidFrame.localizedDescription)
        }
        await fulfillment(of: [failure], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.mp4").path))
        let frames = try await decodedFrames(directory.appendingPathComponent(".recording.partial.mp4"))
        XCTAssertEqual(frames.count, 1)
        let duration = try await AVURLAsset(url: directory.appendingPathComponent(".recording.partial.mp4")).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.001)
    }

    func testNoFramesAndInvalidEncodingSettingsAreExplicitFailures() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (rate, width, height) in [(30.0, 63, 48), (30.0, 64, 1), (30.0, 4098, 48), (24.0, 64, 48)] {
            XCTAssertThrowsError(try VideoRecordingWriter(directory: directory, started: .zero, sampleRate: rate,
                width: width, height: height, onFrame: { _ in }, onFailure: { _, _ in }))
        }
        let writer = try VideoRecordingWriter(directory: directory, started: .zero, sampleRate: 30,
            width: 64, height: 48, onFrame: { _ in }, onFailure: { _, _ in })
        let result = await writer.finish(duration: 1)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error.localizedDescription, KeyframeRecordingError.noFrames.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.mp4").path))
    }

    func testMultiplePausesRemoveGapsAndRejectLateFrames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try VideoRecordingWriter(directory: directory, started: time(100), sampleRate: 30,
            width: 64, height: 48, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) })
        try await append(writer, recordingSample(at: 100, color: (0, 0, 255)))
        try await append(writer, recordingSample(at: 101, color: (255, 0, 0)))
        writer.queue.sync { writer.pause(at: time(102)) }
        try await append(writer, recordingSample(at: 103, color: (0, 0, 0)))
        await writer.resume(at: time(112))
        try await append(writer, recordingSample(at: 108, color: (0, 0, 0)))
        try await Task.sleep(for: .milliseconds(100))
        try await append(writer, recordingSample(at: 112.5, color: (0, 255, 0)))
        writer.queue.sync { writer.pause(at: time(114)) }
        await writer.resume(at: time(134))
        try await Task.sleep(for: .milliseconds(100))
        try await append(writer, recordingSample(at: 134.5, color: (0, 255, 255)))
        let count = try await writer.finish(duration: 5).get()
        XCTAssertEqual(count, 4)
        let url = directory.appendingPathComponent("recording.mp4")
        let frames = try await decodedFrames(url)
        XCTAssertEqual(frames.map(\.time), [0, 1, 2.5, 4.5])
        XCTAssertGreaterThan(frames[2].green, 230)
        XCTAssertGreaterThan(frames[3].red, 230)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 5, accuracy: 0.001)
    }

    func testStopWhilePausedRetainsStaticTailWithoutPauseDuration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try VideoRecordingWriter(directory: directory, started: time(100), sampleRate: 30,
            width: 64, height: 48, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) })
        try await append(writer, recordingSample(at: 100, color: (0, 0, 255)))
        writer.queue.sync { writer.pause(at: time(102.5)) }
        writer.queue.sync { writer.pause(at: time(120)) }
        try await append(writer, recordingSample(at: 121, color: (0, 255, 0)))
        let count = try await writer.finish(duration: 2.5).get()
        XCTAssertEqual(count, 1)
        let url = directory.appendingPathComponent("recording.mp4")
        let frames = try await decodedFrames(url)
        XCTAssertEqual(frames.count, 1)
        XCTAssertGreaterThan(frames[0].red, 230)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.5, accuracy: 0.001)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        _ = try await generator.image(at: time(2.4))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    private func append(_ writer: VideoRecordingWriter, _ buffer: CMSampleBuffer) async {
        writer.queue.sync { writer.append(buffer) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-video-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }


    private struct Frame {
        let time: Double
        let blue: UInt8
        let green: UInt8
        let red: UInt8
    }

    private func decodedFrames(_ url: URL) async throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 64, height: 48))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            frames.append(Frame(time: CMTimeGetSeconds(sample.presentationTimeStamp),
                blue: bytes[0], green: bytes[1], red: bytes[2]))
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return frames
    }
}

func recordingSample(at seconds: Double, color: (UInt8, UInt8, UInt8), width: Int = 64) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(kCFAllocatorDefault, width, 48, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    XCTAssertEqual(result, kCVReturnSuccess)
    let pixels = try XCTUnwrap(pixelBuffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<48 {
        for x in 0..<width {
            let offset = y * rowBytes + x * 4
            bytes[offset] = color.0
            bytes[offset + 1] = color.1
            bytes[offset + 2] = color.2
            bytes[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
    let time = CMTime(seconds: seconds, preferredTimescale: 60_000)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: time)
    var buffer: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
        formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &buffer), noErr)
    let sample = try XCTUnwrap(buffer)
    let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)) as NSArray
    let info = try XCTUnwrap(attachments[0] as? NSMutableDictionary)
    info[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
    info[SCStreamFrameInfo.displayTime.rawValue] = NSNumber(value: CMClockConvertHostTimeToSystemUnits(time))
    return sample
}
