import AppKit
import CSQLite
import XCTest
@testable import Clipato

@MainActor
final class BatchRenameTests: XCTestCase {
    func testNumberingFollowsInputOrderAndKeepsOriginalExtensions() throws {
        let urls = ["last.PNG", "first.jpeg", "middle.mp4", "no-extension"].map { URL(fileURLWithPath: "/tmp/" + $0) }
        let rule = BatchRenameRule(prefix: "旅行_", start: 7, increment: 3, digits: 4)
        XCTAssertEqual(try rule.filenames(for: urls), ["旅行_0007.PNG", "旅行_0010.jpeg", "旅行_0013.mp4", "旅行_0016"])
        XCTAssertEqual(try BatchRenameRule(prefix: "", start: 0, increment: 1, digits: 0).filenames(for: urls), ["0.PNG", "1.jpeg", "2.mp4", "3"])
    }

    func testInvalidRulesFailBeforeProducingPartialNames() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        for prefix in ["folder/name", "bad:name", "bad\0name", "line\nname"] {
            XCTAssertThrowsError(try BatchRenameRule(prefix: prefix).filenames(for: urls))
        }
        for rule in [BatchRenameRule(start: -1), BatchRenameRule(increment: 0), BatchRenameRule(digits: -1), BatchRenameRule(digits: 20),
                     BatchRenameRule(start: Int.max), BatchRenameRule(prefix: String(repeating: "x", count: 255))] {
            XCTAssertThrowsError(try rule.filenames(for: urls))
        }
        XCTAssertEqual(try BatchRenameRule(start: Int.max, digits: 0).filenames(for: [urls[0]]), ["Frame_\(Int.max).png"])
    }

    func testMixedKeyframeDuplicateAndSingleSelectionsAreRejectedWithoutTouchingFiles() throws {
        let library = try makeLibrary()
        let image = try library.addImage(pixels(red: 0.3), source: "截图")
        let video = try addVideo(to: library, bytes: Data([1, 2, 3]))
        try library.reloadSessions()
        let before = try Data(contentsOf: library.imageURL(image))
        for assets in [[.image(image.id)], [.image(image.id), .image(image.id)], [.image(image.id), .video(video)],
                       [.session(UUID()), .session(UUID())], [.session(UUID()), .video(video)]] as [[CollectionAsset]] {
            XCTAssertFalse(BatchRenameRule.supports(assets))
            XCTAssertThrowsError(try library.batchRenameURLs(for: assets))
            XCTAssertThrowsError(try library.batchRename(assets, rule: .init()))
        }
        XCTAssertEqual(try Data(contentsOf: library.imageURL(image)), before)
        XCTAssertEqual(try Data(contentsOf: video), Data([1, 2, 3]))
    }

    func testImagesRenameInCallerOrderAndKeepIDsCollectionsTagsAndBytesAcrossReopen() throws {
        let library = try makeLibrary()
        let collection = try library.createCollection(name: "素材")
        let first = try library.addImage(pixels(red: 0.2), source: "截图", tag: .orange, collectionID: collection.id)
        let second = try library.addImage(pixels(red: 0.8), source: "标注", tag: .purple, collectionID: collection.id)
        let ordered = [second, first]
        let urls = ordered.map(library.imageURL)
        let bytes = try urls.map { try Data(contentsOf: $0) }
        let assets = ordered.map { CollectionAsset.image($0.id) }
        let step = BatchRenameStep(assets: assets, rule: .init(prefix: "Capture_", start: 9, increment: 2, digits: 3))
        let before = library.images

        let preview = try step.preview(in: library)

        XCTAssertEqual(preview.urls, urls)
        XCTAssertEqual(preview.filenames, ["Capture_009.png", "Capture_011.png"])
        XCTAssertEqual(library.images, before)
        XCTAssertEqual(try LibraryStore(root: library.root).images, before)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try step.execute(in: library), assets)

        let reloaded = try LibraryStore(root: library.root)
        for (index, image) in ordered.enumerated() {
            var expected = image
            expected.filename = index == 0 ? "Capture_009.png" : "Capture_011.png"
            let actual = try XCTUnwrap(reloaded.images.first { $0.id == image.id })
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(reloaded.imageURL(actual).deletingLastPathComponent(), urls[index].deletingLastPathComponent())
            XCTAssertEqual(try Data(contentsOf: reloaded.imageURL(actual)), bytes[index])
            XCTAssertFalse(FileManager.default.fileExists(atPath: urls[index].path))
        }
        XCTAssertEqual(reloaded.assets(in: collection.id), Set(assets))
        XCTAssertEqual(reloaded.images, library.images)
    }

    func testExistingDestinationAbortsWholeBatchBeforeAnyMove() throws {
        let library = try makeLibrary()
        let first = try library.addImage(pixels(red: 0.2), source: "截图")
        let second = try library.addImage(pixels(red: 0.8), source: "截图")
        let before = library.images
        let urls = [first, second].map(library.imageURL)
        let bytes = try urls.map { try Data(contentsOf: $0) }
        let occupied = urls[1].deletingLastPathComponent().appendingPathComponent("Frame_002.png")
        try Data([9, 8, 7]).write(to: occupied)

        XCTAssertThrowsError(try library.batchRename([.image(first.id), .image(second.id)], rule: .init())) { error in
            guard case BatchRenameError.existingFile(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, occupied)
        }

        XCTAssertEqual(library.images, before)
        XCTAssertEqual(try LibraryStore(root: library.root).images, before)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try Data(contentsOf: occupied), Data([9, 8, 7]))
    }

    func testImageDatabaseFailureRollsBackEveryFilenameAndStagedFile() throws {
        let library = try makeLibrary()
        let first = try library.addImage(pixels(red: 0.2), source: "截图")
        let second = try library.addImage(pixels(red: 0.8), source: "截图")
        let before = library.images
        let urls = [first, second].map(library.imageURL)
        let bytes = try urls.map { try Data(contentsOf: $0) }
        try executeSQL("CREATE TRIGGER reject_rename BEFORE UPDATE OF filename ON images WHEN OLD.id = '\(second.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'rename denied'); END", root: library.root)

        let step = BatchRenameStep(assets: [.image(first.id), .image(second.id)], rule: .init())
        XCTAssertThrowsError(try step.execute(in: library)) { error in
            XCTAssertTrue(error.localizedDescription.contains("rename denied"))
        }

        XCTAssertEqual(library.images, before)
        XCTAssertEqual(try LibraryStore(root: library.root).images, before)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, bytes)
        for url in urls {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), [url.lastPathComponent])
        }
    }

    func testSelectedImagesCanExchangeFilenamesInsideTheSameDirectory() throws {
        let library = try makeLibrary()
        let first = try library.addImage(pixels(red: 0.2), source: "截图", filename: "Frame_002.png")
        let second = try library.addImage(pixels(red: 0.8), source: "截图", filename: "Frame_001.png")
        let shared = library.root.appendingPathComponent("Shared Images")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        let originals = [first, second]
        let bytes = try originals.map { try Data(contentsOf: library.imageURL($0)) }
        for image in originals {
            let oldURL = library.imageURL(image)
            try FileManager.default.moveItem(at: oldURL, to: shared.appendingPathComponent(image.filename))
            try FileManager.default.removeItem(at: oldURL.deletingLastPathComponent())
            try executeSQL("UPDATE images SET directory = '\(shared.absoluteString)' WHERE id = '\(image.id.uuidString)'", root: library.root)
        }
        try library.reloadImages()

        try library.batchRename(originals.map { .image($0.id) }, rule: .init())

        let reloaded = try LibraryStore(root: library.root)
        for (index, image) in originals.enumerated() {
            let actual = try XCTUnwrap(reloaded.images.first { $0.id == image.id })
            XCTAssertEqual(actual.filename, index == 0 ? "Frame_001.png" : "Frame_002.png")
            XCTAssertEqual(try Data(contentsOf: reloaded.imageURL(actual)), bytes[index])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shared.path).sorted(), ["Frame_001.png", "Frame_002.png"])
    }

    func testVideoRenameKeepsEveryCollectionDirectoryAndTagAcrossReload() throws {
        let library = try makeLibrary()
        let first = try addVideo(to: library, bytes: Data([1, 2, 3]), tag: .blue)
        let second = try addVideo(to: library, bytes: Data([4, 5, 6]), tag: .orange)
        try library.reloadSessions()
        let firstCollection = try library.createCollection(name: "项目")
        let secondCollection = try library.createCollection(name: "备选")
        try library.addToCollection(firstCollection.id, assets: [.video(first), .video(second)])
        try library.addToCollection(secondCollection.id, assets: [.video(first)])
        let assets: [CollectionAsset] = [.video(second), .video(first)]

        let step = BatchRenameStep(assets: assets, rule: .init(prefix: "Video_", start: 3, increment: 2, digits: 2))
        let preview = try step.preview(in: library)
        XCTAssertEqual(preview.urls, [second, first])
        XCTAssertEqual(preview.filenames, ["Video_03.mp4", "Video_05.mp4"])
        let renamed = try step.execute(in: library)

        let newSecond = second.deletingLastPathComponent().appendingPathComponent("Video_03.mp4")
        let newFirst = first.deletingLastPathComponent().appendingPathComponent("Video_05.mp4")
        XCTAssertEqual(renamed, [.video(newSecond), .video(newFirst)])
        XCTAssertEqual(try Data(contentsOf: newFirst), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: newSecond), Data([4, 5, 6]))
        let reloaded = try LibraryStore(root: library.root)
        XCTAssertEqual(Set(reloaded.videos), [newFirst, newSecond])
        XCTAssertEqual(reloaded.recordingTags[first.deletingLastPathComponent()], .blue)
        XCTAssertEqual(reloaded.recordingTags[second.deletingLastPathComponent()], .orange)
        XCTAssertEqual(reloaded.assets(in: firstCollection.id), [.video(newFirst), .video(newSecond)])
        XCTAssertEqual(reloaded.assets(in: secondCollection.id), [.video(newFirst)])
        XCTAssertEqual(reloaded.collectionMembers, library.collectionMembers)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testVideoDatabaseFailureRestoresFilesAndCollectionReferencesTogether() throws {
        let library = try makeLibrary()
        let first = try addVideo(to: library, bytes: Data([1]), tag: .blue)
        let second = try addVideo(to: library, bytes: Data([2]), tag: .purple)
        try library.reloadSessions()
        let collection = try library.createCollection(name: "录屏")
        let assets: Set<CollectionAsset> = [.video(first), .video(second)]
        try library.addToCollection(collection.id, assets: assets)
        try executeSQL("CREATE TRIGGER reject_video_rename BEFORE UPDATE OF videoURL ON collectionMembers WHEN OLD.videoURL = '\(second.absoluteString)' BEGIN SELECT RAISE(ABORT, 'video rename denied'); END", root: library.root)

        XCTAssertThrowsError(try library.batchRename([.video(first), .video(second)], rule: .init()))

        let reloaded = try LibraryStore(root: library.root)
        XCTAssertEqual(Set(reloaded.videos), [first, second])
        XCTAssertEqual(library.assets(in: collection.id), assets)
        XCTAssertEqual(reloaded.assets(in: collection.id), assets)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
        for url in [first, second] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted(), [".framevault-tag", "recording.mp4"])
        }
    }

    func testDotPrefixedVideosRemainDiscoverableAndCollectedAcrossReopen() throws {
        let library = try makeLibrary()
        let first = try addVideo(to: library, bytes: Data([1, 2]), tag: .green)
        let second = try addVideo(to: library, bytes: Data([3, 4]), tag: .purple)
        try library.reloadSessions()
        let collection = try library.createCollection(name: "录屏")
        try library.addToCollection(collection.id, assets: [.video(first), .video(second)])

        let renamed = try library.batchRename([.video(first), .video(second)], rule: .init(prefix: ".Clip_", digits: 2))

        let destinations = [first, second].enumerated().map { index, url in
            url.deletingLastPathComponent().appendingPathComponent(".Clip_0\(index + 1).mp4")
        }
        XCTAssertEqual(renamed, destinations.map(CollectionAsset.video))
        try library.reloadSessions()
        XCTAssertEqual(Set(library.videos), Set(destinations))
        let reopened = try LibraryStore(root: library.root)
        XCTAssertEqual(Set(reopened.videos), Set(destinations))
        XCTAssertEqual(reopened.assets(in: collection.id), Set(destinations.map(CollectionAsset.video)))
        XCTAssertEqual(reopened.recordingTags[first.deletingLastPathComponent()], .green)
        XCTAssertEqual(reopened.recordingTags[second.deletingLastPathComponent()], .purple)
        XCTAssertEqual(try Data(contentsOf: destinations[0]), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: destinations[1]), Data([3, 4]))
    }

    func testVideoDiscoveryRejectsAmbiguousDirectoryInsteadOfPickingAFilename() throws {
        let library = try makeLibrary()
        let original = try addVideo(to: library, bytes: Data([1]))
        try library.reloadSessions()
        try Data([2]).write(to: original.deletingLastPathComponent().appendingPathComponent("other.mp4"))

        XCTAssertThrowsError(try library.reloadSessions()) { error in
            guard case BatchRenameError.multipleVideos(let directory) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(directory, original.deletingLastPathComponent())
        }
        XCTAssertEqual(library.videos, [original])
    }

    func testStepRejectsMissingAssetsWithoutChangingExistingFiles() throws {
        let library = try makeLibrary()
        let image = try library.addImage(pixels(red: 0.3), source: "截图")
        let url = library.imageURL(image)
        let bytes = try Data(contentsOf: url)
        let step = BatchRenameStep(assets: [.image(image.id), .image(UUID())], rule: .init())

        XCTAssertThrowsError(try step.preview(in: library)) { error in
            guard case CollectionError.missingAsset = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try step.execute(in: library)) { error in
            guard case CollectionError.missingAsset = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(try LibraryStore(root: library.root).images, [image])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testVideoDiscoveryExcludesOnlyTheReservedPartialFilename() throws {
        let library = try makeLibrary()
        let original = try addVideo(to: library, bytes: Data([1, 2, 3]), tag: .green)
        let finalized = original.deletingLastPathComponent().appendingPathComponent(".recording.partial-01.mp4")
        try FileManager.default.moveItem(at: original, to: finalized)
        let partial = finalized.deletingLastPathComponent().appendingPathComponent(".recording.partial.mp4")
        let partialBytes = Data("pending encoder output".utf8)
        try partialBytes.write(to: partial)
        let pendingDirectory = try library.newRecordingDirectory()
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: false)
        let pendingOnly = pendingDirectory.appendingPathComponent(".recording.partial.mp4")
        try partialBytes.write(to: pendingOnly)

        try library.reloadSessions()

        XCTAssertEqual(library.videos, [finalized])
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertTrue(library.recordingReadErrors.isEmpty)
        let reopened = try LibraryStore(root: library.root)
        XCTAssertEqual(reopened.videos, [finalized])
        XCTAssertEqual(reopened.recordingTags[finalized.deletingLastPathComponent()], .green)
        XCTAssertEqual(try Data(contentsOf: finalized), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
        XCTAssertEqual(try Data(contentsOf: pendingOnly), partialBytes)
    }

    private func makeLibrary() throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-BatchRename-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try LibraryStore(root: root)
    }

    private func addVideo(to library: LibraryStore, bytes: Data, tag: AssetTag? = nil) throws -> URL {
        let directory = try library.newRecordingDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("recording.mp4")
        try bytes.write(to: url)
        if let tag { try library.setRecordingTag(tag, for: directory) }
        return url
    }

    private func executeSQL(_ sql: String, root: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw LibraryDatabaseError(message: String(cString: sqlite3_errmsg(database))) }
    }

    private func pixels(red: Double) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
