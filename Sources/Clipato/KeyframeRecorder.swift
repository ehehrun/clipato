import AppKit
import Combine
import CoreImage
import CoreMedia
import Darwin
import ClipatoCore
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

struct KeyframeManifest: Codable {
    struct Frame: Codable {
        let file: String
        let time: TimeInterval
    }

    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let sampleRate: Double
    let threshold: Double
    let width: Int
    let height: Int
    let frames: [Frame]
    var name: String? = nil
}

@MainActor
final class KeyframeRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var frameCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var status = L("准备录制")
    @Published private(set) var sessionDirectory: URL?
    @Published private(set) var mode: RecordingMode = .keyframes

    var onFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private var writer: (any RecordingWriter)?
    private var outputClaim: URL?
    private var sessionID: UUID?
    private var timeline = RecordingTimeline(started: .zero)
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var pauseTask: Task<Void, Error>?
    private var timer: Timer?
    private var streamStopped = false
    private var isStarting = false
    private var startupFailure: Error?
    private var stoppingTask: Task<URL, Error>?

    func availableDisplays() async throws -> [SCDisplay] {
        do {
            try AutomationAccess.check()
            let displays = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
            try AutomationAccess.check()
            return displays
        } catch {
            throw ScreenCapturePermission.localizedError(error)
        }
    }

    func start(
        display: SCDisplay, region: RecordingRegion, directory: URL, sampleRate: Double,
        threshold: Double, maxDimension: Int, mode: RecordingMode = .keyframes, name: String? = nil
    ) async throws {
        guard !isStarting, stream == nil else { throw KeyframeRecordingError.alreadyRecording }
        guard sampleRate.isFinite, sampleRate > 0,
              mode == .video ? [15.0, 30.0, 60.0].contains(sampleRate) : sampleRate <= 30,
              threshold.isFinite, (0...1).contains(threshold), maxDimension > 0 else {
            throw KeyframeRecordingError.invalidSettings
        }
        guard mode != .video || (2...4096).contains(maxDimension) else { throw KeyframeRecordingError.invalidVideoSettings }
        try region.validate(displayID: display.displayID, displaySize: CGSize(width: display.width, height: display.height))
        // Vault sessions use UUID folders; a CLI output name carries no session ID.
        let id = UUID(uuidString: directory.lastPathComponent) ?? UUID()
        isStarting = true
        startupFailure = nil
        status = L("正在启动…")
        defer { isStarting = false }

        do {
            try AutomationAccess.check()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try AutomationAccess.check()
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let configuration = try region.configuration(
                displayID: display.displayID, contentRect: filter.contentRect,
                pointPixelScale: CGFloat(filter.pointPixelScale), maxDimension: maxDimension
            )
            if mode == .video {
                configuration.width = configuration.width / 2 * 2
                configuration.height = configuration.height / 2 * 2
                guard configuration.width >= 2, configuration.height >= 2 else { throw KeyframeRecordingError.invalidVideoSettings }
            }
            let width = configuration.width
            let height = configuration.height
            configuration.minimumFrameInterval = CMTime(seconds: 1 / sampleRate, preferredTimescale: 60_000)
            configuration.queueDepth = 2
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = mode == .video
            configuration.capturesAudio = false
            configuration.colorSpaceName = CGColorSpace.sRGB

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw KeyframeRecordingError.outputIsNotDirectory(directory) }
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw KeyframeRecordingError.outputNotEmpty(directory)
                }
            }
            try AutomationAccess.check()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let claim = directory.appendingPathComponent(".recording", isDirectory: true)
            // Both recording modes claim the same path before creating any media.
            let creationError = claim.path.withCString { mkdir($0, 0o755) == 0 ? 0 : errno }
            guard creationError == 0 else {
                if creationError == EEXIST { throw KeyframeRecordingError.outputClaimed(directory) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(creationError), userInfo: [NSFilePathErrorKey: claim.path])
            }
            outputClaim = claim
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path) == [".recording"] else {
                throw KeyframeRecordingError.outputNotEmpty(directory)
            }
            let recordingStarted = CMClockGetTime(CMClockGetHostTimeClock())
            timeline = RecordingTimeline(started: recordingStarted)
            let onFrame: (Int) -> Void = { [weak self] count in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.frameCount = count
                }
            }
            let onFailure: (Error, Bool) -> Void = { [weak self] captureError, alreadyStopped in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.streamStopped = self.streamStopped || alreadyStopped
                    if self.isStarting {
                        self.startupFailure = captureError
                        return
                    }
                    do {
                        _ = try await self.stop()
                    } catch let finalError {
                        self.onFailure?(finalError)
                    }
                }
            }
            let writer: any RecordingWriter
            switch mode {
            case .keyframes:
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames", isDirectory: true), withIntermediateDirectories: false)
                writer = KeyframeWriter(
                    directory: directory, id: id, createdAt: Date(), started: recordingStarted,
                    sampleRate: sampleRate, threshold: threshold, width: width, height: height,
                    onFrame: onFrame, onFailure: onFailure, name: name
                )
            case .video:
                writer = try VideoRecordingWriter(
                    directory: directory, started: recordingStarted, sampleRate: sampleRate,
                    width: width, height: height, onFrame: onFrame, onFailure: onFailure,
                    filename: name.map { $0 + ".mp4" } ?? "recording.mp4"
                )
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            self.writer = writer
            self.stream = stream
            self.filter = filter
            self.configuration = configuration
            self.mode = mode
            sessionID = id
            sessionDirectory = directory
            streamStopped = false
            frameCount = 0
            elapsed = 0
            isPaused = false
            pauseTask = nil

            await writer.prepareStream(stream)
            try AutomationAccess.check()
            try await stream.startCapture()
            isStarting = false
            if startupFailure != nil { _ = try await stop() }
            isRecording = true
            status = mode == .video ? L("直接录制中") : L("关键帧录制中")
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording, !self.isPaused, self.stoppingTask == nil else { return }
                    self.elapsed = CMTimeGetSeconds(self.timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())))
                }
            }
        } catch {
            self.stream = nil
            self.writer = nil
            self.filter = nil
            self.configuration = nil
            sessionID = nil
            var error = ScreenCapturePermission.localizedError(error)
            if let claim = outputClaim {
                outputClaim = nil
                do { try FileManager.default.removeItem(at: claim) }
                catch let cleanupError { error = KeyframeRecordingError.multipleFailures(error, cleanupError) }
            }
            status = L("录制失败：\(error.localizedDescription)")
            throw error
        }
    }

    func setPaused(_ paused: Bool) async throws {
        guard isRecording else { throw KeyframeRecordingError.notRecording }
        guard stoppingTask == nil else { throw KeyframeRecordingError.stopInProgress }
        let previous = pauseTask
        let task = Task { @MainActor in
            // Each caller receives its own failure; the next operation uses the settled state.
            if let previous { _ = await previous.result }
            guard stoppingTask == nil else { throw KeyframeRecordingError.stopInProgress }
            try await changePauseState(paused)
        }
        pauseTask = task
        try await task.value
    }

    private func changePauseState(_ paused: Bool) async throws {
        guard let stream, let writer, let filter, let configuration else {
            throw KeyframeRecordingError.notRecording
        }
        if paused {
            if !isPaused {
                let time = await writer.pause()
                timeline.pause(at: time)
                elapsed = CMTimeGetSeconds(timeline.elapsed(at: time))
                isPaused = true
                status = L("已暂停")
            }
            // A failed stop leaves the writer paused; retrying pause can release the stream.
            if !streamStopped {
                try await stream.stopCapture()
                streamStopped = true
            }
            return
        }
        guard isPaused else { return }
        if !streamStopped {
            try await stream.stopCapture()
            streamStopped = true
        }
        guard stoppingTask == nil else { throw KeyframeRecordingError.stopInProgress }
        let resumedStream = SCStream(filter: filter, configuration: configuration, delegate: writer)
        try resumedStream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        await writer.prepareStream(resumedStream)
        self.stream = resumedStream
        do {
            try await resumedStream.startCapture()
        } catch {
            status = L("继续录制失败：\(error.localizedDescription)")
            throw ScreenCapturePermission.localizedError(error)
        }
        streamStopped = false
        // A queued stop takes priority over making a successfully started stream active.
        guard stoppingTask == nil else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        await writer.resume(at: time)
        timeline.resume(at: time)
        isPaused = false
        status = mode == .video ? L("直接录制中") : L("关键帧录制中")
    }

    func stop() async throws -> URL {
        if let stoppingTask { return try await stoppingTask.value }
        guard !isStarting else { throw KeyframeRecordingError.startInProgress }
        guard stream != nil, writer != nil else { throw KeyframeRecordingError.notRecording }
        let pendingPause = pauseTask
        let task = Task { @MainActor in
            if let pendingPause { _ = await pendingPause.result }
            guard let stream, let writer else { throw KeyframeRecordingError.notRecording }
            timer?.invalidate()
            timer = nil
            status = mode == .video ? L("正在保存视频…") : L("正在保存关键帧…")

            let stoppedAt = await writer.pause()
            timeline.pause(at: stoppedAt)
            let duration = CMTimeGetSeconds(timeline.elapsed(at: stoppedAt))
            elapsed = duration

            var stopError: Error?
            if !streamStopped {
                do {
                    try await stream.stopCapture()
                } catch {
                    stopError = ScreenCapturePermission.localizedError(error)
                }
            }
            // Stop ScreenCaptureKit first, then drain the writer before publishing its output.
            let result = await writer.finish(duration: duration)
            if let claim = outputClaim {
                outputClaim = nil
                do { try FileManager.default.removeItem(at: claim) }
                catch {
                    stopError = stopError.map { KeyframeRecordingError.multipleFailures($0, error) } ?? error
                }
            }
            self.stream = nil
            self.writer = nil
            self.filter = nil
            self.configuration = nil
            pauseTask = nil
            sessionID = nil
            isRecording = false
            isPaused = false
            stoppingTask = nil

            do {
                frameCount = try result.get()
                if let stopError { throw stopError }
                status = mode == .video ? L("已保存视频") : L("已保存 \(frameCount) 张关键帧")
                return writer.directory
            } catch {
                let finalError: Error
                if let stopError, case .failure = result {
                    finalError = KeyframeRecordingError.multipleFailures(error, stopError)
                } else {
                    finalError = ScreenCapturePermission.localizedError(error)
                }
                status = L("录制失败：\(finalError.localizedDescription)")
                throw finalError
            }
        }
        stoppingTask = task
        return try await task.value
    }
}

protocol RecordingWriter: SCStreamOutput, SCStreamDelegate {
    var queue: DispatchQueue { get }
    var directory: URL { get }
    func prepareStream(_ stream: SCStream) async
    func pause() async -> CMTime
    func resume(at time: CMTime) async
    func finish(duration: TimeInterval) async -> Result<Int, Error>
}

// ScreenCaptureKit output and all mutable writer state stay on this serial queue.
final class KeyframeWriter: NSObject, RecordingWriter, @unchecked Sendable {
    let queue = DispatchQueue(label: "Clipato.keyframes", qos: .utility)

    let directory: URL
    private let id: UUID
    private let createdAt: Date
    private let name: String?
    private var timeline: RecordingTimeline
    private weak var activeStream: SCStream?
    private var preparingStream = false
    private var initialSnapshot = true
    private var resumeFrame: CMSampleBuffer?
    private let sampleRate: Double
    private let threshold: Double
    private let width: Int
    private let height: Int
    private let thumbnailWidth: Int
    private let thumbnailHeight: Int
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: (Int) -> Void
    private let onFailure: (Error, Bool) -> Void
    private var previousPixels: [UInt8]
    private var currentPixels: [UInt8]
    private var frames: [KeyframeManifest.Frame] = []
    private var failure: Error?
    private var finished = false

    init(
        directory: URL, id: UUID, createdAt: Date, started: CMTime,
        sampleRate: Double, threshold: Double, width: Int, height: Int,
        onFrame: @escaping (Int) -> Void, onFailure: @escaping (Error, Bool) -> Void,
        name: String? = nil
    ) {
        self.directory = directory
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.timeline = RecordingTimeline(started: started)
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.width = width
        self.height = height
        let scale = min(1, 256 / Double(max(width, height)))
        thumbnailWidth = max(1, Int((Double(width) * scale).rounded()))
        thumbnailHeight = max(1, Int((Double(height) * scale).rounded()))
        currentPixels = [UInt8](repeating: 0, count: thumbnailWidth * thumbnailHeight * 4)
        previousPixels = currentPixels
        self.onFrame = onFrame
        self.onFailure = onFailure
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

    func append(_ sampleBuffer: CMSampleBuffer, initialSnapshot: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, failure == nil, !timeline.isPaused else { return }
        autoreleasepool {
            do {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      let info = attachments.first,
                      let status = info[.status] as? Int else {
                    throw KeyframeRecordingError.invalidFrame
                }
                guard status == SCFrameStatus.complete.rawValue else { return }
                guard sampleBuffer.isValid,
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      CVPixelBufferGetWidth(pixelBuffer) == width,
                      CVPixelBufferGetHeight(pixelBuffer) == height,
                      let displayTime = info[.displayTime] as? NSNumber else {
                    throw KeyframeRecordingError.invalidFrame
                }
                let presentationTime = CMClockMakeHostTimeFromSystemUnits(displayTime.uint64Value)
                guard let frameTime = timeline.frameTime(at: presentationTime, initialSnapshot: initialSnapshot) else { return }
                self.initialSnapshot = false
                let time = CMTimeGetSeconds(frameTime)
                if let last = frames.last, time <= last.time { return }
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let thumbnail = image.transformed(by: CGAffineTransform(
                    scaleX: Double(thumbnailWidth) / Double(width),
                    y: Double(thumbnailHeight) / Double(height)
                ))
                currentPixels.withUnsafeMutableBytes { bytes in
                    context.render(
                        thumbnail, toBitmap: bytes.baseAddress!, rowBytes: thumbnailWidth * 4,
                        bounds: CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight),
                        format: .RGBA8, colorSpace: colorSpace
                    )
                }
                if !frames.isEmpty,
                   FrameDifference.score(previous: previousPixels, current: currentPixels, width: thumbnailWidth, height: thumbnailHeight) <= threshold {
                    return
                }

                let file = String(format: "frames/%06d.png", frames.count + 1)
                let url = directory.appendingPathComponent(file)
                guard let fullImage = context.createCGImage(image, from: image.extent),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw KeyframeRecordingError.cannotWriteFrame(url)
                }
                CGImageDestinationAddImage(destination, fullImage, nil)
                guard CGImageDestinationFinalize(destination) else { throw KeyframeRecordingError.cannotWriteFrame(url) }
                frames.append(KeyframeManifest.Frame(file: file, time: time))
                swap(&previousPixels, &currentPixels)
                onFrame(frames.count)
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
                do {
                    guard !frames.isEmpty else {
                        if let failure { throw failure }
                        throw KeyframeRecordingError.noFrames
                    }
                    let manifest = KeyframeManifest(
                        id: id, createdAt: createdAt, duration: duration,
                        sampleRate: sampleRate, threshold: threshold,
                        width: width, height: height, frames: frames, name: name
                    )
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(manifest)
                    try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
                    // A custom name must remain JSON data inside the HTML script element.
                    let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
                    try playerHTML(manifestJSON: json).write(to: directory.appendingPathComponent("player.html"), atomically: true, encoding: .utf8)
                    if let failure { throw failure }
                    continuation.resume(returning: .success(frames.count))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private func playerHTML(manifestJSON: String) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Clipato · 关键帧回放</title>
        <style>
        :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#111216;color:#e8e9ee}
        *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;grid-template-rows:1fr auto}
        main{display:grid;place-items:center;padding:20px;min-height:0}img{max-width:100%;max-height:calc(100vh - 134px);object-fit:contain;border-radius:8px}
        footer{padding:16px 24px 20px;background:#1b1d24;border-top:1px solid #32353f}.controls{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
        button{border:1px solid #454955;border-radius:7px;background:#292d38;color:inherit;padding:7px 14px;font:inherit;cursor:pointer}
        button:focus-visible,input:focus-visible{outline:2px solid #b5bdfc}input{width:100%;accent-color:#a4afff;margin:14px 0 0}
        .muted{color:#9499a8;font-size:12px;margin-left:auto}#error{color:#fca5a5}#counter{font-variant-numeric:tabular-nums}
        </style>
        <body><main><img id="frame" alt="录屏关键帧"></main><footer>
        <div class="controls"><strong>Clipato</strong><button id="previous" aria-label="上一帧">←</button><button id="play">播放</button><button id="next" aria-label="下一帧">→</button>
        <span id="counter"></span><span id="error" role="alert"></span><span class="muted">空格：播放 / 暂停 · ← →：逐帧</span></div>
        <input id="timeline" type="range" min="0" step="0.01" value="0" aria-label="回放时间"></footer>
        <script id="session" type="application/json">\(manifestJSON)</script>
        <script>
        const session=JSON.parse(document.getElementById('session').textContent);
        const image=document.getElementById('frame'),timeline=document.getElementById('timeline'),playButton=document.getElementById('play'),counter=document.getElementById('counter');
        let index=0,time=0,playing=false,origin=0,animation=0;
        timeline.max=String(session.duration);
        function clock(seconds){const minutes=Math.floor(seconds/60);return String(minutes).padStart(2,'0')+':'+(seconds%60).toFixed(1).padStart(4,'0')}
        function show(){let target=0;while(target+1<session.frames.length&&session.frames[target+1].time<=time)target++;if(target!==index||!image.getAttribute('src')){index=target;image.src=session.frames[index].file}timeline.value=String(time);counter.textContent=(index+1)+' / '+session.frames.length+' · '+clock(time)+' / '+clock(session.duration)}
        function pause(){playing=false;cancelAnimationFrame(animation);playButton.textContent='播放'}
        function tick(now){if(!playing)return;time=Math.min(session.duration,(now-origin)/1000);show();if(time>=session.duration){pause();return}animation=requestAnimationFrame(tick)}
        function toggle(){if(playing){pause();return}if(time>=session.duration)time=0;playing=true;origin=performance.now()-time*1000;playButton.textContent='暂停';animation=requestAnimationFrame(tick)}
        function step(direction){pause();const target=Math.max(0,Math.min(session.frames.length-1,index+direction));time=session.frames[target].time;show()}
        playButton.onclick=toggle;document.getElementById('previous').onclick=()=>step(-1);document.getElementById('next').onclick=()=>step(1);
        timeline.oninput=()=>{pause();time=Number(timeline.value);show()};
        document.addEventListener('keydown',event=>{if(event.code==='Space'){event.preventDefault();toggle()}else if(event.key==='ArrowLeft'){event.preventDefault();step(-1)}else if(event.key==='ArrowRight'){event.preventDefault();step(1)}});
        image.onerror=()=>{pause();document.getElementById('error').textContent='图片无法读取，请保持 frames 文件夹与 player.html 在同一目录。'};
        show();
        </script></body></html>
        """
    }
}

enum KeyframeRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidSettings
    case invalidVideoSettings
    case startInProgress
    case stopInProgress
    case outputIsNotDirectory(URL)
    case outputNotEmpty(URL)
    case outputClaimed(URL)
    case invalidFrame
    case noFrames
    case cannotWriteFrame(URL)
    case multipleFailures(Error, Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return L("已有录制正在进行或保存。")
        case .notRecording: return L("当前没有正在进行的录制。")
        case .invalidSettings: return L("关键帧采样率须大于 0 且不超过 30，视频帧率须为 15、30 或 60；变化阈值须在 0 到 1 之间，最大尺寸须大于 0。")
        case .invalidVideoSettings: return L("H.264 视频最大尺寸须在 2 到 4096 像素之间。")
        case .startInProgress: return L("录制仍在启动，请在启动完成后停止。")
        case .stopInProgress: return L("录制正在保存，不能更改暂停状态。")
        case .outputIsNotDirectory(let url): return L("录屏输出路径不是目录：\(url.path)")
        case .outputNotEmpty(let url): return L("录屏输出目录必须为空，避免覆盖已有文件：\(url.path)")
        case .outputClaimed(let url): return L("录屏输出目录已被其他录制占用：\(url.path)")
        case .invalidFrame: return L("ScreenCaptureKit 返回了无效的画面数据。")
        case .noFrames: return L("未收到可保存的屏幕画面；请确认录屏权限后重试。")
        case .cannotWriteFrame(let url): return L("无法写入关键帧：\(url.path)")
        case .multipleFailures(let first, let second): return L("\(first.localizedDescription)；同时发生错误：\(second.localizedDescription)")
        }
    }
}

