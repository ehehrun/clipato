import AppKit
import CSQLite
import Darwin
import XCTest
@testable import Clipato

@MainActor
final class LibraryStoragePolicyTests: XCTestCase {
    func testPolicyDefaultsPersistAndInvalidChangeDoesNotReplaceSavedPolicy() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        XCTAssertEqual(library.storagePolicy, LibraryStoragePolicy())
        XCTAssertTrue(library.storagePolicy.protectCollectedImages)
        let policy = LibraryStoragePolicy(maximumBytes: 500, automaticallyRemoveOldestImages: false,
                                          protectTaggedImages: false, protectCollectedImages: false, keepRecentDays: 0)
        try library.updateStoragePolicy(policy)
        XCTAssertEqual(try LibraryStore(root: library.root).storagePolicy, policy)
        XCTAssertThrowsError(try library.updateStoragePolicy(.init(maximumBytes: -1)))
        XCTAssertEqual(library.storagePolicy, policy)
        XCTAssertEqual(try LibraryDatabase(root: library.root).storagePolicy(), policy)
        await library.refreshStorageUsage()
    }

    func testLimitOnlyCountsMediaAndAutomaticRemovalIsOptIn() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try addFile(to: library, size: 100, daysOld: 30)
        let cache = directory.appendingPathComponent("Owned Cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 1_000).write(to: cache.appendingPathComponent("cache.bin"))
        library.setCacheDirectories([cache])
        try library.updateStoragePolicy(.init(maximumBytes: 150))
        await library.refreshStorageUsage()
        XCTAssertEqual(library.storageUsage?.imageBytes, 100)
        XCTAssertEqual(library.storageUsage?.cacheBytes, 1_000)
        XCTAssertNil(library.storageUsageError)
        XCTAssertTrue(library.storageUsage!.totalBytes > 1_100)

        try library.updateStoragePolicy(.init(maximumBytes: 1))
        await library.refreshStorageUsage()
        XCTAssertEqual(library.images.map(\.id), [image.id])
        XCTAssertEqual(library.storageUsageError, L("媒体容量已超过上限，自动清理未开启。"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testAutomaticRemovalUsesOldestFirstAndProtectsTagsRecentImagesPinsAndRecordings() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let oldest = try addFile(to: library, size: 100, daysOld: 60)
        let old = try addFile(to: library, size: 100, daysOld: 30)
        let tagged = try addFile(to: library, size: 100, daysOld: 90, tag: .red)
        let recent = try addFile(to: library, size: 100, daysOld: 1)
        let pinned = try addFile(to: library, size: 100, daysOld: 100)
        let video = library.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: false)
        try Data(repeating: 2, count: 200).write(to: video.appendingPathComponent("recording.mp4"))
        try library.reloadSessions()
        library.setProtectedImageIDs([pinned.id])
        try library.updateStoragePolicy(.init(maximumBytes: 600, automaticallyRemoveOldestImages: true))

        await library.refreshStorageUsage()

        XCTAssertEqual(Set(library.images.map(\.id)), [old.id, tagged.id, recent.id, pinned.id])
        XCTAssertEqual(library.storageUsage?.mediaBytes, 600)
        XCTAssertNil(library.storageUsageError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(oldest).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Trash").appendingPathComponent(oldest.id.uuidString).path))
        XCTAssertEqual(try Data(contentsOf: video.appendingPathComponent("recording.mp4")).count, 200)

        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true))
        await library.refreshStorageUsage()
        XCTAssertEqual(Set(library.images.map(\.id)), [tagged.id, recent.id, pinned.id])
        XCTAssertEqual(library.storageUsageError, L("媒体容量仍超过上限；其余图片受到保留规则保护，录屏不会自动清理。"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.appendingPathComponent("recording.mp4").path))
    }

    func testNewCaptureIsProtectedForItsBatchButNotForever() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                             protectTaggedImages: false, keepRecentDays: 0))
        let image = try library.addImage(try XCTUnwrap(context.makeImage()), source: "截图")
        await library.refreshStorageUsage()
        XCTAssertEqual(library.images.map(\.id), [image.id])
        XCTAssertEqual(library.storageUsageError, L("媒体容量仍超过上限；其余图片受到保留规则保护，录屏不会自动清理。"))

        await library.refreshStorageUsage()
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(library.storageUsage?.mediaBytes, 0)
    }

    func testAutomaticRemovalProtectsCollectedImagesByDefaultAndDeletesOldestUncollectedImage() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let collected = try addFile(to: library, size: 100, daysOld: 90)
        let oldestUncollected = try addFile(to: library, size: 100, daysOld: 60)
        let newerUncollected = try addFile(to: library, size: 100, daysOld: 30)
        let collection = try library.createCollection(name: "工作")
        try library.addToCollection(collection.id, assets: [.image(collected.id)])
        try library.updateStoragePolicy(.init(maximumBytes: 200, automaticallyRemoveOldestImages: true,
                                             protectTaggedImages: false, keepRecentDays: 0))

        await library.refreshStorageUsage()

        XCTAssertEqual(Set(library.images.map(\.id)), [collected.id, newerUncollected.id])
        XCTAssertEqual(library.storageUsage?.mediaBytes, 200)
        XCTAssertNil(library.storageUsageError)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(collected)).count, 100)
        XCTAssertEqual(library.assets(in: collection.id), [.image(collected.id)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(oldestUncollected).path))
        let trash = directory.appendingPathComponent("Trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [oldestUncollected.id.uuidString])
    }

    func testExplicitlyDisablingCollectionProtectionAllowsCleanupAndRemovesAllMemberships() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try addFile(to: library, size: 100, daysOld: 30)
        let first = try library.createCollection(name: "工作")
        let second = try library.createCollection(name: "素材")
        try library.addToCollection(first.id, assets: [.image(image.id)])
        try library.addToCollection(second.id, assets: [.image(image.id)])
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                             protectTaggedImages: false, protectCollectedImages: false, keepRecentDays: 0))

        await library.refreshStorageUsage()

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(library.storageUsage?.mediaBytes, 0)
        XCTAssertNil(library.storageUsageError)
        XCTAssertEqual(Set(library.collections.map(\.id)), [first.id, second.id])
        XCTAssertTrue(library.assets(in: first.id).isEmpty)
        XCTAssertTrue(library.assets(in: second.id).isEmpty)
        let trashed = directory.appendingPathComponent("Trash").appendingPathComponent(image.id.uuidString).appendingPathComponent(image.filename)
        XCTAssertEqual(try Data(contentsOf: trashed).count, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(image).path))
    }

    func testImageCollectedWhileCleanupWaitsForLockIsProtected() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try addFile(to: library, size: 100, daysOld: 60)
        let collection = try library.createCollection(name: "待整理")
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                             protectTaggedImages: false, keepRecentDays: 0))
        let descriptor = open(library.root.appendingPathComponent(".images.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let refresh = Task { await library.refreshStorageUsage() }
        try await Task.sleep(for: .milliseconds(50))
        // This writer owns the file lock; cleanup must read its new membership after acquiring it.
        try LibraryDatabase(root: library.root).addToCollection(collection.id, assets: [.image(image.id)])
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await refresh.value

        XCTAssertEqual(library.images.map(\.id), [image.id])
        XCTAssertEqual(library.storageUsage?.imageBytes, 100)
        XCTAssertEqual(library.assets(in: collection.id), [.image(image.id)])
        XCTAssertEqual(library.storageUsageError, L("媒体容量仍超过上限；其余图片受到保留规则保护，录屏不会自动清理。"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testMissingMediaPausesAutomaticRemovalInsteadOfAssumingZeroSize() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let old = try addFile(to: library, size: 100, daysOld: 30)
        let missing = try addFile(to: library, size: 100, daysOld: 60)
        try FileManager.default.removeItem(at: library.imageURL(missing))
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true))

        await library.refreshStorageUsage()

        XCTAssertEqual(library.storageUsage?.isComplete, false)
        XCTAssertEqual(library.storageUsageError, L("部分文件无法访问，当前容量不完整；已暂停自动清理。\n") + library.storageUsage!.unavailablePaths.joined(separator: "\n"))
        XCTAssertEqual(Set(library.images.map(\.id)), [old.id, missing.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(old).path))
    }

    func testFailedIndexDeleteRestoresTrashedImageAndReportsCleanupFailure() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try addFile(to: library, size: 100, daysOld: 60)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_cleanup BEFORE DELETE ON images BEGIN SELECT RAISE(ABORT, 'cleanup denied'); END", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true))

        await library.refreshStorageUsage()

        XCTAssertEqual(library.images.map(\.id), [image.id])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(image)).count, 100)
        XCTAssertTrue(library.storageUsageError!.contains("cleanup denied"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testPinAddedDuringCleanupLockWaitIsRespectedWithoutStartingAnotherScan() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try addFile(to: library, size: 100, daysOld: 60)
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true))
        let descriptor = open(library.root.appendingPathComponent(".images.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let refresh = Task { await library.refreshStorageUsage() }
        try await Task.sleep(for: .milliseconds(50))
        library.setProtectedImageIDs([image.id])
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await refresh.value

        XCTAssertEqual(library.images.map(\.id), [image.id])
        XCTAssertEqual(library.storageUsage?.imageBytes, 100)
        XCTAssertEqual(library.storageUsageError, L("媒体容量仍超过上限；其余图片受到保留规则保护，录屏不会自动清理。"))
    }

    private func makeLibrary(in directory: URL) throws -> LibraryStore {
        let root = directory.appendingPathComponent("Vault")
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        return try LibraryStore(root: root, trashImageDirectory: { source in
            guard source.path.hasPrefix(root.path + "/Images/") else { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
    }

    private func addFile(to library: LibraryStore, size: Int, daysOld: Int, tag: AssetTag? = nil) throws -> VaultImage {
        let image = VaultImage(id: UUID(), filename: "image.png", createdAt: Date().addingTimeInterval(-Double(daysOld) * 86_400),
                               width: 2, height: 2, source: "截图", tag: tag)
        let url = library.imageURL(image)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data(repeating: 1, count: size).write(to: url)
        try LibraryDatabase(root: library.root).insert(image)
        try library.reloadImages()
        return image
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-StoragePolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
