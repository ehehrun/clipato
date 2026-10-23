import AVFoundation
import Darwin
import ClipatoCore
import ImageIO
import UniformTypeIdentifiers

enum BatchExportMode: String, CaseIterable, Identifiable, Sendable {
    case files, zip, video
    var id: Self { self }
}

enum BatchImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, pdf
}

struct BatchExportOptions: Sendable {
    var mode: BatchExportMode = .files
    var imageFormat: BatchImageFormat = .png
    var quality: Int = 100
    var videoFormat: KeyframeExportFormat = .mp4
    var fps: Int = 1
    var maxDimension: Int = 1920
    var processing: ImageProcessingOptions?
    var grid: ImageGridOptions?
}

enum BatchImageExporter {
    static func export(
        images: [URL], output: URL, options: BatchExportOptions, overwrite: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let task = AutomationAccess.detached(priority: .userInitiated) {
            try AutomationAccess.check()
            guard !images.isEmpty else { throw BatchExportError.invalidOptions(L("请先选择要导出的图片。")) }
            guard (1...100).contains(options.quality) else { throw BatchExportError.invalidOptions(L("导出质量须为 1% 到 100%。")) }
            if options.grid != nil {
                guard images.count == 1 else { throw BatchExportError.invalidOptions(L("宫格切图仅支持单张图片。")) }
                guard options.mode == .files else { throw BatchExportError.invalidOptions(L("宫格切图请使用独立文件导出。")) }
                guard options.imageFormat != .pdf else { throw BatchExportError.invalidOptions(L("宫格切图仅支持 PNG 或 JPEG。")) }
                guard options.processing == nil else { throw BatchExportError.invalidOptions(L("宫格切图与图片处理不能同时执行。")) }
            }
            if let processing = options.processing {
                guard processing.isValid else { throw BatchExportError.invalidOptions(processing.validationMessage!) }
                guard options.mode == .files else { throw BatchExportError.invalidOptions(L("图片处理请使用独立文件导出。")) }
            }
            if options.mode == .video {
                guard (1...30).contains(options.fps) else { throw BatchExportError.invalidOptions(L("帧率须为 1 到 30 fps。")) }
                guard ((options.videoFormat == .mp4 ? 2 : 1)...4096).contains(options.maxDimension) else {
                    throw BatchExportError.invalidOptions(L("视频最大尺寸须为 2 到 4096 px；GIF 最小可为 1 px。"))
                }
            }
            let names: [String]
            if let grid = options.grid {
                _ = try ImageGridStep.sourceSide(options: grid)
                names = gridFilenames(images[0], options: grid, format: options.imageFormat)
            } else if let processing = options.processing { names = processedFilenames(images, options: processing) }
            else { names = options.mode != .video && options.imageFormat != .pdf ? filenames(images, format: options.imageFormat) : [] }
            let manager = FileManager.default
            let images = images.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            let sourceURLs = Set(images)
            let sourceIdentities = overwrite ? Set(try images.map(FileIdentity.init)) : []
            let output = output.standardizedFileURL.resolvingSymlinksInPath()
            let directoryOutput = options.mode == .files && (options.grid != nil || options.processing != nil || options.imageFormat != .pdf)
            let targets = directoryOutput ? names.map { output.appendingPathComponent($0) } : [output]
            for target in targets {
                guard !sourceURLs.contains(target.resolvingSymlinksInPath()) else { throw BatchExportError.protectedSource(target) }
                if manager.fileExists(atPath: target.path) {
                    guard overwrite else { throw BatchExportError.outputExists(target) }
                    guard !sourceIdentities.contains(try FileIdentity(target)) else { throw BatchExportError.protectedSource(target) }
                    let values = try target.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { throw BatchExportError.invalidOptions(L("导出目标不是普通文件：\(target.path)")) }
                }
            }
            var isDirectory: ObjCBool = false
            let directoryExists = directoryOutput && manager.fileExists(atPath: output.path, isDirectory: &isDirectory)
            if directoryExists && !isDirectory.boolValue { throw BatchExportError.invalidOptions(L("请选择文件夹作为图片导出位置。")) }
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stagingParent = directoryExists ? output : output.deletingLastPathComponent()
            let staging = stagingParent.appendingPathComponent(".clipato-export-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            progress(0)
            do {
                let products = staging.appendingPathComponent("images", isDirectory: true)
                let artifact = staging.appendingPathComponent("export.\(options.mode == .zip ? "zip" : options.mode == .video ? options.videoFormat.rawValue : options.imageFormat.rawValue)")
                if options.mode == .video {
                    let size = try canvasSize(images: images, options: options)
                    let times = images.indices.map { Double($0) / Double(options.fps) }
                    let duration = Double(images.count) / Double(options.fps)
                    let reader: (Int) throws -> CGImage = { index in
                        try fittedImage(readImage(images[index], maxDimension: max(size.width, size.height)), width: size.width, height: size.height)
                    }
                    switch options.videoFormat {
                    case .mp4:
                        try await KeyframeExporter.writeVideo(frameTimes: times, duration: duration, output: artifact,
                            width: size.width, height: size.height, readImage: reader, progress: progress)
                    case .gif:
                        try autoreleasepool {
                            try KeyframeExporter.writeGIF(frameTimes: times, duration: duration, output: artifact, readImage: reader, progress: progress)
                        }
                    }
                } else {
                    try manager.createDirectory(at: products, withIntermediateDirectories: false)
                    if let grid = options.grid {
                        try autoreleasepool {
                            let image = try ImageFormatStep.readImage(at: images[0])
                            _ = try ImageGridStep.sourceRects(width: image.width, height: image.height, options: grid)
                            let format: ImageOutputFormat = options.imageFormat == .png ? .png : .jpeg
                            for index in names.indices {
                                try AutomationAccess.check()
                                try autoreleasepool {
                                    let tile = try ImageGridStep.execute(image: image, options: grid, index: index)
                                    let data = try ImageFormatStep.execute(image: tile, format: format, quality: options.quality)
                                    try data.write(to: products.appendingPathComponent(names[index]), options: .withoutOverwriting)
                                }
                                progress(Double(index + 1) / Double(names.count) * 0.9)
                            }
                        }
                    } else if let processing = options.processing {
                        let variants: [ImageResizeOptions?] = processing.resizeEnabled ? processing.sizes.map(Optional.some) : [nil]
                        var completed = 0
                        var lastProgress = ContinuousClock.now
                        for source in images {
                            try AutomationAccess.check()
                            try autoreleasepool {
                                let image = try readProcessingImage(source, options: processing)
                                for variant in variants {
                                    try AutomationAccess.check()
                                    try autoreleasepool {
                                        let resized: CGImage
                                        if let variant { resized = try ImageResizeStep.execute(image: image, options: variant) }
                                        else { resized = image }
                                        let data: Data
                                        if let targetBytes = processing.targetBytes {
                                            data = try ImageCompressionStep.execute(image: resized, format: processing.format,
                                                targetBytes: targetBytes, allowResizing: processing.allowResizing).data
                                        } else {
                                            data = try ImageFormatStep.execute(image: resized, format: processing.format, quality: processing.quality)
                                        }
                                        try data.write(to: products.appendingPathComponent(names[completed]), options: .withoutOverwriting)
                                        completed += 1
                                    }
                                    if lastProgress.duration(to: .now) >= .milliseconds(100) {
                                        progress(Double(completed) / Double(names.count) * 0.9)
                                        lastProgress = .now
                                    }
                                }
                            }
                        }
                    } else if options.imageFormat == .pdf {
                        try writePDF(images: images, output: options.mode == .zip ? products.appendingPathComponent(L("图片.pdf")) : artifact,
                            quality: options.quality, progress: progress)
                        let pdf = options.mode == .zip ? products.appendingPathComponent(L("图片.pdf")) : artifact
                        guard let document = CGPDFDocument(pdf as CFURL), document.numberOfPages == images.count else {
                            throw BatchExportError.encoding(L("PDF 写入未完成。"))
                        }
                    } else {
                        var lastProgress = ContinuousClock.now
                        for index in images.indices {
                            try AutomationAccess.check()
                            try autoreleasepool {
                                try writeImage(readImage(images[index]), output: products.appendingPathComponent(names[index]),
                                    format: options.imageFormat, quality: options.quality)
                            }
                            if lastProgress.duration(to: .now) >= .milliseconds(100) {
                                progress(Double(index + 1) / Double(images.count) * 0.9)
                                lastProgress = .now
                            }
                        }
                    }
                    if options.mode == .zip { try await writeZIP(directory: products, output: artifact, errorLog: staging.appendingPathComponent("ditto.log")) }
                }
                try AutomationAccess.check()
                if directoryOutput {
                    if directoryExists {
                        try publishFiles(names: names, staging: products, output: output, overwrite: overwrite)
                    } else {
                        try rename(products, to: output, flags: UInt32(RENAME_EXCL))
                    }
                } else {
                    try rename(artifact, to: output, flags: overwrite ? 0 : UInt32(RENAME_EXCL))
                }
                try manager.removeItem(at: staging)
                progress(1)
            } catch {
                if case BatchExportError.rollbackFailed = error { throw error }
                if manager.fileExists(atPath: staging.path) {
                    do { try manager.removeItem(at: staging) }
                    catch let cleanupError { throw KeyframeRecordingError.multipleFailures(error, cleanupError) }
                }
                throw error
            }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func filenames(_ images: [URL], format: BatchImageFormat) -> [String] {
        uniqueFilenames(images.map { $0.deletingPathExtension().lastPathComponent }, extensionName: format.rawValue)
    }

    static func gridFilenames(_ image: URL, options: ImageGridOptions, format: BatchImageFormat) -> [String] {
        let stem = image.deletingPathExtension().lastPathComponent
        return (1...(options.divisions * options.divisions)).map {
            "\(stem)-grid-\(String(format: "%02d", $0)).\(format.rawValue)"
        }
    }

    static func processedFilenames(_ images: [URL], options: ImageProcessingOptions) -> [String] {
        let stems = images.flatMap { image -> [String] in
            let stem = image.deletingPathExtension().lastPathComponent
            if !options.resizeEnabled { return [stem] }
            return options.sizes.map { "\(stem)-\($0.width)x\($0.height)-\($0.mode.rawValue)" }
        }
        return uniqueFilenames(stems, extensionName: options.format.rawValue)
    }

    private static func readProcessingImage(_ url: URL, options: ImageProcessingOptions) throws -> CGImage {
        guard options.resizeEnabled else { return try ImageFormatStep.readImage(at: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int, sourceWidth > 0, sourceHeight > 0 else {
            throw ImageProcessingError.unreadableImage(url)
        }
        let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        let width = Double(rotated ? sourceHeight : sourceWidth)
        let height = Double(rotated ? sourceWidth : sourceHeight)
        var scale = 0.0
        for size in options.sizes {
            let sx = Double(size.width) / width
            let sy = Double(size.height) / height
            scale = max(scale, size.mode == .crop ? max(sx, sy) : min(sx, sy))
        }
        let maximumDimension = max(1, Int(ceil(max(width, height) * min(1, scale))))
        return try ImageFormatStep.readImage(at: url, maximumDimension: maximumDimension)
    }

    private static func uniqueFilenames(_ stems: [String], extensionName: String) -> [String] {
        var used = Set<String>()
        var nextSuffix: [String: Int] = [:]
        return stems.map { base in
            var name = "\(base).\(extensionName)"
            let key = name.lowercased()
            var suffix = nextSuffix[key, default: 2]
            while !used.insert(name.lowercased()).inserted {
                name = "\(base)-\(suffix).\(extensionName)"
                suffix += 1
            }
            nextSuffix[key] = suffix
            return name
        }
    }

    private static func readImage(_ url: URL, maxDimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) else { throw BatchExportError.invalidImage(url) }
        if type == UTType.png.identifier as CFString { try KeyframeExporter.validatePNGEnd(at: url) }
        guard
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension ?? max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw BatchExportError.invalidImage(url)
        }
        return image
    }

    private static func canvasSize(images: [URL], options: BatchExportOptions) throws -> (width: Int, height: Int) {
        var width = 0, height = 0
        for url in images {
            try AutomationAccess.check()
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = properties[kCGImagePropertyPixelWidth] as? Int,
                      let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { throw BatchExportError.invalidImage(url) }
                let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
                width = max(width, rotated ? h : w)
                height = max(height, rotated ? w : h)
            }
        }
        let scale = min(1, Double(options.maxDimension) / Double(max(width, height)))
        width = max(1, Int((Double(width) * scale).rounded(.down)))
        height = max(1, Int((Double(height) * scale).rounded(.down)))
        if options.videoFormat == .mp4 {
            width = max(2, width / 2 * 2)
            height = max(2, height / 2 * 2)
        }
        return (width, height)
    }

    private static func fittedImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw BatchExportError.encoding(L("无法创建导出画布。"))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(1, min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
            width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw BatchExportError.encoding(L("无法生成导出图片。")) }
        return result
    }

    private static func writeImage(_ image: CGImage, output: URL, format: BatchImageFormat, quality: Int) throws {
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw BatchExportError.encoding(L("无法创建图片文件：\(output.lastPathComponent)"))
        }
        let image = format == .jpeg ? try fittedImage(image, width: image.width, height: image.height) : image
        let properties: CFDictionary? = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw BatchExportError.encoding(L("图片写入未完成：\(output.lastPathComponent)")) }
    }

    private static func writePDF(images: [URL], output: URL, quality: Int, progress: @Sendable (Double) -> Void) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw BatchExportError.encoding(L("无法创建 PDF 文件。"))
        }
        defer { context.closePDF() }
        var lastProgress = ContinuousClock.now
        for (index, url) in images.enumerated() {
            try AutomationAccess.check()
            try autoreleasepool {
                let original = try readImage(url)
                let opaque = try fittedImage(original, width: original.width, height: original.height)
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw BatchExportError.encoding(L("无法压缩 PDF 图片。"))
                }
                CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
                guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data),
                      let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                    throw BatchExportError.encoding(L("PDF 图片压缩未完成。"))
                }
                var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                let page = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: page] as CFDictionary)
                context.draw(image, in: bounds)
                context.endPDFPage()
            }
            if lastProgress.duration(to: .now) >= .milliseconds(100) {
                progress(Double(index + 1) / Double(images.count) * 0.9)
                lastProgress = .now
            }
        }
    }

    private static func writeZIP(directory: URL, output: URL, errorLog: URL) async throws {
        try Data().write(to: errorLog)
        let errors = try FileHandle(forWritingTo: errorLog)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", directory.path, output.path]
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() }
        catch { try errors.close(); throw error }
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                try errors.close()
                throw CancellationError()
            }
            do { try await Task.sleep(for: .milliseconds(30)) }
            catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                try errors.close()
                throw error
            }
        }
        try errors.close()
        guard process.terminationStatus == 0 else {
            let details = try String(contentsOf: errorLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BatchExportError.encoding(L("ZIP 压缩失败（\(process.terminationStatus)）：\(details)"))
        }
    }

    private static func publishFiles(names: [String], staging: URL, output: URL, overwrite: Bool) throws {
        var published: [(name: String, replaced: Bool)] = []
        do {
            for name in names {
                try AutomationAccess.check()
                let target = output.appendingPathComponent(name)
                let replaced = overwrite && FileManager.default.fileExists(atPath: target.path)
                if replaced {
                    guard try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw BatchExportError.invalidOptions(L("导出目标不是普通文件：\(target.path)"))
                    }
                }
                try rename(staging.appendingPathComponent(name), to: target, flags: replaced ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
                published.append((name, replaced))
            }
            try AutomationAccess.check()
        } catch {
            var rollbackError: Error?
            for item in published.reversed() {
                do {
                    try rename(output.appendingPathComponent(item.name), to: staging.appendingPathComponent(item.name),
                        flags: item.replaced ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
                } catch { rollbackError = rollbackError.map { KeyframeRecordingError.multipleFailures($0, error) } ?? error }
            }
            if let rollbackError {
                // A failed rollback must leave the user's previous files available for recovery.
                throw BatchExportError.rollbackFailed(KeyframeRecordingError.multipleFailures(error, rollbackError), staging)
            }
            throw error
        }
    }

    private static func rename(_ source: URL, to destination: URL, flags: UInt32) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, flags) == 0 ? 0 : errno
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [NSFilePathErrorKey: destination.path]) }
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ url: URL) throws {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        device = info.st_dev
        inode = info.st_ino
    }
}

private enum BatchExportError: LocalizedError {
    case invalidOptions(String), invalidImage(URL), protectedSource(URL), outputExists(URL), encoding(String)
    case rollbackFailed(Error, URL)
    var errorDescription: String? {
        switch self {
        case .invalidOptions(let reason), .encoding(let reason): return reason
        case .invalidImage(let url): return L("图片缺失、损坏或格式不支持：\(url.path)")
        case .protectedSource(let url): return L("导出不能覆盖原始图片：\(url.path)")
        case .outputExists(let url): return L("导出文件已存在，请选择其他位置或允许覆盖：\(url.path)")
        case .rollbackFailed(let error, let url): return L("导出未完成，原文件保留在 \(url.path)。\(error.localizedDescription)")
        }
    }
}
