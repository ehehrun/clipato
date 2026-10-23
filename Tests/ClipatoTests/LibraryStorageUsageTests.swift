import Foundation
import XCTest
@testable import Clipato

final class LibraryStorageUsageTests: XCTestCase {
    func testCountsStoredImagesRecordingsCacheLogsAndCoreWithoutEnumeratingOtherFiles() throws {
        let root = try temporaryDirectory()
        let image = VaultImage(id: UUID(), filename: "capture.png", createdAt: Date(), width: 10, height: 10, source: "截图")
        try write(101, to: root.appendingPathComponent("Images/\(image.id.uuidString)/capture.png"))
        try write(8_000, to: root.appendingPathComponent("Images/unregistered.png"))
        let session = root.appendingPathComponent("Sessions/session")
        try write(203, to: session.appendingPathComponent("frames/001.png"))
        try write(11, to: session.appendingPathComponent("manifest.json"))
        let cache = root.appendingPathComponent("Clipato-cache")
        try write(37, to: cache.appendingPathComponent("preview.png"))
        try write(1_000, to: root.appendingPathComponent("other-app-cache/preview.png"))
        let logs = root.appendingPathComponent("Logs/Clipato")
        try write(31, to: logs.appendingPathComponent("mcp-access.log"))
        try write(19, to: logs.appendingPathComponent("mcp-access.log.1"))
        try write(2_000, to: root.appendingPathComponent("Logs/OtherApp/access.log"))
        let coreFiles = ["images.json", "storage.json", ".images.lock", "library.sqlite", "library.sqlite-wal", "library.sqlite-shm"]
        for filename in coreFiles { try write(7, to: root.appendingPathComponent(filename)) }

        let usage = try LibraryStorageUsage.scan(root: root, images: [image], recordingDirectories: [session],
                                                cacheDirectories: [cache], logDirectories: [logs], recordingReadErrors: [])

        XCTAssertEqual(usage.imageBytes, 101)
        XCTAssertEqual(usage.recordingBytes, 214)
        XCTAssertEqual(usage.cacheBytes, 37)
        XCTAssertEqual(usage.logBytes, 50)
        XCTAssertEqual(usage.coreBytes, 42)
        XCTAssertEqual(usage.mediaBytes, 315)
        XCTAssertEqual(usage.totalBytes, 444)
        XCTAssertTrue(usage.isComplete)
    }

    func testDeduplicatesImageURLsAndOverlappingRecordingDirectoriesIncludingAliases() throws {
        let root = try temporaryDirectory()
        let externalImages = root.appendingPathComponent("external-images")
        try write(23, to: externalImages.appendingPathComponent("shared.png"))
        let first = VaultImage(id: UUID(), filename: "shared.png", createdAt: Date(), width: 1, height: 1, source: "导入", directory: externalImages)
        let second = VaultImage(id: UUID(), filename: "shared.png", createdAt: Date(), width: 1, height: 1, source: "导入", directory: externalImages.appendingPathComponent("./"))
        let session = root.appendingPathComponent("Sessions/session")
        let frames = session.appendingPathComponent("frames")
        try write(41, to: frames.appendingPathComponent("001.png"))
        try write(5, to: session.appendingPathComponent("manifest.json"))
        let alias = root.appendingPathComponent("session-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: session)
        let sibling = root.appendingPathComponent("Sessions/session-extra")
        try write(13, to: sibling.appendingPathComponent("recording.mp4"))

        let usage = try LibraryStorageUsage.scan(root: root, images: [first, first, second],
                                                recordingDirectories: [frames, alias, session, sibling, session],
                                                cacheDirectories: [], recordingReadErrors: [])

        XCTAssertEqual(usage.imageBytes, 23)
        XCTAssertEqual(usage.recordingBytes, 59)
        XCTAssertTrue(usage.isComplete)
    }

    func testMissingExternalMediaIsIncompleteButMissingDedicatedCacheAndLogsAreEmpty() throws {
        let root = try temporaryDirectory()
        let external = root.appendingPathComponent("offline-volume")
        let image = VaultImage(id: UUID(), filename: "capture.png", createdAt: Date(), width: 1, height: 1, source: "截图", directory: external)
        let missingSession = external.appendingPathComponent("session")

        let usage = try LibraryStorageUsage.scan(root: root, images: [image], recordingDirectories: [missingSession],
                                                cacheDirectories: [root.appendingPathComponent("unused-cache")],
                                                logDirectories: [root.appendingPathComponent("unused-logs")],
                                                recordingReadErrors: ["录制目录离线"])

        XCTAssertFalse(usage.isComplete)
        XCTAssertEqual(usage.imageBytes, 0)
        XCTAssertEqual(usage.recordingBytes, 0)
        XCTAssertEqual(usage.cacheBytes, 0)
        XCTAssertEqual(usage.logBytes, 0)
        XCTAssertEqual(usage.unavailablePaths.count, 3)
        XCTAssertTrue(usage.unavailablePaths.contains { $0.contains("capture.png") })
        XCTAssertTrue(usage.unavailablePaths.contains { $0.contains("offline-volume/session") })
        XCTAssertTrue(usage.unavailablePaths.contains("录制目录离线"))
        XCTAssertFalse(usage.unavailablePaths.contains { $0.contains("unused-cache") })
        XCTAssertFalse(usage.unavailablePaths.contains { $0.contains("unused-logs") })
    }

    func testEmptyLibraryAndAbsentCacheAndLogsAreComplete() throws {
        let root = try temporaryDirectory()
        let usage = try LibraryStorageUsage.scan(root: root, images: [], recordingDirectories: [],
                                                cacheDirectories: [root.appendingPathComponent("unused-cache")],
                                                logDirectories: [root.appendingPathComponent("unused-logs")], recordingReadErrors: [])

        XCTAssertTrue(usage.isComplete)
        XCTAssertEqual(usage.totalBytes, 0)
    }

    func testLogsCountOnceWithoutFollowingNestedSymlinksAndDoNotConsumeMediaQuota() throws {
        let root = try temporaryDirectory()
        let logs = root.appendingPathComponent("Logs/Clipato")
        let archived = logs.appendingPathComponent("archive")
        try write(29, to: logs.appendingPathComponent("mcp-access.log"))
        try write(43, to: archived.appendingPathComponent("mcp-access.log.1"))
        let outside = root.appendingPathComponent("outside")
        try write(100_000, to: outside.appendingPathComponent("large.log"))
        let alias = root.appendingPathComponent("log-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: logs)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked-file"), withDestinationURL: outside.appendingPathComponent("large.log"))

        let usage = try LibraryStorageUsage.scan(root: root, images: [], recordingDirectories: [],
                                                cacheDirectories: [], logDirectories: [archived, logs, alias, logs], recordingReadErrors: [])

        XCTAssertTrue(usage.isComplete)
        XCTAssertEqual(usage.logBytes, 72)
        XCTAssertEqual(usage.totalBytes, 72)
        XCTAssertEqual(usage.mediaBytes, 0)
    }

    func testDoesNotFollowNestedSymlinksOrCountNeighbouringCaches() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("outside")
        try write(1_000_000, to: outside.appendingPathComponent("large.mp4"))
        let session = root.appendingPathComponent("Sessions/session")
        try write(11, to: session.appendingPathComponent("recording.mp4"))
        let cache = root.appendingPathComponent("temporary/Clipato")
        try write(17, to: cache.appendingPathComponent("preview.png"))
        try write(900_000, to: root.appendingPathComponent("temporary/another-app/file"))
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("linked-file"), withDestinationURL: outside.appendingPathComponent("large.mp4"))
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("loop"), withDestinationURL: cache)

        let usage = try LibraryStorageUsage.scan(root: root, images: [], recordingDirectories: [session],
                                                cacheDirectories: [cache, cache], recordingReadErrors: [])

        XCTAssertTrue(usage.isComplete)
        XCTAssertEqual(usage.recordingBytes, 11)
        XCTAssertEqual(usage.cacheBytes, 17)
        XCTAssertEqual(usage.totalBytes, 28)
    }

    func testCoreFilesDoNotTraverseSymlinksOrUnexpectedDirectories() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("outside")
        try write(1_000, to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("images.json"), withDestinationURL: outside)
        try write(2_000, to: root.appendingPathComponent("library.sqlite/incorrect-directory"))

        let usage = try LibraryStorageUsage.scan(root: root, images: [], recordingDirectories: [],
                                                cacheDirectories: [], recordingReadErrors: [])

        XCTAssertEqual(usage.coreBytes, 0)
        XCTAssertFalse(usage.isComplete)
        XCTAssertEqual(usage.unavailablePaths.count, 1)
        XCTAssertTrue(usage.unavailablePaths[0].contains("library.sqlite"))
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-storage-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
