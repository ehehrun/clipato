import AVFoundation
import ClipatoCore
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum KeyframeExportFormat: String, CaseIterable, Sendable {
    case mp4, gif

    var title: String { self == .mp4 ? L("MP4 视频") : L("GIF 动图") }
    var defaultMaxDimension: Int { self == .mp4 ? 1920 : 1280 }
}

enum KeyframeExporter {
    static func export(
        directory: URL, output: URL, format: KeyframeExportFormat, maxDimension: Int,
        overwrite: Bool = false, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let task = AutomationAccess.detached(priority: .userInitiated) {
            try AutomationAccess.check()
            guard ((format == .mp4 ? 2 : 1)...4096).contains(maxDimension) else {
                throw KeyframeExportError.invalidSize
            }
            let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
            let output = output.standardizedFileURL
            let resolvedOutput = output.resolvingSymlinksInPath()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(KeyframeManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            guard (1...16384).contains(manifest.width), (1...16384).contains(manifest.height),
                  manifest.duration.isFinite, manifest.duration > 0,
                  manifest.duration < Double(Int64.max / 60_000), !manifest.frames.isEmpty else {
                throw KeyframeExportError.invalidManifest(L("录制尺寸、时长或帧列表无效。"))
            }
            let protectedFiles = ["manifest.json", "player.html"].map { directory.appendingPathComponent($0).resolvingSymlinksInPath() }
            guard !protectedFiles.contains(resolvedOutput), resolvedOutput != directory else {
                throw KeyframeExportError.protectedSource(output)
            }
            var previousTime = -Double.infinity
            let frameURLs = try manifest.frames.map { frame in
                guard frame.time.isFinite, frame.time >= 0, frame.time > previousTime, frame.time < manifest.duration else {
                    throw KeyframeExportError.invalidManifest(L("关键帧时间必须递增，并且早于录制结束。"))
                }
                previousTime = frame.time
                let url = directory.appendingPathComponent(frame.file).standardizedFileURL.resolvingSymlinksInPath()
                guard !frame.file.hasPrefix("/"), url.path.hasPrefix(directory.path + "/"), url.pathExtension.lowercased() == "png" else {
                    throw KeyframeExportError.invalidManifest(L("关键帧文件必须是录制目录内的 PNG 图片。"))
                }
                guard url != resolvedOutput else { throw KeyframeExportError.protectedSource(output) }
                return url
            }
            if !overwrite, FileManager.default.fileExists(atPath: output.path) {
                throw KeyframeExportError.outputExists(output)
            }
            let scale = min(1, Double(maxDimension) / Double(max(manifest.width, manifest.height)))
            var width = Int((Double(manifest.width) * scale).rounded(.down))
            var height = Int((Double(manifest.height) * scale).rounded(.down))
            if format == .mp4 {
                width = width / 2 * 2
                height = height / 2 * 2
            }
            guard width >= (format == .mp4 ? 2 : 1), height >= (format == .mp4 ? 2 : 1) else {
                throw KeyframeExportError.invalidSize
            }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).partial.\(format.rawValue)")
            progress(0)
            do {
                switch format {
                case .mp4:
                    try await writeVideo(frameTimes: manifest.frames.map(\.time), duration: manifest.duration, output: temporary, width: width, height: height, readImage: {
                        try readFrame(frameURLs[$0], manifest: manifest, width: width, height: height)
                    }, progress: progress)
                case .gif:
                    try autoreleasepool {
                        try writeGIF(frameTimes: manifest.frames.map(\.time), duration: manifest.duration, output: temporary, readImage: {
                            try readFrame(frameURLs[$0], manifest: manifest, width: width, height: height)
                        }, progress: progress)
                    }
                }
                try AutomationAccess.check()
                let result = temporary.path.withCString { source in
                    output.path.withCString { destination in
                        renamex_np(source, destination, overwrite ? 0 : UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                    }
                }
                guard result == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [NSFilePathErrorKey: output.path])
                }
                progress(1)
            } catch {
                if FileManager.default.fileExists(atPath: temporary.path) {
                    do { try FileManager.default.removeItem(at: temporary) }
                    catch let cleanupError { throw KeyframeRecordingError.multipleFailures(error, cleanupError) }
                }
                throw error
            }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func writeVideo(
        frameTimes: [Double], duration: Double, output: URL, width: Int, height: Int,
        readImage: (Int) throws -> CGImage, progress: @Sendable (Double) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, min(30_000_000, width * height * 5)),
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60_000
        guard writer.canAdd(input) else { throw KeyframeExportError.encoding(L("当前系统不支持此尺寸的 H.264 编码。")) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? KeyframeExportError.encoding(L("H.264 编码器无法启动。")) }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        var lastProgress = ContinuousClock.now
        for index in frameTimes.indices {
            try AutomationAccess.check()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? KeyframeExportError.encoding(L("H.264 编码失败。")) }
                guard ContinuousClock.now < deadline else { throw KeyframeExportError.encoding(L("H.264 编码器超过 10 秒未响应。")) }
                try await Task.sleep(for: .milliseconds(10))
            }
            try autoreleasepool {
                let start = CMTime(seconds: index == 0 ? 0 : frameTimes[index], preferredTimescale: 60_000)
                let end = CMTime(seconds: index + 1 < frameTimes.count ? frameTimes[index + 1] : duration, preferredTimescale: 60_000)
                guard end > start else { throw KeyframeExportError.invalidManifest(L("关键帧间隔小于视频时间精度。")) }
                let image = try readImage(index)
                var pixels: CVPixelBuffer?
                let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
                guard result == kCVReturnSuccess, let pixels else { throw KeyframeExportError.encoding(L("无法创建视频画面（CoreVideo \(result)）。")) }
                CVBufferSetAttachment(pixels, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                CVPixelBufferLockBaseAddress(pixels, [])
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    throw KeyframeExportError.encoding(L("无法绘制视频画面。"))
                }
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                CVPixelBufferUnlockBaseAddress(pixels, [])
                var description: CMVideoFormatDescription?
                let descriptionResult = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description)
                guard descriptionResult == noErr, let description else { throw KeyframeExportError.encoding(L("无法设置视频格式（CoreMedia \(descriptionResult)）。")) }
                var timing = CMSampleTimingInfo(duration: end - start, presentationTimeStamp: start, decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                    formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
                guard sampleResult == noErr, let sample else { throw KeyframeExportError.encoding(L("无法创建视频样本（CoreMedia \(sampleResult)）。")) }
                guard input.append(sample) else { throw writer.error ?? KeyframeExportError.encoding(L("H.264 编码器无法写入画面。")) }
            }
            if lastProgress.duration(to: .now) >= .milliseconds(100) {
                progress(Double(index + 1) / Double(frameTimes.count) * 0.95)
                lastProgress = .now
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
        input.markAsFinished()
        writer.finishWriting {}
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while writer.status == .writing {
            guard ContinuousClock.now < deadline else { throw KeyframeExportError.encoding(L("H.264 编码器超过 30 秒未完成文件。")) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try AutomationAccess.check()
        guard writer.status == .completed else { throw writer.error ?? KeyframeExportError.encoding(L("H.264 视频未完成。")) }
    }

    static func writeGIF(
        frameTimes: [Double], duration: Double, output: URL,
        readImage: (Int) throws -> CGImage, progress: @Sendable (Double) -> Void
    ) throws {
        // GIF stores an unsigned 16-bit delay in centiseconds; quantize cumulative boundaries to avoid drift.
        let boundaries = [0] + frameTimes.dropFirst().map { Int(($0 * 100).rounded()) } + [Int((duration * 100).rounded())]
        let delays = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }
        guard delays.allSatisfy({ $0 > 0 }) else { throw KeyframeExportError.invalidManifest(L("GIF 的时间精度为 1/100 秒；存在量化后为零的关键帧间隔。")) }
        let count = delays.reduce(0) { $0 + ($1 + 65_534) / 65_535 }
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.gif.identifier as CFString, count, nil) else {
            throw KeyframeExportError.encoding(L("无法创建 GIF 文件。"))
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var lastProgress = ContinuousClock.now
        for index in frameTimes.indices {
            try AutomationAccess.check()
            try autoreleasepool {
                let image = try readImage(index)
                var remaining = delays[index]
                while remaining > 0 {
                    try AutomationAccess.check()
                    let delay = min(remaining, 65_535)
                    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: Double(delay) / 100,
                        kCGImagePropertyGIFUnclampedDelayTime: Double(delay) / 100
                    ]] as CFDictionary)
                    remaining -= delay
                }
            }
            if lastProgress.duration(to: .now) >= .milliseconds(100) {
                progress(Double(index + 1) / Double(frameTimes.count) * 0.95)
                lastProgress = .now
            }
        }
        try AutomationAccess.check()
        guard CGImageDestinationFinalize(destination) else { throw KeyframeExportError.encoding(L("GIF 文件未完成。")) }
    }

    static func validatePNGEnd(at url: URL) throws {
        do { try ImageFormatStep.validatePNGEnd(at: url) }
        catch is ImageProcessingError { throw KeyframeExportError.invalidFrame(url) }
    }

    static func readFrame(_ url: URL, manifest: KeyframeManifest, width: Int, height: Int) throws -> CGImage {
        try validatePNGEnd(at: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == manifest.width,
              properties[kCGImagePropertyPixelHeight] as? Int == manifest.height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw KeyframeExportError.invalidFrame(url) }
        if image.width == width, image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KeyframeExportError.invalidFrame(url)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw KeyframeExportError.invalidFrame(url) }
        return scaled
    }
}

enum KeyframeExportError: LocalizedError {
    case invalidSize
    case invalidManifest(String)
    case invalidFrame(URL)
    case protectedSource(URL)
    case outputExists(URL)
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidSize: return L("导出最大尺寸须为 MP4：2 到 4096 像素、GIF：1 到 4096 像素；缩放后的宽高须至少为 MP4：2 像素、GIF：1 像素。")
        case .invalidManifest(let reason): return L("关键帧录制数据无效：\(reason)")
        case .invalidFrame(let url): return L("关键帧缺失、损坏或尺寸与录制不符：\(url.path)")
        case .protectedSource(let url): return L("导出不能覆盖原始录制文件：\(url.path)")
        case .outputExists(let url): return L("导出文件已存在，请选择新文件名或明确允许覆盖：\(url.path)")
        case .encoding(let message): return message
        }
    }
}
