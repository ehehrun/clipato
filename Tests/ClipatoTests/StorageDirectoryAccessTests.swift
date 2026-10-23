import Foundation
import XCTest
@testable import Clipato

final class StorageDirectoryAccessTests: XCTestCase {
    func testDirectDistributionKeepsPlainDirectoriesWithoutCreatingBookmarks() throws {
        let fixture = try directories()
        let access = StorageDirectoryAccess(root: fixture.root, enabled: false)
        var saved = false
        try access.select(fixture.external) { saved = true }

        XCTAssertTrue(saved)
        XCTAssertTrue(access.restore([fixture.external]).isEmpty)
        XCTAssertNoThrow(try access.requireAccess(to: fixture.external))
        XCTAssertTrue(access.activeScopes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bookmarks.path))
    }

    func testContainerDirectoriesNeedNoBookmarkButExternalPathsDo() throws {
        let fixture = try directories()
        let access = StorageDirectoryAccess(root: fixture.root, enabled: true)

        XCTAssertTrue(access.restore([fixture.root.appendingPathComponent("Images")]).isEmpty)
        XCTAssertNoThrow(try access.requireAccess(to: fixture.root.appendingPathComponent("Images/capture.png")))
        XCTAssertNotNil(access.restore([fixture.external])[fixture.external])
        XCTAssertThrowsError(try access.requireAccess(to: fixture.external)) { error in
            guard case StorageLocationError.authorizationRequired(let url) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(url, fixture.external)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bookmarks.path))
    }

    func testRealSecurityBookmarkRestoresDirectoryAndDescendantsAfterOwnerRecreation() throws {
        let fixture = try directories()
        let original = fixture.external.appendingPathComponent("keep.txt")
        try Data("unchanged".utf8).write(to: original)
        do {
            let access = StorageDirectoryAccess(root: fixture.root, enabled: true)
            try access.select(fixture.external) { try StorageLocations.validateDirectory(fixture.external) }
            XCTAssertEqual(access.activeScopes.count, 1)
        }
        let reloaded = StorageDirectoryAccess(root: fixture.root, enabled: true)

        XCTAssertTrue(reloaded.restore([fixture.external, fixture.external]).isEmpty)
        XCTAssertEqual(reloaded.activeScopes.count, 1)
        XCTAssertTrue(reloaded.restore([fixture.external]).isEmpty)
        XCTAssertEqual(reloaded.activeScopes.count, 1)
        XCTAssertNoThrow(try reloaded.requireAccess(to: fixture.external.appendingPathComponent("nested/capture.png")))
        XCTAssertThrowsError(try reloaded.requireAccess(to: fixture.external.appendingPathExtension("sibling")))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "unchanged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.external.path), ["keep.txt"])
    }

    func testFailedLocationSaveRollsBackBookmarkAndReleasesNewScope() throws {
        let fixture = try directories()
        let access = StorageDirectoryAccess(root: fixture.root, enabled: true)

        XCTAssertThrowsError(try access.select(fixture.external) { throw CocoaError(.fileWriteNoPermission) })

        XCTAssertTrue(access.activeScopes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bookmarks.path))
        try access.select(fixture.external) { }
        let before = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: fixture.bookmarks))
        let second = fixture.external.deletingLastPathComponent().appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)

        XCTAssertThrowsError(try access.select(second) { throw CocoaError(.fileWriteNoPermission) })

        let after = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: fixture.bookmarks))
        XCTAssertEqual(after, before)
        XCTAssertEqual(access.activeScopes.map { $0.url.standardizedFileURL.path }, [fixture.external.standardizedFileURL.path])
        XCTAssertThrowsError(try access.requireAccess(to: second))
    }

    func testMovedDirectoryIsReportedWithoutRewritingConfiguredPathOrBookmark() throws {
        let fixture = try directories()
        do {
            let access = StorageDirectoryAccess(root: fixture.root, enabled: true)
            try access.select(fixture.external) { }
        }
        let bookmark = try Data(contentsOf: fixture.bookmarks)
        let moved = fixture.external.deletingLastPathComponent().appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.external, to: moved)
        let reloaded = StorageDirectoryAccess(root: fixture.root, enabled: true)

        let errors = reloaded.restore([fixture.external])

        XCTAssertNotNil(errors[fixture.external])
        XCTAssertTrue(errors[fixture.external]!.contains(moved.path))
        XCTAssertThrowsError(try reloaded.requireAccess(to: moved))
        XCTAssertTrue(reloaded.activeScopes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.bookmarks), bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.external.path))
    }

    func testCorruptBookmarkIsNotReplacedWithAPlainURLGrant() throws {
        let fixture = try directories()
        let data = try PropertyListEncoder().encode([fixture.external.path: Data([0, 1, 2])])
        try data.write(to: fixture.bookmarks)
        let access = StorageDirectoryAccess(root: fixture.root, enabled: true)

        XCTAssertNotNil(access.restore([fixture.external])[fixture.external])
        XCTAssertThrowsError(try access.requireAccess(to: fixture.external))
        XCTAssertTrue(access.activeScopes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.bookmarks), data)
    }

    func testStaleBookmarkIsRefreshedWhenItStillResolvesToTheConfiguredDirectory() throws {
        let fixture = try directories()
        let oldBookmark = try fixture.external.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let configured = fixture.external.deletingLastPathComponent().appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.external, to: configured)
        var stale = false
        _ = try URL(resolvingBookmarkData: oldBookmark, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertTrue(stale)
        try PropertyListEncoder().encode([configured.standardizedFileURL.path: oldBookmark]).write(to: fixture.bookmarks)
        let access = StorageDirectoryAccess(root: fixture.root, enabled: true)

        XCTAssertTrue(access.restore([configured]).isEmpty)

        let stored = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: fixture.bookmarks))
        let refreshed = try XCTUnwrap(stored[configured.standardizedFileURL.path])
        XCTAssertNotEqual(refreshed, oldBookmark)
        _ = try URL(resolvingBookmarkData: refreshed, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertFalse(stale)
        XCTAssertNoThrow(try access.requireAccess(to: configured.appendingPathComponent("image.png")))
    }

    func testCorruptPersistedFileDropsCachedScopeAndSurfacesTheReadFailure() throws {
        let fixture = try directories()
        let access = StorageDirectoryAccess(root: fixture.root, enabled: true)
        try access.select(fixture.external) { }
        let invalid = Data("invalid property list".utf8)
        try invalid.write(to: fixture.bookmarks)

        XCTAssertNotNil(access.restore([fixture.external])[fixture.external])
        XCTAssertTrue(access.activeScopes.isEmpty)
        XCTAssertThrowsError(try access.requireAccess(to: fixture.external))
        XCTAssertEqual(try Data(contentsOf: fixture.bookmarks), invalid)
    }

    func testDroppingDirectoryReleasesScopeAfterInFlightWorkReleasesItsSnapshot() throws {
        let fixture = try directories()
        let access = StorageDirectoryAccess(root: fixture.root, enabled: true)
        try access.select(fixture.external) { }
        weak var scope: StorageDirectoryScope?
        scope = access.activeScopes.first
        var inFlight = access.activeScopes

        XCTAssertTrue(access.restore([]).isEmpty)
        XCTAssertTrue(access.activeScopes.isEmpty)
        XCTAssertNotNil(scope)
        inFlight.removeAll()
        XCTAssertNil(scope)
    }

    private func directories() throws -> (root: URL, external: URL, bookmarks: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-BookmarkTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.appendingPathComponent("Vault", isDirectory: true)
        let external = directory.appendingPathComponent("自选 Images", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return (root, external, root.appendingPathComponent(StorageDirectoryAccess.filename))
    }
}
