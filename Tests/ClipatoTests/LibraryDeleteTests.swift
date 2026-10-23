import AppKit
import Combine
import CSQLite
import XCTest
@testable import Clipato

@MainActor
final class LibraryDeleteTests: XCTestCase {
    func testBatchDeletePublishesImagesAndCollectionMembershipOnce() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let collection = try library.createCollection(name: "素材")
        let items = try makeImages(4, in: library, collectionID: collection.id)
        let other = try library.createCollection(name: "备选")
        try library.addToCollection(other.id, assets: [.image(items[0].id), .image(items[3].id)])
        let originalURLs = items.map(library.imageURL)
        let bytes = try originalURLs.map { try Data(contentsOf: $0) }
        var imageUpdates: [[VaultImage]] = []
        var memberUpdates: [[UUID: Set<CollectionAsset>]] = []
        let imageSubscription = library.$images.dropFirst().sink { imageUpdates.append($0) }
        let memberSubscription = library.$collectionMembers.dropFirst().sink { memberUpdates.append($0) }
        defer { imageSubscription.cancel(); memberSubscription.cancel() }

        try library.delete([items[0], items[1], items[0], items[2]])

        XCTAssertEqual(imageUpdates, [[items[3]]])
        XCTAssertEqual(memberUpdates.count, 1)
        XCTAssertEqual(library.assets(in: collection.id), [.image(items[3].id)])
        XCTAssertEqual(library.assets(in: other.id), [.image(items[3].id)])
        let reopened = try LibraryStore(root: library.root)
        XCTAssertEqual(reopened.images, [items[3]])
        XCTAssertEqual(reopened.collectionMembers, library.collectionMembers)
        for index in 0..<3 {
            XCTAssertFalse(FileManager.default.fileExists(atPath: originalURLs[index].path))
            XCTAssertEqual(try Data(contentsOf: trashedURL(for: items[index], in: directory)), bytes[index])
        }
        XCTAssertEqual(try Data(contentsOf: originalURLs[3]), bytes[3])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).count, 3)
    }

    func testSecondTrashFailurePublishesEarlierSuccessAndLeavesRemainingFilesUntouched() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let collection = try library.createCollection(name: "素材")
        let items = try makeImages(3, in: library, collectionID: collection.id)
        let originalURLs = items.map(library.imageURL)
        let bytes = try originalURLs.map { try Data(contentsOf: $0) }
        let occupied = directory.appendingPathComponent("Trash").appendingPathComponent(items[1].id.uuidString)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let marker = occupied.appendingPathComponent("existing-file")
        try Data([9, 8, 7]).write(to: marker)
        var imageUpdates: [[VaultImage]] = []
        var memberUpdates: [[UUID: Set<CollectionAsset>]] = []
        let imageSubscription = library.$images.dropFirst().sink { imageUpdates.append($0) }
        let memberSubscription = library.$collectionMembers.dropFirst().sink { memberUpdates.append($0) }
        defer { imageSubscription.cancel(); memberSubscription.cancel() }

        XCTAssertThrowsError(try library.delete(items)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }

        XCTAssertEqual(imageUpdates.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(imageUpdates.first).map(\.id)), [items[1].id, items[2].id])
        XCTAssertEqual(memberUpdates.count, 1)
        XCTAssertEqual(library.assets(in: collection.id), [.image(items[1].id), .image(items[2].id)])
        let reopened = try LibraryStore(root: library.root)
        XCTAssertEqual(Set(reopened.images.map(\.id)), [items[1].id, items[2].id])
        XCTAssertEqual(reopened.collectionMembers, library.collectionMembers)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURLs[0].path))
        XCTAssertEqual(try Data(contentsOf: trashedURL(for: items[0], in: directory)), bytes[0])
        for index in 1..<3 { XCTAssertEqual(try Data(contentsOf: originalURLs[index]), bytes[index]) }
        XCTAssertEqual(try Data(contentsOf: marker), Data([9, 8, 7]))
    }

    func testSecondIndexFailureRestoresThatFileAndPublishesEarlierSuccessOnce() throws {
        let directory = try temporaryDirectory()
        let library = try makeLibrary(in: directory)
        let collection = try library.createCollection(name: "素材")
        let items = try makeImages(3, in: library, collectionID: collection.id)
        let originalURLs = items.map(library.imageURL)
        let bytes = try originalURLs.map { try Data(contentsOf: $0) }
        try rejectDeletion(of: items[1].id, root: library.root)
        var imageUpdates: [[VaultImage]] = []
        var memberUpdates: [[UUID: Set<CollectionAsset>]] = []
        let imageSubscription = library.$images.dropFirst().sink { imageUpdates.append($0) }
        let memberSubscription = library.$collectionMembers.dropFirst().sink { memberUpdates.append($0) }
        defer { imageSubscription.cancel(); memberSubscription.cancel() }

        XCTAssertThrowsError(try library.delete(items)) { error in
            XCTAssertTrue(error.localizedDescription.contains("delete denied"))
        }

        XCTAssertEqual(imageUpdates.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(imageUpdates.first).map(\.id)), [items[1].id, items[2].id])
        XCTAssertEqual(memberUpdates.count, 1)
        XCTAssertEqual(library.assets(in: collection.id), [.image(items[1].id), .image(items[2].id)])
        let reopened = try LibraryStore(root: library.root)
        XCTAssertEqual(Set(reopened.images.map(\.id)), [items[1].id, items[2].id])
        XCTAssertEqual(reopened.collectionMembers, library.collectionMembers)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURLs[0].path))
        XCTAssertEqual(try Data(contentsOf: trashedURL(for: items[0], in: directory)), bytes[0])
        for index in 1..<3 { XCTAssertEqual(try Data(contentsOf: originalURLs[index]), bytes[index]) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path), [items[0].id.uuidString])
    }

    func testFailedRestorationRetainsTheIndexErrorAndTheTrashedBytes() throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let library = try LibraryStore(root: root, trashImageDirectory: { source in
            guard source.path.hasPrefix(root.path + "/Images/") else { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            // Reproduce a competing writer recreating the original directory before restoration.
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            return destination
        })
        let collection = try library.createCollection(name: "素材")
        let item = try XCTUnwrap(makeImages(1, in: library, collectionID: collection.id).first)
        let bytes = try Data(contentsOf: library.imageURL(item))
        try rejectDeletion(of: item.id, root: root)
        var imageUpdates: [[VaultImage]] = []
        let imageSubscription = library.$images.dropFirst().sink { imageUpdates.append($0) }
        defer { imageSubscription.cancel() }

        XCTAssertThrowsError(try library.delete([item])) { error in
            guard case KeyframeRecordingError.multipleFailures(let original, let rollback) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(original.localizedDescription.contains("delete denied"))
            XCTAssertEqual((rollback as? CocoaError)?.code, .fileWriteFileExists)
        }

        XCTAssertTrue(imageUpdates.isEmpty)
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(library.assets(in: collection.id), [.image(item.id)])
        let reopened = try LibraryStore(root: root)
        XCTAssertEqual(reopened.images, [item])
        XCTAssertEqual(reopened.collectionMembers, library.collectionMembers)
        XCTAssertEqual(try Data(contentsOf: trashedURL(for: item, in: directory)), bytes)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-LibraryDelete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
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

    private func makeImages(_ count: Int, in library: LibraryStore, collectionID: UUID) throws -> [VaultImage] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        return try (0..<count).map { _ in try library.addImage(image, source: "截图", tag: .green, collectionID: collectionID) }
    }

    private func trashedURL(for item: VaultImage, in directory: URL) -> URL {
        directory.appendingPathComponent("Trash").appendingPathComponent(item.id.uuidString).appendingPathComponent(item.filename)
    }

    private func rejectDeletion(of id: UUID, root: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "CREATE TRIGGER reject_delete BEFORE DELETE ON images WHEN OLD.id = '\(id.uuidString)' BEGIN SELECT RAISE(ABORT, 'delete denied'); END"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw LibraryDatabaseError(message: String(cString: sqlite3_errmsg(database)))
        }
    }
}
