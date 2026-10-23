import AppKit
import Combine
import Darwin
import ClipatoCore
import ScreenCaptureKit

@MainActor
enum ClipatoCLI {
    static func run(arguments: [String], access: AutomationAccess = AutomationAccess(),
                    accessLog: MCPAccessLog? = nil) async -> Int32 {
        let sessionID = UUID()
        let started = ContinuousClock.now
        let caller = accessLog == nil ? nil : AutomationCaller.current.jsonObject
        if let accessLog {
            do {
                try await accessLog.append(.init(sessionID: sessionID, client: nil, id: nil,
                    method: "cli/run", tool: nil, status: "received", params: ["arguments": arguments],
                    transport: "cli", caller: caller))
            } catch {
                stderr("Clipato: Access log write failed; command not executed: \(error.localizedDescription)")
                return 1
            }
        }
        var runAccess = access
        let result: Int32
        do {
            var arguments = arguments
            var libraryPath: String?
            try readLeadingLibrary(&arguments, into: &libraryPath)
            let command = arguments.isEmpty ? "help" : arguments.removeFirst()
            let scopedAccess = command == "mcp" ? AutomationAccess(mcpFrom: access) : access
            runAccess = scopedAccess
            let task = Task { @MainActor in
                await AutomationAccess.$current.withValue(scopedAccess) {
                    await execute(command: command, arguments: arguments, libraryPath: libraryPath,
                                  accessLog: accessLog, sessionID: sessionID, caller: caller)
                }
            }
            let observer = scopedAccess.observeRevocation { task.cancel() }
            defer { DistributedNotificationCenter.default().removeObserver(observer) }
            result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            stderr("Clipato: \(error.localizedDescription)")
            result = 2
        }
        if let accessLog {
            let duration = started.duration(to: .now)
            let status = result == 0 ? "completed" : (!runAccess.isAllowed ? "denied" : (result == 130 ? "cancelled" : "failed"))
            do {
                try await accessLog.append(.init(sessionID: sessionID, client: nil, id: nil,
                    method: "cli/run", tool: nil, status: status,
                    durationMs: Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000),
                    transport: "cli", caller: caller, exitCode: result))
            } catch {
                stderr("Clipato: Command finished (exit \(result)), but the access log could not be written: \(error.localizedDescription).")
            }
        }
        return result
    }

    private static func execute(command: String, arguments: [String], libraryPath: String?, accessLog: MCPAccessLog?, sessionID: UUID,
                                caller: [String: Any]?) async -> Int32 {
        do {
            if command == "help" || command == "--help" || command == "-h" {
                guard arguments.count <= 1 else { throw CLIError.arguments("help 最多接受一个命令名。") }
                try showHelp(arguments.first)
                return 0
            }

            switch command {
            case "tools":
                let options = try parse(arguments, values: ["library"], flags: [], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                guard options.paths.count <= 1 else { throw CLIError.arguments("tools 最多接受一个能力名称。") }
                let result: Any
                if let name = options.paths.first {
                    guard let definition = MCPTools.definitions.first(where: { $0["name"] as? String == name }) else {
                        throw CLIError.arguments("未知能力：\(name)。运行 clipato tools 查看能力列表。")
                    }
                    result = definition
                } else { result = MCPTools.definitions }
                try writeJSON(result)
            case "call":
                let options = try parse(arguments, values: ["input", "library"], flags: [], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                guard options.paths.count == 1, let input = options.values["input"] else {
                    throw CLIError.arguments("用法：clipato call NAME --input FILE|- [--library PATH]")
                }
                let name = options.paths[0]
                guard MCPTools.definitions.contains(where: { $0["name"] as? String == name }) else {
                    throw CLIError.arguments("未知能力：\(name)。运行 clipato tools 查看能力列表。")
                }
                try AutomationAccess.check()
                let data: Data
                if input == "-" {
                    guard let contents = try FileHandle.standardInput.readToEnd() else {
                        throw CLIError.arguments("标准输入为空；请提供 UTF-8 JSON 对象。")
                    }
                    data = contents
                } else { data = try Data(contentsOf: fileURL(input)) }
                guard String(data: data, encoding: .utf8) != nil else {
                    throw CLIError.arguments("--input 必须为 UTF-8 JSON 对象。")
                }
                let decoded: Any
                do { decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
                catch { throw CLIError.arguments("--input JSON 无效：\(error.localizedDescription)") }
                guard let parameters = decoded as? [String: Any] else {
                    throw CLIError.arguments("--input 必须为 JSON 对象。")
                }
                try AutomationAccess.check()
                if let accessLog {
                    do {
                        try await accessLog.append(.init(sessionID: sessionID, client: nil, id: nil,
                            method: "cli/call", tool: name, status: "received", params: parameters,
                            transport: "cli", caller: caller))
                    } catch {
                        throw CLIError.operation("Access log write failed; tool not executed: \(error.localizedDescription)")
                    }
                }
                let library = libraryURL(options)
                let result = try await withExportSignals {
                    try AutomationAccess.check()
                    return try await MCPTools.call(name: name, arguments: parameters, library: library)
                }
                try AutomationAccess.check()
                try writeJSON(result)
            case "mcp":
                let options = try parse(arguments, values: ["library"], flags: [], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                try requireNoPaths(options)
                try AutomationAccess.check()
                try await MCPServer(library: libraryURL(options), accessLog: accessLog).run()
            case "permissions":
                let options = try parse(arguments, values: ["library"], flags: [], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                try requireNoPaths(options)
                stdout("applicationPath: \(Bundle.main.bundleURL.path)")
                stdout("bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "(none)")")
                stdout("screenCapturePreflight: \(CGPreflightScreenCaptureAccess())")
            case "version", "--version":
                let options = try parse(arguments, values: ["library"], flags: [], leadingLibrary: libraryPath)
                if options.help { try showHelp("version"); return 0 }
                try requireNoPaths(options)
                stdout(AppVersion.displayName)
            case "displays":
                let options = try parse(arguments, values: ["library"], flags: [], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                try requireNoPaths(options)
                try AutomationAccess.check()
                let displays = try await KeyframeRecorder().availableDisplays()
                try AutomationAccess.check()
                let data = try JSONSerialization.data(withJSONObject: displays.map {
                    ["displayID": $0.displayID, "width": $0.width, "height": $0.height]
                }, options: [.prettyPrinted, .sortedKeys])
                stdout(String(decoding: data, as: UTF8.self))
            case "screenshot":
                let options = try parse(arguments, values: ["output", "display", "rect", "library", "tag"], flags: ["region", "vault", "overwrite"], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                try requireNoPaths(options)
                let output = try outputURL(options)
                let displayID = try displayID(options)
                let explicitRegion = try recordingRegion(options, displayID: displayID)
                guard !(options.flags.contains("region") && displayID != nil) else {
                    throw CLIError.arguments("--region 不能与 --display 同时使用。")
                }
                var tag = try assetTag(options)
                guard options.values["tag"] == nil || options.flags.contains("vault") else {
                    throw CLIError.arguments("截图的 --tag 需要同时使用 --vault。")
                }
                try AutomationAccess.check()
                try checkOutput(output, overwrite: options.flags.contains("overwrite"))
                if let explicitRegion { try validateRecordingRegion(explicitRegion) }
                let screenshots = ScreenshotController()
                let image: CGImage?
                if let explicitRegion {
                    image = try await screenshots.captureFixedRegion(explicitRegion, excludingWindowIDs: [])
                } else if options.flags.contains("region") {
                    ClipatoApp.startCommandEventLoop()
                    let result = try await screenshots.captureRegion(allowsDestinationActions: false, tag: tag,
                                                                     allowsTagSelection: options.flags.contains("vault"))
                    image = result?.image
                    tag = result?.tag
                } else if let displayID {
                    image = try await screenshots.captureDisplay(displayID: displayID)
                } else {
                    image = try await screenshots.captureDisplay()
                }
                try AutomationAccess.check()
                guard let image else { throw CLIError.operation("截图已取消，没有写入文件。") }
                try writeOutput(image, to: output, overwrite: options.flags.contains("overwrite"))
                if options.flags.contains("vault") {
                    try AutomationAccess.check()
                    let library = try LibraryStore(root: libraryURL(options))
                    let item = try library.addImage(image, source: "截图", filename: output.lastPathComponent, tag: tag)
                    if library.storagePolicy.automaticallyRemoveOldestImages { await library.refreshStorageUsage() }
                    await library.cancelStorageWorkAndWait()
                    try AutomationAccess.check()
                    stderr("已加入保管箱：\(library.imageURL(item).path)")
                }
                stdout(output.path)
            case "collage":
                let options = try parse(arguments, values: ["output", "mode", "rows", "columns", "scale", "max-width", "max-height", "spacing", "library"], flags: ["overwrite"], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                guard !options.paths.isEmpty, options.paths.count <= 4_096 else {
                    throw CLIError.arguments("collage 需要 1 到 4096 个图片路径。")
                }
                let output = try outputURL(options)
                let modeName = options.values["mode"] ?? "grid"
                guard let mode = CollageSettings.Mode(rawValue: modeName) else {
                    throw CLIError.arguments("--mode 必须为 grid 或 flow。")
                }
                let defaultColumns = Int(Double(options.paths.count).squareRoot().rounded(.up))
                let columns = try integer("columns", options: options, default: defaultColumns, range: 1...64)
                let rows = try integer("rows", options: options, default: (options.paths.count + columns - 1) / columns, range: 1...64)
                guard mode != .grid || columns * rows >= options.paths.count else {
                    throw CLIError.arguments("网格容量 \(columns * rows) 小于 \(options.paths.count) 张图片，请增加行数或列数。")
                }
                let settings = CollageSettings(
                    mode: mode, columns: columns, rows: rows,
                    scale: try decimal("scale", options: options, default: 1, range: 0.05...4),
                    maxWidth: try integer("max-width", options: options, default: 1_600, range: 1...8_192),
                    maxHeight: try integer("max-height", options: options, default: 1_200, range: 1...8_192),
                    spacing: try integer("spacing", options: options, default: 12, range: 0...512)
                )
                try AutomationAccess.check()
                try checkOutput(output, overwrite: options.flags.contains("overwrite"))
                let images = try options.paths.map {
                    try AutomationAccess.check()
                    return try LibraryStore.readImage(at: fileURL($0))
                }
                let image: CGImage
                do { image = try CollageRenderer.render(images: images, settings: settings) }
                catch let error as CollageError {
                    if case .contextCreationFailed = error { throw error }
                    throw CLIError.arguments(error.localizedDescription)
                }
                try writeOutput(image, to: output, overwrite: options.flags.contains("overwrite"))
                stdout(output.path)
            case "stitch":
                let options = try parse(arguments, values: ["output", "min-overlap", "max-overlap", "overlaps", "offsets", "library", "tag"],
                                        flags: ["overwrite", "vault"], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                guard (1...256).contains(options.paths.count) else {
                    throw CLIError.arguments("stitch 需要 1 到 256 个按顺序排列的图片路径。")
                }
                let output = try outputURL(options)
                let minimum = try integer("min-overlap", options: options, default: 1, range: 1...32_768)
                let maximum = try integer("max-overlap", options: options, default: 10, range: 0...32_768)
                let tag = try assetTag(options)
                guard options.values["tag"] == nil || options.flags.contains("vault") else {
                    throw CLIError.arguments("长图的 --tag 需要同时使用 --vault。")
                }
                let count = options.paths.count - 1
                func numbers(_ key: String) throws -> [Int]? {
                    guard let text = options.values[key] else { return nil }
                    let values = text.split(separator: ",", omittingEmptySubsequences: false)
                    guard values.count == count else {
                        throw CLIError.arguments("--\(key) 需要 \(count) 个逗号分隔的整数，对应每条接缝。")
                    }
                    return try values.map {
                        guard let value = Int($0.trimmingCharacters(in: .whitespaces)) else {
                            throw CLIError.arguments("--\(key) 必须为可表示的整数。")
                        }
                        return value
                    }
                }
                let overlaps = try numbers("overlaps")
                let offsets = try numbers("offsets")
                guard offsets == nil || overlaps != nil else { throw CLIError.arguments("--offsets 需要同时指定 --overlaps。") }
                try AutomationAccess.check()
                try checkOutput(output, overwrite: options.flags.contains("overwrite"))
                let images = try options.paths.map {
                    try AutomationAccess.check()
                    return try LibraryStore.readImage(at: fileURL($0))
                }
                var joins = Array(repeating: LongScreenshotJoin(overlap: 0), count: count)
                for index in 0..<count {
                    try AutomationAccess.check()
                    if let overlaps {
                        joins[index] = LongScreenshotJoin(overlap: overlaps[index], offsetX: offsets?[index] ?? 0)
                    } else if maximum > 0 {
                        switch try LongScreenshot.analyze(previous: images[index], next: images[index + 1], minimumOverlap: minimum, maximumOverlap: maximum) {
                        case .matched(let join): joins[index] = join
                        case .duplicate:
                            stderr("Clipato: 第 \(index + 1)、\(index + 2) 张图片重复，保留两张原图按顺序无重叠拼接。")
                        case .noReliableMatch:
                            stderr("Clipato: 第 \(index + 1) 条接缝未可靠对齐，保留原图按顺序无重叠拼接；可用 --overlaps、--offsets 手动调整。")
                        }
                    }
                }
                let image = try LongScreenshot.render(images: images, joins: joins)
                try writeOutput(image, to: output, overwrite: options.flags.contains("overwrite"))
                if options.flags.contains("vault") {
                    try AutomationAccess.check()
                    let library = try LibraryStore(root: libraryURL(options))
                    _ = try library.addImage(image, source: "长截图", filename: output.lastPathComponent, tag: tag)
                    if library.storagePolicy.automaticallyRemoveOldestImages { await library.refreshStorageUsage() }
                    await library.cancelStorageWorkAndWait()
                    try AutomationAccess.check()
                }
                stdout(output.path)
            case "export":
                let options = try parse(arguments, values: ["output", "max-dimension", "library"], flags: ["overwrite", "vault"], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                guard options.paths.count == 1 else {
                    throw CLIError.arguments("export 需要一个含 manifest.json 的关键帧录制目录。")
                }
                if options.flags.contains("vault") {
                    guard options.values["output"] == nil, options.values["max-dimension"] == nil,
                          !options.flags.contains("overwrite") else {
                        throw CLIError.arguments("--vault 将原始关键帧加入保管箱，不能同时指定 --output、--max-dimension 或 --overwrite。")
                    }
                    let directory = fileURL(options.paths[0])
                    try AutomationAccess.check()
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let manifest = try decoder.decode(KeyframeManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
                    let library = try LibraryStore(root: libraryURL(options))
                    try await withExportSignals {
                        let count = try await library.importKeyframes(SavedSession(id: manifest.id, directory: directory, manifest: manifest))
                        if library.storagePolicy.automaticallyRemoveOldestImages { await library.refreshStorageUsage() }
                        await library.cancelStorageWorkAndWait()
                        try AutomationAccess.check()
                        stdout("已将 \(count) 个关键帧导出到保管箱")
                    }
                    break
                }
                let output = try outputURL(options, png: false)
                guard let format = KeyframeExportFormat(rawValue: output.pathExtension.lowercased()) else {
                    throw CLIError.arguments("--output 必须使用 .mp4 或 .gif 扩展名。")
                }
                let maxDimension = try integer("max-dimension", options: options, default: format.defaultMaxDimension,
                                               range: format == .mp4 ? 2...4_096 : 1...4_096)
                let overwrite = options.flags.contains("overwrite")
                try AutomationAccess.check()
                try checkOutput(output, overwrite: overwrite)
                stderr("正在导出\(format.title)，保留关键帧停留时间；Ctrl+C 取消。")
                try await withExportSignals {
                    try await KeyframeExporter.export(directory: fileURL(options.paths[0]), output: output, format: format,
                                                      maxDimension: maxDimension, overwrite: overwrite)
                }
                try AutomationAccess.check()
                stdout(output.path)
            case "export-images":
                let options = try parse(arguments, values: ["output", "format", "quality", "fps", "max-dimension", "library"],
                                        flags: ["zip", "overwrite"], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                guard (1...4_096).contains(options.paths.count) else {
                    throw CLIError.arguments("export-images 需要 1 到 4096 个按顺序排列的图片路径。")
                }
                let output = try outputURL(options, png: false)
                let format = options.values["format"] ?? "png"
                var settings = BatchExportOptions()
                if let videoFormat = KeyframeExportFormat(rawValue: format) {
                    guard !options.flags.contains("zip"), options.values["quality"] == nil else {
                        throw CLIError.arguments("MP4 / GIF 不支持 --zip 或 --quality。")
                    }
                    settings.mode = .video
                    settings.videoFormat = videoFormat
                    settings.fps = try integer("fps", options: options, default: 1, range: 1...30)
                    settings.maxDimension = try integer("max-dimension", options: options, default: videoFormat.defaultMaxDimension,
                                                       range: videoFormat == .mp4 ? 2...4_096 : 1...4_096)
                    guard output.pathExtension.lowercased() == format else {
                        throw CLIError.arguments("--output 需要使用 .\(format) 扩展名。")
                    }
                } else if let imageFormat = BatchImageFormat(rawValue: format) {
                    guard options.values["fps"] == nil, options.values["max-dimension"] == nil else {
                        throw CLIError.arguments("--fps 和 --max-dimension 仅用于 MP4 / GIF。")
                    }
                    settings.mode = options.flags.contains("zip") ? .zip : .files
                    settings.imageFormat = imageFormat
                    settings.quality = try integer("quality", options: options, default: 100, range: 1...100)
                    guard imageFormat != .png || settings.quality == 100 else {
                        throw CLIError.arguments("PNG 始终无损，--quality 必须为 100；有损压缩可选 jpeg 或 pdf。")
                    }
                    let requiredExtension = settings.mode == .zip ? "zip" : imageFormat == .pdf ? "pdf" : nil
                    if let requiredExtension, output.pathExtension.lowercased() != requiredExtension {
                        throw CLIError.arguments("--output 需要使用 .\(requiredExtension) 扩展名。")
                    }
                } else {
                    throw CLIError.arguments("--format 必须为 png、jpeg、pdf、mp4 或 gif。")
                }
                let exportOptions = settings
                try AutomationAccess.check()
                try await withExportSignals {
                    try await BatchImageExporter.export(images: options.paths.map(fileURL), output: output,
                                                        options: exportOptions, overwrite: options.flags.contains("overwrite"))
                }
                try AutomationAccess.check()
                stdout(output.path)
            case "record":
                let options = try parse(arguments, values: ["mode", "output", "display", "rect", "duration", "fps", "threshold", "max-dimension", "library", "tag"], flags: ["region"], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                try requireNoPaths(options)
                let output = try outputURL(options, png: false)
                guard let mode = RecordingMode(rawValue: options.values["mode"] ?? "keyframes") else {
                    throw CLIError.arguments("--mode 必须为 video（MP4 视频）或 keyframes（关键帧）。")
                }
                let explicitDisplay = try displayID(options)
                let explicitRegion = try recordingRegion(options, displayID: explicitDisplay)
                let fps = options.values["fps"] == nil ? nil : try integer("fps", options: options, default: mode.defaultFrameRate, range: 1...60)
                let threshold = options.values["threshold"] == nil ? nil : try decimal("threshold", options: options, default: 0.025, range: 0...1)
                let maxDimension = try integer("max-dimension", options: options, default: 1_920, range: 1...16_384)
                _ = try recordingFrameRate(mode: mode, fps: fps, threshold: threshold, maxDimension: maxDimension)
                let duration: Double?
                if let text = options.values["duration"] {
                    guard let value = Double(text), value.isFinite, value > 0,
                          value <= Double(Int64.max) / 1_000_000_000 else {
                        throw CLIError.arguments("--duration 必须为有效正数，单位为秒。")
                    }
                    duration = value
                } else {
                    duration = nil
                }
                let tag = try assetTag(options)
                try AutomationAccess.check()
                try checkRecordingOutput(output)
                if let explicitRegion { try validateRecordingRegion(explicitRegion) }
                ClipatoApp.startCommandEventLoop()
                let saved = try await record(output: output, region: explicitRegion, displayID: explicitDisplay, duration: duration, fps: fps, threshold: threshold, maxDimension: maxDimension, mode: mode, tag: tag)
                try AutomationAccess.check()
                if saved {
                    stdout(output.path)
                } else {
                    stderr("录制已取消，没有写入文件。")
                }
            case "collection":
                try await runCollection(arguments: arguments, leadingLibrary: libraryPath)
            case "vault":
                var arguments = arguments
                var libraryPath = libraryPath
                try readLeadingLibrary(&arguments, into: &libraryPath)
                let subcommand = arguments.isEmpty ? "help" : arguments.removeFirst()
                if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
                    try showHelp(command)
                    return 0
                }
                guard ["list", "import", "path"].contains(subcommand) else {
                    throw CLIError.arguments("未知 vault 命令：\(subcommand)")
                }
                let options = try parse(arguments, values: ["library"], flags: subcommand == "list" ? ["json"] : [], leadingLibrary: libraryPath)
                if options.help { try showHelp(command); return 0 }
                try AutomationAccess.check()
                let root = libraryURL(options)
                if subcommand == "path" {
                    try requireNoPaths(options)
                    stdout(root.path)
                } else {
                    if subcommand == "list" { try requireNoPaths(options) }
                    if subcommand == "import", options.paths.isEmpty { throw CLIError.arguments("vault import 需要至少一个图片路径。") }
                    let library = try LibraryStore(root: root)
                    if subcommand == "import" {
                        try library.importImages(options.paths.map(fileURL))
                        if library.storagePolicy.automaticallyRemoveOldestImages { await library.refreshStorageUsage() }
                        await library.cancelStorageWorkAndWait()
                    }
                    try AutomationAccess.check()
                    if subcommand == "import" || options.flags.contains("json") {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        let images = subcommand == "import" ? Array(library.images.prefix(options.paths.count)) : library.images
                        stdout(String(decoding: try encoder.encode(images), as: UTF8.self))
                    } else {
                        for item in library.images { stdout("\(item.id.uuidString)\t\(item.filename)\t\(item.width)×\(item.height)\t\(item.source)") }
                    }
                }
            default:
                throw CLIError.arguments("未知命令：\(command)。运行 clipato help 查看用法。")
            }
            return 0
        } catch is CancellationError {
            if let access = AutomationAccess.current, !access.isAllowed {
                stderr("Clipato: \(access.denial.localizedDescription)")
                return 1
            }
            stderr("Clipato: 操作已取消。")
            return 130
        } catch let error as CLIError {
            stderr("Clipato: \(error.localizedDescription)")
            if case .arguments = error { return 2 }
            return 1
        } catch let error as MCPError {
            stderr("Clipato: \(error.localizedDescription)")
            return 2
        } catch {
            stderr("Clipato: \(error.localizedDescription)")
            return 1
        }
    }

    private struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var paths: [String] = []
        var help: Bool { flags.contains("help") }
    }

    private static func runCollection(arguments: [String], leadingLibrary: String?) async throws {
        var arguments = arguments
        var libraryPath = leadingLibrary
        try readLeadingLibrary(&arguments, into: &libraryPath)
        let command = arguments.isEmpty ? "help" : arguments.removeFirst()
        if ["help", "--help", "-h"].contains(command) {
            guard arguments.isEmpty else { throw CLIError.arguments("collection help 不接受额外参数。") }
            try showHelp("collection")
            return
        }
        guard ["list", "create", "rename", "move", "delete", "items", "add", "remove"].contains(command) else {
            throw CLIError.arguments("未知 collection 命令：\(command)")
        }
        var values: Set<String> = ["library"]
        if command == "move" { values.insert("before") }
        var flags: Set<String> = []
        if command == "list" || command == "items" { flags.insert("json") }
        let options = try parse(arguments, values: values, flags: flags, leadingLibrary: libraryPath)
        if options.help { try showHelp("collection"); return }
        let paths = options.paths
        switch command {
        case "list": try requireNoPaths(options)
        case "create", "move", "delete", "items":
            guard paths.count == 1 else { throw CLIError.arguments("collection \(command) 需要一个\(command == "create" ? "名称" : "收藏夹 UUID")。") }
        case "rename":
            guard paths.count == 2 else { throw CLIError.arguments("collection rename 需要收藏夹 UUID 和新名称。") }
        case "add", "remove":
            guard paths.count >= 2 else { throw CLIError.arguments("collection \(command) 需要收藏夹 UUID 和至少一个 image:UUID、session:UUID 或 video:PATH。") }
        default: break
        }
        func identifier(_ value: String) throws -> UUID {
            guard let id = UUID(uuidString: value) else { throw CLIError.arguments("无效 UUID：\(value)") }
            return id
        }
        let id = command == "list" || command == "create" ? nil : try identifier(paths[0])
        let before = try options.values["before"].map(identifier)
        var assets: Set<CollectionAsset> = []
        if command == "add" || command == "remove" {
            for token in paths.dropFirst() {
                let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty else {
                    throw CLIError.arguments("内容引用必须为 image:UUID、session:UUID 或 video:PATH：\(token)")
                }
                switch parts[0] {
                case "image": assets.insert(.image(try identifier(String(parts[1]))))
                case "session": assets.insert(.session(try identifier(String(parts[1]))))
                case "video": assets.insert(.video(fileURL(String(parts[1]))))
                default: throw CLIError.arguments("未知内容类型：\(parts[0])")
                }
            }
        }
        try AutomationAccess.check()
        let library = try LibraryStore(root: libraryURL(options))
        do {
            try AutomationAccess.check()
            switch command {
            case "list":
                if options.flags.contains("json") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try AutomationAccess.check()
                    stdout(String(decoding: try encoder.encode(library.collections), as: UTF8.self))
                } else {
                    for item in library.collections {
                        try AutomationAccess.check()
                        stdout("\(item.id.uuidString)\t\(item.parentID?.uuidString ?? "-")\t\(item.position)\t\(item.name)")
                    }
                }
            case "create":
                let id = try library.createCollection(name: paths[0]).id
                try AutomationAccess.check()
                stdout(id.uuidString)
            case "rename": try library.renameCollection(id!, name: paths[1])
            case "move": try library.moveCollection(id!, toParent: nil, before: before)
            case "delete": try library.deleteCollection(id!)
            case "items":
                guard library.collections.contains(where: { $0.id == id! }) else { throw CollectionError.missingCollection }
                let items = library.assets(in: id!)
                    .sorted { collectionAssetToken($0) < collectionAssetToken($1) }
                if options.flags.contains("json") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try AutomationAccess.check()
                    stdout(String(decoding: try encoder.encode(items), as: UTF8.self))
                } else {
                    for item in items {
                        try AutomationAccess.check()
                        stdout(collectionAssetToken(item))
                    }
                }
            case "add": try library.addToCollection(id!, assets: assets)
            case "remove": try library.removeFromCollection(id!, assets: assets)
            default: break
            }
        } catch {
            await library.cancelStorageWorkAndWait()
            throw error
        }
        await library.cancelStorageWorkAndWait()
        try AutomationAccess.check()
    }

    private static func collectionAssetToken(_ asset: CollectionAsset) -> String {
        switch asset {
        case .image(let id): return "image:\(id.uuidString)"
        case .session(let id): return "session:\(id.uuidString)"
        case .video(let url): return "video:\(url.path)"
        }
    }

    private static func parse(_ arguments: [String], values: Set<String>, flags: Set<String>, leadingLibrary: String?) throws -> Options {
        var result = Options()
        result.values["library"] = leadingLibrary
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { result.paths += arguments.dropFirst(index + 1); break }
            if argument == "--help" || argument == "-h" { result.flags.insert("help"); index += 1; continue }
            if argument.hasPrefix("--") {
                let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                guard result.values[name] == nil, !result.flags.contains(name) else {
                    throw CLIError.arguments("参数 --\(name) 重复。")
                }
                if values.contains(name) {
                    let value: String
                    if parts.count == 2 {
                        value = String(parts[1])
                    } else {
                        index += 1
                        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                            throw CLIError.arguments("--\(name) 缺少参数值。")
                        }
                        value = arguments[index]
                    }
                    guard !value.isEmpty else { throw CLIError.arguments("--\(name) 的参数值不能为空。") }
                    result.values[name] = value
                } else if flags.contains(name), parts.count == 1 {
                    result.flags.insert(name)
                } else {
                    throw CLIError.arguments("未知参数：\(argument)")
                }
            } else if argument.hasPrefix("-") {
                throw CLIError.arguments("未知参数：\(argument)。以 - 开头的路径请放在 -- 后面。")
            } else {
                result.paths.append(argument)
            }
            index += 1
        }
        return result
    }

    private static func readLeadingLibrary(_ arguments: inout [String], into library: inout String?) throws {
        while let first = arguments.first, first == "--library" || first.hasPrefix("--library=") {
            guard library == nil else { throw CLIError.arguments("参数 --library 重复。") }
            arguments.removeFirst()
            if first == "--library" {
                guard let path = arguments.first, !path.isEmpty, !path.hasPrefix("--") else {
                    throw CLIError.arguments("--library 缺少目录路径。")
                }
                library = arguments.removeFirst()
            } else {
                let path = String(first.dropFirst("--library=".count))
                guard !path.isEmpty else { throw CLIError.arguments("--library 缺少目录路径。") }
                library = path
            }
        }
    }

    private static func libraryURL(_ options: Options) -> URL {
        if let path = options.values["library"] { return fileURL(path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameVault")
    }

    private static func fileURL(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

    private static func requireNoPaths(_ options: Options) throws {
        guard options.paths.isEmpty else { throw CLIError.arguments("此命令不接受额外路径：\(options.paths.joined(separator: " "))") }
    }

    private static func writeJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        stdout(String(decoding: data, as: UTF8.self))
    }

    private static func outputURL(_ options: Options, png: Bool = true) throws -> URL {
        guard let path = options.values["output"] else { throw CLIError.arguments("缺少 --output。") }
        let url = fileURL(path)
        if png, url.pathExtension.lowercased() != "png" { throw CLIError.arguments("--output 必须使用 .png 扩展名。") }
        return url
    }

    private static func assetTag(_ options: Options) throws -> AssetTag? {
        guard let rawValue = options.values["tag"], rawValue != "none" else { return nil }
        guard let tag = AssetTag(rawValue: rawValue) else {
            throw CLIError.arguments("--tag 必须为 red、orange、yellow、green、blue、purple、gray 或 none。")
        }
        return tag
    }

    private static func displayID(_ options: Options) throws -> CGDirectDisplayID? {
        guard let value = options.values["display"] else { return nil }
        guard let id = UInt32(value), id > 0 else { throw CLIError.arguments("--display 必须为 displays 返回的有效屏幕 ID。") }
        return id
    }

    private static func recordingRegion(_ options: Options, displayID: CGDirectDisplayID?) throws -> RecordingRegion? {
        guard let text = options.values["rect"] else { return nil }
        guard !options.flags.contains("region") else {
            throw CLIError.arguments("--rect 不能与 --region 同时使用。")
        }
        guard let displayID else { throw CLIError.arguments("--rect 必须同时使用 --display 指定屏幕。") }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw CLIError.arguments("--rect 必须为 x,y,width,height，单位是所选屏幕左上角起算的逻辑 point。") }
        let values = try parts.map { part -> Double in
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)), value.isFinite else {
                throw CLIError.arguments("--rect 的四个坐标必须是有限数值。")
            }
            return value
        }
        guard values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0,
              (values[0] + values[2]).isFinite, (values[1] + values[3]).isFinite else {
            throw CLIError.arguments("--rect 的 x、y 必须非负，width、height 必须大于零，且区域必须位于屏幕内。")
        }
        return RecordingRegion(displayID: displayID, rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
    }

    private static func validateRecordingRegion(_ region: RecordingRegion) throws {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value == region.displayID
        }) else {
            throw CLIError.operation("屏幕 \(region.displayID) 不可用，请运行 displays 查看屏幕列表。")
        }
        do { try region.validate(displayID: region.displayID, displaySize: screen.frame.size) }
        catch { throw CLIError.arguments(error.localizedDescription) }
    }

    private static func integer(_ name: String, options: Options, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        let text = options.values[name] ?? String(defaultValue)
        guard let value = Int(text), range.contains(value) else {
            throw CLIError.arguments("--\(name) 必须为 \(range.lowerBound)...\(range.upperBound) 之间的整数。")
        }
        return value
    }

    private static func decimal(_ name: String, options: Options, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
        let text = options.values[name] ?? String(defaultValue)
        guard let value = Double(text), value.isFinite, range.contains(value) else {
            throw CLIError.arguments("--\(name) 必须为 \(range.lowerBound)...\(range.upperBound) 之间的数值。")
        }
        return value
    }

    nonisolated static func checkOutput(_ url: URL, overwrite: Bool) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) {
            guard !directory.boolValue else { throw CLIError.operation("输出路径是目录：\(url.path)") }
            guard overwrite else { throw CLIError.operation("输出文件已存在：\(url.path)。显式传入 --overwrite 才可覆盖。") }
        }
    }

    nonisolated static func writeOutput(_ image: CGImage, to output: URL, overwrite: Bool) throws {
        try AutomationAccess.check()
        try checkOutput(output, overwrite: overwrite)
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".Clipato-\(UUID().uuidString).png")
        do {
            try LibraryStore.writePNG(image, to: temporary)
            try AutomationAccess.check()
            // 先检查存在仍有进程间竞态；禁止覆盖必须由一次文件系统操作保证。
            let result = overwrite
                ? Darwin.rename(temporary.path, output.path)
                : renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL))
            guard result == 0 else {
                let code = errno
                if !overwrite, code == EEXIST {
                    throw CLIError.operation("输出文件已存在：\(output.path)。显式传入 --overwrite 才可覆盖。")
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: output.path])
            }
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }

    nonisolated static func checkRecordingOutput(_ output: URL) throws {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: output.path, isDirectory: &directory) {
            guard directory.boolValue, try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
                throw CLIError.operation("录制输出必须为不存在或为空的目录：\(output.path)")
            }
        }
    }

    private static func withExportSignals<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let oldInterrupt = signal(SIGINT, SIG_IGN)
        let oldTerminate = signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler { task.cancel() }
        terminate.setEventHandler { task.cancel() }
        interrupt.resume()
        terminate.resume()
        defer {
            interrupt.cancel()
            terminate.cancel()
            signal(SIGINT, oldInterrupt)
            signal(SIGTERM, oldTerminate)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func recordingFrameRate(mode: RecordingMode, fps: Int?, threshold: Double?, maxDimension: Int) throws -> Int {
        let frameRate = fps ?? mode.defaultFrameRate
        guard mode.frameRates.contains(frameRate) else {
            throw CLIError.arguments("\(mode.title)的 --fps 必须为 \(mode.frameRates.map(String.init).joined(separator: "、"))。")
        }
        guard mode == .keyframes || threshold == nil else {
            throw CLIError.arguments("--threshold 仅适用于 keyframes 模式。")
        }
        guard mode.maximumDimensionRange.contains(maxDimension) else {
            throw CLIError.arguments("\(mode.title)的 --max-dimension 必须在 \(mode.maximumDimensionRange.lowerBound)...\(mode.maximumDimensionRange.upperBound) 之间。")
        }
        return frameRate
    }

    private static func record(output: URL, region: RecordingRegion?, displayID: CGDirectDisplayID?, duration: Double?, fps: Int?, threshold: Double?, maxDimension: Int, mode: RecordingMode, tag: AssetTag?) async throws -> Bool {
        let recorder = KeyframeRecorder()
        let screenshots = ScreenshotController()
        let overlay = RecordingRegionOverlay()
        var recordingTag = tag
        overlay.onTagChange = { recordingTag = $0 }
        var continuation: CheckedContinuation<Void, Never>?
        var stopRequested = false
        var failure: Error?
        var pauseTask: Task<Void, Never>?
        var pauseRequestID = 0
        let requestStop: @MainActor @Sendable () -> Void = {
            stopRequested = true
            overlay.setStopping()
            screenshots.cancelSelection()
            continuation?.resume()
            continuation = nil
        }
        let requestPause: (Bool) -> Void = { paused in
            guard recorder.isRecording, !stopRequested else { return }
            pauseRequestID += 1
            let requestID = pauseRequestID
            let previous = pauseTask
            overlay.setPauseTransition(true)
            pauseTask = Task { @MainActor in
                await previous?.value
                defer {
                    if requestID == pauseRequestID && !stopRequested { overlay.setPauseTransition(false) }
                }
                guard !stopRequested, recorder.isRecording else { return }
                do {
                    try await recorder.setPaused(paused)
                    if !stopRequested, recorder.isRecording { stderr(paused ? "录屏已暂停。" : "已继续录屏。") }
                } catch {
                    failure = error
                    requestStop()
                }
            }
        }
        overlay.onStop = requestStop
        overlay.onPause = { requestPause(!recorder.isPaused) }
        let metrics = recorder.$elapsed.combineLatest(recorder.$frameCount, recorder.$isPaused).sink { elapsed, count, paused in
            overlay.update(elapsed: elapsed, frameCount: count, isPaused: paused)
            if let duration, elapsed >= duration, !stopRequested { requestStop() }
        }
        let oldInterrupt = signal(SIGINT, SIG_IGN)
        let oldTerminate = signal(SIGTERM, SIG_IGN)
        let oldPause = signal(SIGUSR1, SIG_IGN)
        let oldResume = signal(SIGUSR2, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let pause = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        let resume = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        interrupt.setEventHandler { requestStop() }
        terminate.setEventHandler { requestStop() }
        pause.setEventHandler { requestPause(true) }
        resume.setEventHandler { requestPause(false) }
        interrupt.resume()
        terminate.resume()
        pause.resume()
        resume.resume()
        defer {
            interrupt.cancel()
            terminate.cancel()
            pause.cancel()
            resume.cancel()
            signal(SIGINT, oldInterrupt)
            signal(SIGTERM, oldTerminate)
            signal(SIGUSR1, oldPause)
            signal(SIGUSR2, oldResume)
            metrics.cancel()
            overlay.onStop = nil
            overlay.onPause = nil
            overlay.hide()
        }
        return try await withTaskCancellationHandler {
            try AutomationAccess.check()
            let recordingRegion: RecordingRegion
            let recordingMode: RecordingMode
            if let region {
                recordingRegion = region
                recordingMode = mode
            } else {
                stderr("请拖动框选录制区域，Esc 或 Ctrl+C 取消。")
                do {
                    guard let selected = try await screenshots.selectRecordingRegion(displayID: displayID, mode: mode, tag: recordingTag), !stopRequested else { return false }
                    recordingRegion = selected.region
                    recordingMode = selected.mode
                    recordingTag = selected.tag
                } catch {
                    if stopRequested { return false }
                    throw error
                }
            }
            try AutomationAccess.check()
            guard !stopRequested else { return false }
            let frameRate = try recordingFrameRate(mode: recordingMode, fps: fps, threshold: threshold, maxDimension: maxDimension)
            let displays: [SCDisplay]
            do { displays = try await recorder.availableDisplays() }
            catch {
                if stopRequested { return false }
                throw error
            }
            try AutomationAccess.check()
            guard !stopRequested else { return false }
            guard let display = displays.first(where: { $0.displayID == recordingRegion.displayID }) else {
                throw CLIError.operation("屏幕 \(recordingRegion.displayID) 不可用，请运行 displays 查看屏幕列表。")
            }
            recorder.onFailure = { error in failure = error; requestStop() }
            try await recorder.start(display: display, region: recordingRegion, directory: output, sampleRate: Double(frameRate), threshold: threshold ?? 0.025, maxDimension: maxDimension, mode: recordingMode)
            do { try overlay.show(recordingRegion, mode: recordingMode, tag: recordingTag) }
            catch {
                let overlayError = error
                do { _ = try await recorder.stop() }
                catch {
                    throw CLIError.operation("显示录屏范围失败：\(overlayError.localizedDescription)；停止保存失败：\(error.localizedDescription)")
                }
                throw overlayError
            }
            let regionWidth = Double(recordingRegion.rect.width).formatted(.number.precision(.fractionLength(0...2)))
            let regionHeight = Double(recordingRegion.rect.height).formatted(.number.precision(.fractionLength(0...2)))
            stderr("正在录制 \(regionWidth) × \(regionHeight) point 区域到 \(output.path)（\(recordingMode.title)），绿框标明录制范围，按 Ctrl+C 停止并保存。")
            stderr("PID \(getpid()) · SIGUSR1 暂停 / SIGUSR2 继续；也可点击浮动条操作。暂停时间不计入 --duration。")
            if !stopRequested, !Task.isCancelled { await withCheckedContinuation { continuation = $0 } }
            overlay.setStopping()
            await pauseTask?.value
            if recorder.isRecording {
                do { _ = try await recorder.stop() }
                catch {
                    if let captureError = failure {
                        failure = CLIError.operation("\(captureError.localizedDescription)\n停止保存失败：\(error.localizedDescription)")
                    } else { failure = error }
                }
            }
            if let failure { throw failure }
            try AutomationAccess.check()
            try LibraryStore.writeRecordingTag(recordingTag, to: output)
            if recordingMode == .video {
                stderr("已保存 MP4 视频：\(output.appendingPathComponent("recording.mp4").path)，时长 \(String(format: "%.2f", recorder.elapsed)) 秒。")
            } else {
                stderr("已保存 \(recorder.frameCount) 个关键帧，时长 \(String(format: "%.2f", recorder.elapsed)) 秒。")
            }
            return true
        } onCancel: {
            Task { @MainActor in requestStop() }
        }
    }

    private static func showHelp(_ command: String?) throws {
        let common = "\n全局：--library PATH 指定保管箱目录；--help 查看帮助。\n业务命令需在控制台「AI 终端 → 自动化接入」中开启「允许外部自动化调用」；关闭后 MCP 与命令行业务调用均被禁止，进行中任务会取消。\n输出文件默认禁止覆盖，--overwrite 显式允许覆盖。"
        switch command {
        case nil:
            stdout("""
            Clipato · macOS 截图、视频 / 关键帧录屏与拼图
            用法：clipato [--library PATH] COMMAND [OPTIONS]
              displays      屏幕列表（JSON）
              permissions   当前进程的屏幕捕获权限预检与应用路径
              screenshot    截图并保存 PNG
              record        框选区域录制 MP4 或关键帧，支持 Ctrl+C 完整保存
              export        将关键帧录制导出为 MP4 / GIF 或加入保管箱
              export-images 批量导出 PNG / JPEG / PDF、ZIP 或 MP4 / GIF
              collage       网格 / 自由拼图
              stitch        重叠检测与无缝长图拼接
              vault         list / import / path
              collection    收藏夹目录与图片、录屏归类
              tools [NAME]  查看能力及原始 JSON 参数定义
              call NAME     从 JSON 文件或标准输入直接调用能力
              mcp           本地 stdio MCP 服务（在 AI 终端中开启）
              version       查看版本
              help COMMAND  查看命令用法
            无参数启动 Mac App。\(common)
            """)
        case "tools": stdout("用法：clipato tools [NAME]\n输出全部能力定义数组，或指定能力的原始 JSON 定义。此命令不执行能力，不读取保管箱，无需开启自动化访问。")
        case "call": stdout("用法：clipato call NAME --input FILE|- [--library PATH]\n从 UTF-8 JSON 文件读取参数对象；--input - 从标准输入读取，直到输入结束。运行 clipato tools NAME 查看字段、范围与默认值。直接调用本地能力，不启动 MCP 服务，结果按原字段输出 JSON。截图与录屏使用明确范围，录屏需指定 duration。批量命名前先调用 batch_rename_preview；vault_trash 仍需逐批在 Clipato 确认。Ctrl+C / SIGTERM 取消进行中的调用，录屏保存已录内容。\(common)")
        case "mcp": stdout("用法：clipato mcp [--library PATH]\n先在控制台开启「允许外部自动化调用」，再在「AI 终端 → MCP 服务」中开启「启用 MCP 服务」（默认关闭）。隐私模式开启时无法启用。客户端通过 stdio 按需启动此命令；标准输出只包含 MCP 消息。关闭 MCP 服务仅断开 MCP 会话并取消 MCP 任务，Skills 与 CLI 不受影响；关闭自动化总开关则全部停用。重新开启也不会恢复旧会话授权。支持主要功能与图像处理能力，查看 MCP 客户端的工具列表获取参数。")
        case "displays": stdout("用法：clipato displays\n输出 [{displayID, width, height}, ...] JSON。需要屏幕录制权限。\(common)")
        case "permissions": stdout("用法：clipato permissions\n只读取当前进程的屏幕捕获权限预检与应用路径，不请求权限、不读取画面。GUI 与 CLI 的启动进程可能影响权限归属。\(common)")
        case "version": stdout("用法：clipato version 或 clipato --version\n输出当前版本号与构建号。")
        case "screenshot": stdout("用法：clipato screenshot --output FILE.png [--region] [--display ID] [--rect x,y,width,height] [--vault] [--tag COLOR] [--overwrite]\n--tag 需配合 --vault；交互选区可在工具条选择标签。默认截取鼠标所在屏幕；--region 交互框选，Esc 取消；--display 指定屏幕；配合 --rect 可无交互截取固定区域，坐标为屏幕左上角起算的逻辑 point，重复执行可连续截同一区域。\(common)")
        case "record": stdout("用法：clipato record --output DIRECTORY [--mode video|keyframes] [--region] [--display ID] [--rect x,y,width,height] [--duration SECONDS] [--fps N] [--threshold 0.025] [--max-dimension 1920] [--tag COLOR]\n--tag: red/orange/yellow/green/blue/purple/gray/none；浮动条可修改。默认 keyframes 模式：1/2/4 fps（默认2），输出 PNG / manifest.json / player.html。video 模式：15/30/60 fps（默认30），输出 recording.mp4（H.264，无音频），最长边最多4096，像素宽高向下对齐偶数；--threshold 仅适用于 keyframes。\n默认交互框选，可在工具条切换关键帧视频 / 完整视频；未指定 --fps 时随所选模式使用默认帧率，显式参数不被覆盖且须符合最终模式。--display 限定选区屏幕。--rect 指定屏幕本地左上角起算的逻辑 point 坐标，必须配合 --display，不能与 --region 同用。录制期间绿框标明范围。选区时 Esc / SIGINT / SIGTERM 取消且不写文件；录制开始后 SIGINT / SIGTERM 停止并完整保存；SIGUSR1 暂停，SIGUSR2 继续，暂停时间不计入 --duration。浮动条也可暂停 / 继续 / 停止。输出目录必须不存在或为空。\(common)")
        case "stitch": stdout("用法：clipato stitch --output FILE.png [--max-overlap 10] [--min-overlap 1] [--overlaps N,N,...] [--offsets X,X,...] [--vault] [--tag COLOR] [--overwrite] IMAGE...\n支持单张图片直接输出；多张图片按输入顺序排列，并根据共同内容自动计算横向、纵向位移，支持不同裁剪尺寸与交叠，默认在0至10像素重叠内尝试拼接，以共同内容确认位置；0表示直接顺接。--max-overlap 指定容错上限，设为0直接顺接；--min-overlap 保留正重叠搜索下限。重复或范围内无可靠匹配时保留原图无重叠拼接，并在标准错误输出中提示。--overlaps 手动指定每条接缝重叠像素，负数留间隙，正数允许完整覆盖；--offsets 指定相邻图横向偏移（正数向右），可将图片分离。数量均为图片数减一，只受最终画布资源上限约束。保留原始像素；无需屏幕权限。\(common)")
        case "export": stdout("用法：clipato export SESSION_DIRECTORY --output FILE.mp4|FILE.gif [--max-dimension N] [--overwrite]\n      clipato export SESSION_DIRECTORY --vault\n--vault 按时间顺序将原始 PNG 导出到保管箱，继承录制颜色标签，保留原录制。\n读取目录内的 manifest.json 与 PNG 关键帧，按真实停留时间导出，无需屏幕权限。MP4 使用 H.264、无音频，最长边默认1920，像素宽高向下对齐偶数；GIF 无限循环、最长边默认1280，时间精度为0.01秒。最长边最多4096，不放大原图。\n保留原始录制；Ctrl+C / SIGTERM 取消导出并清理临时文件，返回130。\(common)")
        case "export-images": stdout("用法：clipato export-images IMAGE... --output PATH [--format png|jpeg|pdf|mp4|gif] [--quality 100] [--zip] [--fps 1] [--max-dimension N] [--overwrite]\n默认 PNG，输出路径为目录；JPEG 也逐图输出到目录，PDF 为单个多页文件。--zip 打包所选图片格式，输出 .zip。质量 1–100%，PNG 无损固定100%。\nMP4 / GIF 按输入顺序每张一帧，--fps 1–30（默认1），尺寸不同时等比居中补白；--max-dimension 最多4096，默认 MP4 1920 / GIF 1280。视频不接受 --zip / --quality，图片不接受 --fps / --max-dimension。\n原图保留；Ctrl+C / SIGTERM 取消并清理临时文件，返回130。\(common)")
        case "collage": stdout("用法：clipato collage --output FILE.png [--mode grid|flow] [--rows N] [--columns N] [--scale 1] [--max-width 1600] [--max-height 1200] [--spacing 12] [--overwrite] IMAGE...\n默认按图片数量计算网格行列；flow 按实际尺寸排列，columns 控制目标行宽。元素等比缩放，背景为白色。\(common)")
        case "vault": stdout("用法：clipato vault list [--json]\n      clipato vault import IMAGE...\n      clipato vault path\nimport 保留原文件名与字节，输出新增条目的原字段 JSON；list --json 输出全部图片条目。\(common)")
        case "collection": stdout("""
            用法：clipato collection list [--json]
                  clipato collection create NAME
                  clipato collection rename UUID NAME
                  clipato collection move UUID [--before UUID]
                  clipato collection delete UUID
                  clipato collection items UUID [--json]
                  clipato collection add UUID image:UUID session:UUID video:PATH ...
                  clipato collection remove UUID image:UUID session:UUID video:PATH ...
            收藏夹仅有一级。create 输出新收藏夹 UUID；list 文本列为 id、parentID（固定为 -）、position、name，JSON 保留这些原字段。
            move 只调整顺序；--before 指定前置位置，未指定则移到末尾。
            items 显示当前收藏夹；文本输出可用于 add/remove，含空格的 video:PATH 请整体加引号。
            add/remove 只改变归类，不复制文件；delete 删除当前收藏夹的归类关系，保留全部媒体。
            示例：clipato collection add COLLECTION_UUID image:IMAGE_UUID "video:/path/to/recording.mp4"\(common)
            """)
        default: throw CLIError.arguments("未知帮助主题：\(command!)")
        }
    }

    private static func stdout(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
    private static func stderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}

private enum CLIError: LocalizedError {
    case arguments(String)
    case operation(String)
    var errorDescription: String? {
        switch self {
        case .arguments(let message), .operation(let message): return message
        }
    }
}
