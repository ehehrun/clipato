import CoreImage
import CoreMedia
import Darwin
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

final class GIFRecordingWriter: NSObject, RecordingWriter, @unchecked Sendable {
    let queue = DispatchQueue(label: "Clipato.gif", qos: .userInitiated)
    let directory: URL

    private let filename: String
    private let output: FileHandle
    private let width: Int
    private let height: Int
    private let frameInterval: Double
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let onFrame: (Int) -> Void
    private let onFailure: (Error, Bool) -> Void
    private var timeline: RecordingTimeline
    private weak var activeStream: SCStream?
    private var preparingStream = false
    private var initialSnapshot = true
    private var resumeFrame: CMSampleBuffer?
    private var pendingFrame: Data?
    private var pendingStart: Int64 = 0
    private var lastSampledTime = -Double.infinity
    private var lastNotification = -Double.infinity
    private var frameCount = 0
    private var failure: Error?
    private var finished = false
    private var outputClosed = false

    init(directory: URL, started: CMTime, settings: GIFRecordingSettings, width: Int, height: Int,
         onFrame: @escaping (Int) -> Void, onFailure: @escaping (Error, Bool) -> Void,
         filename: String = "recording.gif") throws {
        try settings.validate()
        guard (1...settings.maximumDimension).contains(width), (1...settings.maximumDimension).contains(height) else {
            throw GIFRecordingError.invalidSettings
        }
        guard !filename.hasPrefix("."), !filename.contains("/"), !filename.contains(":"),
              filename.rangeOfCharacter(from: .controlCharacters) == nil,
              URL(fileURLWithPath: filename).pathExtension.lowercased() == "gif", filename.utf8.count <= 255 else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: filename])
        }
        self.directory = directory
        self.filename = filename
        self.width = width
        self.height = height
        frameInterval = 1 / Double(settings.frameRate)
        timeline = RecordingTimeline(started: started)
        self.onFrame = onFrame
        self.onFailure = onFailure
        let temporary = directory.appendingPathComponent(".recording.partial.gif")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: temporary.path])
        }
        output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        super.init()
        var header = Data("GIF89a".utf8)
        header.append(contentsOf: [UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8), 0x70, 0, 0])
        header.append(contentsOf: [0x21, 0xFF, 11])
        header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [3, 1, 0, 0, 0])
        try output.write(contentsOf: header)
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

    // Encoding runs synchronously on ScreenCaptureKit's depth-two output queue. No frame jobs accumulate.
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
                guard sampleBuffer.isValid, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
                      CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
                      let displayTime = info[.displayTime] as? NSNumber else {
                    throw KeyframeRecordingError.invalidFrame
                }
                let hostTime = CMClockMakeHostTimeFromSystemUnits(displayTime.uint64Value)
                guard let frameTime = timeline.frameTime(at: hostTime, initialSnapshot: initialSnapshot) else { return }
                self.initialSnapshot = false
                let time = frameCount == 0 ? 0 : CMTimeGetSeconds(frameTime)
                guard time.isFinite, time < Double(Int64.max / 100) else { throw KeyframeRecordingError.invalidFrame }
                guard time - lastSampledTime >= frameInterval - 0.000_001 else { return }
                lastSampledTime = time
                let boundary = Int64((time * 100).rounded())
                guard pendingFrame == nil || boundary > pendingStart else { return }
                let image = CIImage(cvPixelBuffer: pixels)
                guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
                    throw GIFRecordingError.encoding
                }
                let encoded = try Self.encodeFrame(rendered)
                if encoded == pendingFrame { return }
                if pendingFrame != nil { try writePendingFrame(endingAt: boundary) }
                pendingFrame = encoded
                pendingStart = boundary
                frameCount += 1
                if time - lastNotification >= 0.25 {
                    lastNotification = time
                    onFrame(frameCount)
                }
            } catch {
                failure = error
                onFailure(error, false)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard !finished, stream === activeStream, failure == nil else { return }
            failure = error
            onFailure(error, true)
        }
    }

    func finish(duration: TimeInterval) async -> Result<Int, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !finished else {
                    continuation.resume(returning: .failure(GIFRecordingError.finished))
                    return
                }
                finished = true
                if pendingFrame == nil {
                    do {
                        try output.close()
                        outputClosed = true
                        continuation.resume(returning: .failure(failure ?? KeyframeRecordingError.noFrames))
                    } catch {
                        let error = failure.map { KeyframeRecordingError.multipleFailures($0, error) } ?? error
                        continuation.resume(returning: .failure(error))
                    }
                    return
                }
                let result: Result<Int, Error>
                do {
                    guard duration.isFinite, duration > 0, duration < Double(Int64.max / 100),
                          duration > lastSampledTime else { throw GIFRecordingError.invalidDuration }
                    try writePendingFrame(endingAt: max(pendingStart + 1, Int64((duration * 100).rounded())))
                    try output.write(contentsOf: Data([0x3B]))
                    try output.close()
                    outputClosed = true
                    if let failure {
                        result = .failure(failure)
                    } else {
                        let temporary = directory.appendingPathComponent(".recording.partial.gif")
                        let target = directory.appendingPathComponent(filename)
                        let renameError = temporary.path.withCString { source in
                            target.path.withCString { destination in
                                renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                            }
                        }
                        guard renameError == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError), userInfo: [NSFilePathErrorKey: target.path])
                        }
                        result = .success(frameCount)
                    }
                } catch {
                    let recordingError = failure.map { KeyframeRecordingError.multipleFailures($0, error) } ?? error
                    if !outputClosed {
                        do {
                            try output.close()
                            outputClosed = true
                        } catch let closeError {
                            continuation.resume(returning: .failure(KeyframeRecordingError.multipleFailures(recordingError, closeError)))
                            return
                        }
                    }
                    result = .failure(recordingError)
                }
                pendingFrame = nil
                resumeFrame = nil
                continuation.resume(returning: result)
            }
        }
    }

    private func writePendingFrame(endingAt boundary: Int64) throws {
        guard let pendingFrame else { throw KeyframeRecordingError.noFrames }
        var remaining = boundary - pendingStart
        guard remaining > 0 else { throw GIFRecordingError.invalidDuration }
        while remaining > 0 {
            let delay = Int(min(remaining, 65_535))
            try output.write(contentsOf: Data([0x21, 0xF9, 4, 4, UInt8(delay & 255), UInt8(delay >> 8), 0, 0]))
            try output.write(contentsOf: pendingFrame)
            remaining -= Int64(delay)
        }
    }

    private static func encodeFrame(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
            throw GIFRecordingError.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GIFRecordingError.encoding }
        return try imageBlock(from: Data(referencing: data), width: image.width, height: image.height)
    }

    // ImageIO requires the final image count up front. Reuse its native palette/LZW output,
    // then stream GIF89a image blocks with local palettes and recording-time delays.
    private static func imageBlock(from data: Data, width: Int, height: Int) throws -> Data {
        guard data.count >= 13, data.prefix(3) == Data("GIF".utf8) else { throw GIFRecordingError.invalidEncodedFrame }
        let globalBits = data[10] & 7
        let globalCount = data[10] & 0x80 == 0 ? 0 : 3 << (Int(globalBits) + 1)
        guard data.count >= 13 + globalCount else { throw GIFRecordingError.invalidEncodedFrame }
        let globalPalette = data.subdata(in: 13..<(13 + globalCount))
        var cursor = 13 + globalCount
        func skipBlocks() throws {
            while cursor < data.count {
                let count = Int(data[cursor])
                cursor += 1
                guard count <= data.count - cursor else { throw GIFRecordingError.invalidEncodedFrame }
                cursor += count
                if count == 0 { return }
            }
            throw GIFRecordingError.invalidEncodedFrame
        }
        while cursor < data.count {
            switch data[cursor] {
            case 0x21:
                guard data.count - cursor >= 2 else { throw GIFRecordingError.invalidEncodedFrame }
                cursor += 2
                try skipBlocks()
            case 0x2C:
                guard data.count - cursor >= 10 else { throw GIFRecordingError.invalidEncodedFrame }
                let descriptor = cursor
                let imageWidth = Int(data[cursor + 5]) | Int(data[cursor + 6]) << 8
                let imageHeight = Int(data[cursor + 7]) | Int(data[cursor + 8]) << 8
                guard data[(cursor + 1)...(cursor + 4)].allSatisfy({ $0 == 0 }),
                      imageWidth == width, imageHeight == height else { throw GIFRecordingError.invalidEncodedFrame }
                let packed = data[cursor + 9]
                cursor += 10
                let local = packed & 0x80 != 0
                let paletteBits = local ? packed & 7 : globalBits
                let paletteCount = 3 << (Int(paletteBits) + 1)
                let palette: Data
                if local {
                    guard data.count - cursor >= paletteCount else { throw GIFRecordingError.invalidEncodedFrame }
                    palette = data.subdata(in: cursor..<(cursor + paletteCount))
                    cursor += paletteCount
                } else {
                    guard globalPalette.count == paletteCount else { throw GIFRecordingError.invalidEncodedFrame }
                    palette = globalPalette
                }
                let compressedStart = cursor
                guard cursor < data.count, (2...8).contains(data[cursor]) else { throw GIFRecordingError.invalidEncodedFrame }
                cursor += 1
                try skipBlocks()
                var block = data.subdata(in: descriptor..<(descriptor + 10))
                block[9] = 0x80 | (packed & 0x40) | paletteBits
                block.append(palette)
                block.append(data.subdata(in: compressedStart..<cursor))
                return block
            default: throw GIFRecordingError.invalidEncodedFrame
            }
        }
        throw GIFRecordingError.invalidEncodedFrame
    }
}
