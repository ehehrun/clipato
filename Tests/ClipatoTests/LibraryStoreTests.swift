import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import CSQLite
import Darwin
@testable import Clipato

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testImportPreservesOriginalFilenameBytesAndDimensionsAcrossReload() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("原始 Screenshot 01.PNG")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)

        try library.importImages([original])

        let item = try XCTUnwrap(library.images.first)
        XCTAssertEqual(item.filename, original.lastPathComponent)
        XCTAssertEqual(item.source, "导入")
        XCTAssertEqual(item.width, 3)
        XCTAssertEqual(item.height, 2)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)

        let reloaded = try LibraryStore(root: root)
        let restored = try XCTUnwrap(reloaded.images.first)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.filename, original.lastPathComponent)
        XCTAssertEqual(restored.width, 3)
        XCTAssertEqual(restored.height, 2)
        XCTAssertEqual(try Data(contentsOf: reloaded.imageURL(restored)), originalBytes)
        XCTAssertEqual(try reloaded.loadImage(restored).width, 3)
    }

    func testDuplicateFilenamesCanCoexistWithoutChangingEitherFile() async throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("First/same.png")
        let second = directory.appendingPathComponent("Second/same.png")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFixture(to: first)
        try writeFixture(to: second, alternate: true)
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)
        XCTAssertNotEqual(firstBytes, secondBytes)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)

        try library.importImages([first, second])

        XCTAssertEqual(library.images.count, 2)
        XCTAssertEqual(library.images.map(\.filename), ["same.png", "same.png"])
        XCTAssertEqual(Set(library.images.map(\.id)).count, 2)
        let savedBytes = try library.images.map { try Data(contentsOf: library.imageURL($0)) }
        XCTAssertEqual(savedBytes, [secondBytes, firstBytes])
        XCTAssertNotEqual(library.imageURL(library.images[0]), library.imageURL(library.images[1]))
        let reloaded = try LibraryStore(root: root)
        XCTAssertEqual(reloaded.images.map(\.id), library.images.map(\.id))
        XCTAssertEqual(try reloaded.images.map { try Data(contentsOf: reloaded.imageURL($0)) }, [secondBytes, firstBytes])
    }

    func testRenameMovesOriginalBytesAndPersistsMatchingIndex() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("original.PNG")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        try library.importImages([original])
        let item = try XCTUnwrap(library.images.first)
        let oldURL = library.imageURL(item)

        try library.rename(item, to: "会议截图")

        let renamed = try XCTUnwrap(library.images.first)
        XCTAssertEqual(renamed.id, item.id)
        XCTAssertEqual(renamed.filename, "会议截图.PNG")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: library.imageURL(renamed)), originalBytes)

        let reloaded = try LibraryStore(root: root)
        let restored = try XCTUnwrap(reloaded.images.first)
        XCTAssertEqual(restored.filename, renamed.filename)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(reloaded.imageURL(restored), library.imageURL(renamed))
        XCTAssertEqual(try Data(contentsOf: reloaded.imageURL(restored)), originalBytes)
    }

    func testInvalidRenameLeavesDiskAndIndexUnchanged() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        try library.importImages([original])
        let item = try XCTUnwrap(library.images.first)
        let originalIndex = library.images
        let originalBytes = try Data(contentsOf: library.imageURL(item))

        for name in ["", "  \n", ".", "..", "folder/image", "folder:image"] {
            XCTAssertThrowsError(try library.rename(item, to: name)) { error in
                guard case LibraryError.invalidName = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(library.images.first?.filename, item.filename)
            XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), originalBytes)
            XCTAssertEqual(try LibraryStore(root: root).images, originalIndex)
        }
    }

    func testCorruptLegacyIndexFailsExplicitlyAndKeepsExistingData() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let indexURL = root.appendingPathComponent("images.json")
        let corrupt = Data("{ broken index".utf8)
        try corrupt.write(to: indexURL)

        for _ in 0..<2 {
            XCTAssertThrowsError(try LibraryStore(root: root)) { error in
                guard case DecodingError.dataCorrupted = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func testUnreadableImportKeepsEarlierImagesAndReportsFailure() async throws {
        let directory = try temporaryDirectory()
        let valid = directory.appendingPathComponent("valid.png")
        let invalid = directory.appendingPathComponent("invalid.png")
        try writeFixture(to: valid)
        try Data("This is not a PNG".utf8).write(to: invalid)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)

        XCTAssertThrowsError(try library.importImages([valid, invalid])) { error in
            guard case LibraryError.unreadableImage(let name) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(name, "invalid.png")
        }
        XCTAssertEqual(library.images.count, 1)
        let item = try XCTUnwrap(library.images.first)
        XCTAssertEqual(item.filename, "valid.png")
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), try Data(contentsOf: valid))
        XCTAssertEqual(try LibraryStore(root: root).images.map(\.id), [item.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path), [item.id.uuidString])
    }

    func testRenameRollsBackDiskMoveWhenIndexCannotBeWritten() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        try library.importImages([original])
        let item = try XCTUnwrap(library.images.first)
        let oldURL = library.imageURL(item)
        let originalBytes = try Data(contentsOf: oldURL)
        try executeSQL("CREATE TRIGGER reject_rename BEFORE UPDATE OF filename ON images BEGIN SELECT RAISE(ABORT, 'write rejected'); END", root: root)

        XCTAssertThrowsError(try library.rename(item, to: "renamed"))

        XCTAssertEqual(library.images.first?.filename, "original.png")
        XCTAssertEqual(try Data(contentsOf: oldURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.deletingLastPathComponent().appendingPathComponent("renamed.png").path))
    }

    func testImportRemovesUnindexedCopyWhenIndexCannotBeWritten() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        try executeSQL("CREATE TRIGGER reject_insert BEFORE INSERT ON images BEGIN SELECT RAISE(ABORT, 'write rejected'); END", root: root)

        XCTAssertThrowsError(try library.importImages([original]))

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func testSessionDiscoveryKeepsKeyframesAndOnlyPublishesFinalVideoNames() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let sessions = root.appendingPathComponent("Sessions")
        let videoDirectory = sessions.appendingPathComponent(UUID().uuidString)
        let keyframeDirectory = sessions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: keyframeDirectory, withIntermediateDirectories: false)
        let pending = videoDirectory.appendingPathComponent(".recording.partial.mp4")
        let finalized = videoDirectory.appendingPathComponent("recording.mp4")
        // Discovery uses the writer's publication filename, without decoding the video again.
        try Data("pending encoder output".utf8).write(to: pending)
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 2, sampleRate: 2,
                                        threshold: 0.025, width: 320, height: 180,
                                        frames: [.init(file: "frame-000001.png", time: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: keyframeDirectory.appendingPathComponent("manifest.json"))
        // Exporting alongside source frames must not expose a second row whose delete removes the source session.
        let exportedVideo = keyframeDirectory.appendingPathComponent("recording.mp4")
        let exportedBytes = Data("keyframe video export".utf8)
        try exportedBytes.write(to: exportedVideo)

        try library.reloadSessions()

        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertEqual(library.sessions.map(\.id), [manifest.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))

        try FileManager.default.moveItem(at: pending, to: finalized)
        try library.reloadSessions()

        XCTAssertEqual(library.videos.map { $0.resolvingSymlinksInPath() }, [finalized.resolvingSymlinksInPath()])
        XCTAssertEqual(library.sessions.map(\.id), [manifest.id])
        XCTAssertEqual(try Data(contentsOf: keyframeDirectory.appendingPathComponent("manifest.json")), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: exportedVideo), exportedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoDirectory.appendingPathComponent("manifest.json").path))
        let reloaded = try LibraryStore(root: root)
        XCTAssertEqual(reloaded.videos.map { $0.resolvingSymlinksInPath() }, [finalized.resolvingSymlinksInPath()])
        XCTAssertEqual(reloaded.sessions.map(\.id), [manifest.id])
    }

    func testCorruptSessionManifestFailsWithoutReplacingPublishedLists() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let directory = root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let video = directory.appendingPathComponent("recording.mp4")
        try Data("published video".utf8).write(to: video)
        try library.reloadSessions()
        XCTAssertEqual(library.videos.map { $0.resolvingSymlinksInPath() }, [video.resolvingSymlinksInPath()])
        try Data("broken manifest".utf8).write(to: directory.appendingPathComponent("manifest.json"))

        XCTAssertThrowsError(try library.reloadSessions())
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertEqual(library.videos.map { $0.resolvingSymlinksInPath() }, [video.resolvingSymlinksInPath()])
    }

    func testNewImagesFollowChangedStorageWithoutMovingOrDuplicatingEarlierImages() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let image = try LibraryStore.readImage(at: original)
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        let earlierClient = try LibraryStore(root: root)
        let old = try library.addImage(image, source: "截图")
        let oldURL = library.imageURL(old)
        let first = directory.appendingPathComponent("First")
        let second = directory.appendingPathComponent("Second")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }

        try library.setStorageDirectory(first, for: .screenshots)
        let external = try earlierClient.addImage(image, source: "截图")
        XCTAssertEqual(external.directory?.deletingLastPathComponent(), first.resolvingSymlinksInPath())
        XCTAssertNil(old.directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path), [old.id.uuidString])
        let externalBytes = try Data(contentsOf: earlierClient.imageURL(external))

        try library.setStorageDirectory(second, for: .screenshots)
        try library.importImages([original])
        let imported = try XCTUnwrap(library.images.first)
        XCTAssertEqual(imported.directory?.deletingLastPathComponent(), second.resolvingSymlinksInPath())
        try library.rename(external, to: "renamed")
        let renamed = try XCTUnwrap(library.images.first { $0.id == external.id })
        XCTAssertEqual(try Data(contentsOf: library.imageURL(renamed)), externalBytes)

        try library.setStorageDirectory(nil, for: .screenshots)
        let restored = try library.addImage(image, source: "截图")
        let reloaded = try LibraryStore(root: root)
        XCTAssertNil(restored.directory)
        XCTAssertNil(reloaded.storage.screenshotDirectory)
        XCTAssertEqual(Set(reloaded.images.map(\.id)), [old.id, external.id, imported.id, restored.id])
        XCTAssertEqual(reloaded.imageURL(old), oldURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try reloaded.loadImage(renamed).width, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [external.id.uuidString])
    }

    func testInvalidOrUnavailableImageStorageDoesNotChangeSettingsOrFallBack() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let external = directory.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let library = try LibraryStore(root: root)
        try library.setStorageDirectory(external, for: .screenshots)
        let settings = try Data(contentsOf: root.appendingPathComponent("storage.json"))
        XCTAssertThrowsError(try library.setStorageDirectory(directory.appendingPathComponent("Missing"), for: .screenshots))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("storage.json")), settings)
        XCTAssertEqual(library.screenshotDirectory, external.resolvingSymlinksInPath())

        let original = directory.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let image = try LibraryStore.readImage(at: original)
        try FileManager.default.removeItem(at: external)
        XCTAssertThrowsError(try library.addImage(image, source: "截图"))
        XCTAssertThrowsError(try library.importImages([original]))
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("storage.json")), settings)
    }

    func testFailedSettingsWriteKeepsPreviousLocationOnDiskAndInMemory() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let first = directory.appendingPathComponent("First")
        let second = directory.appendingPathComponent("Second")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let library = try LibraryStore(root: root)
        try library.setStorageDirectory(first, for: .screenshots)
        let file = root.appendingPathComponent("storage.json")
        let previous = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        XCTAssertThrowsError(try library.setStorageDirectory(second, for: .screenshots))
        XCTAssertEqual(library.screenshotDirectory, first.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: file), previous)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
    }

    func testRecordingHistorySurvivesStorageChangesAndReportsOfflineDirectory() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let first = directory.appendingPathComponent("First")
        let second = directory.appendingPathComponent("Second")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let library = try LibraryStore(root: root)
        try library.setStorageDirectory(first, for: .recordings)
        let firstSession = try library.newRecordingDirectory()
        try FileManager.default.createDirectory(at: firstSession, withIntermediateDirectories: false)
        try Data([1]).write(to: firstSession.appendingPathComponent("recording.mp4"))
        try library.setRecordingTag(.blue, for: firstSession)
        try library.setStorageDirectory(second, for: .recordings)
        let secondSession = try library.newRecordingDirectory()
        try FileManager.default.createDirectory(at: secondSession, withIntermediateDirectories: false)
        try Data([2]).write(to: secondSession.appendingPathComponent("recording.mp4"))
        let unrelated = second.appendingPathComponent("Other App")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data([3]).write(to: unrelated.appendingPathComponent("recording.mp4"))
        try Data([4]).write(to: second.appendingPathComponent(UUID().uuidString))
        try library.reloadSessions()
        XCTAssertEqual(library.videos.count, 2)
        XCTAssertTrue(library.recordingReadErrors.isEmpty)

        let unavailable = directory.appendingPathComponent("Unmounted")
        try FileManager.default.moveItem(at: first, to: unavailable)
        try library.reloadSessions()
        XCTAssertEqual(library.videos.count, 2)
        XCTAssertEqual(library.recordingTags[firstSession], .blue)
        XCTAssertEqual(library.recordingReadErrors.count, 1)
        XCTAssertTrue(library.recordingReadErrors[0].contains(first.path))
        let reloaded = try LibraryStore(root: root)
        XCTAssertEqual(reloaded.videos, [secondSession.appendingPathComponent("recording.mp4")])
        XCTAssertEqual(reloaded.recordingReadErrors.count, 1)
        try reloaded.setStorageDirectory(nil, for: .recordings)
        XCTAssertEqual(reloaded.storage.recordingDirectories.count, 2)
        XCTAssertEqual(try reloaded.newRecordingDirectory().deletingLastPathComponent(), root.appendingPathComponent("Sessions"))
        try reloaded.validateStorageDirectory(for: .screenshots)

        try FileManager.default.moveItem(at: unavailable, to: first)
        try reloaded.reloadSessions()
        XCTAssertEqual(reloaded.videos.count, 2)
        XCTAssertEqual(reloaded.recordingTags[firstSession], .blue)
        XCTAssertTrue(reloaded.recordingReadErrors.isEmpty)
    }

    func testImageAndRecordingTagsPersistWithoutChangingMedia() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let original = directory.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let library = try LibraryStore(root: root)
        try library.importImages([original])
        let item = try XCTUnwrap(library.images.first)
        let bytes = try Data(contentsOf: library.imageURL(item))
        try library.setTag(.purple, for: [item])
        XCTAssertEqual(try LibraryStore(root: root).images.first?.tag, .purple)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), bytes)
        try library.setTag(nil, for: [item])
        XCTAssertNil(try LibraryStore(root: root).images.first?.tag)

        let session = try library.newRecordingDirectory()
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        let video = session.appendingPathComponent("recording.mp4")
        try Data([1, 2, 3]).write(to: video)
        try library.setRecordingTag(.green, for: session)
        XCTAssertEqual(try LibraryStore(root: root).recordingTags[session], .green)
        XCTAssertEqual(try Data(contentsOf: video), Data([1, 2, 3]))
        try library.setRecordingTag(nil, for: session)
        try library.setRecordingTag(nil, for: session)
        XCTAssertNil(try LibraryStore(root: root).recordingTags[session])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent(".framevault-tag").path))
        try Data("unknown".utf8).write(to: session.appendingPathComponent(".framevault-tag"))
        XCTAssertThrowsError(try library.reloadSessions()) { error in
            guard case LibraryError.invalidTag = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testNewImageCommitsItsSelectedTagWithTheImageIndex() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let image = try LibraryStore.readImage(at: source)
        let item = try library.addImage(image, source: "长截图", tag: .orange)
        let restored = try XCTUnwrap(try LibraryStore(root: library.root).images.first)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.filename, item.filename)
        XCTAssertEqual(restored.source, "长截图")
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, item.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(restored.tag, .orange)
        XCTAssertEqual(try library.loadImage(restored).width, image.width)
        let untagged = try library.addImage(image, source: "截图")
        XCTAssertNil(untagged.tag)
    }

    func testSQLiteWriteFailureRollsBackEveryTagInTheBatch() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("original.png")
        try writeFixture(to: original)
        let library = try LibraryStore(root: root.appendingPathComponent("Vault"))
        try library.importImages([original, original])
        let before = library.images
        let rejected = before[1].id.uuidString
        try executeSQL("CREATE TRIGGER reject_tag BEFORE UPDATE OF tag ON images WHEN OLD.id = '\(rejected)' BEGIN SELECT RAISE(ABORT, 'write rejected'); END", root: library.root)

        XCTAssertThrowsError(try library.setTag(.red, for: before))
        XCTAssertEqual(library.images, before)
        XCTAssertEqual(try LibraryStore(root: library.root).images, before)
    }

    func testKeyframeImportPreservesTimeOrderBytesTagAndExternalStorageAcrossReopen() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let external = directory.appendingPathComponent("External Images")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try library.setStorageDirectory(external, for: .screenshots)
        let session = try keyframeSession(at: directory.appendingPathComponent("Original Recording"))
        try LibraryStore.writeRecordingTag(.purple, to: session.directory)
        XCTAssertNil(library.recordingTags[session.directory])
        let manifestBytes = try Data(contentsOf: session.directory.appendingPathComponent("manifest.json"))
        let originalBytes = try session.manifest.frames.map { try Data(contentsOf: session.directory.appendingPathComponent($0.file)) }

        let count = try await library.importKeyframes(session)

        XCTAssertEqual(count, 3)
        XCTAssertEqual(library.images.map(\.filename), session.manifest.frames.map(\.file))
        XCTAssertEqual(Set(library.images.map(\.id)).count, 3)
        XCTAssertEqual(library.images.map(\.source), ["关键帧", "关键帧", "关键帧"])
        XCTAssertEqual(library.images.map(\.tag), [.purple, .purple, .purple])
        XCTAssertEqual(library.images.map(\.createdAt), session.manifest.frames.map { session.manifest.createdAt.addingTimeInterval($0.time) })
        XCTAssertTrue(library.images.allSatisfy { $0.directory?.deletingLastPathComponent() == external.resolvingSymlinksInPath() })
        XCTAssertEqual(try library.images.map { try Data(contentsOf: library.imageURL($0)) }, originalBytes)
        XCTAssertEqual(try session.manifest.frames.map { try Data(contentsOf: session.directory.appendingPathComponent($0.file)) }, originalBytes)
        XCTAssertEqual(try Data(contentsOf: session.directory.appendingPathComponent("manifest.json")), manifestBytes)
        XCTAssertEqual(try LibraryStore(root: library.root).images, library.images)
    }

    func testKeyframeImportRejectsEscapingPathsAndInvalidTimesBeforeCreatingImages() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let session = try keyframeSession(at: directory.appendingPathComponent("Recording"))
        let outside = directory.appendingPathComponent("outside.png")
        try writeFixture(to: outside)
        try FileManager.default.createSymbolicLink(at: session.directory.appendingPathComponent("link.png"), withDestinationURL: outside)
        let badFrames: [[KeyframeManifest.Frame]] = [
            [.init(file: "../outside.png", time: 0)],
            [.init(file: outside.path, time: 0)],
            [.init(file: "link.png", time: 0)],
            [.init(file: "frame-000001.png", time: .nan)],
            [.init(file: "frame-000001.png", time: -1)],
            [.init(file: "frame-000001.png", time: 3)],
            [.init(file: "frame-000001.png", time: 1), .init(file: "frame-000002.png", time: 0)]
        ]
        for frames in badFrames {
            let invalid = replacingFrames(frames, in: session)
            do {
                _ = try await library.importKeyframes(invalid)
                XCTFail("Invalid recording was accepted")
            } catch KeyframeExportError.invalidManifest(_) { }
            XCTAssertTrue(library.images.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty)
        }
        XCTAssertEqual(try LibraryStore.readImage(at: outside).width, 3)
    }

    func testCorruptLaterKeyframeRemovesEarlierCopiesWithoutPublishingPartialBatch() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let session = try keyframeSession(at: directory.appendingPathComponent("Recording"))
        let first = session.directory.appendingPathComponent(session.manifest.frames[0].file)
        let firstBytes = try Data(contentsOf: first)
        let corrupt = session.directory.appendingPathComponent(session.manifest.frames[1].file)
        let badBytes = Data("broken PNG".utf8)
        try badBytes.write(to: corrupt)

        do {
            _ = try await library.importKeyframes(session)
            XCTFail("Broken PNG was accepted")
        } catch KeyframeExportError.invalidFrame(_) { }
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try LibraryStore(root: library.root).images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: corrupt), badBytes)
    }

    func testKeyframeBatchDatabaseFailureRollsBackRowsAndRemovesAllNewCopies() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let session = try keyframeSession(at: directory.appendingPathComponent("Recording"))
        try executeSQL("CREATE TRIGGER reject_second_frame BEFORE INSERT ON images WHEN NEW.filename = 'frame-000002.png' BEGIN SELECT RAISE(ABORT, 'write rejected'); END", root: library.root)

        do {
            _ = try await library.importKeyframes(session)
            XCTFail("Rejected batch was accepted")
        } catch is LibraryDatabaseError { }
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try LibraryStore(root: library.root).images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty)
        for frame in session.manifest.frames {
            XCTAssertEqual(try LibraryStore.readImage(at: session.directory.appendingPathComponent(frame.file)).width, 3)
        }
    }

    func testCancellingKeyframeImportBeforeCommitRemovesStagedFiles() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let session = try keyframeSession(at: directory.appendingPathComponent("Recording"))
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let task = Task { try await library.importKeyframes(session) }
        var staged = false
        for _ in 0..<100 {
            if try !FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty { staged = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(staged)
        XCTAssertTrue(library.images.isEmpty)
        task.cancel()
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await task.value
            XCTFail("Cancelled import was committed")
        } catch is CancellationError { }
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try LibraryStore(root: library.root).images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty)
    }

    func testInvalidKeyframeRecordingTagIsReportedWithoutCreatingImages() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let session = try keyframeSession(at: directory.appendingPathComponent("Recording"))
        try Data("unknown".utf8).write(to: session.directory.appendingPathComponent(".framevault-tag"))
        do {
            _ = try await library.importKeyframes(session)
            XCTFail("Invalid tag was accepted")
        } catch LibraryError.invalidTag(_) { }
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty)
    }

    func testCancellingKeyframeImportDoesNotWaitForAnotherClientsFileLock() async throws {
        let directory = try temporaryDirectory()
        let library = try LibraryStore(root: directory.appendingPathComponent("Vault"))
        let session = try keyframeSession(at: directory.appendingPathComponent("Recording"))
        let descriptor = open(library.root.appendingPathComponent(".images.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let task = Task { try await library.importKeyframes(session) }
        let completed = expectation(description: "Cancelled while the other client still owns the file lock")
        let completion = Task {
            let result = await task.result
            completed.fulfill()
            return result
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await fulfillment(of: [completed], timeout: 1)

        // 直到等待取消完成后才解锁；回归失败也要解锁，让测试进程能收尾。
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        switch await completion.value {
        case .success: XCTFail("Cancelled import was committed")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try LibraryStore(root: library.root).images.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.screenshotDirectory.path).isEmpty)
    }

    func testMetadataEditOnlyWritesItsRowAndDoesNotRewriteLegacyBackup() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let original = root.appendingPathComponent("original.png")
        try writeFixture(to: original)
        try library.importImages([original, original])
        let first = library.images[0]
        let untouched = library.images[1]
        try executeSQL("CREATE TRIGGER protect_delete BEFORE DELETE ON images BEGIN SELECT RAISE(ABORT, 'must update rows'); END; CREATE TRIGGER protect_unrelated BEFORE UPDATE ON images WHEN OLD.id = '\(untouched.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'unrelated row changed'); END", root: root)

        try library.rename(first, to: "renamed")
        try library.setTag(.blue, for: [first])
        let reloaded = try LibraryStore(root: root)
        XCTAssertEqual(reloaded.images[0].filename, "renamed.png")
        XCTAssertEqual(reloaded.images[0].tag, .blue)
        XCTAssertEqual(reloaded.images[1], untouched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("images.json").path))
    }

    private func executeSQL(_ sql: String, root: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw LibraryDatabaseError(message: String(cString: sqlite3_errmsg(database))) }
    }

    private func keyframeSession(at directory: URL) throws -> SavedSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let frames = (0..<3).map { KeyframeManifest.Frame(file: String(format: "frame-%06d.png", $0 + 1), time: Double($0)) }
        for (index, frame) in frames.enumerated() {
            try writeFixture(to: directory.appendingPathComponent(frame.file), alternate: index == 1)
        }
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                        duration: 3, sampleRate: 1, threshold: 0.025, width: 3, height: 2, frames: frames)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return SavedSession(id: manifest.id, directory: directory, manifest: manifest)
    }

    private func replacingFrames(_ frames: [KeyframeManifest.Frame], in session: SavedSession) -> SavedSession {
        let manifest = session.manifest
        return SavedSession(id: session.id, directory: session.directory,
                            manifest: KeyframeManifest(id: manifest.id, createdAt: manifest.createdAt, duration: manifest.duration,
                                                       sampleRate: manifest.sampleRate, threshold: manifest.threshold,
                                                       width: manifest.width, height: manifest.height, frames: frames))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-LibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeFixture(to url: URL, alternate: Bool = false) throws {
        let bytes = Data(alternate ? [
            0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255,
            255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255, 255
        ] : [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            0, 0, 0, 255, 255, 255, 255, 255, 128, 128, 128, 255
        ])
        let image = try XCTUnwrap(CGImage(
            width: 3,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 12,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
