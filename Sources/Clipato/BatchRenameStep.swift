import Darwin
import Foundation

struct BatchRenameStep {
    let assets: [CollectionAsset]
    let rule: BatchRenameRule

    @MainActor
    func preview(in library: LibraryStore) throws -> (urls: [URL], filenames: [String]) {
        let urls = try library.batchRenameURLs(for: assets)
        return (urls, try rule.filenames(for: urls))
    }

    @MainActor
    func execute(in library: LibraryStore) throws -> [CollectionAsset] {
        try library.batchRename(assets, rule: rule)
    }

    static func execute(urls sources: [URL], rule: BatchRenameRule) throws -> [URL] {
        guard sources.count >= 2, sources.allSatisfy(\.isFileURL) else {
            throw BatchRenameError.unsupportedSelection
        }
        let filenames = try rule.filenames(for: sources)
        let destinations = zip(sources, filenames).map { $0.deletingLastPathComponent().appendingPathComponent($1) }
        var sourceInfo: [dev_t: Set<ino_t>] = [:]
        for source in sources {
            var info = stat()
            guard lstat(source.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw BatchRenameError.unsupportedSelection }
            guard sourceInfo[info.st_dev, default: []].insert(info.st_ino).inserted else {
                throw BatchRenameError.unsupportedSelection
            }
        }
        for destination in destinations {
            var info = stat()
            if lstat(destination.path, &info) == 0 {
                guard sourceInfo[info.st_dev]?.contains(info.st_ino) == true else {
                    throw BatchRenameError.existingFile(destination)
                }
            } else if errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
        let changed = sources.indices.filter { sources[$0] != destinations[$0] }
        let temporary = sources.map { $0.deletingLastPathComponent().appendingPathComponent(".clipato-rename-\(UUID().uuidString)") }
        var locations = sources
        func move(_ source: URL, to destination: URL) throws {
            let result = source.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
        do {
            // Stage sources together so a destination can be another selected file's original name.
            for index in changed {
                try AutomationAccess.check()
                try move(sources[index], to: temporary[index])
                locations[index] = temporary[index]
            }
            for index in changed {
                try AutomationAccess.check()
                try move(temporary[index], to: destinations[index])
                locations[index] = destinations[index]
            }
            try AutomationAccess.check()
        } catch {
            var failure = error
            for index in changed.reversed() where locations[index] != sources[index] && locations[index] != temporary[index] {
                do {
                    try move(locations[index], to: temporary[index])
                    locations[index] = temporary[index]
                } catch { failure = KeyframeRecordingError.multipleFailures(failure, error) }
            }
            for index in changed.reversed() where locations[index] != sources[index] {
                do { try move(locations[index], to: sources[index]) }
                catch { failure = KeyframeRecordingError.multipleFailures(failure, error) }
            }
            throw failure
        }
        return destinations
    }
}
