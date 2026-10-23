import Foundation
import XCTest
@testable import Clipato

final class AssetFileInfoTests: XCTestCase {
    func testMetadataRenameMovesBytesErrorsAndCreationDatesWithoutLosingUnrelatedEntries() {
        let source = URL(fileURLWithPath: "/tmp/original.mp4")
        let destination = URL(fileURLWithPath: "/tmp/renamed.mp4")
        let other = URL(fileURLWithPath: "/tmp/other.mp4")
        let info: [URL: AssetFileInfo] = [source: .size(1_234), other: .unavailable("offline")]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = [source: date, other: date.addingTimeInterval(1)]
        let changes = [source: destination]

        XCTAssertEqual(remappingAssetMetadata(info, renames: changes), [destination: .size(1_234), other: .unavailable("offline")])
        XCTAssertEqual(remappingAssetMetadata(dates, renames: changes), [destination: date, other: date.addingTimeInterval(1)])
        XCTAssertEqual(info[source], .size(1_234), "The source snapshot must remain available for every move in the batch.")
        XCTAssertEqual(dates[source], date)
    }

    func testMetadataRenameReadsEverySwapAndChainValueFromTheOriginalSnapshot() {
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.png")
        let third = URL(fileURLWithPath: "/tmp/third.png")
        let cache: [URL: AssetFileInfo] = [first: .size(10), second: .size(20), third: .size(30)]

        XCTAssertEqual(remappingAssetMetadata(cache, renames: [first: second, second: first]),
                       [first: .size(20), second: .size(10), third: .size(30)])
        XCTAssertEqual(remappingAssetMetadata(cache, renames: [first: second, second: third, third: first]),
                       [first: .size(30), second: .size(10), third: .size(20)])
    }

    func testMissingSourceMetadataDoesNotInheritAnOldDestinationValueAndURLCaseIsPreserved() {
        let missing = URL(fileURLWithPath: "/tmp/missing.png")
        let upper = URL(fileURLWithPath: "/tmp/Capture.PNG")
        let lower = URL(fileURLWithPath: "/tmp/capture.png")
        let cache: [URL: AssetFileInfo] = [upper: .size(10), lower: .size(99)]

        XCTAssertEqual(remappingAssetMetadata(cache, renames: [upper: lower]), [lower: .size(10)])
        XCTAssertEqual(remappingAssetMetadata(cache, renames: [missing: lower]), [upper: .size(10)])
        XCTAssertEqual(remappingAssetMetadata(cache, renames: [:]), cache)
    }

    func testImageMetadataRenameMatchesUUIDAcrossReorderingAndDoesNotTransferDeletedIDs() {
        let directory = URL(fileURLWithPath: "/tmp/shared-images", isDirectory: true)
        let first = VaultImage(id: UUID(), filename: "first.png", createdAt: .distantPast, width: 1, height: 1, source: "截图", directory: directory)
        let second = VaultImage(id: UUID(), filename: "second.png", createdAt: .distantPast, width: 1, height: 1, source: "截图", directory: directory)
        let deleted = VaultImage(id: UUID(), filename: "deleted.png", createdAt: .distantPast, width: 1, height: 1, source: "截图", directory: directory)
        let added = VaultImage(id: UUID(), filename: "added.png", createdAt: .distantPast, width: 1, height: 1, source: "截图", directory: directory)
        var renamed = first
        renamed.filename = "renamed.png"
        let imageURL: (VaultImage) -> URL = { directory.appendingPathComponent($0.filename) }
        let changes = renamedImageURLs(previous: [first, deleted, second], current: [second, added, renamed], imageURL: imageURL)
        let cache: [URL: AssetFileInfo] = [imageURL(first): .size(10), imageURL(second): .size(20), imageURL(deleted): .size(30), imageURL(renamed): .size(999)]
        let updated = remappingAssetMetadata(cache, renames: changes)

        XCTAssertEqual(changes, [imageURL(first): imageURL(renamed)])
        XCTAssertEqual(updated[imageURL(renamed)], .size(10))
        XCTAssertEqual(updated[imageURL(second)], .size(20))
        XCTAssertNil(updated[imageURL(added)], "A deleted image must not transfer its metadata to the item occupying its old position.")
        XCTAssertNil(updated[imageURL(first)])
    }

    func testReadsActualFileBytesIncludingZeroByteFile() async throws {
        let directory = try temporaryDirectory()
        let populated = directory.appendingPathComponent("populated.png")
        let empty = directory.appendingPathComponent("empty.mp4")
        try Data(repeating: 7, count: 12_345).write(to: populated)
        try Data().write(to: empty)

        let result = try await AssetFileInfoLoader().load([populated, empty])

        XCTAssertEqual(result[populated], .size(12_345))
        XCTAssertEqual(result[empty], .size(0))
    }

    func testSessionIncludesNestedFilesWithoutFollowingLinksOutsideSession() async throws {
        let directory = try temporaryDirectory()
        let session = directory.appendingPathComponent("session")
        let frames = session.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 400).write(to: session.appendingPathComponent("manifest.json"))
        try Data(repeating: 2, count: 900).write(to: frames.appendingPathComponent("001.png"))
        let outside = directory.appendingPathComponent("outside.mp4")
        try Data(repeating: 3, count: 8000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("linked.mp4"), withDestinationURL: outside)

        let result = try await AssetFileInfoLoader().load([session])

        XCTAssertEqual(result[session], .size(1300))
    }

    func testMissingFileIsExplicitlyUnavailableWhileOtherFilesStillLoad() async throws {
        let directory = try temporaryDirectory()
        let missing = directory.appendingPathComponent("deleted.png")
        let existing = directory.appendingPathComponent("existing.png")
        try Data(repeating: 1, count: 11).write(to: existing)

        let result = try await AssetFileInfoLoader().load([missing, existing])

        guard case .unavailable(let message) = result[missing] else {
            return XCTFail("A missing file must not be represented by a zero-byte size")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(result[missing]?.byteCount)
        XCTAssertEqual(result[existing], .size(11))
    }

    func testExplicitInvalidationRefreshesChangedFileAndPrunesRemovedEntries() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("recording.mp4")
        let removed = directory.appendingPathComponent("removed.png")
        try Data(repeating: 1, count: 10).write(to: file)
        try Data(repeating: 2, count: 20).write(to: removed)
        let loader = AssetFileInfoLoader()
        let first = try await loader.load([file, removed])
        XCTAssertEqual(first[file], .size(10))
        try Data(repeating: 3, count: 300).write(to: file)

        await loader.invalidate([file])
        let refreshed = try await loader.load([file])

        XCTAssertEqual(refreshed[file], .size(300))
        XCTAssertNil(refreshed[removed])
    }

    func testSizeSortIsStableAndKeepsUnavailableItemsLastInBothDirections() {
        let files = ["small", "missing", "large", "equal", "unknown"]
        let bytes: [String: Int64] = ["small": 20, "large": 900, "equal": 20]

        XCTAssertEqual(AssetSortOrder.sizeAscending.sorted(files, date: { _ in XCTFail("Size sorting must not read dates"); return nil }, size: { bytes[$0] }, name: { _ in XCTFail("Size sorting must not read names"); return "" }),
                       ["small", "equal", "large", "missing", "unknown"])
        XCTAssertEqual(AssetSortOrder.sizeDescending.sorted(files, date: { _ in XCTFail("Size sorting must not read dates"); return nil }, size: { bytes[$0] }, name: { _ in XCTFail("Size sorting must not read names"); return "" }),
                       ["large", "small", "equal", "missing", "unknown"])
    }

    func testTimeSortUsesActualDatesWithStableTiesAndUnavailableItemsLast() {
        let files = ["middle", "missing", "new", "old", "equal", "unknown"]
        let dates: [String: Date] = [
            "middle": Date(timeIntervalSince1970: 200),
            "new": Date(timeIntervalSince1970: 300),
            "old": Date(timeIntervalSince1970: 100),
            "equal": Date(timeIntervalSince1970: 200)
        ]

        XCTAssertEqual(AssetSortOrder.newest.sorted(files, date: { dates[$0] }, size: { _ in XCTFail("Time sorting must not read sizes"); return nil }, name: { _ in XCTFail("Time sorting must not read names"); return "" }),
                       ["new", "middle", "equal", "old", "missing", "unknown"])
        XCTAssertEqual(AssetSortOrder.oldest.sorted(files, date: { dates[$0] }, size: { _ in XCTFail("Time sorting must not read sizes"); return nil }, name: { _ in XCTFail("Time sorting must not read names"); return "" }),
                       ["old", "middle", "equal", "new", "missing", "unknown"])
    }

    func testNameSortUsesNaturalNumericOrderAndKeepsEqualNamesStableInBothDirections() {
        let files = [(id: "ten", name: "Frame 10.png"),
                     (id: "two", name: "Frame 2.png"),
                     (id: "equal", name: "Frame 2.png"),
                     (id: "one", name: "Frame 1.png")]
        let date: ((id: String, name: String)) -> Date? = { _ in
            XCTFail("Name sorting must not read dates")
            return nil
        }
        let size: ((id: String, name: String)) -> Int64? = { _ in
            XCTFail("Name sorting must not read sizes")
            return nil
        }

        XCTAssertEqual(AssetSortOrder.nameAscending.sorted(files, date: date, size: size, name: { $0.name }).map(\.id),
                       ["one", "two", "equal", "ten"])
        XCTAssertEqual(AssetSortOrder.nameDescending.sorted(files, date: date, size: size, name: { $0.name }).map(\.id),
                       ["ten", "two", "equal", "one"])
    }

    func testCreationDatesAreOptInAndReadTheRootFileOrSession() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("recording.mp4")
        let session = directory.appendingPathComponent("session")
        try Data(repeating: 1, count: 42).write(to: file)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        let frame = session.appendingPathComponent("frame.png")
        try Data(repeating: 2, count: 19).write(to: frame)
        let fileDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionDate = Date(timeIntervalSince1970: 1_710_000_000)
        try FileManager.default.setAttributes([.creationDate: fileDate], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.creationDate: sessionDate], ofItemAtPath: session.path)
        let loader = AssetFileInfoLoader()

        _ = try await loader.load([file, session])
        let initiallyLoaded = await loader.creationDates
        XCTAssertTrue(initiallyLoaded.isEmpty)
        let sizes = try await loader.load([file, session], includingCreationDates: true)
        let dates = await loader.creationDates

        XCTAssertEqual(sizes[file], .size(42))
        XCTAssertEqual(sizes[session], .size(19))
        XCTAssertEqual(dates[file], fileDate)
        XCTAssertEqual(dates[session], sessionDate)
        XCTAssertNil(dates[frame])
    }

    func testCreationDateCacheInvalidatesAndPrunesWithFileInfo() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("recording.mp4")
        let removed = directory.appendingPathComponent("removed.mp4")
        try Data([1]).write(to: file)
        try Data([2]).write(to: removed)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = Date(timeIntervalSince1970: 1_710_000_000)
        try FileManager.default.setAttributes([.creationDate: originalDate], ofItemAtPath: file.path)
        let loader = AssetFileInfoLoader()
        _ = try await loader.load([file, removed], includingCreationDates: true)
        try FileManager.default.setAttributes([.creationDate: updatedDate], ofItemAtPath: file.path)

        _ = try await loader.load([file, removed], includingCreationDates: true)
        let cachedDates = await loader.creationDates
        XCTAssertEqual(cachedDates[file], originalDate)
        await loader.invalidate([file])
        let invalidatedDates = await loader.creationDates
        XCTAssertNil(invalidatedDates[file])
        _ = try await loader.load([file], includingCreationDates: true)
        let refreshedDates = await loader.creationDates

        XCTAssertEqual(refreshedDates[file], updatedDate)
        XCTAssertNil(refreshedDates[removed])
    }

    func testCreationDateFailureIsVisibleWithoutBlockingOtherFilesAndCanBeRetried() async throws {
        let directory = try temporaryDirectory()
        let missing = directory.appendingPathComponent("missing.mp4")
        let existing = directory.appendingPathComponent("existing.mp4")
        try Data([1, 2]).write(to: existing)
        let loader = AssetFileInfoLoader()
        let first = try await loader.load([missing, existing], includingCreationDates: true)
        let firstDates = await loader.creationDates
        guard case .unavailable(let message) = first[missing] else {
            return XCTFail("The failed date lookup must remain visible on this file")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(firstDates[missing])
        XCTAssertEqual(first[existing], .size(2))
        XCTAssertNotNil(firstDates[existing])
        try Data([1]).write(to: missing)
        await loader.invalidate([missing])
        let sizes = try await loader.load([missing], includingCreationDates: true)
        let dates = await loader.creationDates
        XCTAssertEqual(sizes[missing], .size(1))
        XCTAssertNotNil(dates[missing])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
