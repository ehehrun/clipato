import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import Clipato

final class VideoRecordingBackpressureTests: XCTestCase {
    func testStaticResumeSnapshotDrainsAtFinishAfterRealEncoderBackpressure() async throws {
        try await verifyResumedSnapshot(drainOnFrame: false)
    }

    func testStaticResumeSnapshotDrainsBeforeFollowingFrameAfterRealEncoderBackpressure() async throws {
        try await verifyResumedSnapshot(drainOnFrame: true)
    }

    private func verifyResumedSnapshot(drainOnFrame: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-backpressure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try pixels(blue: 0, green: 0, red: 255)
        let blue = try pixels(blue: 255, green: 0, red: 0)
        let writer = try VideoRecordingWriter(directory: directory, started: time(100), sampleRate: 60,
            width: 4096, height: 3072, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) })
        // Reuse immutable pixels: the burst exercises the real H.264 encoder without allocating 500 images.
        let buffers = try (0..<500).map { try sample(red, at: 100 + Double($0) / 60) }
        writer.queue.sync {
            for buffer in buffers { writer.append(buffer) }
            writer.pause(at: time(110))
        }
        await writer.resume(at: time(120))
        let resumed = try sample(blue, at: 119.9)
        writer.queue.sync { writer.append(resumed, initialSnapshot: true) }
        if drainOnFrame {
            try await Task.sleep(for: .milliseconds(300))
            let later = try sample(red, at: 121)
            writer.queue.sync { writer.append(later) }
        }
        let count = try await writer.finish(duration: 12).get()
        XCTAssertLessThan(count, 500, "The burst must reach encoder backpressure to exercise this regression")
        let asset = AVURLAsset(url: directory.appendingPathComponent("recording.mp4"))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 12, accuracy: 0.002)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var blueTimes: [Double] = []
        var times: [Double] = []
        var lastIsBlue = false
        while let buffer = output.copyNextSampleBuffer() {
            let decoded = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
            CVPixelBufferLockBaseAddress(decoded, .readOnly)
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded)).assumingMemoryBound(to: UInt8.self)
            lastIsBlue = bytes[0] > 220 && bytes[2] < 30
            let seconds = CMTimeGetSeconds(buffer.presentationTimeStamp)
            if lastIsBlue { blueTimes.append(seconds) }
            times.append(seconds)
            CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(times.count, count)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "Draining must preserve monotonic presentation times")
        XCTAssertEqual(blueTimes.count, 1, "The resumed static snapshot must survive either drain path")
        XCTAssertEqual(try XCTUnwrap(blueTimes.first), 10, accuracy: 0.002)
        if !drainOnFrame { XCTAssertTrue(lastIsBlue, "Finish must retain the resumed static image through the tail") }
    }


    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }

    private func pixels(blue: UInt8, green: UInt8, red: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4096, 3072, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let value = UInt32(blue) | UInt32(green) << 8 | UInt32(red) << 16 | 255 << 24
        for y in 0..<3072 {
            base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self).initialize(repeating: value, count: 4096)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func sample(_ pixels: CVPixelBuffer, at seconds: Double) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: time(1.0 / 60), presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &buffer), noErr)
        let sample = try XCTUnwrap(buffer)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)) as NSArray
        let info = try XCTUnwrap(attachments[0] as? NSMutableDictionary)
        info[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
        info[SCStreamFrameInfo.displayTime.rawValue] = NSNumber(value: CMClockConvertHostTimeToSystemUnits(time(seconds)))
        return sample
    }
}
