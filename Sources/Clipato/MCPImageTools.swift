import AVFoundation
import Darwin
import ClipatoCore
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum MCPImageTools {
    static let definitions: [[String: Any]] = {
        let files: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 4096,
                                    "description": "Absolute input file paths, in processing order. Originals are preserved."]
        let output: [String: Any] = ["type": "string", "description": "Absolute output directory. Existing files are never overwritten."]
        let format: [String: Any] = ["type": "string", "enum": ["jpeg", "png", "webp"], "default": "jpeg"]
        let quality: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 100, "default": 90]
        var renameFiles = files
        renameFiles["minItems"] = 2
        let numbering: [String: Any] = [
            "files": renameFiles,
            "prefix": ["type": "string", "default": "Frame_"],
            "start": ["type": "integer", "minimum": 0, "default": 1],
            "increment": ["type": "integer", "minimum": 1, "default": 1],
            "digits": ["type": "integer", "minimum": 0, "maximum": 19, "default": 3]
        ]
        return [
            MCPTool.define("image_compress", "Compress images to targetBytes each. Reads the first frame. Exports new files without importing them into the vault.",
                properties: ["files": files, "output": output, "format": format,
                             "targetBytes": ["type": "integer", "minimum": 1, "default": 512000],
                             "allowResizing": ["type": "boolean", "default": true]], required: ["files", "output"]),
            MCPTool.define("image_resize", "Resize every image to each specification. fit preserves aspect ratio, pad adds white margins, crop fills the requested size. Reads the first frame.",
                properties: ["files": files, "output": output, "format": format, "quality": quality,
                             "sizes": ["type": "array", "minItems": 1, "maxItems": 64, "items": [
                                "type": "object", "additionalProperties": false, "required": ["width", "height"],
                                "properties": ["width": ["type": "integer", "minimum": 1, "maximum": 32768],
                                               "height": ["type": "integer", "minimum": 1, "maximum": 32768],
                                               "mode": ["type": "string", "enum": ["fit", "pad", "crop"], "default": "fit"]]]]],
                required: ["files", "output", "sizes"]),
            MCPTool.define("image_convert", "Convert the first frame of images to JPEG, PNG or WebP. JPEG flattens transparency onto white; PNG and WebP retain it.",
                properties: ["files": files, "output": output, "format": format, "quality": quality], required: ["files", "output"]),
            MCPTool.define("image_grid", "Split one square image or an explicit square crop into four or nine tiles, ordered left to right then top to bottom. gap removes source pixels between tiles; it does not add padding.",
                properties: ["files": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 1],
                             "output": output, "format": ["type": "string", "enum": ["png", "jpeg"], "default": "png"], "quality": quality,
                             "divisions": ["type": "integer", "enum": [2, 3], "default": 3],
                             "tileSize": ["type": "integer", "minimum": 1, "maximum": 4096,
                                          "description": "Output tile width/height. When omitted, fits the source crop without upscaling, capped at 1080 px."],
                             "gap": ["type": "integer", "minimum": 0, "default": 0],
                             "crop": ["type": "object", "additionalProperties": false, "required": ["x", "y", "width", "height"],
                                      "description": "Integer square in source pixels, with a top-left origin. Required for nonsquare input.",
                                      "properties": ["x": ["type": "integer", "minimum": 0], "y": ["type": "integer", "minimum": 0],
                                                     "width": ["type": "integer", "minimum": 1], "height": ["type": "integer", "minimum": 1]]]],
                required: ["files", "output"]),
            MCPTool.define("files_find_duplicates", "Find exact duplicate files using size, header/tail samples and full SHA-256. Hard links to one file are one input. Returns groups; never deletes files.",
                properties: ["files": files], required: ["files"], readOnly: true),
            MCPTool.define("images_find_similar", "Compare image first frames, including resized/compressed copies and one image contained within another. Returns first/second/kind/score; never deletes files.",
                properties: ["files": files], required: ["files"], readOnly: true),
            MCPTool.define("batch_rename_preview", "Preview sequential filenames in supplied file order. Requires at least two images or two complete videos; mixed types and keyframe recordings are unsupported. No files are renamed.",
                properties: numbering, required: ["files"], readOnly: true),
            MCPTool.define("batch_rename", "Apply sequential filenames in supplied file order. Call batch_rename_preview first. Requires at least two images or two complete videos. Vault IDs, tags and collection membership are preserved. Does not overwrite existing files.",
                properties: numbering, required: ["files"], destructive: true)
        ]
    }()

    static func call(name: String, arguments: [String: Any], library: URL) async throws -> [String: Any] {
        try AutomationAccess.check()
        switch name {
        case "image_compress", "image_resize", "image_convert":
            return try await process(name: name, arguments: arguments)
        case "image_grid":
            return try await grid(arguments)
        case "files_find_duplicates":
            let input = try MCPInput(arguments, allowed: ["files"])
            let urls = try input.paths()
            let task = Task.detached(priority: .userInitiated) { try FileDuplicateStep.execute(urls: urls) }
            let groups = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try AutomationAccess.check()
            return ["groups": groups.map { ["urls": $0.urls.map(\.path), "fileSize": $0.fileSize, "sha256": $0.sha256] }]
        case "images_find_similar":
            let input = try MCPInput(arguments, allowed: ["files"])
            let urls = try input.paths()
            let task = Task.detached(priority: .userInitiated) { try ImageSimilarityStep.execute(urls: urls) }
            let matches = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try AutomationAccess.check()
            return ["matches": matches.map { ["first": $0.first.path, "second": $0.second.path, "kind": $0.kind.rawValue, "score": $0.score] }]
        case "batch_rename_preview", "batch_rename":
            return try await rename(arguments, library: library, apply: name == "batch_rename")
        default:
            throw MCPError.invalidArguments("Unknown image tool: \(name)")
        }
    }

    private static func process(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        var allowed: Set<String> = ["files", "output", "format"]
        if name == "image_compress" { allowed.formUnion(["targetBytes", "allowResizing"]) }
        else { allowed.insert("quality") }
        if name == "image_resize" { allowed.insert("sizes") }
        let input = try MCPInput(arguments, allowed: allowed)
        let files = try input.paths()
        let output = try input.path("output")
        let formatName = try input.string("format", default: "jpeg")
        guard let format = ImageOutputFormat(rawValue: formatName) else {
            throw MCPError.invalidArguments("format must be jpeg, png or webp.")
        }
        var processing = ImageProcessingOptions(tool: .convert)
        processing.format = format
        if name == "image_compress" {
            processing.targetBytes = try input.int("targetBytes", default: 512_000, range: 1...Int.max)
            processing.allowResizing = try input.bool("allowResizing", default: true)
        } else { processing.quality = try input.int("quality", default: 90, range: 1...100) }
        if name == "image_resize" {
            guard let sizes = arguments["sizes"] as? [[String: Any]], (1...64).contains(sizes.count) else {
                throw MCPError.invalidArguments("sizes must contain 1 to 64 width/height/mode specifications.")
            }
            processing.resizeEnabled = true
            processing.sizes = try sizes.map { values in
                let size = try MCPInput(values, allowed: ["width", "height", "mode"])
                guard values["width"] != nil, values["height"] != nil else {
                    throw MCPError.invalidArguments("Each size requires width and height.")
                }
                let modeName = try size.string("mode", default: "fit")
                guard let mode = ImageResizeOptions.Mode(rawValue: modeName) else {
                    throw MCPError.invalidArguments("mode must be fit, pad or crop.")
                }
                return ImageResizeOptions(width: try size.int("width", default: 1280, range: 1...ImageResizeStep.maximumDimension),
                                          height: try size.int("height", default: 720, range: 1...ImageResizeStep.maximumDimension), mode: mode)
            }
        }
        let names = BatchImageExporter.processedFilenames(files, options: processing)
        try AutomationAccess.check()
        try await BatchImageExporter.export(images: files, output: output, options: .init(processing: processing))
        try AutomationAccess.check()
        return ["files": names.map { output.appendingPathComponent($0).path }]
    }

    private static func grid(_ arguments: [String: Any]) async throws -> [String: Any] {
        let input = try MCPInput(arguments, allowed: ["files", "output", "format", "quality", "divisions", "tileSize", "gap", "crop"])
        let files = try input.paths(maximum: 1)
        let output = try input.path("output")
        let formatName = try input.string("format", default: "png")
        guard let format = BatchImageFormat(rawValue: formatName), format != .pdf else {
            throw MCPError.invalidArguments("Grid format must be png or jpeg.")
        }
        var crop: CGRect?
        if let values = try input.object("crop") {
            let rectangle = try MCPInput(values, allowed: ["x", "y", "width", "height"])
            guard ["x", "y", "width", "height"].allSatisfy({ values[$0] != nil }) else {
                throw MCPError.invalidArguments("crop requires x, y, width and height.")
            }
            crop = CGRect(x: try rectangle.int("x", default: 0, range: 0...ImageResizeStep.maximumDimension),
                          y: try rectangle.int("y", default: 0, range: 0...ImageResizeStep.maximumDimension),
                          width: try rectangle.int("width", default: 1, range: 1...ImageResizeStep.maximumDimension),
                          height: try rectangle.int("height", default: 1, range: 1...ImageResizeStep.maximumDimension))
        }
        var options = ImageGridOptions(divisions: try input.int("divisions", default: 3, range: 2...3),
                                       tileSize: try input.int("tileSize", default: 1, range: 1...4096),
                                       gap: try input.int("gap", default: 0, range: 0...Int.max), crop: crop)
        if arguments["tileSize"] == nil {
            let url = files[0]
            let sourceOptions = options
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    throw ImageProcessingError.unreadableImage(url)
                }
                let orientation = properties[kCGImagePropertyOrientation] as? Int
                let rotated = orientation.map { (5...8).contains($0) } == true
                let rects = try ImageGridStep.sourceRects(width: rotated ? height : width, height: rotated ? width : height,
                                                         options: sourceOptions)
                return min(1080, Int(rects[0].width))
            }
            options.tileSize = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        let quality = try input.int("quality", default: 90, range: 1...100)
        try AutomationAccess.check()
        try await BatchImageExporter.export(images: files, output: output, options: .init(imageFormat: format, quality: quality, grid: options))
        try AutomationAccess.check()
        return ["files": BatchImageExporter.gridFilenames(files[0], options: options, format: format).map { output.appendingPathComponent($0).path }]
    }

    private static func rename(_ arguments: [String: Any], library root: URL, apply: Bool) async throws -> [String: Any] {
        let input = try MCPInput(arguments, allowed: ["files", "prefix", "start", "increment", "digits"])
        let files = try input.paths(minimum: 2)
        guard Set(files).count == files.count else { throw BatchRenameError.unsupportedSelection }
        let rule = BatchRenameRule(prefix: try input.string("prefix", default: "Frame_"),
                                   start: try input.int("start", default: 1, range: 0...Int.max),
                                   increment: try input.int("increment", default: 1, range: 1...Int.max),
                                   digits: try input.int("digits", default: 3, range: 0...19))
        let library = try LibraryStore(root: root, enforceStorageQuota: false)
        do {
            let known = Dictionary(uniqueKeysWithValues: library.images.map { (library.imageURL($0).resolvingSymlinksInPath().standardizedFileURL, CollectionAsset.image($0.id)) }
                + library.videos.map { ($0.resolvingSymlinksInPath().standardizedFileURL, CollectionAsset.video($0)) })
            let assets = files.compactMap { known[$0.resolvingSymlinksInPath().standardizedFileURL] }
            let filenames: [String]
            let destinations: [URL]
            if assets.count == files.count {
                let step = BatchRenameStep(assets: assets, rule: rule)
                let preview = try step.preview(in: library)
                filenames = preview.filenames
                if apply {
                    try AutomationAccess.check()
                    let renamed = try step.execute(in: library)
                    destinations = try library.batchRenameURLs(for: renamed)
                } else { destinations = zip(preview.urls, filenames).map { $0.deletingLastPathComponent().appendingPathComponent($1) } }
            } else {
                guard assets.isEmpty else { throw BatchRenameError.unsupportedSelection }
                try validateExternalRenamePaths(files, library: library)
                await library.cancelStorageWorkAndWait()
                try AutomationAccess.check()
                let access = AutomationAccess.current
                let task = Task.detached(priority: .userInitiated) {
                    try await AutomationAccess.$current.withValue(access) {
                        var imageCount = 0
                        var videoCount = 0
                        for url in files {
                            try AutomationAccess.check()
                            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                               CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0 {
                                imageCount += 1
                            } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie),
                                      !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty {
                                videoCount += 1
                            } else { throw BatchRenameError.unsupportedSelection }
                        }
                        guard imageCount == files.count || videoCount == files.count else { throw BatchRenameError.unsupportedSelection }
                        let filenames = try rule.filenames(for: files)
                        try AutomationAccess.check()
                        let destinations = apply ? try BatchRenameStep.execute(urls: files, rule: rule)
                            : zip(files, filenames).map { $0.deletingLastPathComponent().appendingPathComponent($1) }
                        return (filenames, destinations)
                    }
                }
                (filenames, destinations) = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            }
            await library.cancelStorageWorkAndWait()
            try AutomationAccess.check()
            return ["files": files.map(\.path), "filenames": filenames, "destinations": destinations.map(\.path), "applied": apply]
        } catch {
            await library.cancelStorageWorkAndWait()
            throw error
        }
    }

    private static func validateExternalRenamePaths(_ files: [URL], library: LibraryStore) throws {
        let directories = [library.root, library.screenshotDirectory, library.recordingDirectory]
            + library.storage.recordingDirectories + library.images.compactMap(\.directory)
        let roots = Set(directories.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var linkedFiles: [stat] = []
        var identities: [dev_t: Set<ino_t>] = [:]
        for url in files {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                throw MCPError.invalidArguments("Unindexed files inside managed vault directories cannot be renamed. Supply paths of indexed vault images or complete videos.")
            }
            let values = try scannedFileValues(at: url)
            guard identities[values.st_dev, default: []].insert(values.st_ino).inserted else { throw BatchRenameError.unsupportedSelection }
            if values.st_nlink > 1 { linkedFiles.append(values) }
        }
        guard !linkedFiles.isEmpty else { return }
        for url in library.images.map(library.imageURL) + library.videos {
            var values = stat()
            guard lstat(url.path, &values) == 0 else {
                if errno == ENOENT { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            guard !linkedFiles.contains(where: { $0.st_dev == values.st_dev && $0.st_ino == values.st_ino }) else {
                throw MCPError.invalidArguments("Hard links to vault assets must be renamed through their indexed vault paths.")
            }
        }
    }
}
