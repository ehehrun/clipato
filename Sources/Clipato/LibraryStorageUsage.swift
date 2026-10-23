import Foundation

struct LibraryStorageUsage: Equatable {
    let imageBytes: Int64
    let recordingBytes: Int64
    let cacheBytes: Int64
    let logBytes: Int64
    let coreBytes: Int64
    let unavailablePaths: [String]

    var mediaBytes: Int64 { imageBytes + recordingBytes }
    var totalBytes: Int64 { mediaBytes + cacheBytes + logBytes + coreBytes }
    var isComplete: Bool { unavailablePaths.isEmpty }

    nonisolated static func scan(
        root: URL,
        images: [VaultImage],
        recordingDirectories: [URL],
        cacheDirectories: [URL],
        logDirectories: [URL] = [],
        recordingReadErrors: [String]
    ) throws -> LibraryStorageUsage {
        try Task.checkCancellation()
        var unavailable = recordingReadErrors

        func count(_ url: URL, missingIsEmpty: Bool = false) throws -> Int64 {
            try Task.checkCancellation()
            do {
                if missingIsEmpty {
                    do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]) }
                    catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                        return 0
                    }
                }
                return try AssetFileInfoLoader.byteCount(at: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unavailable.append("\(url.path)：\(error.localizedDescription)")
                return 0
            }
        }

        let imageURLs = Set(images.map { image in
            let directory = image.directory ?? root.appendingPathComponent("Images").appendingPathComponent(image.id.uuidString)
            return directory.appendingPathComponent(image.filename).standardizedFileURL.resolvingSymlinksInPath()
        })
        var imageBytes: Int64 = 0
        for url in imageURLs { imageBytes += try count(url) }

        var recordingBytes: Int64 = 0
        for directory in distinctDirectories(recordingDirectories) {
            recordingBytes += try count(directory)
        }

        var cacheBytes: Int64 = 0
        for directory in distinctDirectories(cacheDirectories) {
            cacheBytes += try count(directory, missingIsEmpty: true)
        }

        var logBytes: Int64 = 0
        for directory in distinctDirectories(logDirectories) {
            logBytes += try count(directory, missingIsEmpty: true)
        }

        var coreBytes: Int64 = 0
        // Media is already counted above; only Clipato's own root-level metadata belongs here.
        for filename in ["images.json", "storage.json", "storage-bookmarks.plist", ".images.lock", "library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(filename)
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true, let bytes = values.fileSize else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
                coreBytes += Int64(bytes)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                unavailable.append("\(url.path)：\(error.localizedDescription)")
            }
        }
        return LibraryStorageUsage(imageBytes: imageBytes, recordingBytes: recordingBytes,
                                   cacheBytes: cacheBytes, logBytes: logBytes, coreBytes: coreBytes,
                                   unavailablePaths: Array(Set(unavailable)).sorted())
    }

    private nonisolated static func distinctDirectories(_ directories: [URL]) -> [URL] {
        let paths = Set(directories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        return paths.sorted().compactMap { path in
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            var parent = directory
            while parent.path != "/" {
                parent.deleteLastPathComponent()
                if paths.contains(parent.path) { return nil }
            }
            return directory
        }
    }
}
