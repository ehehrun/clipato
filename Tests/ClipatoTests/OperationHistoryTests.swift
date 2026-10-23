import AppKit
import XCTest
@testable import Clipato

@MainActor
final class OperationHistoryTests: XCTestCase {
    func testClearingPersistsWithoutChangingImagesCollectionsTagsOrFiles() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let collection = try library.createCollection(name: "保留的收藏夹")
        let first = try library.addImage(pixels(), source: "截图", filename: "first.png", tag: .purple, collectionID: collection.id)
        let second = try library.addImage(pixels(), source: "截图", filename: "second.png", tag: .green, collectionID: collection.id)
        let images = library.images
        let collections = library.collections
        let members = library.collectionMembers
        let policy = library.storagePolicy
        let files = try [first, second].map { (library.imageURL($0), try Data(contentsOf: library.imageURL($0))) }
        XCTAssertEqual(try library.recentImage(), second)

        try library.clearOperationHistory()
        try library.clearOperationHistory()

        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(library.images, images)
        XCTAssertEqual(library.collections, collections)
        XCTAssertEqual(library.collectionMembers, members)
        XCTAssertEqual(library.storagePolicy, policy)
        let reopened = try LibraryStore(root: library.root)
        XCTAssertNil(try reopened.recentImage())
        XCTAssertEqual(reopened.images, images)
        XCTAssertEqual(reopened.collections, collections)
        XCTAssertEqual(reopened.collectionMembers, members)
        XCTAssertEqual(reopened.storagePolicy, policy)
        for (url, bytes) in files { XCTAssertEqual(try Data(contentsOf: url), bytes) }
    }

    func testNewImageAndImportStartFreshHistoryAfterClearing() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        _ = try library.addImage(pixels(), source: "截图")
        try library.clearOperationHistory()

        let fresh = try library.addImage(pixels(), source: "拼图", filename: "fresh.png")
        XCTAssertEqual(try library.recentImage(), fresh)
        try library.clearOperationHistory()
        let input = directory.appendingPathComponent("external.png")
        try LibraryStore.writePNG(pixels(), to: input)
        let bytes = try Data(contentsOf: input)
        try library.importImages([input])

        let imported = try XCTUnwrap(library.recentImage())
        XCTAssertEqual(imported.filename, "external.png")
        XCTAssertEqual(imported.source, "导入")
        XCTAssertNotEqual(imported.id, fresh.id)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(imported)), bytes)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try LibraryStore(root: library.root).recentImage(), imported)
    }

    func testRememberingOlderImageFollowsRenameWithoutChangingAssetOrder() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let older = try library.addImage(pixels(), source: "截图", filename: "older.png", tag: .orange)
        let latest = try library.addImage(pixels(), source: "截图", filename: "latest.png")
        let bytes = try Data(contentsOf: library.imageURL(older))
        try library.clearOperationHistory()

        try library.rememberImage(older.id)
        XCTAssertEqual(try library.recentImage(), older)
        XCTAssertEqual(library.images.map(\.id), [latest.id, older.id])
        try library.rename(older, to: "renamed")

        let remembered = try XCTUnwrap(library.recentImage())
        XCTAssertEqual(remembered.id, older.id)
        XCTAssertEqual(remembered.filename, "renamed.png")
        XCTAssertEqual(remembered.tag, .orange)
        XCTAssertEqual(library.images.map(\.id), [latest.id, older.id])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(remembered)), bytes)
        XCTAssertEqual(try LibraryStore(root: library.root).recentImage(), remembered)
    }

    func testDeletingRememberedImageDoesNotFallBackToAnOlderImage() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let older = try library.addImage(pixels(), source: "截图", filename: "older.png")
        let latest = try library.addImage(pixels(), source: "截图", filename: "latest.png")
        let originalBytes = try Data(contentsOf: library.imageURL(older))

        try library.delete([latest])

        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(library.images, [older])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(older)), originalBytes)
        let reopened = try LibraryStore(root: library.root)
        XCTAssertNil(try reopened.recentImage())
        XCTAssertEqual(reopened.images, [older])
        try library.rememberImage(older.id)
        XCTAssertEqual(try library.recentImage(), older)
    }

    func testRecentImageObservesOtherConnectionsInsertsClearsAndRememberedChoices() throws {
        let directory = try temporaryDirectory()
        let reader = try makeLibrary(in: directory)
        let older = try reader.addImage(pixels(), source: "截图", filename: "older.png")
        let writer = try LibraryStore(root: reader.root)

        let latest = try writer.addImage(pixels(), source: "截图", filename: "latest.png")
        XCTAssertEqual(try reader.recentImage(), latest)
        XCTAssertEqual(reader.images.map(\.id), [latest.id, older.id])
        try writer.clearOperationHistory()
        XCTAssertNil(try reader.recentImage())
        try reader.rememberImage(older.id)
        XCTAssertEqual(try writer.recentImage(), older)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-OperationHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeLibrary(in directory: URL) throws -> LibraryStore {
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        return try LibraryStore(root: directory.appendingPathComponent("Vault"), trashImageDirectory: { source in
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
