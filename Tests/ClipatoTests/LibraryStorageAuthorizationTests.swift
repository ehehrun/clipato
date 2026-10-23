import CoreGraphics
import Foundation
import XCTest
@testable import Clipato

@MainActor
final class LibraryStorageAuthorizationTests: XCTestCase {
    func testMissingAuthorizationRetainsMetadataAndConfiguredPathUntilExplicitReselection() async throws {
        let fixture = try directories()
        let direct = try LibraryStore(root: fixture.root, defaults: fixture.defaults, enforceStorageQuota: false,
                                      requiresStorageAuthorization: false)
        try direct.setStorageDirectory(fixture.external, for: .screenshots)
        let item = try direct.addImage(image(), source: "fixture")
        let original = try Data(contentsOf: direct.imageURL(item))
        let storage = try Data(contentsOf: fixture.root.appendingPathComponent("storage.json"))
        await direct.cancelStorageWorkAndWait()
        let store = try LibraryStore(root: fixture.root, defaults: fixture.defaults, enforceStorageQuota: false,
                                     requiresStorageAuthorization: true)

        XCTAssertEqual(store.images, [item])
        XCTAssertEqual(store.screenshotDirectory, fixture.external)
        XCTAssertNotNil(store.storageAuthorizationErrors[fixture.external])
        XCTAssertThrowsError(try store.addImage(image(), source: "must not use default"))
        XCTAssertThrowsError(try store.loadImage(item))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Images").path).isEmpty)

        try store.authorizeStorageDirectory(fixture.external, for: fixture.external)

        XCTAssertTrue(store.storageAuthorizationErrors.isEmpty)
        XCTAssertEqual(try store.loadImage(item).width, 2)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(item)), original)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("storage.json")), storage)
        XCTAssertEqual(store.images, [item])
        await store.cancelStorageWorkAndWait()
    }

    func testHistoricalImageAndRecordingDirectoriesRemainAuthorizedAfterChangingAndRestoringDefaults() async throws {
        let fixture = try directories()
        let oldRecording = fixture.external.deletingLastPathComponent().appendingPathComponent("old recordings", isDirectory: true)
        let nextImages = fixture.external.deletingLastPathComponent().appendingPathComponent("new images", isDirectory: true)
        let nextRecordings = fixture.external.deletingLastPathComponent().appendingPathComponent("new recordings", isDirectory: true)
        for directory in [oldRecording, nextImages, nextRecordings] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        var expected: VaultImage!
        do {
            let store = try LibraryStore(root: fixture.root, defaults: fixture.defaults, enforceStorageQuota: false,
                                         requiresStorageAuthorization: true)
            try store.setStorageDirectory(fixture.external, for: .screenshots)
            expected = try store.addImage(image(), source: "fixture")
            try store.setStorageDirectory(oldRecording, for: .recordings)
            let session = try store.newRecordingDirectory()
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
            try Data("fixture video filename only".utf8).write(to: session.appendingPathComponent("recording.mp4"))
            try store.setStorageDirectory(nextImages, for: .screenshots)
            try store.setStorageDirectory(nextRecordings, for: .recordings)
            try store.setStorageDirectory(nil, for: .screenshots)
            try store.setStorageDirectory(nil, for: .recordings)
            await store.cancelStorageWorkAndWait()
        }
        let reloaded = try LibraryStore(root: fixture.root, defaults: fixture.defaults, enforceStorageQuota: false,
                                        requiresStorageAuthorization: true)

        XCTAssertTrue(reloaded.storageAuthorizationErrors.isEmpty)
        XCTAssertNil(reloaded.storage.screenshotDirectory)
        XCTAssertNil(reloaded.storage.recordingDirectory)
        XCTAssertEqual(reloaded.images, [expected])
        XCTAssertEqual(try reloaded.loadImage(expected).height, 2)
        XCTAssertEqual(reloaded.videos.count, 1)
        XCTAssertTrue(reloaded.videos[0].path.hasPrefix(oldRecording.path + "/"))
        XCTAssertTrue(reloaded.recordingReadErrors.isEmpty)
        await reloaded.cancelStorageWorkAndWait()
    }

    func testReselectingDifferentDirectoryDoesNotChangeStoredLocationOrGrantIt() async throws {
        let fixture = try directories()
        let other = fixture.external.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let store = try LibraryStore(root: fixture.root, defaults: fixture.defaults, enforceStorageQuota: false,
                                     requiresStorageAuthorization: true)
        try store.setStorageDirectory(fixture.external, for: .screenshots)
        let storage = try Data(contentsOf: fixture.root.appendingPathComponent("storage.json"))
        let bookmarks = try Data(contentsOf: fixture.root.appendingPathComponent(StorageDirectoryAccess.filename))

        XCTAssertThrowsError(try store.authorizeStorageDirectory(other, for: fixture.external))

        XCTAssertEqual(store.screenshotDirectory, fixture.external)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("storage.json")), storage)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(StorageDirectoryAccess.filename)), bookmarks)
        await store.cancelStorageWorkAndWait()
    }

    private func directories() throws -> (root: URL, external: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-StorageAuthorization-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.appendingPathComponent("Vault", isDirectory: true)
        let external = directory.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let suite = "Clipato-StorageAuthorization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        return (root, external, defaults)
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
