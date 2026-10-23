import AVFoundation
import Darwin
@preconcurrency import ScreenCaptureKit

final class VideoRecordingWriter: NSObject, RecordingWriter, @unchecked Sendable {
    let queue = DispatchQueue(label: "Clipato.video", qos: .userInitiated)
    let directory: URL

    private let writer: AVAssetWriter
    private let filename: String
    private let input: AVAssetWriterInput
    private var timeline: RecordingTimeline
    private weak var activeStream: SCStream?
    private var preparingStream = false
    private var initialSnapshot = true
    private var resumeFrame: CMSampleBuffer?
    private let width: Int
    private let height: Int
    private let onFrame: (Int) -> Void
    private let onFailure: (Error, Bool) -> Void
    private var frameCount = 0
    private var lastTime = CMTime.invalid
    private var lastNotification = CMTime.invalid
    private var pendingFrame: CMSampleBuffer?
    private var deferredResumeFrame: (buffer: CMSampleBuffer, time: CMTime)?
    private var failure: Error?
    private var finished = false

    init(
        directory: URL, started: CMTime, sampleRate: Double, width: Int, height: Int,
        onFrame: @escaping (Int) -> Void, onFailure: @escaping (Error, Bool) -> Void,
        filename: String = "recording.mp4"
    ) throws {
        guard !filename.hasPrefix("."), !filename.contains("/"), !filename.contains(":"),
              filename.rangeOfCharacter(from: .controlCharacters) == nil,
              URL(fileURLWithPath: filename).pathExtension.lowercased() == "mp4", filename.utf8.count <= 255 else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: filename])
        }
        self.directory = directory
        self.filename = filename
        self.timeline = RecordingTimeline(started: started)
        self.width = width
        self.height = height
        self.onFrame = onFrame
        self.onFailure = onFailure
        guard (2...4096).contains(width), (2...4096).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2), [15.0, 30.0, 60.0].contains(sampleRate) else {
            throw KeyframeRecordingError.invalidVideoSettings
        }
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(".recording.partial.mp4"), fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, min(30_000_000, width * height * 5)),
                AVVideoExpectedSourceFrameRateKey: sampleRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw VideoRecordingError.unsupportedFormat }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoRecordingError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
        super.init()
    }

    func prepareStream(_ stream: SCStream) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                activeStream = stream
                preparingStream = timeline.isPaused
                initialSnapshot = true
                resumeFrame = nil
                continuation.resume()
            }
        }
    }

    func pause() async -> CMTime {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let time = CMClockGetTime(CMClockGetHostTimeClock())
                pause(at: time)
                continuation.resume(returning: time)
            }
        }
    }

    func pause(at time: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        timeline.pause(at: time)
        resumeFrame = nil
        preparingStream = false
    }

    func resume(at time: CMTime) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                timeline.resume(at: time)
                preparingStream = false
                if let resumeFrame { append(resumeFrame, initialSnapshot: true) }
                resumeFrame = nil
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === activeStream else { return }
        if timeline.isPaused {
            if preparingStream,
               let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
               info[.status] as? Int == SCFrameStatus.complete.rawValue {
                resumeFrame = sampleBuffer
            }
            return
        }
        append(sampleBuffer, initialSnapshot: initialSnapshot)
    }

    // Keep one pending image; encoder backpressure drops new frames instead of building a queue.
    func append(_ sampleBuffer: CMSampleBuffer, initialSnapshot: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, failure == nil, !timeline.isPaused else { return }
        autoreleasepool {
            do {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let info = attachments.first, let status = info[.status] as? Int else {
                    throw KeyframeRecordingError.invalidFrame
                }
                guard status == SCFrameStatus.complete.rawValue else { return }
                guard sampleBuffer.isValid, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height,
                      let displayTime = info[.displayTime] as? NSNumber else {
                    throw KeyframeRecordingError.invalidFrame
                }
                guard writer.status == .writing else { throw writer.error ?? VideoRecordingError.encodingFailed }
                let hostTime = CMClockMakeHostTimeFromSystemUnits(displayTime.uint64Value)
                guard let frameTime = timeline.frameTime(at: hostTime, initialSnapshot: initialSnapshot) else { return }
                self.initialSnapshot = false
                let time = frameCount == 0 ? CMTime.zero : frameTime
                guard !lastTime.isValid || time > lastTime else { return }
                if let deferredResumeFrame, time <= deferredResumeFrame.time { return }
                if !(try drainResumeFrame()) || (pendingFrame != nil && !input.isReadyForMoreMediaData) {
                    // Keep the latest resumed snapshot even when its static screen emits no later frame.
                    if initialSnapshot { deferredResumeFrame = (sampleBuffer, time) }
                    return
                }
                if pendingFrame != nil { try appendPendingFrame(endingAt: time) }
                retainPendingFrame(sampleBuffer, at: time)
            } catch {
                failure = error
                onFailure(error, false)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard !finished, stream === activeStream else { return }
            if failure == nil {
                failure = error
                onFailure(error, true)
            }
        }
    }

    func finish(duration: TimeInterval) async -> Result<Int, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finished = true
                guard frameCount > 0 else {
                    writer.cancelWriting()
                    continuation.resume(returning: .failure(failure ?? KeyframeRecordingError.noFrames))
                    return
                }
                finishWhenReady(duration: duration, deadline: .now() + 10, continuation: continuation)
            }
        }
    }

    private func finishWhenReady(duration: TimeInterval, deadline: DispatchTime, continuation: CheckedContinuation<Result<Int, Error>, Never>) {
        do {
            guard writer.status == .writing else { throw writer.error ?? VideoRecordingError.encodingFailed }
            guard try drainResumeFrame(), input.isReadyForMoreMediaData else {
                guard .now() < deadline else { throw VideoRecordingError.encoderStalled }
                queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                    finishWhenReady(duration: duration, deadline: deadline, continuation: continuation)
                }
                return
            }
            guard duration.isFinite, duration > 0 else { throw VideoRecordingError.invalidDuration }
            let end = CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
            guard end > lastTime else { throw VideoRecordingError.invalidDuration }
            // One retained frame has a known duration at stop, including a fully static tail.
            try appendPendingFrame(endingAt: end)
            writer.endSession(atSourceTime: end)
            input.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { [self] in
                    do {
                        guard writer.status == .completed else { throw writer.error ?? VideoRecordingError.encodingFailed }
                        if let failure {
                            continuation.resume(returning: .failure(failure))
                            return
                        }
                        let target = directory.appendingPathComponent(filename)
                        let renameError = writer.outputURL.path.withCString { source in
                            target.path.withCString { destination in
                                renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                            }
                        }
                        guard renameError == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError), userInfo: [NSFilePathErrorKey: target.path])
                        }
                        continuation.resume(returning: .success(frameCount))
                    } catch {
                        continuation.resume(returning: .failure(combinedFailure(error)))
                    }
                }
            }
        } catch {
            writer.cancelWriting()
            continuation.resume(returning: .failure(combinedFailure(error)))
        }
    }

    private func drainResumeFrame() throws -> Bool {
        guard let deferredResumeFrame else { return true }
        guard input.isReadyForMoreMediaData else { return false }
        try appendPendingFrame(endingAt: deferredResumeFrame.time)
        retainPendingFrame(deferredResumeFrame.buffer, at: deferredResumeFrame.time)
        self.deferredResumeFrame = nil
        return true
    }

    private func retainPendingFrame(_ sampleBuffer: CMSampleBuffer, at time: CMTime) {
        pendingFrame = sampleBuffer
        lastTime = time
        frameCount += 1
        if !lastNotification.isValid || CMTimeGetSeconds(time - lastNotification) >= 0.25 {
            lastNotification = time
            onFrame(frameCount)
        }
    }

    private func appendPendingFrame(endingAt end: CMTime) throws {
        guard let pendingFrame else { throw KeyframeRecordingError.noFrames }
        var timing = CMSampleTimingInfo(duration: end - lastTime, presentationTimeStamp: lastTime, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: pendingFrame,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
        guard result == noErr, let retimed else { throw VideoRecordingError.sampleTiming(result) }
        guard input.append(retimed) else { throw writer.error ?? VideoRecordingError.encodingFailed }
        self.pendingFrame = nil
    }

    private func combinedFailure(_ error: Error) -> Error {
        if let failure { return KeyframeRecordingError.multipleFailures(failure, error) }
        return error
    }
}

private enum VideoRecordingError: LocalizedError {
    case unsupportedFormat
    case encodingFailed
    case encoderStalled
    case sampleTiming(OSStatus)
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return L("当前系统不支持此尺寸的 H.264 视频编码。")
        case .encodingFailed: return L("H.264 编码器无法继续写入视频。")
        case .encoderStalled: return L("视频编码器超过 10 秒未能完成待写入画面，录制未完成。")
        case .sampleTiming(let status): return L("无法设置视频画面时间（CoreMedia \(status)）。")
        case .invalidDuration: return L("视频结束时间早于最后一帧，无法保存完整录制。")
        }
    }
}
