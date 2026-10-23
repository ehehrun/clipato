import Foundation

final class StorageDirectoryScope: @unchecked Sendable {
    let url: URL
    let bookmark: Data

    init(bookmark: Data, directory: URL) throws {
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        guard resolved.startAccessingSecurityScopedResource() else {
            throw StorageLocationError.authorizationRequired(directory)
        }
        do {
            guard resolved.standardizedFileURL.path == directory.standardizedFileURL.path else {
                throw StorageLocationError.directoryMoved(directory, resolved)
            }
            self.bookmark = stale
                ? try resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                : bookmark
            url = resolved
        } catch {
            resolved.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    deinit { url.stopAccessingSecurityScopedResource() }
}

/// Saved URLs retain their original meaning; bookmarks only retain permission to use those locations.
final class StorageDirectoryAccess {
    static let filename = "storage-bookmarks.plist"
    private let root: URL
    private let enabled: Bool
    private let file: URL
    private var scopes: [String: StorageDirectoryScope] = [:]

    init(root: URL, enabled: Bool = DistributionChannel.isAppStore) {
        self.root = root.standardizedFileURL
        self.enabled = enabled
        file = root.appendingPathComponent(Self.filename)
    }

    var activeScopes: [StorageDirectoryScope] { Array(scopes.values) }

    func restore(_ directories: [URL]) -> [URL: String] {
        guard enabled else { return [:] }
        let directories = Dictionary(directories.filter { !contains($0, in: root) }
            .map { ($0.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        scopes = scopes.filter { directories[$0.key] != nil }
        var errors: [URL: String] = [:]
        do {
            var bookmarks = try readBookmarks()
            var refreshed = false
            for (key, directory) in directories.sorted(by: { $0.key < $1.key }) {
                do {
                    guard let bookmark = bookmarks[key] else { throw StorageLocationError.authorizationRequired(directory) }
                    let scope: StorageDirectoryScope
                    if let active = scopes[key] { scope = active }
                    else { scope = try StorageDirectoryScope(bookmark: bookmark, directory: directory) }
                    if scope.bookmark != bookmark {
                        bookmarks[key] = scope.bookmark
                        refreshed = true
                    }
                    scopes[key] = scope
                } catch {
                    scopes[key] = nil
                    errors[directory] = error.localizedDescription
                }
            }
            if refreshed { try writeBookmarks(bookmarks) }
        } catch {
            scopes.removeAll()
            for directory in directories.values { errors[directory] = error.localizedDescription }
        }
        return errors
    }

    func requireAccess(to url: URL) throws {
        guard enabled, !contains(url, in: root) else { return }
        guard scopes.values.contains(where: { contains(url, in: $0.url) }) else {
            throw StorageLocationError.authorizationRequired(url)
        }
    }

    func select(_ directory: URL, savingLocation: () throws -> Void) throws {
        guard enabled, !contains(directory, in: root) else {
            try savingLocation()
            return
        }
        let bookmark = try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let scope = try StorageDirectoryScope(bookmark: bookmark, directory: directory)
        let previous = try readBookmarks()
        var updated = previous
        updated[directory.standardizedFileURL.path] = scope.bookmark
        try writeBookmarks(updated)
        do { try savingLocation() }
        catch {
            let failure = error
            do { try writeBookmarks(previous) }
            catch { throw KeyframeRecordingError.multipleFailures(failure, error) }
            throw failure
        }
        scopes[directory.standardizedFileURL.path] = scope
    }

    private func readBookmarks() throws -> [String: Data] {
        do { return try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }

    private func writeBookmarks(_ bookmarks: [String: Data]) throws {
        if bookmarks.isEmpty {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        } else {
            try PropertyListEncoder().encode(bookmarks).write(to: file, options: .atomic)
        }
    }

    private func contains(_ url: URL, in directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let parent = directory.standardizedFileURL.path
        return path == parent || path.hasPrefix(parent + "/")
    }
}
