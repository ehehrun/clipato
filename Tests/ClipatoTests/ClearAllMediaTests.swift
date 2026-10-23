import AppKit
import CSQLite
import Combine
import Darwin
import XCTest
@testable import Clipato

@MainActor
final class ClearAllMediaTests: XCTestCase {
    func testClearTrashesManagedMediaAcrossCustomLocationsAndRemovesCollectionsWhileKeepingSettingsAndUnrelatedFiles() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let first = try library.addImage(pixels(), source: "截图", filename: "default.png", tag: .blue)
        let screenshotRoot = directory.appendingPathComponent("Custom Images")
        let recordingRoot = directory.appendingPathComponent("Custom Recordings")
        for root in [screenshotRoot, recordingRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        try library.setStorageDirectory(screenshotRoot, for: .screenshots)
        let second = try library.addImage(pixels(), source: "截图", filename: "custom.png")
        let legacy = try makeSession(in: library.root.appendingPathComponent("Sessions"), name: "legacy-session")
        try Data("video exported alongside keyframes".utf8).write(to: legacy.directory.appendingPathComponent("export.mp4"))
        try library.setStorageDirectory(recordingRoot, for: .recordings)
        let video = try makeVideo(in: recordingRoot)
        try library.reloadSessions()
        let collection = try library.createCollection(name: "保留收藏夹")
        try library.setCollectionColor(collection.id, color: .purple)
        try library.addToCollection(collection.id, assets: [.image(first.id), .image(second.id), .session(legacy.id), .video(video)])
        try library.updateStoragePolicy(.init(maximumBytes: 4096, keepRecentDays: 3))
        let settings = library.storage
        let policy = library.storagePolicy
        let media = [library.imageURL(first), library.imageURL(second),
                     legacy.directory.appendingPathComponent("frame.png"), legacy.directory.appendingPathComponent("export.mp4"), video]
        let contents = try media.map { ($0, try Data(contentsOf: $0)) }
        let unrelated = [library.root.appendingPathComponent("notes.txt"), screenshotRoot.appendingPathComponent("loose.png"),
                         recordingRoot.appendingPathComponent("personal.mp4")]
        for url in unrelated { try Data("unmanaged file".utf8).write(to: url) }

        try await library.clearAllMedia(options: .init())

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertNil(try library.recentImage())
        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertEqual(library.assets(in: collection.id), [])
        XCTAssertEqual(library.storage, settings)
        XCTAssertEqual(library.storagePolicy, policy)
        let trash = directory.appendingPathComponent("Trash")
        for (source, bytes) in contents {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            let trashed = trash.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent).appendingPathComponent(source.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: trashed), bytes)
        }
        for url in unrelated { XCTAssertEqual(try Data(contentsOf: url), Data("unmanaged file".utf8)) }
        for root in [library.root, screenshotRoot, recordingRoot] { XCTAssertTrue(FileManager.default.fileExists(atPath: root.path)) }
        let reopened = try reopen(library.root)
        XCTAssertTrue(reopened.images.isEmpty)
        XCTAssertTrue(reopened.sessions.isEmpty)
        XCTAssertTrue(reopened.videos.isEmpty)
        XCTAssertNil(try reopened.recentImage())
        XCTAssertTrue(reopened.collections.isEmpty)
        XCTAssertEqual(reopened.assets(in: collection.id), [])
        XCTAssertEqual(reopened.storage, settings)
        XCTAssertEqual(reopened.storagePolicy, policy)
    }

    func testTrashFailureKeepsSuccessfulDeletesPublishedAndClearsHistoryWithoutClaimingTheRestWasRemoved() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory, deniedFilename: "denied.png")
        let denied = try library.addImage(pixels(), source: "截图", filename: "denied.png")
        let removable = try library.addImage(pixels(), source: "截图", filename: "removable.png")
        let session = try makeSession(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()
        let collection = try library.createCollection(name: "保留")
        try library.addToCollection(collection.id, assets: [.image(denied.id), .image(removable.id), .session(session.id)])

        await expectClearFailure(in: library) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }

        XCTAssertEqual(library.images, [denied])
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(library.assets(in: collection.id), [.image(denied.id), .session(session.id)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(denied).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(removable).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Trash").appendingPathComponent(removable.id.uuidString).path))
        let reopened = try reopen(library.root)
        XCTAssertEqual(reopened.images, [denied])
        XCTAssertNil(try reopened.recentImage())
        XCTAssertEqual(reopened.assets(in: collection.id), [.image(denied.id), .session(session.id)])
    }

    func testMissingImageDirectoryReportsFailureAndKeepsItsIndexWhileClearingHistory() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let missing = library.imageURL(image).deletingLastPathComponent()
        let moved = directory.appendingPathComponent("Offline Image")
        try FileManager.default.moveItem(at: missing, to: moved)

        await expectClearFailure(in: library)

        XCTAssertEqual(library.images, [image])
        XCTAssertNil(try library.recentImage())
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(image.filename).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        XCTAssertEqual(try reopen(library.root).images, [image])
    }

    func testUnavailableRecordingLocationStopsBeforeTrashingOtherMediaAndClearsHistory() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let recordingRoot = directory.appendingPathComponent("External Recordings")
        try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: false)
        try library.setStorageDirectory(recordingRoot, for: .recordings)
        let session = try makeSession(in: recordingRoot)
        try library.reloadSessions()
        let offline = directory.appendingPathComponent("Offline Recordings")
        try FileManager.default.moveItem(at: recordingRoot, to: offline)

        await expectClearFailure(in: library) { error in
            XCTAssertTrue(error.localizedDescription.contains(recordingRoot.path))
        }

        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertNil(try library.recentImage())
        XCTAssertFalse(library.recordingReadErrors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: offline.appendingPathComponent(session.directory.lastPathComponent).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testUnreadableRecordingLocationDoesNotDeleteOtherMedia() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Directory permissions do not restrict root.") }
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let recordingRoot = directory.appendingPathComponent("Unreadable Recordings")
        try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: false)
        try library.setStorageDirectory(recordingRoot, for: .recordings)
        _ = try makeVideo(in: recordingRoot)
        try library.reloadSessions()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: recordingRoot.path)
        addTeardownBlock { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordingRoot.path) }

        await expectClearFailure(in: library)

        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(library.videos.count, 1)
        XCTAssertNil(try library.recentImage())
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testFailedDatabaseDeleteRestoresTrashedImageAndLeavesHistoryCleared() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let bytes = try Data(contentsOf: library.imageURL(image))
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TRIGGER reject_clear BEFORE DELETE ON images BEGIN SELECT RAISE(ABORT, 'clear denied'); END", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(connection), SQLITE_OK)

        await expectClearFailure(in: library) { error in XCTAssertTrue(error.localizedDescription.contains("clear denied")) }

        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(image)), bytes)
        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(try reopen(library.root).images, [image])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testSharedImageParentIsNeverTrashed() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let shared = directory.appendingPathComponent("Shared Images")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        let image = VaultImage(id: UUID(), filename: "legacy.png", createdAt: Date(), width: 3, height: 2,
                               source: "导入", directory: shared)
        try LibraryStore.writePNG(pixels(), to: shared.appendingPathComponent(image.filename))
        let unrelated = shared.appendingPathComponent("personal.txt")
        try Data("keep".utf8).write(to: unrelated)
        try LibraryDatabase(root: library.root).insert(image)

        await expectClearFailure(in: library)

        XCTAssertEqual(library.images, [image])
        XCTAssertNil(try library.recentImage())
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent(image.filename).path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testClearRemovesCollectionsAndOrphanMembershipsWithoutRemovingMovedFiles() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let session = try makeSession(in: library.root.appendingPathComponent("Sessions"))
        let video = try makeVideo(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()
        let first = try library.createCollection(name: "工作")
        let second = try library.createCollection(name: "灵感")
        try library.setCollectionColor(second.id, color: .green)
        let members: Set<CollectionAsset> = [.image(image.id), .session(session.id), .video(video)]
        for collection in [first, second] { try library.addToCollection(collection.id, assets: members) }
        let movedSession = directory.appendingPathComponent("Finder Moved Session")
        let movedVideo = directory.appendingPathComponent("Finder Moved Video")
        try FileManager.default.moveItem(at: session.directory, to: movedSession)
        try FileManager.default.moveItem(at: video.deletingLastPathComponent(), to: movedVideo)
        try library.reloadSessions()
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertEqual(library.assets(in: first.id), members)

        try await library.clearAllMedia(options: .init())

        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertEqual(library.assets(in: first.id), [])
        XCTAssertEqual(library.assets(in: second.id), [])
        XCTAssertEqual(try Data(contentsOf: movedVideo.appendingPathComponent(video.lastPathComponent)), Data("recorded video".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSession.appendingPathComponent("frame.png").path))
        let reopened = try reopen(library.root)
        XCTAssertTrue(reopened.collections.isEmpty)
        XCTAssertTrue(reopened.collectionMembers.values.allSatisfy(\.isEmpty))
        XCTAssertNil(try reopened.recentImage())
    }

    func testOrphanMembershipDeleteFailureIsReportedAndDoesNotFalsifyPublishedState() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let collection = try library.createCollection(name: "保留")
        let orphan = CollectionAsset.session(UUID())
        let database = try LibraryDatabase(root: library.root)
        try database.addToCollection(collection.id, assets: [orphan])
        try library.reloadImages()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TRIGGER reject_members_clear BEFORE DELETE ON collectionMembers BEGIN SELECT RAISE(ABORT, 'members clear denied'); END", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(connection), SQLITE_OK)

        await expectClearFailure(in: library) { error in XCTAssertTrue(error.localizedDescription.contains("members clear denied")) }

        XCTAssertEqual(library.assets(in: collection.id), [orphan])
        XCTAssertEqual(try database.collectionState().1[collection.id], [orphan])
        XCTAssertEqual(library.collections, [collection])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testMediaAddedDuringClearSurvivesWithItsCollectionAndReportsConcurrentChange() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try pixels()
        for index in 0..<33 {
            _ = try library.addImage(image, source: "截图", filename: "old-\(index).png")
        }
        let collection = try library.createCollection(name: "并发新增素材")
        let writer = try reopen(library.root)
        var writeTask: Task<VaultImage, Error>?
        let subscription = library.$images.dropFirst().sink { remaining in
            guard remaining.count == 1, writeTask == nil else { return }
            writeTask = Task(priority: .high) { @MainActor in
                let fresh = try writer.addImage(image, source: "截图", filename: "new-during-clear.png")
                try writer.addToCollection(collection.id, assets: [.image(fresh.id)])
                return fresh
            }
        }
        defer { subscription.cancel() }
        let clearTask = Task(priority: .low) { @MainActor in try await library.clearAllMedia(options: .init()) }

        do {
            try await clearTask.value
            XCTFail("Clear must report media created after the initial snapshot.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("清空期间媒体内容发生变化，请重试。"))
        }

        let pendingWrite = try XCTUnwrap(writeTask)
        let fresh = try await pendingWrite.value
        XCTAssertEqual(library.images, [fresh])
        XCTAssertEqual(library.assets(in: collection.id), [.image(fresh.id)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(fresh).path))
        let reopened = try reopen(library.root)
        XCTAssertEqual(reopened.images, [fresh])
        XCTAssertEqual(reopened.assets(in: collection.id), [.image(fresh.id)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).count, 33)
    }

    func testImagesOnlyPreservesRecordingsCollectionsAndTheirMemberships() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let session = try makeSession(in: library.root.appendingPathComponent("Sessions"))
        let video = try makeVideo(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()
        let collection = try library.createCollection(name: "保留录屏")
        try library.addToCollection(collection.id, assets: [.image(image.id), .session(session.id), .video(video)])

        try await library.clearAllMedia(options: .init(images: true, recordings: false, collections: false, history: false))

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertEqual(library.videos, [video])
        XCTAssertEqual(library.collections, [collection])
        XCTAssertEqual(library.assets(in: collection.id), [.session(session.id), .video(video)])
        XCTAssertNil(try library.recentImage(), "A deleted image cannot remain as the recent image even when history was not selected.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        let reopened = try reopen(library.root)
        XCTAssertEqual(reopened.collections, [collection])
        XCTAssertEqual(reopened.assets(in: collection.id), [.session(session.id), .video(video)])
    }

    func testRecordingsOnlyPreservesImagesCollectionsAndHistory() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let session = try makeSession(in: library.root.appendingPathComponent("Sessions"))
        let video = try makeVideo(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()
        let collection = try library.createCollection(name: "保留图片")
        try library.addToCollection(collection.id, assets: [.image(image.id), .session(session.id), .video(video)])

        try await library.clearAllMedia(options: .init(images: false, recordings: true, collections: false, history: false))

        XCTAssertEqual(library.images, [image])
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertEqual(library.collections, [collection])
        XCTAssertEqual(library.assets(in: collection.id), [.image(image.id)])
        XCTAssertEqual(try library.recentImage(), image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertEqual(try reopen(library.root).assets(in: collection.id), [.image(image.id)])
    }

    func testCollectionsOnlyRemovesFoldersAndRelationsWithoutTrashingMediaOrClearingHistory() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let session = try makeSession(in: library.root.appendingPathComponent("Sessions"))
        let video = try makeVideo(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()
        let first = try library.createCollection(name: "工作")
        let second = try library.createCollection(name: "灵感")
        for collection in [first, second] {
            try library.addToCollection(collection.id, assets: [.image(image.id), .session(session.id), .video(video)])
        }

        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: true, history: false))

        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertTrue(library.collectionMembers.isEmpty)
        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertEqual(library.videos, [video])
        XCTAssertEqual(try library.recentImage(), image)
        for url in [library.imageURL(image), session.directory, video] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        let reopened = try reopen(library.root)
        XCTAssertTrue(reopened.collections.isEmpty)
        XCTAssertTrue(reopened.collectionMembers.isEmpty)
        XCTAssertEqual(try reopened.recentImage(), image)
    }

    func testHistoryOnlyPreservesMediaAndCollections() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let session = try makeSession(in: library.root.appendingPathComponent("Sessions"))
        let video = try makeVideo(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()
        let collection = try library.createCollection(name: "保留")
        let assets: Set<CollectionAsset> = [.image(image.id), .session(session.id), .video(video)]
        try library.addToCollection(collection.id, assets: assets)

        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: false, history: true))

        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertEqual(library.videos, [video])
        XCTAssertEqual(library.collections, [collection])
        XCTAssertEqual(library.assets(in: collection.id), assets)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        XCTAssertNil(try reopen(library.root).recentImage())
    }

    func testNothingSelectedDoesNotChangeMediaCollectionsOrHistory() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let collection = try library.createCollection(name: "保留")
        try library.addToCollection(collection.id, assets: [.image(image.id)])
        let options = LibraryCleanupOptions(images: false, recordings: false, collections: false, history: false)
        XCTAssertTrue(options.isEmpty)
        XCTAssertFalse(LibraryCleanupOptions().isEmpty)

        try await library.clearAllMedia(options: options)

        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(library.collections, [collection])
        XCTAssertEqual(library.assets(in: collection.id), [.image(image.id)])
        XCTAssertEqual(try library.recentImage(), image)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
    }

    func testUnselectedUnavailableRecordingsDoNotBlockImageCollectionOrHistoryCleanup() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let recordingRoot = directory.appendingPathComponent("External Recordings")
        try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: false)
        try library.setStorageDirectory(recordingRoot, for: .recordings)
        let session = try makeSession(in: recordingRoot)
        try library.reloadSessions()
        let collection = try library.createCollection(name: "离线收藏夹")
        try library.addToCollection(collection.id, assets: [.image(image.id), .session(session.id)])
        let offline = directory.appendingPathComponent("Offline Recordings")
        try FileManager.default.moveItem(at: recordingRoot, to: offline)

        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: false, history: true))
        XCTAssertNil(try library.recentImage())
        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: true, history: false))
        XCTAssertTrue(library.collections.isEmpty)
        try await library.clearAllMedia(options: .init(images: true, recordings: false, collections: false, history: false))

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: offline.appendingPathComponent(session.directory.lastPathComponent).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path), [image.id.uuidString])
    }

    func testRecordingCleanupDoesNotInspectUnselectedLegacyImageParent() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let shared = directory.appendingPathComponent("Shared Images")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        let image = VaultImage(id: UUID(), filename: "legacy.png", createdAt: Date(), width: 3, height: 2, source: "导入", directory: shared)
        try LibraryStore.writePNG(pixels(), to: shared.appendingPathComponent(image.filename))
        try LibraryDatabase(root: library.root).insert(image, remember: true)
        let video = try makeVideo(in: library.root.appendingPathComponent("Sessions"))
        try library.reloadSessions()

        try await library.clearAllMedia(options: .init(images: false, recordings: true, collections: false, history: false))

        XCTAssertEqual(try library.recentImage(), image)
        XCTAssertEqual(library.images, [image])
        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent(image.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
    }

    func testImageFailureDoesNotClearUnselectedHistoryOrCollections() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory, deniedFilename: "denied.png")
        let image = try library.addImage(pixels(), source: "截图", filename: "denied.png")
        let collection = try library.createCollection(name: "保留")
        try library.addToCollection(collection.id, assets: [.image(image.id)])

        await expectClearFailure(in: library, options: .init(images: true, recordings: false, collections: false, history: false)) {
            XCTAssertEqual(($0 as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }

        XCTAssertEqual(try library.recentImage(), image)
        XCTAssertEqual(library.collections, [collection])
        XCTAssertEqual(library.assets(in: collection.id), [.image(image.id)])
    }

    func testCollectionDeleteFailureRollsBackAllFoldersAndMemberships() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let first = try library.createCollection(name: "一")
        let second = try library.createCollection(name: "二")
        for collection in [first, second] { try library.addToCollection(collection.id, assets: [.image(image.id)]) }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        let sql = "CREATE TRIGGER reject_collection_clear BEFORE DELETE ON collections WHEN OLD.id = '\(second.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'collection clear denied'); END"
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(connection), SQLITE_OK)

        await expectClearFailure(in: library, options: .init(images: false, recordings: false, collections: true, history: false)) {
            XCTAssertTrue($0.localizedDescription.contains("collection clear denied"))
        }

        XCTAssertEqual(library.collections, [first, second])
        XCTAssertEqual(library.assets(in: first.id), [.image(image.id)])
        XCTAssertEqual(library.assets(in: second.id), [.image(image.id)])
        let reopened = try reopen(library.root)
        XCTAssertEqual(reopened.collections, [first, second])
        XCTAssertEqual(reopened.assets(in: first.id), [.image(image.id)])
        XCTAssertEqual(reopened.assets(in: second.id), [.image(image.id)])
        XCTAssertEqual(try reopened.recentImage(), image)
    }

    func testNewUnselectedRecordingDuringImageCleanupSurvivesWithoutBlockingCompletion() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try pixels()
        for index in 0..<33 { _ = try library.addImage(image, source: "截图", filename: "old-\(index).png") }
        let collection = try library.createCollection(name: "新增录屏")
        let writer = try reopen(library.root)
        var writeTask: Task<URL, Error>?
        let subscription = library.$images.dropFirst().sink { remaining in
            guard remaining.count == 1, writeTask == nil else { return }
            writeTask = Task(priority: .high) { @MainActor in
                let video = try self.makeVideo(in: library.root.appendingPathComponent("Sessions"))
                try writer.reloadSessions()
                try writer.addToCollection(collection.id, assets: [.video(video)])
                return video
            }
        }
        defer { subscription.cancel() }
        let clearTask = Task(priority: .low) { @MainActor in
            try await library.clearAllMedia(options: .init(images: true, recordings: false, collections: false, history: false))
        }

        try await clearTask.value
        let pendingWrite = try XCTUnwrap(writeTask)
        let video = try await pendingWrite.value
        try library.reloadSessions()
        try library.reloadImages()
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(library.videos, [video])
        XCTAssertEqual(library.collections, [collection])
        XCTAssertEqual(library.assets(in: collection.id), [.video(video)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testCollectionCleanupAndUsageRefreshNeverApplyQuotaToUnselectedImages() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        let collection = try library.createCollection(name: "保护图片")
        try library.addToCollection(collection.id, assets: [.image(image.id)])
        let policy = LibraryStoragePolicy(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                          protectTaggedImages: false, keepRecentDays: 0)
        try library.updateStoragePolicy(policy)
        await library.refreshStorageUsage()
        XCTAssertEqual(library.images, [image])

        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: true, history: false))
        await library.refreshStorageUsage(enforceQuota: false)

        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(library.storagePolicy, policy)
        XCTAssertGreaterThan(try XCTUnwrap(library.storageUsage).imageBytes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        XCTAssertFalse(library.hasPendingStorageWork)
    }

    func testCleanupCancelsPendingQuotaBeforeChangingOnlyHistory() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        await library.refreshStorageUsage(enforceQuota: false)
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                             protectTaggedImages: false, keepRecentDays: 0))
        XCTAssertTrue(library.hasPendingStorageWork)

        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: false, history: true))
        await library.refreshStorageUsage(enforceQuota: false)

        XCTAssertEqual(library.images, [image])
        XCTAssertNil(try library.recentImage())
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        XCTAssertFalse(library.hasPendingStorageWork)
    }

    func testRefreshDuringRecordingCleanupDoesNotApplyQuotaAndNormalRefreshResumesAfterward() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try library.addImage(pixels(), source: "截图")
        for _ in 0..<32 { _ = try makeVideo(in: library.root.appendingPathComponent("Sessions")) }
        try library.reloadSessions()
        await library.refreshStorageUsage(enforceQuota: false)
        try library.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                             protectTaggedImages: false, keepRecentDays: 0))
        var refreshTask: Task<Void, Never>?
        let subscription = library.$videos.dropFirst().sink { remaining in
            guard remaining.isEmpty, refreshTask == nil else { return }
            refreshTask = Task(priority: .high) { @MainActor in await library.refreshStorageUsage() }
        }
        defer { subscription.cancel() }
        let clearTask = Task(priority: .low) { @MainActor in
            try await library.clearAllMedia(options: .init(images: false, recordings: true, collections: false, history: false))
        }

        try await clearTask.value
        await (try XCTUnwrap(refreshTask)).value

        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertEqual(library.images, [image])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertFalse(library.hasPendingStorageWork)
        await library.refreshStorageUsage()
        XCTAssertTrue(library.images.isEmpty, "Quota must resume for a later ordinary refresh.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(image).path))
    }

    func testReentrantCleanupIsRejectedAndLaterCleanupCanProceed() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try pixels()
        for _ in 0..<33 { _ = try library.addImage(image, source: "截图") }
        var secondTask: Task<Bool, Never>?
        let subscription = library.$images.dropFirst().sink { remaining in
            guard remaining.count == 1, secondTask == nil else { return }
            secondTask = Task(priority: .high) { @MainActor in
                do {
                    try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: false, history: true))
                    return false
                } catch { return error.localizedDescription == L("正在清理…") }
            }
        }
        defer { subscription.cancel() }
        let firstTask = Task(priority: .low) { @MainActor in
            try await library.clearAllMedia(options: .init(images: true, recordings: false, collections: false, history: false))
        }

        try await firstTask.value
        let rejected = await (try XCTUnwrap(secondTask)).value
        XCTAssertTrue(rejected)
        XCTAssertTrue(library.images.isEmpty)
        _ = try library.addImage(image, source: "截图")
        try await library.clearAllMedia(options: .init(images: false, recordings: false, collections: false, history: true))
        XCTAssertNil(try library.recentImage())
    }

    func testCancelledCleanupLeavesRemainingMediaAndAllowsRetry() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let image = try pixels()
        for _ in 0..<33 { _ = try library.addImage(image, source: "截图") }
        var clearTask: Task<Void, Error>?
        var cancellationTask: Task<Void, Never>?
        let subscription = library.$images.dropFirst().sink { remaining in
            guard remaining.count == 1, cancellationTask == nil else { return }
            cancellationTask = Task(priority: .high) { @MainActor in clearTask!.cancel() }
        }
        defer { subscription.cancel() }
        clearTask = Task(priority: .low) { @MainActor in
            try await library.clearAllMedia(options: .init(images: true, recordings: false, collections: false, history: false))
        }

        do {
            try await clearTask!.value
            XCTFail("Cancellation must stop before the next batch.")
        } catch { XCTAssertTrue(error is CancellationError) }
        await (try XCTUnwrap(cancellationTask)).value
        XCTAssertEqual(library.images.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(library.images[0]).path))

        try await library.clearAllMedia(options: .init(images: true, recordings: false, collections: false, history: false))
        XCTAssertTrue(library.images.isEmpty)
    }

    private func expectClearFailure(in library: LibraryStore, options: LibraryCleanupOptions = .init(), file: StaticString = #filePath, line: UInt = #line,
                                    verify: (Error) -> Void = { _ in }) async {
        do {
            try await library.clearAllMedia(options: options)
            XCTFail("Expected clear to fail.", file: file, line: line)
        } catch { verify(error) }
    }

    private func makeLibrary(in directory: URL, deniedFilename: String? = nil) throws -> LibraryStore {
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let defaults = try isolatedDefaults()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"), defaults: defaults,
            trashImageDirectory: { source in
                if let deniedFilename, FileManager.default.fileExists(atPath: source.appendingPathComponent(deniedFilename).path) {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: source.path])
                }
                let destination = trash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            })
        addTeardownBlock { await library.cancelStorageWorkAndWait() }
        return library
    }

    private func reopen(_ root: URL) throws -> LibraryStore {
        let library = try LibraryStore(root: root, defaults: isolatedDefaults())
        addTeardownBlock { await library.cancelStorageWorkAndWait() }
        return library
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "Clipato.ClearAllMedia.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeSession(in root: URL, name: String = UUID().uuidString) throws -> SavedSession {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try LibraryStore.writePNG(pixels(), to: directory.appendingPathComponent("frame.png"))
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 1, sampleRate: 1,
                                        threshold: 0.025, width: 3, height: 2, frames: [.init(file: "frame.png", time: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return SavedSession(id: manifest.id, directory: directory, manifest: manifest)
    }

    private func makeVideo(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("recording.mp4")
        try Data("recorded video".utf8).write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ClearAllMedia.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
