import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
import os

struct VaultImage: Identifiable, Codable, Hashable {
    let id: UUID
    var filename: String
    let createdAt: Date
    let width: Int
    let height: Int
    let source: String
    var directory: URL? = nil
    var tag: AssetTag? = nil
}

struct SavedSession: Identifiable {
    let id: UUID
    let directory: URL
    let manifest: KeyframeManifest
}

struct LibraryCleanupOptions {
    var images = true
    var recordings = true
    var collections = true
    var history = true

    var isEmpty: Bool { !images && !recordings && !collections && !history }
}

enum LibraryError: LocalizedError {
    case unreadableImage(String)
    case imageWrite
    case invalidName
    case invalidTag(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): return L("无法读取图片：\(name)")
        case .imageWrite: return L("图片写入失败。请检查磁盘空间与目录权限。")
        case .invalidName: return L("图片名称不能为空，也不能包含 / 或 :。")
        case .invalidTag(let url): return L("录制颜色标签无法识别：\(url.path)")
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var images: [VaultImage] = []
    @Published private(set) var sessions: [SavedSession] = []
    @Published private(set) var videos: [URL] = []
    @Published private(set) var collections: [AssetCollection] = []
    @Published private(set) var collectionMembers: [UUID: Set<CollectionAsset>] = [:]
    @Published private(set) var storage = StorageLocations()
    @Published private(set) var recordingReadErrors: [String] = []
    @Published private(set) var recordingTags: [URL: AssetTag] = [:]
    @Published private(set) var storageUsage: LibraryStorageUsage?
    @Published private(set) var storagePolicy = LibraryStoragePolicy()
    @Published private(set) var storageUsageError: String?
    @Published private(set) var storageAuthorizationErrors: [URL: String] = [:]
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let thumbnails = ThumbnailLoader()
    private let database: LibraryDatabase
    private let defaults: UserDefaults
    private let enforcesStorageQuota: Bool
    private let storageDirectoryAccess: StorageDirectoryAccess
    private var imageVersion: Int64?
    private let trashImageDirectory: @Sendable (URL) throws -> URL
    private var cacheDirectories: [URL] = []
    private let protectedImageIDs = OSAllocatedUnfairLock(initialState: Set<UUID>())
    private var pendingNewImages: Set<UUID> = []
    private var scheduledStorageRefresh: Task<Void, Never>?
    private var storageRefreshTask: Task<(LibraryStorageUsage, String?), Error>?
    private var storageRefreshGeneration = 0
    private var cleanupInProgress = false
    private var isReady = false

    init(root: URL, defaults: UserDefaults = .standard, enforceStorageQuota: Bool = true,
         trashImageDirectory: @escaping @Sendable (URL) throws -> URL = { try LibraryStore.moveImageDirectoryToTrash($0) },
         requiresStorageAuthorization: Bool = DistributionChannel.isAppStore) throws {
        self.root = root
        self.defaults = defaults
        self.enforcesStorageQuota = enforceStorageQuota
        storageDirectoryAccess = StorageDirectoryAccess(root: root, enabled: requiresStorageAuthorization)
        self.trashImageDirectory = trashImageDirectory
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
        database = try Self.withImageLock(at: root) { try LibraryDatabase(root: root) }
        try reloadStorage()
        try reloadImages()
        try reloadSessions()
        isReady = true
    }

    deinit {
        scheduledStorageRefresh?.cancel()
        storageRefreshTask?.cancel()
    }

    var hasPendingStorageWork: Bool { scheduledStorageRefresh != nil || storageRefreshTask != nil }

    func cancelStorageWorkAndWait() async {
        storageRefreshGeneration += 1
        let generation = storageRefreshGeneration
        scheduledStorageRefresh?.cancel()
        scheduledStorageRefresh = nil
        let worker = storageRefreshTask
        worker?.cancel()
        _ = await worker?.result
        if storageRefreshGeneration == generation { storageRefreshTask = nil }
    }

    func reloadImages() throws {
        try reloadImages(refreshUsage: true)
    }

    private func reloadImages(refreshUsage: Bool) throws {
        let version = try database.dataVersion()
        guard imageVersion != version else { return }
        let policy = try database.storagePolicy()
        let updated = try database.images()
        try reloadCollectionState()
        imageVersion = version
        if policy != storagePolicy {
            storagePolicy = policy
            if refreshUsage { scheduleStorageRefresh() }
        }
        guard updated != images else { return }
        let currentURLs = Set(updated.map(imageURL))
        let removedURLs = images.map(imageURL).filter { !currentURLs.contains($0) }
        if !removedURLs.isEmpty { Task { await thumbnails.invalidate(removedURLs) } }
        images = updated
        restoreStorageAccess()
        if refreshUsage { scheduleStorageRefresh() }
    }

    private func reloadCollectionState() throws {
        let (updatedCollections, updatedMembers) = try database.collectionState()
        if updatedCollections != collections { collections = updatedCollections }
        if updatedMembers != collectionMembers { collectionMembers = updatedMembers }
    }

    func recentImage() throws -> VaultImage? {
        try reloadImages()
        return try database.recentImage()
    }

    func rememberImage(_ id: UUID) throws {
        guard !defaults.bool(forKey: "privacyMode") else { return }
        try withImageLock { try database.rememberImage(id) }
    }

    func clearOperationHistory() throws {
        try withImageLock { try database.clearOperationHistory() }
    }

    func clearAllMedia(options: LibraryCleanupOptions) async throws {
        guard !options.isEmpty else { return }
        guard !cleanupInProgress else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("正在清理…")])
        }
        try AutomationAccess.check()
        cleanupInProgress = true
        defer { cleanupInProgress = false }
        await cancelStorageWorkAndWait()
        try AutomationAccess.check()
        if options.history { try clearOperationHistory() }
        if options.images { try reloadImages() }
        if options.recordings {
            try reloadSessions()
            guard recordingReadErrors.isEmpty else {
                throw NSError(domain: "Clipato", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: recordingReadErrors.joined(separator: "\n")
                ])
            }
        }
        // Only per-asset directories belong to the vault; never trash an imported parent folder.
        guard !options.images || images.allSatisfy({ UUID(uuidString: imageURL($0).deletingLastPathComponent().lastPathComponent) == $0.id }) else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("媒体目录包含非独立素材文件夹，已停止清空。")
            ])
        }
        let deletingImages = options.images ? images : []
        let deletingSessions = options.recordings ? sessions : []
        let deletingVideos = options.recordings ? videos : []
        for start in stride(from: 0, to: deletingImages.count, by: 32) {
            try AutomationAccess.check()
            try delete(Array(deletingImages[start..<min(start + 32, deletingImages.count)]))
            await Task.yield()
        }
        var recordingsRemoved = 0
        for session in deletingSessions {
            try AutomationAccess.check()
            try deleteSession(session)
            recordingsRemoved += 1
            if recordingsRemoved % 32 == 0 { await Task.yield() }
        }
        for video in deletingVideos {
            try AutomationAccess.check()
            try deleteVideo(video)
            recordingsRemoved += 1
            if recordingsRemoved % 32 == 0 { await Task.yield() }
        }
        try AutomationAccess.check()
        try withImageLock {
            if options.images { try reloadImages() }
            if options.recordings {
                try reloadSessions()
                guard recordingReadErrors.isEmpty else {
                    throw NSError(domain: "Clipato", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: recordingReadErrors.joined(separator: "\n")
                    ])
                }
            }
            guard (!options.images || images.isEmpty),
                  (!options.recordings || (sessions.isEmpty && videos.isEmpty)) else {
                throw NSError(domain: "Clipato", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("清空期间媒体内容发生变化，请重试。")
                ])
            }
            if options.collections {
                try database.clearCollections()
                try reloadCollectionState()
            }
        }
    }

    @discardableResult
    func createCollection(name: String, parentID: UUID? = nil) throws -> AssetCollection {
        try withImageLock {
            try AutomationAccess.check()
            let collection = try database.createCollection(name: name, parentID: parentID)
            try reloadCollectionState()
            return collection
        }
    }

    func renameCollection(_ id: UUID, name: String) throws {
        try withImageLock {
            try AutomationAccess.check()
            try database.renameCollection(id, name: name)
            try reloadCollectionState()
        }
    }

    func setCollectionColor(_ id: UUID, color: AssetTag?) throws {
        try withImageLock {
            try AutomationAccess.check()
            try database.setCollectionColor(id, color: color)
            try reloadCollectionState()
        }
    }

    func deleteCollection(_ id: UUID) throws {
        try withImageLock {
            try AutomationAccess.check()
            try database.deleteCollection(id)
            try reloadCollectionState()
        }
    }

    func moveCollection(_ id: UUID, toParent parentID: UUID?, before: UUID? = nil) throws {
        try withImageLock {
            try AutomationAccess.check()
            try database.moveCollection(id, toParent: parentID, before: before)
            try reloadCollectionState()
        }
    }

    func addToCollection(_ id: UUID, assets: Set<CollectionAsset>) throws {
        try withImageLock {
            try reloadImages()
            if assets.contains(where: { if case .image = $0 { return false }; return true }) {
                try reloadSessions()
            }
            let available = Set(images.map { CollectionAsset.image($0.id) })
                .union(sessions.map { CollectionAsset.session($0.id) })
                .union(videos.map { CollectionAsset.video($0) })
            guard assets.isSubset(of: available) else { throw CollectionError.missingAsset }
            try AutomationAccess.check()
            try database.addToCollection(id, assets: assets)
            try reloadCollectionState()
        }
    }

    func removeFromCollection(_ id: UUID, assets: Set<CollectionAsset>) throws {
        try withImageLock {
            try AutomationAccess.check()
            try database.removeFromCollection(id, assets: assets)
            try reloadCollectionState()
        }
    }

    func assets(in id: UUID) -> Set<CollectionAsset> {
        collectionMembers[id, default: []]
    }

    func collections(containing asset: CollectionAsset) -> [AssetCollection] {
        collections.filter { collectionMembers[$0.id, default: []].contains(asset) }
    }

    private func removePublishedCollectionAsset(_ asset: CollectionAsset) {
        var updated = collectionMembers
        for id in updated.keys where updated[id]!.contains(asset) { updated[id]!.remove(asset) }
        if updated != collectionMembers { collectionMembers = updated }
    }

    func updateStoragePolicy(_ policy: LibraryStoragePolicy) throws {
        try withImageLock { try database.updateStoragePolicy(policy) }
        storagePolicy = policy
        scheduleStorageRefresh()
    }

    func setCacheDirectories(_ directories: [URL]) {
        cacheDirectories = directories
        scheduleStorageRefresh()
    }

    func setProtectedImageIDs(_ ids: Set<UUID>) {
        protectedImageIDs.withLock { $0 = ids }
    }

    func refreshStorageUsage(enforceQuota: Bool = true) async {
        scheduledStorageRefresh?.cancel()
        scheduledStorageRefresh = nil
        storageRefreshGeneration += 1
        let generation = storageRefreshGeneration
        let previous = storageRefreshTask
        previous?.cancel()
        _ = await previous?.result
        guard generation == storageRefreshGeneration else { return }
        let root = root
        let directories = sessions.map(\.directory) + videos.map { $0.deletingLastPathComponent() }
        let caches = cacheDirectories
        let readErrors = recordingReadErrors + Array(storageAuthorizationErrors.values)
        let newImages = pendingNewImages
        let protected = newImages
        let pins = protectedImageIDs
        let knownImages = Set(images.map(\.id))
        let trash = trashImageDirectory
        let enforceQuota = enforceQuota && enforcesStorageQuota && !cleanupInProgress
        let scopes = storageDirectoryAccess.activeScopes
        let task = AutomationAccess.detached(priority: .utility) {
            defer { withExtendedLifetime(scopes) { } }
            return try Self.measureAndManageStorage(root: root, recordingDirectories: directories, cacheDirectories: caches,
                                            recordingReadErrors: readErrors, protected: protected, pins: pins, knownImages: knownImages,
                                            enforceQuota: enforceQuota, trash: trash)
        }
        storageRefreshTask = task
        do {
            let (usage, message) = try await task.value
            guard generation == storageRefreshGeneration else { return }
            try reloadImages(refreshUsage: false)
            storageUsage = usage
            storageUsageError = message
            pendingNewImages.subtract(newImages)
        } catch is CancellationError {
        } catch {
            guard generation == storageRefreshGeneration else { return }
            storageUsage = nil
            storageUsageError = error.localizedDescription
        }
        if generation == storageRefreshGeneration { storageRefreshTask = nil }
    }

    private func scheduleStorageRefresh(protecting ids: [UUID] = []) {
        pendingNewImages.formUnion(ids)
        guard isReady, !cleanupInProgress else { return }
        storageRefreshTask?.cancel()
        scheduledStorageRefresh?.cancel()
        scheduledStorageRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard let self else { return }
            self.scheduledStorageRefresh = nil
            await self.refreshStorageUsage()
        }
    }

    nonisolated static func moveImageDirectoryToTrash(_ directory: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: directory, resultingItemURL: &trashed)
        return trashed! as URL
    }

    nonisolated private static func measureAndManageStorage(
        root: URL, recordingDirectories: [URL], cacheDirectories: [URL], recordingReadErrors: [String],
        protected: Set<UUID>, pins: OSAllocatedUnfairLock<Set<UUID>>, knownImages: Set<UUID>, enforceQuota: Bool,
        trash: @Sendable (URL) throws -> URL
    ) throws -> (LibraryStorageUsage, String?) {
        try AutomationAccess.check()
        let database = try LibraryDatabase(root: root)
        var items = try database.images()
        let policy = try database.storagePolicy()
        var usage = try LibraryStorageUsage.scan(root: root, images: items, recordingDirectories: recordingDirectories,
                                                cacheDirectories: cacheDirectories,
                                                logDirectories: [MCPAccessLog.fileURL.deletingLastPathComponent()],
                                                recordingReadErrors: recordingReadErrors)
        guard usage.isComplete else {
            return (usage, L("部分文件无法访问，当前容量不完整；已暂停自动清理。\n") + usage.unavailablePaths.joined(separator: "\n"))
        }
        guard enforceQuota else { return (usage, nil) }
        guard let maximum = policy.maximumBytes, usage.mediaBytes > maximum else { return (usage, nil) }
        guard policy.automaticallyRemoveOldestImages else { return (usage, L("媒体容量已超过上限，自动清理未开启。")) }
        let recentBoundary = Date().addingTimeInterval(-Double(policy.keepRecentDays) * 86_400)
        var mediaBytes = usage.mediaBytes
        var cleanupError: String?
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) where mediaBytes > maximum {
            try AutomationAccess.check()
            guard knownImages.contains(item.id), !protected.contains(item.id) else { continue }
            do {
                let removedBytes: Int64 = try withImageLock(at: root, cancellable: true) {
                    try AutomationAccess.check()
                    guard try database.storagePolicy() == policy,
                          let current = try database.image(item.id),
                          !policy.protectTaggedImages || current.tag == nil,
                          policy.keepRecentDays == 0 || current.createdAt < recentBoundary else { return 0 }
                    let directory = current.directory ?? root.appendingPathComponent("Images").appendingPathComponent(current.id.uuidString)
                    guard directory.lastPathComponent == current.id.uuidString else { return 0 }
                    let bytes = try AssetFileInfoLoader.byteCount(at: directory.appendingPathComponent(current.filename))
                    try AutomationAccess.check()
                    if policy.protectCollectedImages, try database.isCollectedImage(current.id) { return 0 }
                    guard !pins.withLock({ $0.contains(current.id) }) else { return 0 }
                    let trashed = try trash(directory)
                    do { try database.delete(current.id) }
                    catch {
                        do { try FileManager.default.moveItem(at: trashed, to: directory) }
                        catch let rollback { throw KeyframeRecordingError.multipleFailures(error, rollback) }
                        throw error
                    }
                    return bytes
                }
                mediaBytes -= removedBytes
            } catch is CancellationError { throw CancellationError() }
            catch { cleanupError = L("自动清理未完成：") + error.localizedDescription; break }
        }
        items = try database.images()
        usage = try LibraryStorageUsage.scan(root: root, images: items, recordingDirectories: recordingDirectories,
                                            cacheDirectories: cacheDirectories,
                                            logDirectories: [MCPAccessLog.fileURL.deletingLastPathComponent()],
                                            recordingReadErrors: recordingReadErrors)
        if !usage.isComplete {
            return (usage, L("部分文件无法访问，当前容量不完整；已暂停自动清理。\n") + usage.unavailablePaths.joined(separator: "\n"))
        }
        if let cleanupError { return (usage, cleanupError) }
        if usage.mediaBytes > maximum { return (usage, L("媒体容量仍超过上限；其余图片受到保留规则保护，录屏不会自动清理。")) }
        return (usage, nil)
    }

    func imageURL(_ item: VaultImage) -> URL {
        let directory = item.directory ?? root.appendingPathComponent("Images").appendingPathComponent(item.id.uuidString)
        return directory.appendingPathComponent(item.filename)
    }

    var screenshotDirectory: URL { storage.screenshotDirectory ?? root.appendingPathComponent("Images") }
    var recordingDirectory: URL { storage.recordingDirectory ?? root.appendingPathComponent("Sessions") }

    func setStorageDirectory(_ directory: URL?, for kind: StorageKind) throws {
        let directory = directory?.standardizedFileURL.resolvingSymlinksInPath()
        let defaultDirectory = root.appendingPathComponent(kind == .screenshots ? "Images" : "Sessions")
        try withImageLock {
            try reloadStorage()
            var updated = storage
            let chosen = directory == defaultDirectory.standardizedFileURL.resolvingSymlinksInPath() ? nil : directory
            switch kind {
            case .screenshots:
                updated.screenshotDirectory = chosen
            case .recordings:
                updated.recordingDirectory = chosen
                if let chosen, !updated.recordingDirectories.contains(chosen) {
                    updated.recordingDirectories.append(chosen)
                }
            }
            try storageDirectoryAccess.select(directory ?? defaultDirectory) {
                try StorageLocations.validateDirectory(directory ?? defaultDirectory)
                try encoder.encode(updated).write(to: root.appendingPathComponent("storage.json"), options: .atomic)
            }
            storage = updated
            restoreStorageAccess()
            scheduleStorageRefresh()
        }
    }

    func authorizeStorageDirectory(_ directory: URL, for configuredDirectory: URL) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory == configuredDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw StorageLocationError.differentDirectory(configuredDirectory)
        }
        try withImageLock {
            try storageDirectoryAccess.select(directory) {
                try StorageLocations.validateDirectory(directory)
            }
            restoreStorageAccess()
        }
    }

    func validateStorageDirectory(for kind: StorageKind) throws {
        try reloadStorage()
        let directory = kind == .screenshots ? screenshotDirectory : recordingDirectory
        try storageDirectoryAccess.requireAccess(to: directory)
        try StorageLocations.validateDirectory(directory)
    }

    func newRecordingDirectory() throws -> URL {
        try validateStorageDirectory(for: .recordings)
        return recordingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func reloadStorage() throws {
        storage = try Self.readStorage(at: root)
        restoreStorageAccess()
    }

    private func restoreStorageAccess() {
        let directories = [storage.screenshotDirectory, storage.recordingDirectory].compactMap { $0 }
            + storage.recordingDirectories + images.compactMap { $0.directory?.deletingLastPathComponent() }
        storageAuthorizationErrors = storageDirectoryAccess.restore(directories)
    }

    nonisolated private static func readStorage(at root: URL) throws -> StorageLocations {
        let file = root.appendingPathComponent("storage.json")
        do { return try JSONDecoder().decode(StorageLocations.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return StorageLocations() }
    }

    func loadImage(_ item: VaultImage) throws -> CGImage {
        let url = imageURL(item)
        try storageDirectoryAccess.requireAccess(to: url)
        return try Self.readImage(at: url)
    }

    nonisolated static func readImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw LibraryError.unreadableImage(url.lastPathComponent)
        }
        let image: CGImage?
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        } else {
            // 普通截图延迟解码，批量拼图不必同时持有所有原图的像素缓存。
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else {
            throw LibraryError.unreadableImage(url.lastPathComponent)
        }
        return image
    }

    func thumbnail(_ item: VaultImage) async throws -> NSImage {
        try storageDirectoryAccess.requireAccess(to: imageURL(item))
        return try await thumbnail(at: imageURL(item))
    }

    func thumbnail(at url: URL) async throws -> NSImage {
        let scopes = storageDirectoryAccess.activeScopes
        defer { withExtendedLifetime(scopes) { } }
        let image = try await thumbnails.image(at: url)
        try AutomationAccess.check()
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func videoThumbnail(at url: URL) async throws -> NSImage {
        try storageDirectoryAccess.requireAccess(to: url)
        let scopes = storageDirectoryAccess.activeScopes
        defer { withExtendedLifetime(scopes) { } }
        let image = try await thumbnails.video(at: url)
        try AutomationAccess.check()
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func clearThumbnails() async {
        await thumbnails.clear()
    }

    @discardableResult
    func addImage(_ image: CGImage, source: String, filename: String? = nil, tag: AssetTag? = nil, collectionID: UUID? = nil) throws -> VaultImage {
        try AutomationAccess.check()
        return try withImageLock {
            try reloadImages()
            try reloadStorage()
            try storageDirectoryAccess.requireAccess(to: screenshotDirectory)
            let id = UUID()
            let item = VaultImage(id: id, filename: filename ?? Self.captureName(source), createdAt: Date(),
                                  width: image.width, height: image.height, source: source,
                                  directory: storage.screenshotDirectory?.appendingPathComponent(id.uuidString, isDirectory: true), tag: tag)
            let directory = imageURL(item).deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                try Self.writePNG(image, to: imageURL(item))
                try AutomationAccess.check()
                try database.insert(item, collectionID: collectionID, remember: !defaults.bool(forKey: "privacyMode"))
                if let collectionID { collectionMembers[collectionID, default: []].insert(.image(item.id)) }
                images.insert(item, at: 0)
                scheduleStorageRefresh(protecting: [item.id])
            } catch {
                try fileManager.removeItem(at: directory)
                throw error
            }
            return item
        }
    }

    func importImages(_ urls: [URL]) throws {
        var imported: [UUID] = []
        defer { if !imported.isEmpty { scheduleStorageRefresh(protecting: imported) } }
        try withImageLock {
            try reloadImages()
            try reloadStorage()
            try storageDirectoryAccess.requireAccess(to: screenshotDirectory)
            for url in urls {
                try AutomationAccess.check()
                let image = try Self.readImage(at: url)
                try AutomationAccess.check()
                let id = UUID()
                let item = VaultImage(id: id, filename: url.lastPathComponent, createdAt: Date(),
                                      width: image.width, height: image.height, source: "导入",
                                      directory: storage.screenshotDirectory?.appendingPathComponent(id.uuidString, isDirectory: true))
                let directory = imageURL(item).deletingLastPathComponent()
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                do {
                    try fileManager.copyItem(at: url, to: imageURL(item))
                    try AutomationAccess.check()
                    try database.insert(item, remember: !defaults.bool(forKey: "privacyMode"))
                    images.insert(item, at: 0)
                    imported.append(item.id)
                } catch {
                    try fileManager.removeItem(at: directory)
                    throw error
                }
            }
        }
    }

    func importKeyframes(_ session: SavedSession) async throws -> Int {
        try AutomationAccess.check()
        try reloadStorage()
        try storageDirectoryAccess.requireAccess(to: screenshotDirectory)
        try storageDirectoryAccess.requireAccess(to: session.directory)
        let root = root
        let scopes = storageDirectoryAccess.activeScopes
        nonisolated(unsafe) let defaults = defaults
        let task = AutomationAccess.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(scopes) { } }
            return try Self.importKeyframes(session, root: root, defaults: defaults)
        }
        let imported = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try reloadImages(refreshUsage: false)
        scheduleStorageRefresh(protecting: imported)
        return imported.count
    }

    nonisolated private static func importKeyframes(_ session: SavedSession, root: URL, defaults: UserDefaults) throws -> [UUID] {
        try AutomationAccess.check()
        let manifest = session.manifest
        guard (1...16384).contains(manifest.width), (1...16384).contains(manifest.height),
              manifest.duration.isFinite, manifest.duration > 0, !manifest.frames.isEmpty else {
            throw KeyframeExportError.invalidManifest(L("录制尺寸、时长或帧列表无效。"))
        }
        let sourceDirectory = session.directory.standardizedFileURL.resolvingSymlinksInPath()
        let tag = try readRecordingTag(at: sourceDirectory)
        var previousTime = -Double.infinity
        let sources = try manifest.frames.map { frame in
            guard frame.time.isFinite, frame.time >= 0, frame.time > previousTime, frame.time < manifest.duration else {
                throw KeyframeExportError.invalidManifest(L("关键帧时间必须递增，并且早于录制结束。"))
            }
            previousTime = frame.time
            let url = sourceDirectory.appendingPathComponent(frame.file).standardizedFileURL.resolvingSymlinksInPath()
            guard !frame.file.hasPrefix("/"), url.path.hasPrefix(sourceDirectory.path + "/"), url.pathExtension.lowercased() == "png" else {
                throw KeyframeExportError.invalidManifest(L("关键帧文件必须是录制目录内的 PNG 图片。"))
            }
            return url
        }
        let storage = try withImageLock(at: root, cancellable: true) {
            try AutomationAccess.check()
            return try readStorage(at: root)
        }
        let destination = storage.screenshotDirectory ?? root.appendingPathComponent("Images")
        let manager = FileManager.default
        var directories: [URL] = []
        var images: [VaultImage] = []
        do {
            for (index, source) in sources.enumerated() {
                try AutomationAccess.check()
                try autoreleasepool {
                    _ = try KeyframeExporter.readFrame(source, manifest: manifest, width: manifest.width, height: manifest.height)
                    let id = UUID()
                    let directory = destination.appendingPathComponent(id.uuidString, isDirectory: true)
                    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                    directories.append(directory)
                    try manager.copyItem(at: source, to: directory.appendingPathComponent(source.lastPathComponent))
                    images.append(VaultImage(id: id, filename: source.lastPathComponent,
                                             createdAt: manifest.createdAt.addingTimeInterval(manifest.frames[index].time),
                                             width: manifest.width, height: manifest.height, source: "关键帧",
                                             directory: storage.screenshotDirectory == nil ? nil : directory, tag: tag))
                }
            }
            try withImageLock(at: root, cancellable: true) {
                try AutomationAccess.check()
                let database = try LibraryDatabase(root: root)
                // 保管箱按插入顺序倒序展示，同批关键帧要按录制时间正序排列。
                try database.insert(Array(images.reversed()), remember: !defaults.bool(forKey: "privacyMode"))
            }
        } catch {
            var failure = error
            for directory in directories {
                do { try manager.removeItem(at: directory) }
                catch { failure = KeyframeRecordingError.multipleFailures(failure, error) }
            }
            throw failure
        }
        return images.map(\.id)
    }

    func rename(_ item: VaultImage, to name: String) throws {
        try withImageLock {
            try reloadImages()
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), trimmed != ".", trimmed != ".." else {
                throw LibraryError.invalidName
            }
            guard let index = images.firstIndex(where: { $0.id == item.id }) else { return }
            let current = images[index]
            try storageDirectoryAccess.requireAccess(to: imageURL(current))
            let ext = imageURL(current).pathExtension
            let filename = (trimmed as NSString).pathExtension.lowercased() == ext.lowercased() ? trimmed : trimmed + "." + ext
            if filename == current.filename { return }
            let destination = imageURL(current).deletingLastPathComponent().appendingPathComponent(filename)
            var updated = images
            updated[index].filename = filename
            try fileManager.moveItem(at: imageURL(current), to: destination)
            do { try database.rename(current.id, to: filename) } catch {
                try fileManager.moveItem(at: destination, to: imageURL(current))
                throw error
            }
            images = updated
            scheduleStorageRefresh()
            Task { await thumbnails.invalidate([imageURL(current)]) }
        }
    }

    func batchRenameURLs(for assets: [CollectionAsset]) throws -> [URL] {
        guard BatchRenameRule.supports(assets) else { throw BatchRenameError.unsupportedSelection }
        let imagesByID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        let availableVideos = Set(videos)
        return try assets.map { asset in
            switch asset {
            case .image(let id):
                guard let image = imagesByID[id] else { throw CollectionError.missingAsset }
                try storageDirectoryAccess.requireAccess(to: imageURL(image))
                return imageURL(image)
            case .video(let url):
                guard availableVideos.contains(url) else { throw CollectionError.missingAsset }
                try storageDirectoryAccess.requireAccess(to: url)
                return url
            case .session: throw BatchRenameError.unsupportedSelection
            }
        }
    }

    @discardableResult
    func batchRename(_ assets: [CollectionAsset], rule: BatchRenameRule) throws -> [CollectionAsset] {
        guard BatchRenameRule.supports(assets) else { throw BatchRenameError.unsupportedSelection }
        return try withImageLock {
            try reloadImages()
            if case .video = assets[0] { try reloadSessions() }
            let sources = try batchRenameURLs(for: assets)
            let filenames = try rule.filenames(for: sources)
            let destinations = zip(sources, filenames).map { $0.deletingLastPathComponent().appendingPathComponent($1) }
            var sourceInfo: [dev_t: Set<ino_t>] = [:]
            for source in sources {
                var info = stat()
                guard lstat(source.path, &info) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
                }
                guard info.st_mode & S_IFMT == S_IFREG else { throw CollectionError.missingAsset }
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
            let renamedAssets = zip(assets, destinations).map { asset, destination in
                if case .video = asset { return CollectionAsset.video(destination) }
                return asset
            }
            guard !changed.isEmpty else { return renamedAssets }
            let temporary = sources.map { $0.deletingLastPathComponent().appendingPathComponent(".clipato-rename-\(UUID().uuidString)") }
            var locations = sources
            do {
                // Stage every source before placing any destination; this also permits name exchanges.
                for index in changed {
                    try AutomationAccess.check()
                    try moveForBatchRename(sources[index], to: temporary[index])
                    locations[index] = temporary[index]
                }
                for index in changed {
                    try AutomationAccess.check()
                    try moveForBatchRename(temporary[index], to: destinations[index])
                    locations[index] = destinations[index]
                }
                try AutomationAccess.check()
                try database.batchRename(changed.map { (assets[$0], destinations[$0]) })
            } catch {
                var failure = error
                for index in changed.reversed() where locations[index] != sources[index] && locations[index] != temporary[index] {
                    do {
                        try moveForBatchRename(locations[index], to: temporary[index])
                        locations[index] = temporary[index]
                    } catch { failure = KeyframeRecordingError.multipleFailures(failure, error) }
                }
                for index in changed.reversed() where locations[index] != sources[index] {
                    do { try moveForBatchRename(locations[index], to: sources[index]) }
                    catch { failure = KeyframeRecordingError.multipleFailures(failure, error) }
                }
                throw failure
            }
            let imageNames = Dictionary(uniqueKeysWithValues: zip(assets, filenames).compactMap { asset, filename -> (UUID, String)? in
                if case .image(let id) = asset { return (id, filename) }
                return nil
            })
            images = images.map { image in
                guard let filename = imageNames[image.id] else { return image }
                var updated = image
                updated.filename = filename
                return updated
            }
            let videoURLs = Dictionary(uniqueKeysWithValues: zip(assets, destinations).compactMap { asset, destination -> (URL, URL)? in
                if case .video(let source) = asset { return (source, destination) }
                return nil
            })
            videos = videos.map { videoURLs[$0] ?? $0 }
            collectionMembers = collectionMembers.mapValues { members in
                Set(members.map { asset in
                    if case .video(let source) = asset, let destination = videoURLs[source] { return .video(destination) }
                    return asset
                })
            }
            scheduleStorageRefresh()
            Task { await thumbnails.invalidate(changed.map { sources[$0] }) }
            return renamedAssets
        }
    }

    private func moveForBatchRename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    func delete(_ items: [VaultImage]) throws {
        try withImageLock {
            try reloadImages()
            var remaining = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
            var removedIDs: Set<UUID> = []
            var removedURLs: [URL] = []
            defer {
                if !removedIDs.isEmpty {
                    images.removeAll { removedIDs.contains($0.id) }
                    let assets = Set(removedIDs.map(CollectionAsset.image))
                    var updated = collectionMembers
                    for id in updated.keys { updated[id]!.subtract(assets) }
                    if updated != collectionMembers { collectionMembers = updated }
                    scheduleStorageRefresh()
                    let urls = removedURLs
                    Task { await thumbnails.invalidate(urls) }
                }
            }
            for item in items {
                guard let current = remaining.removeValue(forKey: item.id) else { continue }
                let url = imageURL(current)
                let directory = url.deletingLastPathComponent()
                try storageDirectoryAccess.requireAccess(to: directory)
                // 使用系统废纸篓，保管箱的批量删除可由 Finder 恢复。
                let trashed = try trashImageDirectory(directory)
                do { try database.delete(current.id) } catch {
                    do { try fileManager.moveItem(at: trashed, to: directory) }
                    catch let rollback { throw KeyframeRecordingError.multipleFailures(error, rollback) }
                    throw error
                }
                removedIDs.insert(current.id)
                removedURLs.append(url)
            }
        }
    }

    func setTag(_ tag: AssetTag?, for items: [VaultImage]) throws {
        let ids = Set(items.map(\.id))
        try withImageLock {
            try reloadImages()
            var updated = images
            for index in updated.indices where ids.contains(updated[index].id) { updated[index].tag = tag }
            guard updated != images else { return }
            try database.setTag(tag, for: updated.filter { ids.contains($0.id) }.map(\.id))
            images = updated
            scheduleStorageRefresh()
        }
    }

    func setRecordingTag(_ tag: AssetTag?, for directory: URL) throws {
        try storageDirectoryAccess.requireAccess(to: directory)
        try Self.writeRecordingTag(tag, to: directory)
        recordingTags[directory] = tag
        scheduleStorageRefresh()
    }

    static func writeRecordingTag(_ tag: AssetTag?, to directory: URL) throws {
        let file = directory.appendingPathComponent(".framevault-tag")
        if let tag {
            try Data(tag.rawValue.utf8).write(to: file, options: .atomic)
        } else {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    func reloadSessions() throws {
        try reloadStorage()
        let defaultDirectory = root.appendingPathComponent("Sessions")
        var (loaded, loadedVideos, tags) = try readSessions(at: defaultDirectory, external: false)
        var errors: [String] = []
        for directory in storage.recordingDirectories {
            do {
                let (sessions, videos, loadedTags) = try readSessions(at: directory, external: true)
                loaded.append(contentsOf: sessions)
                loadedVideos.append(contentsOf: videos)
                tags.merge(loadedTags) { _, new in new }
            } catch {
                errors.append("\(directory.path)：\(error.localizedDescription)")
                loaded.append(contentsOf: sessions.filter { $0.directory.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL })
                loadedVideos.append(contentsOf: videos.filter { $0.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL })
                tags.merge(recordingTags.filter { $0.key.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }) { _, old in old }
            }
        }
        let changed = Set(sessions.map(\.directory)) != Set(loaded.map(\.directory)) || Set(videos) != Set(loadedVideos) || recordingReadErrors != errors || recordingTags != tags
        sessions = loaded.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
        videos = loadedVideos
        recordingReadErrors = errors
        recordingTags = tags
        if changed { scheduleStorageRefresh() }
    }

    private func readSessions(at directory: URL, external: Bool) throws -> ([SavedSession], [URL], [URL: AssetTag]) {
        try storageDirectoryAccess.requireAccess(to: directory)
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var loaded: [SavedSession] = []
        var loadedVideos: [URL] = []
        var tags: [URL: AssetTag] = [:]
        for found in entries {
            if external, UUID(uuidString: found.lastPathComponent) == nil { continue }
            guard try found.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            // Directory enumeration may rewrite /var to /private/var; keep the saved root spelling,
            // including when that volume later goes offline and can no longer resolve aliases.
            let entry = directory.appendingPathComponent(found.lastPathComponent, isDirectory: true)
            let manifestURL = entry.appendingPathComponent("manifest.json")
            if fileManager.fileExists(atPath: manifestURL.path) {
                let manifest = try decoder.decode(KeyframeManifest.self, from: Data(contentsOf: manifestURL))
                loaded.append(SavedSession(id: manifest.id, directory: entry, manifest: manifest))
            } else {
                // 关键帧目录内的导出视频属于该录制，不能作为独立视频删除整个源目录。
                let candidates = try fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
                    .filter { url in
                        guard url.pathExtension.lowercased() == "mp4", url.lastPathComponent != ".recording.partial.mp4" else { return false }
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        return values.isRegularFile == true && values.isSymbolicLink != true
                    }
                guard candidates.count <= 1 else { throw BatchRenameError.multipleVideos(entry) }
                guard let found = candidates.first else { continue }
                let videoURL = entry.appendingPathComponent(found.lastPathComponent)
                loadedVideos.append(videoURL)
            }
            tags[entry] = try Self.readRecordingTag(at: entry)
        }
        return (loaded, loadedVideos, tags)
    }

    nonisolated private static func readRecordingTag(at directory: URL) throws -> AssetTag? {
        let file = directory.appendingPathComponent(".framevault-tag")
        do {
            let value = try String(contentsOf: file, encoding: .utf8)
            guard let tag = AssetTag(rawValue: value) else { throw LibraryError.invalidTag(file) }
            return tag
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func deleteSession(_ session: SavedSession) throws {
        try withImageLock {
            try reloadImages()
            try storageDirectoryAccess.requireAccess(to: session.directory)
            let trashed = try trashImageDirectory(session.directory)
            do { try database.removeCollectionAsset(.session(session.id)) }
            catch {
                do { try fileManager.moveItem(at: trashed, to: session.directory) }
                catch let rollback { throw KeyframeRecordingError.multipleFailures(error, rollback) }
                throw error
            }
            removePublishedCollectionAsset(.session(session.id))
        }
        sessions.removeAll { $0.id == session.id }
        recordingTags[session.directory] = nil
        scheduleStorageRefresh()
        if let first = session.manifest.frames.first {
            Task { await thumbnails.invalidate([session.directory.appendingPathComponent(first.file)]) }
        }
    }

    func deleteVideo(_ url: URL) throws {
        try withImageLock {
            try reloadImages()
            let directory = url.deletingLastPathComponent()
            try storageDirectoryAccess.requireAccess(to: directory)
            let trashed = try trashImageDirectory(directory)
            do { try database.removeCollectionAsset(.video(url)) }
            catch {
                do { try fileManager.moveItem(at: trashed, to: directory) }
                catch let rollback { throw KeyframeRecordingError.multipleFailures(error, rollback) }
                throw error
            }
            removePublishedCollectionAsset(.video(url))
        }
        videos.removeAll { $0 == url }
        recordingTags[url.deletingLastPathComponent()] = nil
        scheduleStorageRefresh()
        Task { await thumbnails.invalidate([url]) }
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LibraryError.imageWrite
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.imageWrite }
    }

    // GUI 与 CLI 可能同时写同一保管箱；锁内重新读取索引，避免旧进程覆盖新条目。
    private func withImageLock<T>(_ action: () throws -> T) throws -> T {
        try Self.withImageLock(at: root, action)
    }

    nonisolated private static func withImageLock<T>(at root: URL, cancellable: Bool = false, _ action: () throws -> T) throws -> T {
        let descriptor = open(root.appendingPathComponent(".images.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        if cancellable {
            while true {
                try AutomationAccess.check()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
                let code = errno
                guard code == EWOULDBLOCK || code == EINTR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                usleep(20_000)
            }
        } else {
            guard flock(descriptor, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    static func captureName(_ source: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(source) \(formatter.string(from: Date())).png"
    }
}
