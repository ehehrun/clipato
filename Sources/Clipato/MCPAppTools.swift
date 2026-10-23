import AppKit
import Darwin
import ClipatoCore
import ScreenCaptureKit

@MainActor
enum MCPAppTools {
    static let definitions: [[String: Any]] = {
        let file: [String: Any] = ["type": "string", "description": "Absolute local file path."]
        let files: [String: Any] = ["type": "array", "items": file, "minItems": 1, "maxItems": 4096]
        let overwrite: [String: Any] = ["type": "boolean", "default": false]
        let display: [String: Any] = ["type": "integer", "minimum": 1, "maximum": UInt32.max, "description": "ID from displays; defaults to the main display."]
        let rect: [String: Any] = ["type": "object", "properties": ["x": number(0, 100_000), "y": number(0, 100_000), "width": number(0.01, 100_000), "height": number(0.01, 100_000)], "required": ["x", "y", "width", "height"], "additionalProperties": false, "description": "Display-local logical points, origin at top left. Requires displayID."]
        let identifier: [String: Any] = ["type": "string", "format": "uuid"]
        let assets: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 4096, "description": "References: image:UUID, session:UUID, video:/absolute/path. Multiple collections may reference the same asset."]
        return [
            MCPTool.define("permissions", "Read screen capture permission preflight and application identity; does not request permission or capture content.", properties: [:], readOnly: true),
            MCPTool.define("displays", "List available displays. Requires macOS screen recording permission.", properties: [:], readOnly: true),
            MCPTool.define("screenshot", "Capture a display or fixed rectangle to PNG without interactive selection. Optional vault explicitly saves a copy; privacy mode still prevents recent-history updates. Explicit overwrite replaces an existing output; MCP vault imports do not run automatic quota cleanup.", properties: ["output": file, "displayID": display, "rect": rect, "vault": ["type": "boolean", "default": false], "tag": tags, "overwrite": overwrite], required: ["output"], destructive: true),
            MCPTool.define("record", "Record a display or fixed rectangle for a required bounded duration. No audio or interactive selection. Cancellation stops and finalizes the recording at output. Output directory must not exist or be empty. keyframes writes PNG/manifest.json/player.html; video writes recording.mp4.", properties: ["output": file, "displayID": display, "rect": rect, "duration": number(0.01, 3600), "mode": choice(["keyframes", "video"]), "fps": ["type": "integer", "enum": [1, 2, 4, 15, 30, 60], "description": "keyframes: 1/2/4, default 2. video: 15/30/60, default 30."], "threshold": number(0, 1), "maxDimension": number(1, 16_384, integer: true), "tag": tags], required: ["output", "duration"]),
            MCPTool.define("collage", "Render images in supplied order to one PNG. grid uses rows/columns; flow packs to columns and does not accept rows. Original files remain unchanged; explicit overwrite replaces an existing output.", properties: ["files": files, "output": file, "mode": choice(["grid", "flow"]), "rows": number(1, 64, integer: true), "columns": number(1, 64, integer: true), "scale": number(0.05, 4), "maxWidth": number(1, 8192, integer: true), "maxHeight": number(1, 8192, integer: true), "spacing": number(0, 512, integer: true), "overwrite": overwrite], required: ["files", "output"], destructive: true),
            MCPTool.define("stitch", "Vertically stitch ordered images to PNG using the existing overlap detector. Uncertain or duplicate seams remain separate and are reported as warnings. Manual overlaps/offsets contain one integer per seam; negative overlaps leave gaps. Does not modify originals; explicit overwrite replaces an existing output.", properties: ["files": files.merging(["maxItems": 256]) { _, new in new }, "output": file, "minimumOverlap": number(1, 32_768, integer: true), "maximumOverlap": number(0, 32_768, integer: true), "overlaps": integerArray, "offsets": integerArray, "overwrite": overwrite], required: ["files", "output"], destructive: true),
            MCPTool.define("export_images", "Export ordered images as PNG/JPEG files into a directory, one multi-page PDF, ZIP, or MP4/GIF. PNG is lossless (quality 100); video accepts fps/maxDimension instead of quality/zip. Transactional output, originals retained. Explicit overwrite replaces existing outputs.", properties: ["files": files, "output": file, "format": choice(["png", "jpeg", "pdf", "mp4", "gif"]), "quality": number(1, 100, integer: true), "zip": ["type": "boolean"], "fps": number(1, 30, integer: true), "maxDimension": number(1, 4096, integer: true), "overwrite": overwrite], required: ["files", "output"], destructive: true),
            MCPTool.define("export_recording", "Export an existing keyframe session directory to MP4/GIF preserving frame dwell time, or explicitly import its original frames to the vault. vault cannot combine with output/maxDimension/overwrite. Originals retained. Explicit overwrite replaces an output; MCP vault imports do not run automatic quota cleanup.", properties: ["directory": file, "output": file, "vault": ["type": "boolean"], "maxDimension": number(1, 4096, integer: true), "overwrite": overwrite], required: ["directory"], destructive: true),
            MCPTool.define("vault_list", "List vault images in vault insertion order. Returns existing VaultImage fields and separate file paths.", properties: ["offset": number(0, Double(Int.max), integer: true), "limit": number(1, 1000, integer: true)], readOnly: true),
            MCPTool.define("vault_trash", "Move selected existing vault images or recordings to the macOS Trash, removing their collection references. Disabled by default in AI Terminal settings. Every batch requires a local user confirmation in Clipato; no confirmation argument or permanent-delete mode is accepted. Only existing assets from this vault may be selected.", properties: ["assets": assets], required: ["assets"], destructive: true),
            MCPTool.define("vault_import", "Explicitly import local images, preserving original filenames and bytes. Privacy mode prevents recent-history updates. Does not run automatic quota cleanup; moving existing assets to Trash requires vault_trash and local confirmation.", properties: ["files": files], required: ["files"], destructive: true),
            MCPTool.define("recordings_list", "List keyframe session metadata and video paths. offset/limit apply separately to sessions and videos; defaults 0/100. Session metadata preserves id/directory/createdAt/duration/sampleRate/threshold/width/height and adds frameCount. Full manifest with all frames is returned only when includeManifest=true. Does not capture the screen.", properties: ["offset": number(0, Double(Int.max), integer: true), "limit": number(1, 1000, integer: true), "includeManifest": ["type": "boolean", "default": false]], readOnly: true),
            MCPTool.define("collection_list", "List single-level collections using existing fields.", properties: [:], readOnly: true),
            MCPTool.define("collection_create", "Create a single-level collection. Does not copy media.", properties: ["name": ["type": "string", "minLength": 1]], required: ["name"]),
            MCPTool.define("collection_rename", "Rename one collection; media remains unchanged.", properties: ["id": identifier, "name": ["type": "string", "minLength": 1]], required: ["id", "name"]),
            MCPTool.define("collection_delete", "Delete one collection and its membership relations. All original images and recordings remain in the vault.", properties: ["id": identifier], required: ["id"], destructive: true),
            MCPTool.define("collection_items", "List collection membership using existing CollectionAsset Codable fields.", properties: ["id": identifier], required: ["id"], readOnly: true),
            MCPTool.define("collection_add", "Add existing vault images/recordings to one collection without moving or copying files. Membership in other collections is retained.", properties: ["id": identifier, "assets": assets], required: ["id", "assets"]),
            MCPTool.define("collection_remove", "Remove membership from one collection; media and other collection memberships are retained.", properties: ["id": identifier, "assets": assets], required: ["id", "assets"], destructive: true)
        ]
    }()

    static func call(name: String, arguments: [String: Any], library: URL) async throws -> [String: Any] {
        try AutomationAccess.check()
        guard let definition = definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            throw MCPError.invalidArguments("Unknown tool: \(name)")
        }
        let input = try MCPInput(arguments, allowed: Set(properties.keys))
        let missing = Set(schema["required"] as! [String]).subtracting(arguments.keys)
        guard missing.isEmpty else { throw MCPError.invalidArguments("Required arguments: \(missing.sorted().joined(separator: ", "))") }
        if arguments["overwrite"] != nil, try input.bool("overwrite"), let output = try input.optionalString("output") {
            try await protectManagedOverwrite(MCPInput.fileURL(output), library: library)
        }
        switch name {
        case "vault_trash":
            guard MCPSettings.allowsTrash() else { throw MCPTrashAuthorizationError.disabled }
            let selected = try input.strings("assets").map(asset)
            return try await withLibrary(library) { store in
                try await MCPTrashOperation.perform(assets: selected, store: store)
            }
        case "permissions":
            return ["applicationPath": Bundle.main.bundleURL.path, "bundleIdentifier": Bundle.main.bundleIdentifier as Any? ?? NSNull(), "screenCapturePreflight": CGPreflightScreenCaptureAccess()]
        case "displays":
            let displays = try await KeyframeRecorder().availableDisplays()
            try AutomationAccess.check()
            return ["displays": displays.map { ["displayID": $0.displayID, "width": $0.width, "height": $0.height] }]
        case "screenshot":
            let output = try pngOutput(input)
            let overwrite = try input.bool("overwrite")
            let vault = try input.bool("vault")
            let tag = try assetTag(input)
            guard arguments["tag"] == nil || vault else { throw MCPError.invalidArguments("tag requires vault=true.") }
            try ClipatoCLI.checkOutput(output, overwrite: overwrite)
            let displayID = try selectedDisplay(input)
            let region = try region(input, displayID: displayID)
            let screenshots = ScreenshotController()
            let image: CGImage
            try AutomationAccess.check()
            if let region { image = try await screenshots.captureFixedRegion(region, excludingWindowIDs: []) }
            else {
                guard let captured = try await screenshots.captureDisplay(displayID: displayID) else { throw MCPError.invalidArguments("No screenshot was captured.") }
                image = captured
            }
            try AutomationAccess.check()
            try await background { try ClipatoCLI.writeOutput(image, to: output, overwrite: overwrite) }
            var result: [String: Any] = ["output": output.path, "width": image.width, "height": image.height]
            if vault {
                let saved = try await withLibrary(library, enforceQuota: true) { store in
                    let item = try store.addImage(image, source: "截图", filename: output.lastPathComponent, tag: tag)
                    return ["image": try MCPTool.encode(item), "path": store.imageURL(item).path]
                }
                result.merge(saved) { _, value in value }
            }
            try AutomationAccess.check()
            return result
        case "record": return try await record(input)
        case "collage":
            let files = try input.paths()
            let output = try pngOutput(input)
            let overwrite = try input.bool("overwrite")
            try protectSources(files, output: output)
            guard let mode = CollageSettings.Mode(rawValue: try input.string("mode", default: "grid")) else { throw MCPError.invalidArguments("mode must be grid or flow.") }
            guard mode == .grid || arguments["rows"] == nil else { throw MCPError.invalidArguments("rows is only used by grid mode.") }
            let columns = try input.int("columns", default: Int(Double(files.count).squareRoot().rounded(.up)), range: 1...64)
            let settings = CollageSettings(mode: mode, columns: columns,
                rows: try input.int("rows", default: (files.count + columns - 1) / columns, range: 1...64),
                scale: try input.double("scale", default: 1, range: 0.05...4),
                maxWidth: try input.int("maxWidth", default: 1600, range: 1...8192),
                maxHeight: try input.int("maxHeight", default: 1200, range: 1...8192),
                spacing: try input.int("spacing", default: 12, range: 0...512))
            try ClipatoCLI.checkOutput(output, overwrite: overwrite)
            return try await background {
                let images = try files.map(LibraryStore.readImage)
                let image = try CollageRenderer.render(images: images, settings: settings)
                try AutomationAccess.check()
                try ClipatoCLI.writeOutput(image, to: output, overwrite: overwrite)
                return ["output": output.path, "width": image.width, "height": image.height]
            }
        case "stitch":
            let files = try input.paths(maximum: 256)
            let output = try pngOutput(input)
            let overwrite = try input.bool("overwrite")
            try protectSources(files, output: output)
            let minimum = try input.int("minimumOverlap", default: 1, range: 1...32_768)
            let maximum = try input.int("maximumOverlap", default: 10, range: 0...32_768)
            let overlaps = try integers(input, key: "overlaps", count: files.count - 1)
            let offsets = try integers(input, key: "offsets", count: files.count - 1)
            guard offsets == nil || overlaps != nil else { throw MCPError.invalidArguments("offsets requires overlaps.") }
            guard overlaps == nil || arguments["minimumOverlap"] == nil && arguments["maximumOverlap"] == nil else { throw MCPError.invalidArguments("Manual overlaps cannot combine with automatic overlap limits.") }
            guard maximum == 0 || minimum <= maximum else { throw MCPError.invalidArguments("minimumOverlap must not exceed maximumOverlap.") }
            try ClipatoCLI.checkOutput(output, overwrite: overwrite)
            return try await background {
                let images = try files.map(LibraryStore.readImage)
                var joins: [LongScreenshotJoin] = []
                var warnings: [String] = []
                for index in 0..<(images.count - 1) {
                    try AutomationAccess.check()
                    if let overlaps { joins.append(LongScreenshotJoin(overlap: overlaps[index], offsetX: offsets?[index] ?? 0)) }
                    else if maximum == 0 { joins.append(LongScreenshotJoin(overlap: 0)) }
                    else {
                        switch try LongScreenshot.analyze(previous: images[index], next: images[index + 1], minimumOverlap: minimum, maximumOverlap: maximum) {
                        case .matched(let join): joins.append(join)
                        case .duplicate:
                            joins.append(LongScreenshotJoin(overlap: 0))
                            warnings.append("Seam \(index + 1): duplicate images retained separately.")
                        case .noReliableMatch:
                            joins.append(LongScreenshotJoin(overlap: 0))
                            warnings.append("Seam \(index + 1): no reliable match; images retained without overlap.")
                        }
                    }
                }
                let image = try LongScreenshot.render(images: images, joins: joins)
                try AutomationAccess.check()
                try ClipatoCLI.writeOutput(image, to: output, overwrite: overwrite)
                return ["output": output.path, "width": image.width, "height": image.height, "warnings": warnings]
            }
        case "export_images":
            let files = try input.paths()
            let output = try input.path("output")
            let format = try input.string("format", default: "png")
            var options = BatchExportOptions()
            if let videoFormat = KeyframeExportFormat(rawValue: format) {
                guard arguments["zip"] == nil, arguments["quality"] == nil else { throw MCPError.invalidArguments("Video export does not accept zip or quality.") }
                options.mode = .video
                options.videoFormat = videoFormat
                options.fps = try input.int("fps", default: 1, range: 1...30)
                options.maxDimension = try input.int("maxDimension", default: videoFormat.defaultMaxDimension, range: (videoFormat == .mp4 ? 2 : 1)...4096)
                try requireExtension(output, format)
            } else if let imageFormat = BatchImageFormat(rawValue: format) {
                guard arguments["fps"] == nil, arguments["maxDimension"] == nil else { throw MCPError.invalidArguments("fps and maxDimension only apply to video export.") }
                options.mode = try input.bool("zip") ? .zip : .files
                options.imageFormat = imageFormat
                options.quality = try input.int("quality", default: 100, range: 1...100)
                guard imageFormat != .png || options.quality == 100 else { throw MCPError.invalidArguments("PNG is lossless; quality must be 100.") }
                if options.mode == .zip { try requireExtension(output, "zip") }
                else if imageFormat == .pdf { try requireExtension(output, "pdf") }
            } else { throw MCPError.invalidArguments("format must be png, jpeg, pdf, mp4 or gif.") }
            try await BatchImageExporter.export(images: files, output: output, options: options, overwrite: input.bool("overwrite"))
            try AutomationAccess.check()
            return ["output": output.path]
        case "export_recording":
            let directory = try input.path("directory")
            if try input.bool("vault") {
                guard arguments["output"] == nil, arguments["maxDimension"] == nil, arguments["overwrite"] == nil else { throw MCPError.invalidArguments("vault cannot combine with output, maxDimension or overwrite.") }
                let manifest = try readManifest(directory)
                return try await withLibrary(library, enforceQuota: true) { store in
                    let count = try await store.importKeyframes(SavedSession(id: manifest.id, directory: directory, manifest: manifest))
                    return ["count": count]
                }
            }
            let output = try input.path("output")
            guard let format = KeyframeExportFormat(rawValue: output.pathExtension.lowercased()) else { throw MCPError.invalidArguments("output must end in .mp4 or .gif.") }
            let dimension = try input.int("maxDimension", default: format.defaultMaxDimension, range: (format == .mp4 ? 2 : 1)...4096)
            try await KeyframeExporter.export(directory: directory, output: output, format: format, maxDimension: dimension, overwrite: input.bool("overwrite"))
            try AutomationAccess.check()
            return ["output": output.path]
        case "vault_list":
            let offset = try input.int("offset", default: 0, range: 0...Int.max)
            let limit = try input.int("limit", default: 100, range: 1...1000)
            return try await withLibrary(library) { store in
                let images = Array(store.images.dropFirst(offset).prefix(limit))
                return ["images": try MCPTool.encode(images), "paths": images.map { store.imageURL($0).path }, "total": store.images.count]
            }
        case "vault_import":
            let files = try input.paths()
            return try await withLibrary(library, enforceQuota: true) { store in
                let before = Set(store.images.map(\.id))
                try store.importImages(files)
                let images = store.images.filter { !before.contains($0.id) }
                return ["images": try MCPTool.encode(images), "paths": images.map { store.imageURL($0).path }]
            }
        case "recordings_list":
            let offset = try input.int("offset", default: 0, range: 0...Int.max)
            let limit = try input.int("limit", default: 100, range: 1...1000)
            let includeManifest = try input.bool("includeManifest")
            return try await withLibrary(library) { store in
                let sessions = try store.sessions.dropFirst(offset).prefix(limit).map { session -> [String: Any] in
                    let manifest = session.manifest
                    var result: [String: Any] = ["id": session.id.uuidString, "directory": session.directory.path,
                        "createdAt": try MCPTool.encode(manifest.createdAt), "duration": manifest.duration,
                        "sampleRate": manifest.sampleRate, "threshold": manifest.threshold, "width": manifest.width,
                        "height": manifest.height, "frameCount": manifest.frames.count]
                    if let name = manifest.name { result["name"] = name }
                    if includeManifest { result["manifest"] = try MCPTool.encode(manifest) }
                    return result
                }
                return ["sessions": sessions, "videos": store.videos.dropFirst(offset).prefix(limit).map(\.path),
                    "totalSessions": store.sessions.count, "totalVideos": store.videos.count, "recordingReadErrors": store.recordingReadErrors]
            }
        default: return try await collection(name: name, input: input, root: library)
        }
    }

    private static func collection(name: String, input: MCPInput, root: URL) async throws -> [String: Any] {
        let id = name == "collection_list" || name == "collection_create" ? nil : try identifier(input.string("id"))
        let assets = name == "collection_add" || name == "collection_remove" ? try Set(input.strings("assets").map(asset)) : []
        return try await withLibrary(root) { store in
            switch name {
            case "collection_list": return ["collections": try MCPTool.encode(store.collections)]
            case "collection_create": return ["collection": try MCPTool.encode(store.createCollection(name: input.string("name")))]
            case "collection_rename": try store.renameCollection(id!, name: input.string("name"))
            case "collection_delete": try store.deleteCollection(id!)
            case "collection_items":
                guard store.collections.contains(where: { $0.id == id! }) else { throw CollectionError.missingCollection }
                return ["assets": try MCPTool.encode(store.assets(in: id!).sorted { token($0) < token($1) })]
            case "collection_add": try store.addToCollection(id!, assets: assets)
            case "collection_remove": try store.removeFromCollection(id!, assets: assets)
            default: throw MCPError.invalidArguments("Unknown tool: \(name)")
            }
            return ["collections": try MCPTool.encode(store.collections)]
        }
    }

    private static func record(_ input: MCPInput) async throws -> [String: Any] {
        let output = try input.path("output")
        let duration = try input.double("duration", default: .nan, range: 0.01...3600)
        guard let mode = RecordingMode(rawValue: try input.string("mode", default: "keyframes")) else { throw MCPError.invalidArguments("mode must be keyframes or video.") }
        let fps = input.values["fps"] == nil ? nil : try input.int("fps", default: mode.defaultFrameRate, range: 1...60)
        let threshold = input.values["threshold"] == nil ? nil : try input.double("threshold", default: 0.025, range: 0...1)
        let maximum = try input.int("maxDimension", default: 1920, range: 1...16_384)
        let frameRate = try ClipatoCLI.recordingFrameRate(mode: mode, fps: fps, threshold: threshold, maxDimension: maximum)
        let tag = try assetTag(input)
        try ClipatoCLI.checkRecordingOutput(output)
        let displayID = try selectedDisplay(input)
        let suppliedRegion = try region(input, displayID: displayID)
        let recorder = KeyframeRecorder()
        let displays = try await recorder.availableDisplays()
        guard let display = displays.first(where: { $0.displayID == displayID }) else { throw MCPError.invalidArguments("Display \(displayID) is unavailable.") }
        let region = suppliedRegion ?? RecordingRegion(displayID: displayID, rect: CGRect(x: 0, y: 0, width: display.width, height: display.height))
        try region.validate(displayID: displayID, displaySize: CGSize(width: display.width, height: display.height))
        try AutomationAccess.check()
        try await recorder.start(display: display, region: region, directory: output, sampleRate: Double(frameRate), threshold: threshold ?? 0.025, maxDimension: maximum, mode: mode)
        let delay = Task { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
        var failure: Error?
        recorder.onFailure = { error in failure = error; delay.cancel() }
        defer { recorder.onFailure = nil }
        do {
            try AutomationAccess.check()
            try await withTaskCancellationHandler { try await delay.value } onCancel: { delay.cancel() }
            try AutomationAccess.check()
        } catch {
            delay.cancel()
            let cause = failure ?? error
            do {
                if recorder.isRecording { _ = try await recorder.stop() }
                try LibraryStore.writeRecordingTag(tag, to: output)
            } catch { throw KeyframeRecordingError.multipleFailures(cause, error) }
            throw cause
        }
        _ = try await recorder.stop()
        try LibraryStore.writeRecordingTag(tag, to: output)
        try AutomationAccess.check()
        if mode == .video { return ["output": output.path, "video": output.appendingPathComponent("recording.mp4").path, "duration": recorder.elapsed] }
        return ["output": output.path, "manifest": try MCPTool.encode(readManifest(output))]
    }

    private static func withLibrary(_ root: URL, enforceQuota: Bool = false, operation: (LibraryStore) async throws -> [String: Any]) async throws -> [String: Any] {
        try AutomationAccess.check()
        let store = try LibraryStore(root: root, enforceStorageQuota: false)
        await store.cancelStorageWorkAndWait()
        do {
            try AutomationAccess.check()
            let result = try await operation(store)
            try AutomationAccess.check()
            if enforceQuota { await store.refreshStorageUsage(enforceQuota: false) }
            await store.cancelStorageWorkAndWait()
            try AutomationAccess.check()
            return result
        } catch {
            await store.cancelStorageWorkAndWait()
            throw error
        }
    }

    private static func protectManagedOverwrite(_ output: URL, library root: URL) async throws {
        let destination = output.resolvingSymlinksInPath().standardizedFileURL
        let path = destination.pathComponents
        func overlaps(_ directory: URL) -> Bool {
            let components = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return path.starts(with: components) || components.starts(with: path)
        }
        func denied() -> MCPError {
            .invalidArguments("MCP output cannot overwrite vault files or directories containing vault data. Export elsewhere; use vault_trash with local confirmation to remove existing assets.")
        }
        guard !overlaps(root) else { throw denied() }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path) else { return }
        let store = try LibraryStore(root: root, enforceStorageQuota: false)
        await store.cancelStorageWorkAndWait()
        try AutomationAccess.check()
        let directories = [store.screenshotDirectory, store.recordingDirectory] + store.storage.recordingDirectories
            + store.images.compactMap(\.directory)
        guard !directories.contains(where: overlaps) else { throw denied() }
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        var target = stat()
        guard lstat(destination.path, &target) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if target.st_mode & S_IFMT == S_IFREG, target.st_nlink > 1 {
            let sources = store.images.map(store.imageURL) + store.videos
                + store.sessions.map { $0.directory.appendingPathComponent("manifest.json") }
            for source in sources {
                var original = stat()
                guard lstat(source.path, &original) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
                }
                guard target.st_dev != original.st_dev || target.st_ino != original.st_ino else { throw denied() }
            }
        }
    }

    private static func background<T>(_ operation: @escaping () throws -> T) async throws -> T {
        let access = AutomationAccess.current
        let worker = Task.detached(priority: .userInitiated) {
            try AutomationAccess.$current.withValue(access) {
                try AutomationAccess.check()
                let result = try operation()
                try AutomationAccess.check()
                return result
            }
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try AutomationAccess.check()
        return result
    }

    private static func selectedDisplay(_ input: MCPInput) throws -> CGDirectDisplayID {
        CGDirectDisplayID(try input.int("displayID", default: Int(CGMainDisplayID()), range: 1...Int(UInt32.max)))
    }

    private static func region(_ input: MCPInput, displayID: CGDirectDisplayID) throws -> RecordingRegion? {
        guard let object = try input.object("rect") else { return nil }
        guard input.values["displayID"] != nil else { throw MCPError.invalidArguments("rect requires displayID.") }
        let rect = try MCPInput(object, allowed: ["x", "y", "width", "height"])
        guard Set(object.keys) == ["x", "y", "width", "height"] else { throw MCPError.invalidArguments("rect requires x, y, width and height.") }
        let x = try rect.double("x", default: .nan, range: 0...100_000)
        let y = try rect.double("y", default: .nan, range: 0...100_000)
        let width = try rect.double("width", default: .nan, range: 0.01...100_000)
        let height = try rect.double("height", default: .nan, range: 0.01...100_000)
        return RecordingRegion(displayID: displayID, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    private static func pngOutput(_ input: MCPInput) throws -> URL {
        let url = try input.path("output")
        try requireExtension(url, "png")
        return url
    }

    private static func requireExtension(_ url: URL, _ extensionName: String) throws {
        guard url.pathExtension.lowercased() == extensionName else { throw MCPError.invalidArguments("output must end in .\(extensionName).") }
    }

    private static func protectSources(_ sources: [URL], output: URL) throws {
        let destination = output.resolvingSymlinksInPath()
        guard !sources.contains(where: { $0.resolvingSymlinksInPath() == destination }) else {
            throw MCPError.invalidArguments("output cannot replace a source image.")
        }
    }

    private static func assetTag(_ input: MCPInput) throws -> AssetTag? {
        guard let value = try input.optionalString("tag"), value != "none" else { return nil }
        guard let tag = AssetTag(rawValue: value) else { throw MCPError.invalidArguments("Unknown asset tag: \(value)") }
        return tag
    }

    private static func readManifest(_ directory: URL) throws -> KeyframeManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KeyframeManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    private static func identifier(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw MCPError.invalidArguments("Invalid UUID: \(text)") }
        return id
    }

    private static func asset(_ text: String) throws -> CollectionAsset {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw MCPError.invalidArguments("Asset must be image:UUID, session:UUID or video:/absolute/path.") }
        switch parts[0] {
        case "image": return .image(try identifier(String(parts[1])))
        case "session": return .session(try identifier(String(parts[1])))
        case "video": return .video(try MCPInput.fileURL(String(parts[1])))
        default: throw MCPError.invalidArguments("Unknown asset type: \(parts[0])")
        }
    }

    private static func token(_ asset: CollectionAsset) -> String {
        switch asset {
        case .image(let id): return "image:\(id.uuidString)"
        case .session(let id): return "session:\(id.uuidString)"
        case .video(let url): return "video:\(url.path)"
        }
    }

    private static func integers(_ input: MCPInput, key: String, count: Int) throws -> [Int]? {
        guard let value = input.values[key] else { return nil }
        guard let values = value as? [Any], values.count == count else { throw MCPError.invalidArguments("\(key) must contain \(count) integers, one per seam.") }
        return try values.map { try MCPInput(["value": $0], allowed: ["value"]).int("value", default: 0, range: -32_768...32_768) }
    }

    private static func number(_ minimum: Double, _ maximum: Double, integer: Bool = false) -> [String: Any] {
        ["type": integer ? "integer" : "number", "minimum": minimum, "maximum": maximum]
    }

    private static func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private static var tags: [String: Any] { choice(["red", "orange", "yellow", "green", "blue", "purple", "gray", "none"]) }
    private static var integerArray: [String: Any] { ["type": "array", "items": number(-32_768, 32_768, integer: true), "maxItems": 255] }
}
